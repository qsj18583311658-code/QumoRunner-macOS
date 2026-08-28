import Foundation

public enum SubmissionExecutionOutcome: Equatable, Sendable {
    case process(LibTVProcessResult, snapshot: LibTVTaskSnapshot?)
    case queryOnly(remoteTaskID: String)
    case alreadyTerminal(RunnerJobState)
    case needsReview
}

private actor RemoteTaskDiscovery {
    private let jobID: String
    private let journal: SubmissionJournal
    private let onRemoteTask: @Sendable (String) async throws -> Void
    private let onTaskSnapshot: @Sendable (LibTVTaskSnapshot) async -> Void
    private var remoteTaskID: String?
    private var lastProgressPercent: Double?
    private var failure: (any Error)?

    init(
        jobID: String,
        journal: SubmissionJournal,
        onRemoteTask: @escaping @Sendable (String) async throws -> Void,
        onTaskSnapshot: @escaping @Sendable (LibTVTaskSnapshot) async -> Void
    ) {
        self.jobID = jobID
        self.journal = journal
        self.onRemoteTask = onRemoteTask
        self.onTaskSnapshot = onTaskSnapshot
    }

    func consume(_ output: LibTVProcessOutput) async {
        guard failure == nil else { return }
        let snapshot = try? LibTVOutputParser.parse(output.line)
        if let discovered = snapshot?.taskID ?? LibTVOutputParser.remoteTaskID(in: output.line) {
            if let remoteTaskID {
                if remoteTaskID != discovered {
                    failure = RemoteTaskDiscoveryError.conflictingTaskIDs(remoteTaskID, discovered)
                    return
                }
            } else {
                do {
                    // Local durability is deliberately completed before any network event is attempted.
                    try await journal.attachRemoteTask(jobID: jobID, remoteTaskID: discovered)
                    remoteTaskID = discovered
                    try await onRemoteTask(discovered)
                } catch {
                    failure = error
                    return
                }
            }
        }

        // Live CLI diagnostics contain progress before the process exits. Only running
        // snapshots are forwarded here; terminal state still comes from the final JSON
        // payload so a status=2 line without downloadable outputs cannot finish a job early.
        if let snapshot,
           snapshot.state == .running,
           let progress = snapshot.progressPercent,
           progress != lastProgressPercent {
            lastProgressPercent = progress
            await onTaskSnapshot(snapshot)
        }
    }

    func discoveredID() -> String? { remoteTaskID }

    func checkForFailure() throws {
        if let failure { throw failure }
    }
}

private enum RemoteTaskDiscoveryError: Error, LocalizedError, Sendable {
    case conflictingTaskIDs(String, String)

    var errorDescription: String? {
        switch self {
        case .conflictingTaskIDs(let first, let second):
            "LibTV emitted conflicting remote task IDs: \(first) and \(second)."
        }
    }
}

