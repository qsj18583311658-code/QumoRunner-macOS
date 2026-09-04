import Foundation
import Testing
@testable import RunnerCore

private actor TaskSnapshotRecorder {
    private var values: [LibTVTaskSnapshot] = []

    func append(_ snapshot: LibTVTaskSnapshot) { values.append(snapshot) }
    func snapshots() -> [LibTVTaskSnapshot] { values }
}

@Suite struct SubmissionJournalTests {
    @Test
    func testRuntimeIdentityIsWriteOnceAndSurvivesReopen() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("runner.sqlite")
        let first = LibTVRuntimeIdentity(version: "1.0.2", sha256: String(repeating: "a", count: 64))
        do {
            let journal = try SubmissionJournal(databaseURL: databaseURL)
            _ = try await journal.recordSubmissionIntent(
                jobID: "runtime-job",
                profileRef: "profile-1",
                requestFingerprint: "hash",
                runtime: first
            )
            await #expect(throws: SubmissionJournalError.self) {
                try await journal.bindRuntime(
                    jobID: "runtime-job",
                    runtime: .init(version: "1.1.0", sha256: String(repeating: "b", count: 64))
                )
            }
        }
        let reopened = try SubmissionJournal(databaseURL: databaseURL)
        #expect(try await reopened.record(for: "runtime-job")?.runtimeIdentity == first)
    }

    @Test
    func testIntentIsIdempotentAndUnknownSubmissionNeedsReview() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try SubmissionJournal(databaseURL: directory.appendingPathComponent("runner.sqlite"))
        let inserted = try await journal.recordSubmissionIntent(
            jobID: "job-1", profileRef: "profile-1", requestFingerprint: "hash"
        )
        let duplicate = try await journal.recordSubmissionIntent(
            jobID: "job-1", profileRef: "profile-1", requestFingerprint: "hash"
        )
        let action = try await journal.recoveryAction(for: "job-1")
        #expect(inserted)
        #expect(!duplicate)
        #expect(action == .needsReview)
    }

    @Test
    func testKnownRemoteTaskIsQueryOnlyAcrossRestart() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("runner.sqlite")
        do {
            let journal = try SubmissionJournal(databaseURL: databaseURL)
            _ = try await journal.recordSubmissionIntent(
                jobID: "job-2", profileRef: "profile-1", requestFingerprint: "hash"
            )
            try await journal.attachRemoteTask(jobID: "job-2", remoteTaskID: "remote-2")
        }
        let reopened = try SubmissionJournal(databaseURL: databaseURL)
        let action = try await reopened.recoveryAction(for: "job-2")
        #expect(action == .queryRemote(taskID: "remote-2"))
    }

    @Test
    func testCrashAfterIntentIsPersistedAsNeedsReview() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try TestSupport.fakeLibTV()
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let journal = try SubmissionJournal(databaseURL: directory.appendingPathComponent("runner.sqlite"))
        let limiter = try GlobalConcurrencyLimiter(limit: 1)
        let profile = ProfileExecutor(
            profileRef: "profile-1",
            runner: LibTVProcessRunner(executableURL: executable, homeURL: directory),
            limiter: limiter
        )
        let executor = SubmissionExecutor(profile: profile, journal: journal)
        let outcome = try await executor.submit(
            jobID: "job-crash",
            profileRef: "profile-1",
            requestFingerprint: "hash",
            arguments: ["crash"],
            timeout: .seconds(2)
        )
        guard case .process(let result, _) = outcome else {
            Issue.record("Expected process result")
            return
        }
        #expect(result.disposition == .crashed)
        let action = try await journal.recoveryAction(for: "job-crash")
        #expect(action == .alreadyTerminal(.needsReview))
    }

    @Test
    func testArgumentParserRejectionIsKnownFailed() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try TestSupport.fakeLibTV()
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let journal = try SubmissionJournal(databaseURL: directory.appendingPathComponent("runner.sqlite"))
        let limiter = try GlobalConcurrencyLimiter(limit: 1)
        let profile = ProfileExecutor(
            profileRef: "profile-1",
            runner: LibTVProcessRunner(executableURL: executable, homeURL: directory),
            limiter: limiter
        )
        let executor = SubmissionExecutor(profile: profile, journal: journal)

        let outcome = try await executor.submit(
            jobID: "job-invalid-arguments",
            profileRef: "profile-1",
            requestFingerprint: "hash",
            arguments: ["argument-rejected"],
            timeout: .seconds(2)
        )

        guard case .process(let result, let snapshot?) = outcome else {
            Issue.record("Expected a known failed process result")
            return
        }
        #expect(result.wasRejectedByArgumentParser)
        #expect(snapshot.state == .failed)
        #expect(try await journal.recoveryAction(for: "job-invalid-arguments") == .alreadyTerminal(.failed))
    }

    @Test(arguments: [
        ("seedance-compliance-rejected-zh", "seedance_compliance_rejected", SeedanceComplianceCLIErrorClassification.rejected),
        ("seedance-compliance-retryable-en", "seedance_compliance_retryable_error", SeedanceComplianceCLIErrorClassification.retryableError),
    ])
    func testExplicitSeedanceComplianceFailureBeforeRemoteIDIsKnownFailed(
        scenario: String,
        rawStatus: String,
        classification: SeedanceComplianceCLIErrorClassification
    ) async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try TestSupport.fakeLibTV()
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let journal = try SubmissionJournal(databaseURL: directory.appendingPathComponent("runner.sqlite"))
        let executor = SubmissionExecutor(
            profile: ProfileExecutor(
                profileRef: "profile-1",
                runner: LibTVProcessRunner(executableURL: executable, homeURL: directory),
                limiter: try GlobalConcurrencyLimiter(limit: 1)
            ),
            journal: journal
        )

        let outcome = try await executor.submit(
            jobID: "job-\(classification.rawValue)",
            profileRef: "profile-1",
            requestFingerprint: "hash",
            arguments: [scenario],
            seedanceCompliancePreflight: .init(status: .checking, inputOrders: [0]),
            timeout: .seconds(2)
        )

        guard case .process(_, let snapshot?) = outcome else {
            Issue.record("Expected a classified compliance failure")
            return
        }
        #expect(snapshot.state == .failed)
        #expect(snapshot.taskID == nil)
        #expect(snapshot.rawStatus == rawStatus)
        #expect(try await journal.recoveryAction(for: "job-\(classification.rawValue)") == .alreadyTerminal(.failed))
    }

    @Test(arguments: ["seedance-compliance-ambiguous", "ordinary-model-failed"])
    func testAmbiguousOrOrdinaryFailureBeforeRemoteIDStillNeedsReview(scenario: String) async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try TestSupport.fakeLibTV()
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let journal = try SubmissionJournal(databaseURL: directory.appendingPathComponent("runner.sqlite"))
        let executor = SubmissionExecutor(
            profile: ProfileExecutor(
                profileRef: "profile-1",
                runner: LibTVProcessRunner(executableURL: executable, homeURL: directory),
                limiter: try GlobalConcurrencyLimiter(limit: 1)
            ),
            journal: journal
        )

        let outcome = try await executor.submit(
            jobID: "job-\(scenario)",
            profileRef: "profile-1",
            requestFingerprint: "hash",
            arguments: [scenario],
            seedanceCompliancePreflight: .init(status: .checking, inputOrders: [0]),
            timeout: .seconds(2)
        )

        guard case .process(_, nil) = outcome else {
            Issue.record("Expected an uncertain submission outcome")
            return
        }
        #expect(try await journal.recoveryAction(for: "job-\(scenario)") == .alreadyTerminal(.needsReview))
    }

    @Test
    func testRemoteTerminalFailureRemainsQueryableUntilEngineConfirmsIt() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try TestSupport.fakeLibTV()
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let journal = try SubmissionJournal(databaseURL: directory.appendingPathComponent("runner.sqlite"))
        let profile = ProfileExecutor(
            profileRef: "profile-1",
            runner: LibTVProcessRunner(executableURL: executable, homeURL: directory),
            limiter: try GlobalConcurrencyLimiter(limit: 1)
        )
        let executor = SubmissionExecutor(profile: profile, journal: journal)

        let outcome = try await executor.submit(
            jobID: "job-remote-failed",
            profileRef: "profile-1",
            requestFingerprint: "hash",
            arguments: ["remote-failed"],
            timeout: .seconds(2)
        )

        guard case .process(let result, let snapshot?) = outcome else {
            Issue.record("Expected a known remote failure")
            return
        }
        #expect(result.exitCode == 1)
        #expect(snapshot.taskID == "remote-failed-123")
        #expect(snapshot.state == .failed)
        #expect(try await journal.recoveryAction(for: "job-remote-failed") == .queryRemote(taskID: "remote-failed-123"))
    }

    @Test
    func testExplicitReviewReopensSameRemoteIdentityAndRejectsConflicts() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try SubmissionJournal(databaseURL: directory.appendingPathComponent("runner.sqlite"))
        _ = try await journal.recordSubmissionIntent(
            jobID: "review-job", profileRef: "profile-1", requestFingerprint: "hash"
        )
        try await journal.attachRemoteTask(jobID: "review-job", remoteTaskID: "remote-review")
        try await journal.markTerminal(jobID: "review-job", state: .needsReview)

        try await journal.resumeRemoteQuery(
            jobID: "review-job", profileRef: "profile-1", remoteTaskID: "remote-review"
        )
        #expect(try await journal.recoveryAction(for: "review-job") == .queryRemote(taskID: "remote-review"))

        do {
            try await journal.resumeRemoteQuery(
                jobID: "review-job", profileRef: "profile-1", remoteTaskID: "different-remote"
            )
            Issue.record("Expected a remote identity conflict")
        } catch let error as SubmissionJournalError {
            guard case .conflictingRemoteTaskID(let stored, let requested) = error else {
                Issue.record("Expected conflictingRemoteTaskID")
                return
            }
            #expect(stored == "remote-review")
            #expect(requested == "different-remote")
        }
    }

    @Test
    func testLiveRunningProgressIsForwardedBeforeProcessExit() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try TestSupport.fakeLibTV()
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let journal = try SubmissionJournal(databaseURL: directory.appendingPathComponent("runner.sqlite"))
        let profile = ProfileExecutor(
            profileRef: "profile-1",
            runner: LibTVProcessRunner(executableURL: executable, homeURL: directory),
            limiter: try GlobalConcurrencyLimiter(limit: 1)
        )
        let executor = SubmissionExecutor(profile: profile, journal: journal)
        let recorder = TaskSnapshotRecorder()

        _ = try await executor.submit(
            jobID: "job-live-progress",
            profileRef: "profile-1",
            requestFingerprint: "hash",
            arguments: ["stream-task", "0.1"],
            timeout: .seconds(2),
            onTaskSnapshot: { snapshot in await recorder.append(snapshot) }
        )

        let snapshots = await recorder.snapshots()
        #expect(snapshots.map(\.taskID) == ["remote-stream-123"])
        #expect(snapshots.map(\.progressPercent) == [1])
        #expect(snapshots.map(\.state) == [.running])
    }

    @Test
    func testCreatedNodeVisibilityRaceRunsExistingNodeWithoutRepeatingCreate() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try TestSupport.fakeLibTV()
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let journal = try SubmissionJournal(databaseURL: directory.appendingPathComponent("runner.sqlite"))
        let profile = ProfileExecutor(
            profileRef: "profile-1",
            runner: LibTVProcessRunner(executableURL: executable, homeURL: directory),
            limiter: try GlobalConcurrencyLimiter(limit: 1)
        )
        let executor = SubmissionExecutor(profile: profile, journal: journal)

        let outcome = try await executor.submit(
            jobID: "job-visibility-race",
            profileRef: "profile-1",
            requestFingerprint: "hash",
            arguments: [
                "node", "create", "visibility-race",
                "--project", "project-1",
                "--group", "group-1",
                "--type", "image",
                "--run",
            ],
            timeout: .seconds(3)
        )

        guard case .process(let result, let snapshot?) = outcome else {
            Issue.record("Expected recovered process result")
            return
        }
        #expect(result.exitCode == 0)
        #expect(snapshot.taskID == "remote-visibility-123")
        #expect(snapshot.state == .succeeded)
        #expect(try await journal.recoveryAction(for: "job-visibility-race") == .alreadyTerminal(.succeeded))

        let invocations = try String(
            contentsOf: directory.appendingPathComponent("invocations.log"),
            encoding: .utf8
        )
        #expect(invocations.components(separatedBy: "node create visibility-race").count - 1 == 1)
        #expect(invocations.contains("node visibility-race --project project-1 --group group-1 --run"))
    }

    @Test
    func testKnownRemoteNetworkQueryFailureRemainsRetryable() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try TestSupport.fakeLibTV()
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let journal = try SubmissionJournal(databaseURL: directory.appendingPathComponent("runner.sqlite"))
        _ = try await journal.recordSubmissionIntent(
            jobID: "job-query-retry",
            profileRef: "profile-1",
            requestFingerprint: "hash"
        )
        try await journal.attachRemoteTask(jobID: "job-query-retry", remoteTaskID: "remote-query-123")
        let profile = ProfileExecutor(
            profileRef: "profile-1",
            runner: LibTVProcessRunner(executableURL: executable, homeURL: directory),
            limiter: try GlobalConcurrencyLimiter(limit: 1)
        )
        let executor = SubmissionExecutor(profile: profile, journal: journal)

        let outcome = try await executor.queryKnownRemote(
            jobID: "job-query-retry",
            arguments: ["query-network-failed"],
            timeout: .seconds(2)
        )

        guard case .process(let result, let snapshot?) = outcome else {
            Issue.record("Expected retryable running snapshot")
            return
        }
        #expect(result.exitCode == 1)
        #expect(snapshot.taskID == "remote-query-123")
        #expect(snapshot.state == .running)
        #expect(snapshot.rawStatus == "query_retry")
        #expect(try await journal.recoveryAction(for: "job-query-retry") == .queryRemote(taskID: "remote-query-123"))
    }

    @Test
    func testLogsCanBeFiltered() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try SubmissionJournal(databaseURL: directory.appendingPathComponent("runner.sqlite"))
        try await journal.appendLog(level: "info", message: "one", jobID: "a", profileRef: "p")
        try await journal.appendLog(level: "error", message: "two", jobID: "b", profileRef: "p")
        let logs = try await journal.logs(jobID: "a")
        #expect(logs.map(\.message) == ["one"])
    }
}
