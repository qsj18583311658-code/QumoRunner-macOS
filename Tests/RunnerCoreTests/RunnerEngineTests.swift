import Foundation
import Testing
@testable import RunnerCore

@Suite struct RunnerEngineTests {
    @Test
    func testRuntimeValidationCommandDefersClaimUntilNextHeartbeat() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try TestSupport.fakeLibTV()
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let api = FakeRunnerAPI(
            job: RunnerJob(id: "runtime-canary", state: .queued, capability: "image"),
            heartbeatCommands: [[RunnerControlCommand(id: "validate", kind: .runtimeValidate)], []]
        )
        let engine = RunnerEngine(
            api: api,
            journal: try SubmissionJournal(databaseURL: directory.appendingPathComponent("runner.sqlite")),
            hostname: "test",
            version: "1"
        )
        await engine.register(
            profile: RunnerProfile(profileRef: "p1", accountRef: "a1", displayName: "A", capabilities: ["image"]),
            executor: ProfileExecutor(
                profileRef: "p1",
                runner: LibTVProcessRunner(executableURL: executable, homeURL: directory),
                limiter: try GlobalConcurrencyLimiter(limit: 1)
            )
        )
        try await engine.tick()
        #expect(await api.claimCount() == 0)
        try await engine.tick()
        #expect(await api.claimCount() == 1)
    }

    @Test
    func testPauseHeartbeatsButDoesNotClaimAndResumeRunsJob() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try TestSupport.fakeLibTV()
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let artifact = directory.appendingPathComponent("result.png")
        try Data("image".utf8).write(to: artifact)
        let api = FakeRunnerAPI(
            job: RunnerJob(
                id: "job-1",
                state: .leased,
                idempotencyKey: "idem-1",
                capability: "image",
                payload: ["arguments": .array([.string("success-local"), .string(artifact.path)])]
            ),
            heartbeatCommands: [[RunnerControlCommand(id: "pause", kind: .pause)], []]
        )
        let journal = try SubmissionJournal(databaseURL: directory.appendingPathComponent("runner.sqlite"))
        let limiter = try GlobalConcurrencyLimiter(limit: 1)
        let executor = ProfileExecutor(
            profileRef: "p1",
            runner: LibTVProcessRunner(executableURL: executable, homeURL: directory),
            limiter: limiter
        )
        let engine = RunnerEngine(api: api, journal: journal, commandBuilder: PayloadArgumentsCommandBuilder(), hostname: "test", version: "1")
        await engine.register(profile: RunnerProfile(
            profileRef: "p1", accountRef: "a1", displayName: "A", capabilities: ["image"]
        ), executor: executor)

        try await engine.tick()
        let pausedClaimCount = await api.claimCount()
        #expect(pausedClaimCount == 0)
        await engine.resume()
        try await engine.tick()
        try await waitForEvent(api)
        let events = await api.recordedEvents()
        #expect(events.map(\.status).starts(with: [.submitting, .running, .succeeded]))
        #expect(events.last?.remoteTaskID == "remote-123")
        let uploads = await api.uploadCount()
        #expect(uploads == 1)
    }

    @Test
    func testKnownRemoteTaskUsesQueryBuilderAndNeverSubmissionArguments() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try TestSupport.fakeLibTV()
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let api = FakeRunnerAPI(job: RunnerJob(
            id: "known",
            state: .running,
            idempotencyKey: "known-idem",
            capability: "image",
            payload: [:],
            remoteTaskID: "remote-existing"
        ))
        let journal = try SubmissionJournal(databaseURL: directory.appendingPathComponent("runner.sqlite"))
        let limiter = try GlobalConcurrencyLimiter(limit: 1)
        let engine = RunnerEngine(
            api: api,
            journal: journal,
            commandBuilder: QueryOnlyBuilder(),
            hostname: "test",
            version: "1",
            pollInterval: .milliseconds(10),
            maximumPollCount: 1
        )
        await engine.register(
            profile: RunnerProfile(profileRef: "p1", accountRef: "a1", displayName: "A", capabilities: ["image"]),
            executor: ProfileExecutor(
                profileRef: "p1",
                runner: LibTVProcessRunner(executableURL: executable, homeURL: directory),
                limiter: limiter
            )
        )
        try await engine.tick()
        try await waitForEvent(api)
        let events = await api.recordedEvents()
        #expect(events.first?.status == .running)
        #expect(events.last?.status == .needsReview)
        let action = try await journal.recoveryAction(for: "known")
        #expect(action == .alreadyTerminal(.needsReview))
    }

    @Test
    func testKnownRemoteImmediateSuccessReportsRunningBeforeArtifactUpload() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try TestSupport.fakeLibTV()
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let artifact = directory.appendingPathComponent("rechecked.png")
        try Data("rechecked image".utf8).write(to: artifact)
        let api = FakeRunnerAPI(job: RunnerJob(
            id: "known-success",
            state: .leased,
            idempotencyKey: "known-success-idem",
            capability: "image",
            payload: [:],
            remoteTaskID: "remote-existing"
        ))
        let journal = try SubmissionJournal(databaseURL: directory.appendingPathComponent("runner.sqlite"))
        let engine = RunnerEngine(
            api: api,
            journal: journal,
            commandBuilder: KnownRemoteSuccessBuilder(successPath: artifact.path),
            hostname: "test",
            version: "1",
            pollInterval: .milliseconds(10)
        )
        await engine.register(
            profile: RunnerProfile(profileRef: "p1", accountRef: "a1", displayName: "A", capabilities: ["image"]),
            executor: ProfileExecutor(
                profileRef: "p1",
                runner: LibTVProcessRunner(executableURL: executable, homeURL: directory),
                limiter: try GlobalConcurrencyLimiter(limit: 1)
            )
        )

        try await engine.tick()
        try await waitForEvent(api)

        #expect(await api.recordedEvents().map(\.status) == [.running, .succeeded])
        #expect(await api.uploadCount() == 1)
        #expect(try await journal.recoveryAction(for: "known-success") == .alreadyTerminal(.succeeded))
    }

    @Test
    func testKnownRemoteTaskRecoveryUsesPersistedNodeLayoutInsteadOfMissingTaskCommand() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try TestSupport.fakeLibTV()
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let journal = try SubmissionJournal(databaseURL: directory.appendingPathComponent("runner.sqlite"))
        try await journal.recordExecutionLayout(
            jobID: "layout-recovery",
            profileRef: "p1",
            projectUUID: "86ba514d50e34c7dbd2ef571a2885383",
            groupName: "qumo-job-recovery",
            inputNodeNames: [],
            generationNodeName: "generate-b696a21c1472ab0b7b60"
        )
        let api = FakeRunnerAPI(job: RunnerJob(
            id: "layout-recovery",
            state: .running,
            capability: "image",
            remoteTaskID: "remote-existing"
        ))
        let engine = RunnerEngine(
            api: api,
            journal: journal,
            hostname: "test",
            version: "1",
            pollInterval: .seconds(1)
        )
        await engine.register(
            profile: RunnerProfile(profileRef: "p1", accountRef: "a", displayName: "A", capabilities: ["image"]),
            executor: ProfileExecutor(
                profileRef: "p1",
                runner: LibTVProcessRunner(executableURL: executable, homeURL: directory),
                limiter: try GlobalConcurrencyLimiter(limit: 1)
            )
        )

        try await engine.tick()
        for _ in 0..<100 {
            if await api.recordedEvents().contains(where: { $0.status == .running }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let invocationURL = directory.appendingPathComponent("invocations.log")
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: invocationURL.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let invocation = try String(contentsOf: invocationURL, encoding: .utf8)
        #expect(invocation.contains("node generate-b696a21c1472ab0b7b60 --project 86ba514d50e34c7dbd2ef571a2885383 --group qumo-job-recovery"))
        #expect(!invocation.contains("task info"))
        #expect(!invocation.contains("--run"))
        try await engine.stopTracking(jobID: "layout-recovery")
        try await waitForEngineToDrain(engine)
    }

    @Test
    func testLiveTaskIDIsJournaledAndReportedBeforeLibTVProcessExits() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try TestSupport.fakeLibTV()
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let journal = try SubmissionJournal(databaseURL: directory.appendingPathComponent("runner.sqlite"))
        let api = FakeRunnerAPI(job: RunnerJob(
            id: "streaming-remote",
            state: .leased,
            capability: "image",
            payload: ["arguments": .array([.string("stream-task"), .string("0.5")])]
        ))
        let engine = RunnerEngine(
            api: api,
            journal: journal,
            commandBuilder: PayloadArgumentsCommandBuilder(queryPrefix: ["stream-failed-query"]),
            hostname: "test",
            version: "1",
            pollInterval: .milliseconds(10)
        )
        await engine.register(
            profile: RunnerProfile(profileRef: "p1", accountRef: "a", displayName: "A", capabilities: ["image"]),
            executor: ProfileExecutor(
                profileRef: "p1",
                runner: LibTVProcessRunner(executableURL: executable, homeURL: directory),
                limiter: try GlobalConcurrencyLimiter(limit: 1)
            )
        )

        try await engine.tick()
        for _ in 0..<100 {
            if await api.recordedEvents().contains(where: {
                $0.status == .running && $0.remoteTaskID == "remote-stream-123"
            }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(await engine.snapshot().activeJobs["streaming-remote"] == "p1")
        #expect(try await journal.recoveryAction(for: "streaming-remote") == .queryRemote(taskID: "remote-stream-123"))
        let earlyEvents = await api.recordedEvents()
        #expect(earlyEvents.map(\.status).starts(with: [.submitting, .running]))
        #expect(!earlyEvents.contains(where: { $0.status.isTerminal }))

        try await waitForEvent(api)
        let finalEvents = await api.recordedEvents()
        #expect(finalEvents.last?.status == .failed)
        #expect(finalEvents.last?.remoteTaskID == "remote-stream-123")
        #expect(await api.claimCount() == 1)
    }

    @Test
    func testSeedanceComplianceEventsMoveFromCheckingToPassedWhenRemoteIDAppears() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try TestSupport.fakeLibTV()
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let preflight = SeedanceCompliancePreflight(status: .checking, inputOrders: [3, 1])
        let api = FakeRunnerAPI(job: RunnerJob(
            id: "seedance-pass",
            state: .leased,
            capability: "video"
        ))
        let engine = RunnerEngine(
            api: api,
            journal: try SubmissionJournal(databaseURL: directory.appendingPathComponent("runner.sqlite")),
            commandBuilder: PayloadArgumentsCommandBuilder(queryPrefix: ["stream-failed-query"]),
            generationPreparer: StaticGenerationPreparer(prepared: .init(
                arguments: ["stream-task", "0.2"],
                requestFingerprint: "seedance-pass-fingerprint",
                seedanceCompliancePreflight: preflight
            )),
            hostname: "test",
            version: "1",
            pollInterval: .milliseconds(10),
            terminalConfirmationCount: 1
        )
        await engine.register(
            profile: RunnerProfile(profileRef: "p1", accountRef: "a", displayName: "A", capabilities: ["video"]),
            executor: ProfileExecutor(
                profileRef: "p1",
                runner: LibTVProcessRunner(executableURL: executable, homeURL: directory),
                limiter: try GlobalConcurrencyLimiter(limit: 1)
            )
        )

        try await engine.tick()
        for _ in 0..<100 {
            if await api.recordedEvents().contains(where: { $0.remoteTaskID == "remote-stream-123" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let earlyEvents = await api.recordedEvents()
        let submitting = try #require(earlyEvents.first(where: { $0.status == .submitting }))
        let running = try #require(earlyEvents.first(where: { $0.remoteTaskID == "remote-stream-123" }))
        #expect(submitting.result?.objectValue?["preflight"]?.objectValue?["status"] == .string("checking"))
        #expect(submitting.result?.objectValue?["preflight"]?.objectValue?["checked"] == .number(0))
        #expect(submitting.result?.objectValue?["preflight"]?.objectValue?["total"] == .number(2))
        #expect(running.result?.objectValue?["preflight"]?.objectValue?["status"] == .string("passed"))
        #expect(running.result?.objectValue?["preflight"]?.objectValue?["checked"] == .number(2))
        #expect(running.result?.objectValue?["preflight"]?.objectValue?["total"] == .number(2))
        #expect(submitting.result?.objectValue?["preflight"]?.objectValue?["inputs"] == .array([
            .object(["order": .number(1), "status": .string("checking")]),
            .object(["order": .number(3), "status": .string("checking")]),
        ]))
        #expect(running.result?.objectValue?["preflight"]?.objectValue?["inputs"] == .array([
            .object(["order": .number(1), "status": .string("passed")]),
            .object(["order": .number(3), "status": .string("passed")]),
        ]))
        try await waitForEvent(api)
    }

    @Test
    func testSeedanceComplianceRejectionIsReportedFailedWithoutRunningEvent() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try TestSupport.fakeLibTV()
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let journal = try SubmissionJournal(databaseURL: directory.appendingPathComponent("runner.sqlite"))
        let api = FakeRunnerAPI(job: RunnerJob(
            id: "seedance-rejected",
            state: .leased,
            capability: "video"
        ))
        let engine = RunnerEngine(
            api: api,
            journal: journal,
            generationPreparer: StaticGenerationPreparer(prepared: .init(
                arguments: ["seedance-compliance-rejected-zh"],
                requestFingerprint: "seedance-rejected-fingerprint",
                seedanceCompliancePreflight: .init(status: .checking, inputOrders: [0])
            )),
            hostname: "test",
            version: "1"
        )
        await engine.register(
            profile: RunnerProfile(profileRef: "p1", accountRef: "a", displayName: "A", capabilities: ["video"]),
            executor: ProfileExecutor(
                profileRef: "p1",
                runner: LibTVProcessRunner(executableURL: executable, homeURL: directory),
                limiter: try GlobalConcurrencyLimiter(limit: 1)
            )
        )

        try await engine.tick()
        try await waitForEvent(api)
        let events = await api.recordedEvents()
        #expect(events.map(\.status) == [.submitting, .failed])
        #expect(!events.contains(where: { $0.status == .running }))
        #expect(events.last?.result?.objectValue?["preflight"]?.objectValue?["status"] == .string("rejected"))
        #expect(events.last?.result?.objectValue?["preflight"]?.objectValue?["inputs"] == nil)
        #expect(events.last?.remoteTaskID == nil)
        #expect(try await journal.recoveryAction(for: "seedance-rejected") == .alreadyTerminal(.failed))
    }

    @Test
    func testTransientCancelledRemoteResultIsRequeriedAndRecoveredAsSuccess() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try TestSupport.fakeLibTV()
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let artifact = directory.appendingPathComponent("recovered.png")
        try Data("recovered image".utf8).write(to: artifact)
        let api = FakeRunnerAPI(job: RunnerJob(
            id: "transient-cancelled",
            state: .leased,
            capability: "image",
            payload: ["arguments": .array([.string("cancelled")])]
        ))
        let journal = try SubmissionJournal(databaseURL: directory.appendingPathComponent("runner.sqlite"))
        let engine = RunnerEngine(
            api: api,
            journal: journal,
            commandBuilder: CancelledThenSuccessBuilder(successPath: artifact.path),
            hostname: "test",
            version: "1",
            pollInterval: .milliseconds(10)
        )
        await engine.register(
            profile: RunnerProfile(profileRef: "p1", accountRef: "a", displayName: "A", capabilities: ["image"]),
            executor: ProfileExecutor(
                profileRef: "p1",
                runner: LibTVProcessRunner(executableURL: executable, homeURL: directory),
                limiter: try GlobalConcurrencyLimiter(limit: 1)
            )
        )

        try await engine.tick()
        try await waitForEvent(api)

        let events = await api.recordedEvents()
        #expect(events.map(\.status) == [.submitting, .running, .succeeded])
        #expect(!events.contains(where: { $0.status == .cancelled || $0.status == .needsReview }))
        #expect(await api.uploadCount() == 1)
        #expect(try await journal.recoveryAction(for: "transient-cancelled") == .alreadyTerminal(.succeeded))
    }

    @Test
    func testRunningSubmissionIsPolledUntilSuccess() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try TestSupport.fakeLibTV()
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let artifact = directory.appendingPathComponent("polled.png")
        try Data("polled image".utf8).write(to: artifact)
        let api = FakeRunnerAPI(job: RunnerJob(
            id: "poll-success",
            state: .leased,
            capability: "image",
            payload: ["arguments": .array([.string("running")])]
        ))
        let journal = try SubmissionJournal(databaseURL: directory.appendingPathComponent("runner.sqlite"))
        let engine = RunnerEngine(
            api: api,
            journal: journal,
            commandBuilder: TransitionBuilder(successPath: artifact.path),
            hostname: "test",
            version: "1",
            pollInterval: .milliseconds(10)
        )
        await engine.register(
            profile: RunnerProfile(profileRef: "p1", accountRef: "a", displayName: "A", capabilities: ["image"]),
            executor: ProfileExecutor(
                profileRef: "p1",
                runner: LibTVProcessRunner(executableURL: executable, homeURL: directory),
                limiter: try GlobalConcurrencyLimiter(limit: 1)
            )
        )
        try await engine.tick()
        try await waitForEvent(api)
        let statuses = await api.recordedEvents().map(\.status)
        #expect(statuses == [.submitting, .running, .running, .running, .succeeded])
    }

    @Test
    func testDiscoveredRemoteTaskIDIsIncludedInNextStructuredHeartbeat() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try TestSupport.fakeLibTV()
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let api = FakeRunnerAPI(job: RunnerJob(
            id: "heartbeat-remote",
            state: .leased,
            capability: "image",
            payload: ["arguments": .array([.string("running")])]
        ))
        let journal = try SubmissionJournal(databaseURL: directory.appendingPathComponent("runner.sqlite"))
        let engine = RunnerEngine(
            api: api,
            journal: journal,
            commandBuilder: PayloadArgumentsCommandBuilder(),
            hostname: "test",
            version: "1",
            pollInterval: .seconds(5)
        )
        await engine.register(
            profile: RunnerProfile(
                profileRef: "p1",
                accountRef: "a1",
                displayName: "A",
                capabilities: ["image"]
            ),
            executor: ProfileExecutor(
                profileRef: "p1",
                runner: LibTVProcessRunner(executableURL: executable, homeURL: directory),
                limiter: try GlobalConcurrencyLimiter(limit: 1)
            )
        )

        try await engine.tick()
        for _ in 0..<100 {
            if await api.recordedEvents().contains(where: {
                $0.status == .running && $0.remoteTaskID == "remote-123"
            }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await engine.tick()

        let heartbeat = try #require(await api.recordedHeartbeats().last)
        let active = try #require(heartbeat.activeJobs.first(where: { $0.jobID == "heartbeat-remote" }))
        #expect(active.profileRef == "p1")
        #expect(active.remoteTaskID == "remote-123")

        try await engine.stopTracking(jobID: "heartbeat-remote")
        try await waitForEngineToDrain(engine)
    }

    @Test
    func testCancelBeforeSubmissionPreventsProcessLaunch() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try TestSupport.fakeLibTV()
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let api = FakeRunnerAPI(job: RunnerJob(
            id: "cancel-me",
            state: .leased,
            capability: "image",
            payload: ["arguments": .array([.string("crash")])]
        ))
        let journal = try SubmissionJournal(databaseURL: directory.appendingPathComponent("runner.sqlite"))
        let engine = RunnerEngine(
            api: api,
            journal: journal,
            hostname: "test",
            version: "1",
            preSubmissionDelay: .seconds(1)
        )
        await engine.register(
            profile: RunnerProfile(profileRef: "p1", accountRef: "a", displayName: "A", capabilities: ["image"]),
            executor: ProfileExecutor(
                profileRef: "p1",
                runner: LibTVProcessRunner(
                    executableURL: executable,
                    homeURL: directory
                ),
                limiter: try GlobalConcurrencyLimiter(limit: 1)
            )
        )
        try await engine.tick()
        let cancelled = try await engine.cancelBeforeSubmission(jobID: "cancel-me")
        #expect(cancelled.status == .cancelled)
        try await Task.sleep(for: .milliseconds(50))
        let events = await api.recordedEvents()
        let action = try await journal.recoveryAction(for: "cancel-me")
        #expect(events.isEmpty)
        #expect(action == .submitNew)
    }

    @Test
    func testCancelIsRejectedAfterSubmittingTransition() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try TestSupport.fakeLibTV()
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let api = FakeRunnerAPI(job: RunnerJob(
            id: "already-submitting",
            state: .leased,
            capability: "image",
            payload: ["arguments": .array([.string("sleep"), .string("1")])]
        ))
        let journal = try SubmissionJournal(databaseURL: directory.appendingPathComponent("runner.sqlite"))
        let engine = RunnerEngine(api: api, journal: journal, commandBuilder: PayloadArgumentsCommandBuilder(), hostname: "test", version: "1")
        await engine.register(
            profile: RunnerProfile(profileRef: "p1", accountRef: "a", displayName: "A", capabilities: ["image"]),
            executor: ProfileExecutor(
                profileRef: "p1",
                runner: LibTVProcessRunner(executableURL: executable, homeURL: directory),
                limiter: try GlobalConcurrencyLimiter(limit: 1)
            )
        )
        try await engine.tick()
        for _ in 0..<100 {
            if await api.recordedEvents().contains(where: { $0.status == .submitting }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        do {
            _ = try await engine.cancelBeforeSubmission(jobID: "already-submitting")
            Issue.record("Expected cancellation to be rejected after submitting")
        } catch let error as RunnerEngineControlError {
            #expect(error == .submissionAlreadyStarted)
        }
        await engine.stopTracking(profileRef: "p1")
        try await waitForEvent(api)
    }

    @Test
    func testDynamicProfileCapacityClaimsMultipleJobsAndShrinksByDraining() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try TestSupport.fakeLibTV()
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let jobs = (1...3).map { index in
            RunnerJob(
                id: "dynamic-\(index)",
                state: .leased,
                capability: "image",
                payload: ["arguments": .array([.string("sleep"), .string("0.12")])]
            )
        }
        let api = FakeRunnerAPI(jobs: jobs)
        let journal = try SubmissionJournal(databaseURL: directory.appendingPathComponent("runner.sqlite"))
        let engine = RunnerEngine(
            api: api,
            journal: journal,
            commandBuilder: DynamicRunningBuilder(),
            hostname: "test",
            version: "1",
            pollInterval: .milliseconds(10),
            maximumPollCount: 1
        )
        await engine.register(
            profile: RunnerProfile(
                profileRef: "p1",
                accountRef: "a",
                displayName: "A",
                capabilities: ["image"],
                maxConcurrency: 2
            ),
            executor: ProfileExecutor(
                profileRef: "p1",
                runner: LibTVProcessRunner(executableURL: executable, homeURL: directory),
                limiter: try GlobalConcurrencyLimiter(limit: 4)
            )
        )

        try await engine.tick()
        let initial = await engine.snapshot()
        #expect(initial.activeJobs == ["dynamic-1": "p1", "dynamic-2": "p1"])
        #expect(await api.claimCount() == 2)

        try await engine.setProfileMaxConcurrency(0, profileRef: "p1")
        #expect(try await engine.effectiveMaxConcurrency(profileRef: "p1") == 0)
        try await engine.tick()
        #expect(await api.claimCount() == 2)
        try await waitForEngineToDrain(engine)

        try await engine.setProfileMaxConcurrency(1, profileRef: "p1")
        try await engine.tick()
        let expanded = await engine.snapshot()
        #expect(expanded.activeJobs == ["dynamic-3": "p1"])
        #expect(await api.claimCount() == 3)
        await #expect(throws: RunnerEngineControlError.invalidProfileConcurrency) {
            try await engine.setProfileMaxConcurrency(9, profileRef: "p1")
        }
        try await engine.stopTracking(jobID: "dynamic-3")
        try await waitForEngineToDrain(engine)
    }

    @Test
    func testGlobalRemoteJobLimitIsSharedAcrossProfiles() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try TestSupport.fakeLibTV()
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let api = FakeRunnerAPI(jobs: (1...2).map { index in
            RunnerJob(
                id: "global-\(index)",
                state: .leased,
                capability: "image",
                payload: ["arguments": .array([.string("sleep"), .string("1")])]
            )
        })
        let journal = try SubmissionJournal(databaseURL: directory.appendingPathComponent("runner.sqlite"))
        let engine = RunnerEngine(
            api: api,
            journal: journal,
            commandBuilder: PayloadArgumentsCommandBuilder(),
            globalMaxConcurrency: 1,
            hostname: "test",
            version: "1"
        )
        let limiter = try GlobalConcurrencyLimiter(limit: 2)
        for profileRef in ["p1", "p2"] {
            await engine.register(
                profile: RunnerProfile(
                    profileRef: profileRef,
                    accountRef: "account-\(profileRef)",
                    displayName: profileRef,
                    capabilities: ["image"]
                ),
                executor: ProfileExecutor(
                    profileRef: profileRef,
                    runner: LibTVProcessRunner(
                        executableURL: executable,
                        homeURL: directory.appendingPathComponent(profileRef)
                    ),
                    limiter: limiter
                )
            )
        }

        try await engine.tick()
        let snapshot = await engine.snapshot()
        #expect(snapshot.registeredProfiles == 2)
        #expect(snapshot.globalMaxConcurrency == 1)
        #expect(snapshot.activeJobs.count == 1)
        #expect(await api.claimCount() == 1)
        #expect(await api.recordedHeartbeats().first?.globalMaxConcurrency == 1)

        let jobID = try #require(snapshot.activeJobs.keys.first)
        try await engine.stopTracking(jobID: jobID)
        try await waitForEngineToDrain(engine)
    }

    @Test
    func testGlobalConcurrencyShrinkDrainsWithoutInterruptingActiveJobs() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try TestSupport.fakeLibTV()
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let api = FakeRunnerAPI(jobs: (1...3).map { index in
            RunnerJob(
                id: "shrink-global-\(index)",
                state: .leased,
                capability: "image",
                payload: ["arguments": .array([.string("sleep"), .string("1")])]
            )
        })
        let journal = try SubmissionJournal(databaseURL: directory.appendingPathComponent("runner.sqlite"))
        let engine = RunnerEngine(
            api: api,
            journal: journal,
            commandBuilder: PayloadArgumentsCommandBuilder(),
            globalMaxConcurrency: 2,
            hostname: "test",
            version: "1"
        )
        let limiter = try GlobalConcurrencyLimiter(limit: 2)
        for profileRef in ["p1", "p2"] {
            await engine.register(
                profile: RunnerProfile(
                    profileRef: profileRef,
                    accountRef: "account-\(profileRef)",
                    displayName: profileRef,
                    capabilities: ["image"]
                ),
                executor: ProfileExecutor(
                    profileRef: profileRef,
                    runner: LibTVProcessRunner(
                        executableURL: executable,
                        homeURL: directory.appendingPathComponent(profileRef)
                    ),
                    limiter: limiter
                )
            )
        }

        try await engine.tick()
        for _ in 0..<100 {
            if await api.eventLog().filter({ $0.event.status == .submitting }).count == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let beforeShrink = await engine.snapshot()
        #expect(beforeShrink.activeJobs.count == 2)
        #expect(await api.claimCount() == 2)
        #expect(await api.eventLog().filter({ $0.event.status == .submitting }).count == 2)

        try await engine.setGlobalMaxConcurrency(1)
        let afterShrink = await engine.snapshot()
        #expect(afterShrink.globalMaxConcurrency == 1)
        #expect(afterShrink.activeJobs == beforeShrink.activeJobs)
        try await engine.tick()
        #expect(await api.claimCount() == 2)
        #expect(await engine.snapshot().activeJobs.count == 2)
        let eventsAfterShrink = await api.recordedEvents()
        #expect(!eventsAfterShrink.contains(where: { $0.status.isTerminal }))
        await #expect(throws: RunnerEngineControlError.invalidGlobalConcurrency) {
            try await engine.setGlobalMaxConcurrency(0)
        }

        for jobID in beforeShrink.activeJobs.keys {
            try await engine.stopTracking(jobID: jobID)
        }
        try await waitForEngineToDrain(engine)
    }

    @Test
    func testStopTrackingTargetsOneJobWithoutStoppingProfilePeer() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try TestSupport.fakeLibTV()
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let jobs = ["peer-1", "peer-2"].map { id in
            RunnerJob(
                id: id,
                state: .leased,
                capability: "image",
                payload: ["arguments": .array([.string("sleep"), .string("1")])]
            )
        }
        let api = FakeRunnerAPI(jobs: jobs)
        let journal = try SubmissionJournal(databaseURL: directory.appendingPathComponent("runner.sqlite"))
        let engine = RunnerEngine(api: api, journal: journal, commandBuilder: PayloadArgumentsCommandBuilder(), hostname: "test", version: "1")
        await engine.register(
            profile: RunnerProfile(
                profileRef: "p1", accountRef: "a", displayName: "A",
                capabilities: ["image"], maxConcurrency: 2
            ),
            executor: ProfileExecutor(
                profileRef: "p1",
                runner: LibTVProcessRunner(executableURL: executable, homeURL: directory),
                limiter: try GlobalConcurrencyLimiter(limit: 2)
            )
        )
        try await engine.tick()
        for _ in 0..<100 {
            if await api.eventLog().filter({ $0.event.status == .submitting }).count == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await engine.stopTracking(jobID: "peer-2")
        for _ in 0..<100 {
            if await api.eventLog().contains(where: {
                $0.jobID == "peer-2" && $0.event.status == .needsReview
            }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let afterStop = await engine.snapshot()
        #expect(afterStop.activeJobs["peer-1"] == "p1")
        let peerOneEvents = await api.eventLog().filter { $0.jobID == "peer-1" }
        #expect(!peerOneEvents.contains(where: { $0.event.status == .needsReview }))
        try await engine.stopTracking(jobID: "peer-1")
        try await waitForEngineToDrain(engine)
    }

    @Test
    func testCancelBeforeSubmissionTargetsOneLeasedJobOnly() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try TestSupport.fakeLibTV()
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let api = FakeRunnerAPI(jobs: ["leased-1", "leased-2"].map { id in
            RunnerJob(
                id: id,
                state: .leased,
                capability: "image",
                payload: ["arguments": .array([.string("running")])]
            )
        })
        let journal = try SubmissionJournal(databaseURL: directory.appendingPathComponent("runner.sqlite"))
        let engine = RunnerEngine(
            api: api,
            journal: journal,
            commandBuilder: PayloadArgumentsCommandBuilder(),
            hostname: "test",
            version: "1",
            preSubmissionDelay: .seconds(1)
        )
        await engine.register(
            profile: RunnerProfile(
                profileRef: "p1", accountRef: "a", displayName: "A",
                capabilities: ["image"], maxConcurrency: 2
            ),
            executor: ProfileExecutor(
                profileRef: "p1",
                runner: LibTVProcessRunner(executableURL: executable, homeURL: directory),
                limiter: try GlobalConcurrencyLimiter(limit: 2)
            )
        )
        try await engine.tick()
        _ = try await engine.cancelBeforeSubmission(jobID: "leased-2")
        try await Task.sleep(for: .milliseconds(30))
        let snapshot = await engine.snapshot()
        #expect(snapshot.activeJobs["leased-1"] == "p1")
        #expect(snapshot.activeJobs["leased-2"] == nil)
        #expect(await api.cancelledJobIDs() == ["leased-2"])
        _ = try await engine.cancelBeforeSubmission(jobID: "leased-1")
        try await waitForEngineToDrain(engine)
    }

    @Test
    func testRemoteTrackingKeepsTaskSlotButReleasesGlobalProcessPermit() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try TestSupport.fakeLibTV()
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let api = FakeRunnerAPI(job: RunnerJob(
            id: "tracking-slot",
            state: .running,
            capability: "image",
            remoteTaskID: "remote-tracking"
        ))
        let limiter = try GlobalConcurrencyLimiter(limit: 1)
        let journal = try SubmissionJournal(databaseURL: directory.appendingPathComponent("runner.sqlite"))
        let engine = RunnerEngine(
            api: api,
            journal: journal,
            commandBuilder: QueryOnlyBuilder(),
            hostname: "test",
            version: "1",
            pollInterval: .seconds(1),
            maximumPollCount: 5
        )
        await engine.register(
            profile: RunnerProfile(profileRef: "p1", accountRef: "a", displayName: "A", capabilities: ["image"]),
            executor: ProfileExecutor(
                profileRef: "p1",
                runner: LibTVProcessRunner(executableURL: executable, homeURL: directory),
                limiter: limiter
            )
        )
        try await engine.tick()
        for _ in 0..<100 {
            if await api.eventLog().contains(where: { $0.event.status == .running }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        for _ in 0..<100 {
            if await limiter.activeCount() == 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await engine.snapshot().activeJobs["tracking-slot"] == "p1")
        #expect(await limiter.activeCount() == 0)
        try await engine.stopTracking(jobID: "tracking-slot")
        try await waitForEngineToDrain(engine)
    }

    @Test
    func testPreparationFailureIsKnownFailedBeforePaidSubmission() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try TestSupport.fakeLibTV()
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let api = FakeRunnerAPI(job: RunnerJob(
            id: "prepare-failed",
            state: .leased,
            idempotencyKey: "prepare-failed-idem",
            capability: "image"
        ))
        let journal = try SubmissionJournal(databaseURL: directory.appendingPathComponent("runner.sqlite"))
        let engine = RunnerEngine(
            api: api,
            journal: journal,
            generationPreparer: FailingGenerationPreparer(),
            hostname: "test",
            version: "1"
        )
        await engine.register(
            profile: RunnerProfile(profileRef: "p1", accountRef: "a", displayName: "A", capabilities: ["image"]),
            executor: ProfileExecutor(
                profileRef: "p1",
                runner: LibTVProcessRunner(executableURL: executable, homeURL: directory),
                limiter: try GlobalConcurrencyLimiter(limit: 1)
            )
        )

        try await engine.tick()
        try await waitForEvent(api)

        #expect(await api.recordedEvents().last?.status == .failed)
        #expect(try await journal.recoveryAction(for: "prepare-failed") == .submitNew)
    }

    @Test
    func testShrinkDuringInFlightClaimCancelsLeaseBeforeSubmission() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try TestSupport.fakeLibTV()
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let api = FakeRunnerAPI(
            jobs: [RunnerJob(
                id: "in-flight",
                state: .leased,
                capability: "image",
                payload: ["arguments": .array([.string("crash")])]
            )],
            claimDelay: .milliseconds(100)
        )
        let journal = try SubmissionJournal(databaseURL: directory.appendingPathComponent("runner.sqlite"))
        let engine = RunnerEngine(api: api, journal: journal, commandBuilder: PayloadArgumentsCommandBuilder(), hostname: "test", version: "1")
        await engine.register(
            profile: RunnerProfile(
                profileRef: "p1", accountRef: "a", displayName: "A",
                capabilities: ["image"], maxConcurrency: 2
            ),
            executor: ProfileExecutor(
                profileRef: "p1",
                runner: LibTVProcessRunner(executableURL: executable, homeURL: directory),
                limiter: try GlobalConcurrencyLimiter(limit: 2)
            )
        )
        let tick = Task { try await engine.tick() }
        try await Task.sleep(for: .milliseconds(20))
        try await engine.setProfileMaxConcurrency(0, profileRef: "p1")
        try await tick.value
        #expect(await engine.snapshot().activeJobs.isEmpty)
        #expect(await api.cancelledJobIDs() == ["in-flight"])
        #expect(await api.recordedEvents().isEmpty)
        #expect(try await journal.recoveryAction(for: "in-flight") == .submitNew)
    }

    private func waitForEvent(_ api: FakeRunnerAPI) async throws {
        for _ in 0..<100 {
            let events = await api.recordedEvents()
            if events.last?.status.isTerminal == true { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Timed out waiting for engine event")
    }

    private func waitForEngineToDrain(_ engine: RunnerEngine) async throws {
        for _ in 0..<200 {
            if await engine.snapshot().activeJobs.isEmpty { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for RunnerEngine to drain")
    }
}

private struct QueryOnlyBuilder: LibTVCommandBuilding {
    func submissionArguments(for job: RunnerJob) throws -> [String] {
        Issue.record("A known remote task must never be submitted")
        return ["crash"]
    }

    func queryArguments(remoteTaskID: String, for job: RunnerJob) throws -> [String] {
        ["running-id", remoteTaskID]
    }
}

private struct TransitionBuilder: LibTVCommandBuilding {
    let successPath: String

    func submissionArguments(for job: RunnerJob) throws -> [String] { ["running"] }
    func queryArguments(remoteTaskID: String, for job: RunnerJob) throws -> [String] {
        ["success-local", successPath]
    }
}

private struct KnownRemoteSuccessBuilder: LibTVCommandBuilding {
    let successPath: String

    func submissionArguments(for job: RunnerJob) throws -> [String] {
        Issue.record("A known remote task must never be submitted")
        return ["crash"]
    }

    func queryArguments(remoteTaskID: String, for job: RunnerJob) throws -> [String] {
        ["success-local-id", remoteTaskID, successPath]
    }
}

private struct CancelledThenSuccessBuilder: LibTVCommandBuilding {
    let successPath: String

    func submissionArguments(for job: RunnerJob) throws -> [String] {
        try PayloadArgumentsCommandBuilder().submissionArguments(for: job)
    }

    func queryArguments(remoteTaskID: String, for job: RunnerJob) throws -> [String] {
        ["success-local", successPath]
    }
}

private struct DynamicRunningBuilder: LibTVCommandBuilding {
    func submissionArguments(for job: RunnerJob) throws -> [String] {
        try PayloadArgumentsCommandBuilder().submissionArguments(for: job)
    }

    func queryArguments(remoteTaskID: String, for job: RunnerJob) throws -> [String] {
        ["running"]
    }
}

private struct FailingGenerationPreparer: GenerationJobPreparing {
    struct PreparationFailure: LocalizedError {
        var errorDescription: String? { "preparation failed before submission" }
    }

    func prepare(job: RunnerJob, profileRef: String, executor: ProfileExecutor) async throws -> PreparedLibTVSubmission {
        throw PreparationFailure()
    }
}

private struct StaticGenerationPreparer: GenerationJobPreparing {
    let prepared: PreparedLibTVSubmission

    func prepare(job: RunnerJob, profileRef: String, executor: ProfileExecutor) async throws -> PreparedLibTVSubmission {
        prepared
    }
}

private actor FakeRunnerAPI: RunnerAPITransport, ArtifactAPITransport {
    private var jobs: [RunnerJob]
    private var heartbeatCommands: [[RunnerControlCommand]]
    private var claims = 0
    private var events: [JobEventRequest] = []
    private var eventsByJob: [(jobID: String, event: JobEventRequest)] = []
    private var cancelledJobs: [String] = []
    private var heartbeats: [RunnerHeartbeatRequest] = []
    private var uploads = 0
    private let claimDelay: Duration

    init(job: RunnerJob?, heartbeatCommands: [[RunnerControlCommand]] = []) {
        self.jobs = job.map { [$0] } ?? []
        self.heartbeatCommands = heartbeatCommands
        self.claimDelay = .zero
    }

    init(
        jobs: [RunnerJob],
        heartbeatCommands: [[RunnerControlCommand]] = [],
        claimDelay: Duration = .zero
    ) {
        self.jobs = jobs
        self.heartbeatCommands = heartbeatCommands
        self.claimDelay = claimDelay
    }

    func syncProfiles(_ profiles: [RunnerProfile]) async throws -> SyncProfilesResponse {
        SyncProfilesResponse(runnerID: "runner", synced: profiles.count, profileRefs: profiles.map(\.profileRef))
    }

    func claim(profileRef: String, capabilities: [String]) async throws -> ClaimedJob {
        claims += 1
        if claimDelay > .zero { try await Task.sleep(for: claimDelay) }
        return ClaimedJob(job: jobs.isEmpty ? nil : jobs.removeFirst())
    }

    func heartbeat(_ request: RunnerHeartbeatRequest) async throws -> RunnerHeartbeatResponse {
        heartbeats.append(request)
        let commands = heartbeatCommands.isEmpty ? [] : heartbeatCommands.removeFirst()
        return RunnerHeartbeatResponse(ok: true, serverTime: .now, leaseSeconds: 60, commands: commands)
    }

    func acknowledge(commandID: String, acknowledgement: CommandAcknowledgement) async throws { }

    func postJobEvent(jobID: String, event: JobEventRequest) async throws {
        events.append(event)
        eventsByJob.append((jobID, event))
    }

    func cancelLeasedJob(jobID: String, profileRef: String) async throws -> RunnerJob {
        cancelledJobs.append(jobID)
        return RunnerJob(id: jobID, state: .cancelled, executionProfileRef: profileRef)
    }

    func initializeArtifact(jobID: String, request: ArtifactInitRequest) async throws -> ArtifactInitResponse {
        ArtifactInitResponse(
            artifactID: "artifact-1",
            uploadURL: URL(string: "https://upload.test/object")!,
            method: "PUT",
            headers: ["x-test": "yes"],
            expiresInSeconds: 300
        )
    }

    func uploadArtifact(
        fileURL: URL,
        to signedURL: URL,
        method: String,
        contentType: String,
        headers: [String: String]
    ) async throws {
        uploads += 1
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        #expect(headers["x-test"] == "yes")
    }

    func completeArtifact(
        jobID: String,
        artifactID: String,
        request: ArtifactCompleteRequest
    ) async throws -> ArtifactCompleteResponse {
        ArtifactCompleteResponse(
            artifactID: artifactID,
            completed: true,
            contentURL: URL(string: "https://canvas.test/artifacts/\(artifactID)")!
        )
    }

    func claimCount() -> Int { claims }
    func recordedEvents() -> [JobEventRequest] { events }
    func eventLog() -> [(jobID: String, event: JobEventRequest)] { eventsByJob }
    func uploadCount() -> Int { uploads }
    func cancelledJobIDs() -> [String] { cancelledJobs }
    func recordedHeartbeats() -> [RunnerHeartbeatRequest] { heartbeats }
}
