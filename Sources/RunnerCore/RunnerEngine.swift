import Foundation

public enum LibTVCommandBuilderError: Error, Equatable, LocalizedError, Sendable {
    case missingArguments
    case nonStringArgument
    case structuredPreparerRequired
    case missingExecutionLayout

    public var errorDescription: String? {
        switch self {
        case .missingArguments: "Job payload.arguments is missing or empty."
        case .nonStringArgument: "Every payload.arguments entry must be a string."
        case .structuredPreparerRequired: "Production generation requires LibTVGenerationSpecV1 and a structured preparer; payload.arguments is rejected."
        case .missingExecutionLayout:
            "A known LibTV task cannot be queried because its execution layout is missing."
        }
    }
}

public struct RejectingLibTVCommandBuilder: LibTVCommandBuilding, Sendable {
    public init() { }
    public func submissionArguments(for job: RunnerJob) throws -> [String] {
        throw LibTVCommandBuilderError.structuredPreparerRequired
    }
    public func queryArguments(remoteTaskID: String, for job: RunnerJob) throws -> [String] {
        throw LibTVCommandBuilderError.missingExecutionLayout
    }
}

public protocol LibTVCommandBuilding: Sendable {
    func submissionArguments(for job: RunnerJob) throws -> [String]
    func queryArguments(remoteTaskID: String, for job: RunnerJob) throws -> [String]
}

/// Legacy/test-only adapter for the pre-v1.1 payload contract. Production uses
/// `RejectingLibTVCommandBuilder` plus `LibTVGenerationPreparer`; this type is never a default.
public struct PayloadArgumentsCommandBuilder: LibTVCommandBuilding, Sendable {
    public let queryPrefix: [String]?

    public init(queryPrefix: [String]? = nil) {
        self.queryPrefix = queryPrefix
    }

    public func submissionArguments(for job: RunnerJob) throws -> [String] {
        guard let raw = job.payload["arguments"]?.arrayValue, !raw.isEmpty else {
            throw LibTVCommandBuilderError.missingArguments
        }
        let arguments = raw.compactMap(\.stringValue)
        guard arguments.count == raw.count else { throw LibTVCommandBuilderError.nonStringArgument }
        return arguments
    }

    public func queryArguments(remoteTaskID: String, for job: RunnerJob) throws -> [String] {
        guard let queryPrefix else { throw LibTVCommandBuilderError.missingExecutionLayout }
        return queryPrefix + [remoteTaskID]
    }
}

public struct RunnerEngineSnapshot: Equatable, Sendable {
    public let state: RunnerServiceState
    public let paused: Bool
    public let registeredProfiles: Int
    public let globalMaxConcurrency: Int
    /// Job ID -> Profile reference.
    public let activeJobs: [String: String]
}

public enum RunnerEngineJobPhase: String, Equatable, Sendable {
    case leased
    case submitting
    case tracking
}

public enum RunnerEngineControlError: Error, Equatable, LocalizedError, Sendable {
    case jobNotActive
    case submissionAlreadyStarted
    case profileNotFound
    case invalidProfileConcurrency
    case invalidGlobalConcurrency

    public var errorDescription: String? {
        switch self {
        case .jobNotActive: "The job is not active on this Runner."
        case .submissionAlreadyStarted: "LibTV submission has started; use stop tracking instead of cancel."
        case .profileNotFound: "The Runner profile is not registered."
        case .invalidProfileConcurrency: "Profile concurrency must be between 0 and 8."
        case .invalidGlobalConcurrency: "Global concurrency must be between 1 and 8."
        }
    }
}