/// Couples idempotency journaling to process launch. Callers cannot accidentally launch a
/// paid submission before the durable intent exists, and recovered remote IDs are query-only.
public actor SubmissionExecutor {
    private let profile: ProfileExecutor
    private let journal: SubmissionJournal

    public init(profile: ProfileExecutor, journal: SubmissionJournal) {
        self.profile = profile
        self.journal = journal
    }

    public func submit(
        jobID: String,
        profileRef: String,
        requestFingerprint: String,
        arguments: [String],
        timeout: Duration? = nil,
        beforeLaunch: @Sendable () async throws -> Void = { },
        onRemoteTask: @escaping @Sendable (String) async throws -> Void = { _ in },
        onTaskSnapshot: @escaping @Sendable (LibTVTaskSnapshot) async -> Void = { _ in }
    ) async throws -> SubmissionExecutionOutcome {
        switch try await journal.recoveryAction(for: jobID) {
        case .queryRemote(let taskID): return .queryOnly(remoteTaskID: taskID)
        case .alreadyTerminal(let state): return .alreadyTerminal(state)
        case .needsReview: return .needsReview
        case .submitNew: break
        }

        let inserted = try await journal.recordSubmissionIntent(
            jobID: jobID,
            profileRef: profileRef,
            requestFingerprint: requestFingerprint
        )
        guard inserted else {
            // Covers a concurrent duplicate claim racing between the read and insert.
            switch try await journal.recoveryAction(for: jobID) {
            case .queryRemote(let taskID): return .queryOnly(remoteTaskID: taskID)
            case .alreadyTerminal(let state): return .alreadyTerminal(state)
            case .submitNew, .needsReview: return .needsReview
            }
        }


        // The durable local intent exists before the server transition, and both precede
        // Process.run. A failed server transition therefore cannot accidentally launch LibTV.
        try await beforeLaunch()

        let discovery = RemoteTaskDiscovery(
            jobID: jobID,
            journal: journal,
            onRemoteTask: onRemoteTask,
            onTaskSnapshot: onTaskSnapshot
        )
        var result: LibTVProcessResult
        do {
            result = try await profile.execute(
                jobID: jobID,
                arguments: arguments,
                timeout: timeout,
                onOutput: { output in await discovery.consume(output) }
            )
            try await discovery.checkForFailure()
            if await discovery.discoveredID() == nil,
               let recovered = try await recoverCreatedNodeVisibilityRace(
                   jobID: jobID,
                   arguments: arguments,
                   originalResult: result,
                   timeout: timeout,
                   discovery: discovery
               ) {
                result = recovered
                try await discovery.checkForFailure()
            }
        } catch is CancellationError {
            // Cancellation observed before Process.run is a true pre-submission cancellation.
            try await journal.markTerminal(jobID: jobID, state: .cancelled)
            throw CancellationError()
        } catch {
            try await journal.markTerminal(jobID: jobID, state: .needsReview)
            throw error
        }
        if result.wasRejectedByArgumentParser {
            let snapshot = LibTVTaskSnapshot(
                taskID: nil,
                state: .failed,
                loading: false,
                progressPercent: nil,
                outputs: [],
                rawStatus: "argument_rejected"
            )
            try await journal.markTerminal(jobID: jobID, state: .failed)
            return .process(result, snapshot: snapshot)
        }
        let snapshot = try? LibTVOutputParser.parse(result.standardOutput + "\n" + result.standardError)
        if result.requiresManualReview || result.disposition == .crashed
            || (result.exitCode != 0 && ![.failed, .cancelled].contains(snapshot?.state)) {
            try await journal.markTerminal(jobID: jobID, state: .needsReview)
            return .process(result, snapshot: nil)
        }

        let incrementallyDiscoveredID = await discovery.discoveredID()
        if let remoteTaskID = snapshot?.taskID ?? incrementallyDiscoveredID {
            try await journal.attachRemoteTask(jobID: jobID, remoteTaskID: remoteTaskID)
        }
        if let state = snapshot?.state, state.isTerminal {
            try await journal.markTerminal(jobID: jobID, state: state)
        } else if snapshot == nil {
            try await journal.markTerminal(jobID: jobID, state: .needsReview)
        }
        return .process(result, snapshot: snapshot)
    }

    /// LibTV 1.0.2 can successfully create a node but fail the immediate `--run` lookup while
    /// concurrent groups are being written to the same hidden project. The error occurs before a
    /// remote task exists. Once the deterministic node becomes readable, running that existing
    /// node is safe and avoids repeating `node create` or creating a second paid task.
    private func recoverCreatedNodeVisibilityRace(
        jobID: String,
        arguments: [String],
        originalResult: LibTVProcessResult,
        timeout: Duration?,
        discovery: RemoteTaskDiscovery
    ) async throws -> LibTVProcessResult? {
        guard originalResult.disposition == .exited,
              originalResult.exitCode != 0,
              visibilityRaceDiagnostic(in: originalResult),
              arguments.count >= 3,
              arguments[0] == "node",
              arguments[1] == "create",
              let project = optionValue("--project", in: arguments),
              let group = optionValue("--group", in: arguments) else { return nil }

        let nodeName = arguments[2]
        let queryArguments = [
            "node", nodeName,
            "--project", project,
            "--group", group,
        ]
        for attempt in 1...5 {
            try await Task.sleep(for: .milliseconds(400))
            let query = try await profile.execute(
                jobID: "\(jobID):visibility-check-\(attempt)",
                arguments: queryArguments,
                timeout: .seconds(45)
            )
            guard query.disposition == .exited, query.exitCode == 0 else { continue }
            return try await profile.execute(
                jobID: jobID,
                arguments: queryArguments + ["--run"],
                timeout: timeout,
                onOutput: { output in await discovery.consume(output) }
            )
        }
        return nil
    }

    private func visibilityRaceDiagnostic(in result: LibTVProcessResult) -> Bool {
        let diagnostic = result.standardError + "\n" + result.standardOutput
        return diagnostic.contains("未找到可运行的节点")
            || diagnostic.localizedCaseInsensitiveContains("runnable node was not found")
    }

    private func optionValue(_ option: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    public func queryKnownRemote(
        jobID: String,
        arguments: [String],
        timeout: Duration? = nil
    ) async throws -> SubmissionExecutionOutcome {
        guard case .queryRemote(let remoteTaskID) = try await journal.recoveryAction(for: jobID) else {
            return .needsReview
        }
        let result: LibTVProcessResult
        do {
            result = try await profile.execute(jobID: jobID, arguments: arguments, timeout: timeout)
        } catch {
            try await journal.markTerminal(jobID: jobID, state: .needsReview)
            throw error
        }
        let combinedOutput = result.standardOutput + "\n" + result.standardError
        guard result.disposition == .exited, result.exitCode == 0,
              let snapshot = try? LibTVOutputParser.parse(combinedOutput) else {
            if isTransientKnownRemoteQueryFailure(result) {
                // The paid task identity is durable. A temporary canvas/API read failure is not
                // submission uncertainty and must never force a new generation or terminal state.
                return .process(
                    result,
                    snapshot: LibTVTaskSnapshot(
                        taskID: remoteTaskID,
                        state: .running,
                        loading: true,
                        progressPercent: nil,
                        outputs: [],
                        rawStatus: "query_retry"
                    )
                )
            }
            try await journal.markTerminal(jobID: jobID, state: .needsReview)
            return .process(result, snapshot: nil)
        }
        if snapshot.state.isTerminal {
            try await journal.markTerminal(jobID: jobID, state: snapshot.state)
        }
        return .process(result, snapshot: snapshot)
    }

    private func isTransientKnownRemoteQueryFailure(_ result: LibTVProcessResult) -> Bool {
        let diagnostic = (result.standardError + "\n" + result.standardOutput).lowercased()
        return result.requiresManualReview
            || diagnostic.contains("fetch failed")
            || diagnostic.contains("econnreset")
            || diagnostic.contains("etimedout")
            || diagnostic.contains("request fail")
            || diagnostic.contains("拉取画布失败")
            || diagnostic.contains("network")
    }
}