public actor RunnerEngine {
    private struct RegisteredProfile: Sendable {
        var metadata: RunnerProfile
        let executor: ProfileExecutor
        let submission: SubmissionExecutor
    }

    private struct ActiveJob: Sendable {
        let jobID: String
        let profileRef: String
        var remoteTaskID: String?
        var runtime: LibTVRuntimeIdentity?
        var seedanceCompliancePreflight: SeedanceCompliancePreflight?
    }

    private let api: any RunnerAPITransport
    private let journal: SubmissionJournal
    private let commandBuilder: any LibTVCommandBuilding
    private let generationPreparer: (any GenerationJobPreparing)?
    private let runtimeProvider: (any LibTVRuntimeProviding)?
    private let artifactArchiver: ArtifactArchiver
    private let hostname: String
    private let version: String
    private let pollInterval: Duration
    private let maximumPollCount: Int
    private let maximumTrackingDuration: Duration
    private let terminalConfirmationCount: Int
    private let preSubmissionDelay: Duration
    private var profiles: [String: RegisteredProfile] = [:]
    private var activeJobs: [String: ActiveJob] = [:]
    private var activeTasks: [String: Task<Void, Never>] = [:]
    private var activePhases: [String: RunnerEngineJobPhase] = [:]
    private var cancelledJobs = Set<String>()
    private var stoppedJobs = Set<String>()
    private var globalMaxConcurrency: Int
    private var paused = false
    private var runtimeMaintenance = false
    private var tickInProgress = false

    public init<API: RunnerAPITransport & ArtifactAPITransport>(
        api: API,
        journal: SubmissionJournal,
        commandBuilder: any LibTVCommandBuilding = RejectingLibTVCommandBuilder(),
        generationPreparer: (any GenerationJobPreparing)? = nil,
        runtimeProvider: (any LibTVRuntimeProviding)? = nil,
        artifactArchiver: ArtifactArchiver? = nil,
        globalMaxConcurrency: Int = 4,  // Default 4, synced from server configuration
        hostname: String = ProcessInfo.processInfo.hostName,
        version: String,
        pollInterval: Duration = .seconds(5),
        maximumPollCount: Int = 360,
        maximumTrackingDuration: Duration = .seconds(30 * 60),
        terminalConfirmationCount: Int = 3,
        preSubmissionDelay: Duration = .zero
    ) {
        self.api = api
        self.journal = journal
        self.commandBuilder = commandBuilder
        self.generationPreparer = generationPreparer
        self.runtimeProvider = runtimeProvider
        self.artifactArchiver = artifactArchiver ?? ArtifactArchiver(transport: api)
        self.globalMaxConcurrency = min(8, max(1, globalMaxConcurrency))
        self.hostname = hostname
        self.version = version
        self.pollInterval = pollInterval
        self.maximumPollCount = max(1, maximumPollCount)
        self.maximumTrackingDuration = maximumTrackingDuration
        self.terminalConfirmationCount = max(1, terminalConfirmationCount)
        self.preSubmissionDelay = preSubmissionDelay
    }

    public func register(profile: RunnerProfile, executor: ProfileExecutor) async {
        var profile = profile
        profile.maxConcurrency = min(8, max(0, profile.maxConcurrency))
        await executor.setMaxConcurrency(profile.maxConcurrency)
        profiles[profile.profileRef] = RegisteredProfile(
            metadata: profile,
            executor: executor,
            submission: SubmissionExecutor(profile: executor, journal: journal)
        )
    }

    public func unregister(profileRef: String) {
        guard !activeJobs.values.contains(where: { $0.profileRef == profileRef }) else { return }
        profiles.removeValue(forKey: profileRef)
    }

    /// Changes future claim capacity. Shrinking never interrupts active jobs; the profile drains
    /// naturally until its active count is at or below the new limit. Zero disables new claims.
    public func setProfileMaxConcurrency(_ maxConcurrency: Int, profileRef: String) async throws {
        guard (0...8).contains(maxConcurrency) else {
            throw RunnerEngineControlError.invalidProfileConcurrency
        }
        guard var registration = profiles[profileRef] else {
            throw RunnerEngineControlError.profileNotFound
        }
        registration.metadata.maxConcurrency = maxConcurrency
        profiles[profileRef] = registration
        // Existing remote lifecycles may still need short read-only node queries. Keep enough
        // process slots for those jobs while immediately preventing any new claims above.
        await registration.executor.setMaxConcurrency(
            max(maxConcurrency, activeJobCount(profileRef: profileRef))
        )
    }

    public func effectiveMaxConcurrency(profileRef: String) throws -> Int {
        guard let profile = profiles[profileRef]?.metadata else {
            throw RunnerEngineControlError.profileNotFound
        }
        return profile.enabled && profile.healthy ? profile.maxConcurrency : 0
    }

    /// Changes the number of remote job lifecycles this Runner may own at once. Shrinking is
    /// drain-only: active submissions and remote tracking continue, while new claims remain
    /// blocked until the active count falls below the configured limit.
    public func setGlobalMaxConcurrency(_ maxConcurrency: Int) throws {
        guard (1...8).contains(maxConcurrency) else {
            throw RunnerEngineControlError.invalidGlobalConcurrency
        }
        globalMaxConcurrency = maxConcurrency
    }

    public func configuredGlobalMaxConcurrency() -> Int {
        globalMaxConcurrency
    }

    public func maintenanceExecutors() -> [String: ProfileExecutor] {
        // A zero-capacity executor cannot acquire a CLI slot. Returning it here
        // would let housekeeping block the scheduler before schema refresh can run.
        profiles.filter { $0.value.metadata.maxConcurrency > 0 }.mapValues(\.executor)
    }

    public func synchronizeProfiles() async throws -> SyncProfilesResponse {
        try await api.syncProfiles(profiles.values.map(\.metadata).sorted {
            $0.profileRef < $1.profileRef
        })
    }

    public func beginRuntimeMaintenance() { runtimeMaintenance = true }
    public func endRuntimeMaintenance() { runtimeMaintenance = false }
    public func runtimeSwitchReady() -> Bool { runtimeMaintenance && !tickInProgress && activeJobs.isEmpty }

    public func pause() { paused = true }
    public func resume() { paused = false }

    public func snapshot() -> RunnerEngineSnapshot {
        RunnerEngineSnapshot(
            state: serviceState,
            paused: paused,
            registeredProfiles: profiles.count,
            globalMaxConcurrency: globalMaxConcurrency,
            activeJobs: Dictionary(uniqueKeysWithValues: activeJobs.values.map {
                ($0.jobID, $0.profileRef)
            })
        )
    }

    /// One scheduler cycle: heartbeat and commands always run; pause only suppresses new claims.
    public func tick() async throws {
        guard !tickInProgress else { return }
        tickInProgress = true
        defer { tickInProgress = false }
        let enabled = profiles.values.map(\.metadata).filter { $0.enabled && $0.healthy }
        let capabilities = Array(Set(enabled.flatMap(\.capabilities))).sorted()
        let runtimeHeartbeat = await runtimeProvider?.runtimeHeartbeat()
        let runtimeValidations = await runtimeProvider?.pendingRuntimeValidationReports() ?? []
        let heartbeat = try await api.heartbeat(RunnerHeartbeatRequest(
            state: serviceState,
            hostname: hostname,
            version: version,
            capabilities: capabilities,
            activeJobIDs: Array(activeJobs.keys).sorted(),
            activeJobs: activeJobs.values.map {
                RunnerActiveJobHeartbeat(
                    jobID: $0.jobID,
                    profileRef: $0.profileRef,
                    remoteTaskID: $0.remoteTaskID
                )
            }.sorted { $0.jobID < $1.jobID },
            globalMaxConcurrency: globalMaxConcurrency,
            runtimeVersion: runtimeHeartbeat?.active.version,
            runtimeSHA256: runtimeHeartbeat?.active.sha256,
            runtimePlatform: runtimeHeartbeat == nil ? nil : "macos-arm64",
            runtimeVerified: runtimeHeartbeat?.activeVerified,
            runnerProtocolVersion: runtimeHeartbeat?.protocolVersion,
            runtime: runtimeHeartbeat.map(RunnerRuntimeBundleHeartbeat.init(metadata:)),
            runtimeValidations: runtimeValidations
        ))
        if let acknowledgements = heartbeat.runtimeValidations {
            await runtimeProvider?.acknowledgeRuntimeValidationReports(acknowledgements)
        }
        // Sync global concurrency from server if different
        if let serverConcurrency = heartbeat.globalMaxConcurrency, serverConcurrency != globalMaxConcurrency {
            try? setGlobalMaxConcurrency(serverConcurrency)
        }
        let runtimeCommandBarrier = heartbeat.commands.contains {
            switch $0.kind {
            case .runtimeValidate, .runtimeActivate, .runtimeRollback: true
            default: false
            }
        }
        for command in heartbeat.commands {
            switch command.kind {
            case .refreshProfiles, .refreshInventory, .diagnostics, .healthCheck,
                 .runtimeDiscover, .runtimeValidate, .runtimeApprove, .runtimeActivate,
                 .runtimeRollback:
                continue
            default:
                break
            }
            await apply(command)
            try await api.acknowledge(
                commandID: command.id,
                acknowledgement: .init()
            )
        }
        // The server may queue canary jobs in the same transaction as runtime_validate. The Agent
        // stages/activates after this scheduler call, so claiming must wait until the next tick.
        guard !runtimeCommandBarrier else { return }
        guard !paused && !runtimeMaintenance else { return }

        for registration in enabled {
            var attempts = 0
            while attempts < 8 {
                guard !paused && !runtimeMaintenance, let current = profiles[registration.profileRef]?.metadata,
                      current.enabled, current.healthy else { break }
                guard activeJobs.count < globalMaxConcurrency else { break }
                let activeBeforeClaim = activeJobCount(profileRef: registration.profileRef)
                guard activeBeforeClaim < current.maxConcurrency else { break }
                attempts += 1
                let claim = try await api.claim(
                    profileRef: registration.profileRef,
                    capabilities: current.capabilities
                )
                guard let job = claim.job else { break }
                // A duplicate claim never creates a second local execution path.
                guard activeJobs[job.id] == nil else { break }

                // Actor reentrancy allows a concurrent settings update while Claim is in flight.
                // If capacity shrank (or the profile was disabled), release the still-leased job
                // before any local journal intent or LibTV process can start.
                let latest = profiles[registration.profileRef]?.metadata
                let effective = latest.map {
                    $0.enabled && $0.healthy ? $0.maxConcurrency : 0
                } ?? 0
                if paused || runtimeMaintenance || activeJobs.count >= globalMaxConcurrency ||
                    activeJobCount(profileRef: registration.profileRef) >= effective {
                    _ = try await api.cancelLeasedJob(
                        jobID: job.id,
                        profileRef: registration.profileRef
                    )
                    break
                }
                activeJobs[job.id] = ActiveJob(
                    jobID: job.id,
                    profileRef: registration.profileRef,
                    remoteTaskID: job.remoteTaskID,
                    runtime: nil,
                    seedanceCompliancePreflight: nil
                )
                activePhases[job.id] = job.remoteTaskID == nil ? .leased : .tracking
                let task = Task { [weak self] in
                    guard let self else { return }
                    await self.run(job: job, on: registration)
                }
                activeTasks[job.id] = task
            }
        }
    }

    public func stopTracking(jobID: String) async throws {
        guard let active = activeJobs[jobID], let registration = profiles[active.profileRef] else {
            throw RunnerEngineControlError.jobNotActive
        }
        stoppedJobs.insert(jobID)
        activeTasks[jobID]?.cancel()
        _ = await registration.executor.stopTracking(jobID: jobID)
    }

    /// Compatibility helper for a profile-wide operator action. Job-targeted control should use
    /// `stopTracking(jobID:)` so another task sharing the account is never stopped accidentally.
    public func stopTracking(profileRef: String) async {
        let jobIDs = activeJobs.values.filter { $0.profileRef == profileRef }.map(\.jobID)
        for jobID in jobIDs { try? await stopTracking(jobID: jobID) }
    }

    /// Cancels only while the job remains locally leased. Actor isolation makes the phase
    /// transition atomic with `beginSubmitting`, preventing a successful cancel followed by launch.
    @discardableResult
    public func cancelBeforeSubmission(jobID: String) async throws -> RunnerJob {
        guard let profileRef = activeJobs[jobID]?.profileRef else {
            throw RunnerEngineControlError.jobNotActive
        }
        guard activePhases[jobID] == .leased else {
            throw RunnerEngineControlError.submissionAlreadyStarted
        }
        cancelledJobs.insert(jobID)
        activeTasks[jobID]?.cancel()
        return try await api.cancelLeasedJob(jobID: jobID, profileRef: profileRef)
    }

    private var serviceState: RunnerServiceState {
        if paused || runtimeMaintenance { return .paused }
        return activeJobs.isEmpty ? .idle : .busy
    }

    private func activeJobCount(profileRef: String) -> Int {
        activeJobs.values.reduce(into: 0) { count, active in
            if active.profileRef == profileRef { count += 1 }
        }
    }

    private func apply(_ command: RunnerControlCommand) async {
        switch command.kind {
        case .pause: paused = true
        case .resume: paused = false
        case .stopTracking:
            if let jobID = command.jobID {
                try? await stopTracking(jobID: jobID)
            } else if let profileRef = command.profileRef {
                await stopTracking(profileRef: profileRef)
            }
        case .healthCheck:
            break
        case .refreshProfiles, .refreshInventory, .diagnostics,
             .runtimeDiscover, .runtimeValidate, .runtimeApprove, .runtimeActivate,
             .runtimeRollback:
            // AgentRuntime owns these service-level operations. RunnerCore still decodes them so
            // one newer server command cannot invalidate the entire heartbeat response.
            break
        }
    }

    private func run(job: RunnerJob, on registration: RunnerProfile) async {
        defer {
            activeJobs.removeValue(forKey: job.id)
            activeTasks.removeValue(forKey: job.id)
            activePhases.removeValue(forKey: job.id)
            cancelledJobs.remove(job.id)
            stoppedJobs.remove(job.id)
            let remaining = activeJobCount(profileRef: registration.profileRef)
            let configured = profiles[registration.profileRef]?.metadata.maxConcurrency ?? 0
            Task {
                await registeredExecutor(registration.profileRef)?.unbindRuntime(jobID: job.id)
                await registeredExecutor(registration.profileRef)?.setMaxConcurrency(
                    max(configured, remaining)
                )
            }
        }
        guard let registered = profiles[registration.profileRef] else { return }
        do {
            let persistedRuntime = try await journal.runtimeIdentity(for: job.id)
            let selectedRuntime = try await runtimeProvider?.resolveRuntime(
                requirement: job.runtimeRequirement,
                persisted: persistedRuntime,
                remoteTaskExists: job.remoteTaskID != nil
            )
            if let selectedRuntime {
                try await journal.bindJobRuntime(jobID: job.id, runtime: selectedRuntime.identity)
                try await registered.executor.bindRuntime(
                    jobID: job.id,
                    executableURL: selectedRuntime.executableURL
                )
                activeJobs[job.id]?.runtime = selectedRuntime.identity
                try await journal.bindCLIAdapter(jobID: job.id, legacy: persistedRuntime != nil || job.remoteTaskID != nil)
                _ = try await registered.executor.verifyCLIContract(jobID: job.id, runtime: selectedRuntime.identity)
            }
            let outcome: SubmissionExecutionOutcome
            if let remoteTaskID = job.remoteTaskID {
                _ = try await journal.recordSubmissionIntent(
                    jobID: job.id,
                    profileRef: registration.profileRef,
                    requestFingerprint: job.idempotencyKey,
                    runtime: selectedRuntime?.identity
                )
                try await journal.resumeRemoteQuery(
                    jobID: job.id,
                    profileRef: registration.profileRef,
                    remoteTaskID: remoteTaskID
                )
                // A recheck is claimed as `leased`, even though the paid remote task already
                // exists. Move the server job back to `running` before querying so an immediate
                // success can archive its output through the normal artifact endpoints.
                try didDiscoverRemoteTask(
                    jobID: job.id,
                    profileRef: registration.profileRef,
                    remoteTaskID: remoteTaskID
                )
                try await api.postJobEvent(
                    jobID: job.id,
                    event: JobEventRequest(
                        profileRef: registration.profileRef,
                        status: .running,
                        remoteTaskID: remoteTaskID
                    )
                )
                outcome = try await registered.submission.queryKnownRemote(
                    jobID: job.id,
                    arguments: try await queryArguments(remoteTaskID: remoteTaskID, for: job)
                )
            } else {
                if preSubmissionDelay > .zero { try await Task.sleep(for: preSubmissionDelay) }
                let prepared = try await generationPreparer?.prepare(
                    job: job,
                    profileRef: registration.profileRef,
                    executor: registered.executor
                )
                activeJobs[job.id]?.seedanceCompliancePreflight = prepared?.seedanceCompliancePreflight
                outcome = try await registered.submission.submit(
                    jobID: job.id,
                    profileRef: registration.profileRef,
                    requestFingerprint: prepared?.requestFingerprint ?? job.idempotencyKey,
                    runtime: selectedRuntime?.identity,
                    arguments: try prepared?.arguments ?? commandBuilder.submissionArguments(for: job),
                    seedanceCompliancePreflight: prepared?.seedanceCompliancePreflight ?? .notRequired(),
                    beforeLaunch: { [weak self, api] in
                        guard let self else { throw CancellationError() }
                        try await self.beginSubmitting(jobID: job.id)
                        try await api.postJobEvent(
                            jobID: job.id,
                            event: JobEventRequest(
                                profileRef: registration.profileRef,
                                status: .submitting,
                                result: prepared.map(Self.submittingResult)
                            )
                        )
                    },
                    onRemoteTask: { [weak self, api] remoteTaskID in
                        guard let self else { throw CancellationError() }
                        try await self.didDiscoverRemoteTask(
                            jobID: job.id,
                            profileRef: registration.profileRef,
                            remoteTaskID: remoteTaskID
                        )
                        try await api.postJobEvent(
                            jobID: job.id,
                            event: JobEventRequest(
                                profileRef: registration.profileRef,
                                status: .running,
                                remoteTaskID: remoteTaskID,
                                result: prepared.map(Self.remoteTaskDiscoveredResult)
                            )
                        )
                    },
                    onTaskSnapshot: { [api] snapshot in
                        guard snapshot.state == .running,
                              let progress = snapshot.progressPercent else { return }
                        try? await api.postJobEvent(
                            jobID: job.id,
                            event: JobEventRequest(
                                profileRef: registration.profileRef,
                                status: .running,
                                remoteTaskID: snapshot.taskID,
                                result: .object([
                                    "progress_percent": .number(progress),
                                ])
                            )
                        )
                    }
                )
            }
            try await track(
                initialOutcome: outcome,
                job: job,
                profileRef: registration.profileRef,
                submission: registered.submission
            )
        } catch is CancellationError where cancelledJobs.contains(job.id) {
            // The server-side cancel endpoint owns the final leased -> cancelled transition.
        } catch {
            // Preparation happens entirely before `beginSubmitting` and therefore before the
            // paid LibTV command can launch. A network or hidden-project failure in this phase
            // is known-safe and must not be reported as an uncertain submission.
            let terminalState: RunnerJobState = activePhases[job.id] == .leased && job.remoteTaskID == nil
                ? .failed
                : .needsReview
            try? await journal.markTerminal(jobID: job.id, state: terminalState)
            try? await api.postJobEvent(
                jobID: job.id,
                event: JobEventRequest(
                    profileRef: registration.profileRef,
                    status: terminalState,
                    remoteTaskID: activeJobs[job.id]?.remoteTaskID ?? job.remoteTaskID,
                    result: activeJobs[job.id]?.seedanceCompliancePreflight.map { preflight in
                        .object([
                            "preflight": preflight.payload(
                                status: terminalState == .needsReview && preflight.requiresCheck
                                    ? .unknown
                                    : preflight.status
                            ),
                        ])
                    },
                    error: error.localizedDescription
                )
            )
        }
    }

    private func registeredExecutor(_ profileRef: String) -> ProfileExecutor? {
        profiles[profileRef]?.executor
    }

    private nonisolated static func submittingResult(_ prepared: PreparedLibTVSubmission) -> JSONPayloadValue {
        .object([
            "parameter_diagnostics": prepared.parameterDiagnostics,
            "preflight": prepared.seedanceCompliancePreflight.payload(),
        ])
    }

    private nonisolated static func remoteTaskDiscoveredResult(_ prepared: PreparedLibTVSubmission) -> JSONPayloadValue {
        let preflight = prepared.seedanceCompliancePreflight
        return .object([
            "preflight": preflight.payload(status: preflight.requiresCheck ? .passed : preflight.status),
        ])
    }

    private func beginSubmitting(jobID: String) throws {
        guard !cancelledJobs.contains(jobID), activePhases[jobID] == .leased else {
            throw CancellationError()
        }
        activePhases[jobID] = .submitting
    }

    private func didDiscoverRemoteTask(
        jobID: String,
        profileRef: String,
        remoteTaskID: String
    ) throws {
        guard var active = activeJobs[jobID], active.profileRef == profileRef else {
            throw RunnerEngineControlError.jobNotActive
        }
        if let existing = active.remoteTaskID, existing != remoteTaskID {
            throw RemoteTaskIdentityError.conflictingTaskIDs(existing, remoteTaskID)
        }
        active.remoteTaskID = remoteTaskID
        activeJobs[jobID] = active
        activePhases[jobID] = .tracking
    }

    private func track(
        initialOutcome: SubmissionExecutionOutcome,
        job: RunnerJob,
        profileRef: String,
        submission: SubmissionExecutor
    ) async throws {
        var outcome = initialOutcome
        var polls = 0
        var pendingTerminalState: RunnerJobState?
        var terminalObservations = 0
        let clock = ContinuousClock()
        let started = clock.now
        while true {
            if case .process(_, let snapshot?) = outcome, let remoteTaskID = snapshot.taskID {
                activeJobs[job.id]?.remoteTaskID = remoteTaskID
            }
            guard case .process(_, let snapshot?) = outcome else {
                try await report(outcome: outcome, job: job, profileRef: profileRef)
                return
            }
            let remoteTaskID = snapshot.taskID ?? activeJobs[job.id]?.remoteTaskID ?? job.remoteTaskID
            if snapshot.state == .succeeded {
                try await journal.markTerminal(jobID: job.id, state: .succeeded)
                try await report(outcome: outcome, job: job, profileRef: profileRef)
                return
            }
            if snapshot.state.isTerminal, let remoteTaskID {
                if pendingTerminalState == snapshot.state {
                    terminalObservations += 1
                } else {
                    pendingTerminalState = snapshot.state
                    terminalObservations = 1
                }
                if terminalObservations >= terminalConfirmationCount {
                    try await journal.markTerminal(jobID: job.id, state: snapshot.state)
                    try await report(outcome: outcome, job: job, profileRef: profileRef)
                    return
                }
                activePhases[job.id] = .tracking
                if polls >= maximumPollCount || started.duration(to: clock.now) >= maximumTrackingDuration {
                    try await journal.markTerminal(jobID: job.id, state: .needsReview)
                    try await report(outcome: .needsReview, job: job, profileRef: profileRef)
                    return
                }
                polls += 1
                try await Task.sleep(for: pollInterval)
                outcome = try await submission.queryKnownRemote(
                    jobID: job.id,
                    arguments: try await queryArguments(remoteTaskID: remoteTaskID, for: job)
                )
                continue
            }
            guard snapshot.state == .running, let remoteTaskID else {
                try await report(outcome: outcome, job: job, profileRef: profileRef)
                return
            }
            pendingTerminalState = nil
            terminalObservations = 0
            try await report(outcome: outcome, job: job, profileRef: profileRef)
            activePhases[job.id] = .tracking
            if stoppedJobs.contains(job.id) {
                try await journal.markTerminal(jobID: job.id, state: .needsReview)
                try await report(outcome: .needsReview, job: job, profileRef: profileRef)
                return
            }
            if polls >= maximumPollCount || started.duration(to: clock.now) >= maximumTrackingDuration {
                try await journal.markTerminal(jobID: job.id, state: .needsReview)
                try await report(outcome: .needsReview, job: job, profileRef: profileRef)
                return
            }
            polls += 1
            try await Task.sleep(for: pollInterval)
            if stoppedJobs.contains(job.id) {
                try await journal.markTerminal(jobID: job.id, state: .needsReview)
                try await report(outcome: .needsReview, job: job, profileRef: profileRef)
                return
            }
            outcome = try await submission.queryKnownRemote(
                jobID: job.id,
                arguments: try await queryArguments(remoteTaskID: remoteTaskID, for: job)
            )
        }
    }

    private func report(
        outcome: SubmissionExecutionOutcome,
        job: RunnerJob,
        profileRef: String
    ) async throws {
        switch outcome {
        case .process(let process, let snapshot):
            let status = snapshot?.state ?? .needsReview
            var result: JSONPayloadValue?
            var resultObject: [String: JSONPayloadValue] = [:]
            if let snapshot {
                if status == .succeeded {
                    // Stable Canvas artifacts are completed before the succeeded event. The
                    // server never persists LibTV's expiring output URLs as final results.
                    let artifacts = try await archiveOutputs(jobID: job.id, outputs: snapshot.outputs)
                    resultObject["artifacts"] = .array(artifacts.map { artifact in
                            .object([
                                "artifact_id": .string(artifact.artifactID),
                                "content_url": .string(artifact.contentURL.absoluteString),
                                "file_name": .string(artifact.fileName),
                                "file_size": .number(Double(artifact.fileSize)),
                                "sha256": .string(artifact.sha256),
                            ])
                        })
                    resultObject["progress_percent"] = snapshot.progressPercent.map(JSONPayloadValue.number) ?? .null
                } else {
                    resultObject["progress_percent"] = snapshot.progressPercent.map(JSONPayloadValue.number) ?? .null
                }
            }
            if let preflight = activeJobs[job.id]?.seedanceCompliancePreflight {
                let reportedStatus: SeedanceCompliancePreflightStatus
                switch snapshot?.rawStatus {
                case "seedance_compliance_rejected": reportedStatus = .rejected
                case "seedance_compliance_retryable_error": reportedStatus = .retryableError
                default:
                    let hasRemoteTask = snapshot?.taskID != nil
                        || activeJobs[job.id]?.remoteTaskID != nil
                        || job.remoteTaskID != nil
                    if preflight.requiresCheck && hasRemoteTask {
                        reportedStatus = .passed
                    } else if preflight.requiresCheck && [.failed, .needsReview].contains(status) {
                        reportedStatus = .unknown
                    } else {
                        reportedStatus = preflight.status
                    }
                }
                resultObject["preflight"] = preflight.payload(status: reportedStatus)
            }
            if !resultObject.isEmpty { result = .object(resultObject) }
            try await api.postJobEvent(
                jobID: job.id,
                event: JobEventRequest(
                    profileRef: profileRef,
                    status: status,
                    remoteTaskID: snapshot?.taskID ?? activeJobs[job.id]?.remoteTaskID ?? job.remoteTaskID,
                    result: result,
                    error: [.failed, .needsReview].contains(status)
                        ? (snapshot?.failureReason ?? process.standardError)
                        : nil
                )
            )
        case .alreadyTerminal(let state):
            try await api.postJobEvent(
                jobID: job.id,
                event: JobEventRequest(
                    profileRef: profileRef,
                    status: state,
                    remoteTaskID: activeJobs[job.id]?.remoteTaskID ?? job.remoteTaskID
                )
            )
        case .queryOnly(let remoteTaskID):
            // This branch is possible for a duplicate claim discovered by the journal.
            guard let registered = profiles[profileRef] else { return }
            let queried = try await registered.submission.queryKnownRemote(
                jobID: job.id,
                arguments: try await queryArguments(remoteTaskID: remoteTaskID, for: job)
            )
            try await report(outcome: queried, job: job, profileRef: profileRef)
        case .needsReview:
            try await api.postJobEvent(
                jobID: job.id,
                event: JobEventRequest(
                    profileRef: profileRef,
                    status: .needsReview,
                    remoteTaskID: activeJobs[job.id]?.remoteTaskID ?? job.remoteTaskID,
                    result: activeJobs[job.id]?.seedanceCompliancePreflight.map { preflight in
                        .object([
                            "preflight": preflight.payload(
                                status: preflight.requiresCheck ? .unknown : preflight.status
                            ),
                        ])
                    },
                    error: "Submission state is uncertain; automatic retry is disabled."
                )
            )
        }
    }

    /// LibTV 1.0.2 exposes generation state on the hidden canvas node. Legacy tests may inject
    /// an explicit query builder, but production never fabricates an unsupported task command.
    private func queryArguments(remoteTaskID: String, for job: RunnerJob) async throws -> [String] {
        if let layout = try await journal.executionLayout(jobID: job.id) {
            return LibTVCLIAdapter.queryNode(layout.generationNodeName, project: layout.projectUUID, group: layout.groupName)
        }
        return try commandBuilder.queryArguments(remoteTaskID: remoteTaskID, for: job)
    }

    private func archiveOutputs(jobID: String, outputs: [String]) async throws -> [ArchivedArtifact] {
        var artifacts: [ArchivedArtifact] = []
        for output in outputs {
            artifacts.append(try await artifactArchiver.archive(jobID: jobID, output: output))
        }
        return artifacts
    }
}

private enum RemoteTaskIdentityError: Error, LocalizedError, Sendable {
    case conflictingTaskIDs(String, String)

    var errorDescription: String? {
        switch self {
        case .conflictingTaskIDs(let first, let second):
            "The active job changed remote task ID from \(first) to \(second)."
        }
    }
}
