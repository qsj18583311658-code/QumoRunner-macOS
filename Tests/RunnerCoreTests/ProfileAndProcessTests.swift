import Foundation
import Testing
@testable import RunnerCore

@Suite struct ProfileAndProcessTests {
    @Test
    func testProfileStorageCreatesSecureDirectoriesAndCredentials() throws {
        let temporary = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let storage = ProfileStorage(applicationSupportRoot: temporary.appendingPathComponent("QumoRunner"))
        let paths = try storage.prepare(profileRef: "account-1")
        FileManager.default.createFile(atPath: paths.credentials.path, contents: Data("secret".utf8))
        try storage.secureCredentials(for: "account-1")

        let directoryMode = try #require(
            FileManager.default.attributesOfItem(atPath: paths.home.path)[.posixPermissions] as? NSNumber
        ).intValue
        let credentialMode = try #require(
            FileManager.default.attributesOfItem(atPath: paths.credentials.path)[.posixPermissions] as? NSNumber
        ).intValue
        #expect(directoryMode & 0o777 == 0o700)
        #expect(credentialMode & 0o777 == 0o600)
        #expect(throws: ProfileStorageError.invalidProfileReference) {
            try storage.prepare(profileRef: "../escape")
        }
    }

    @Test
    func testProcessUsesIsolatedHomeAndDoesNotInvokeShell() async throws {
        let executable = try TestSupport.fakeLibTV()
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let home = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = LibTVProcessRunner(executableURL: executable, homeURL: home)

        let homeResult = try await runner.run(arguments: ["home"], timeout: .seconds(2))
        #expect(homeResult.standardOutput == home.path)

        let marker = home.appendingPathComponent("must-not-exist")
        let literal = "$(touch \(marker.path))"
        let argumentResult = try await runner.run(arguments: ["echo-arg", literal], timeout: .seconds(2))
        #expect(argumentResult.standardOutput == literal)
        #expect(!FileManager.default.fileExists(atPath: marker.path))

        let isolatedEnvironment = try await runner.run(
            arguments: ["identity-env"],
            additionalEnvironment: [
                "HOME": "/tmp/wrong-home",
                "LIBTV_TOKEN": "wrong-token",
                "LIBTV_CONFIG_DIR": "/tmp/wrong-config",
            ],
            timeout: .seconds(2)
        )
        #expect(isolatedEnvironment.standardOutput == "||\(home.path)")
    }

    @Test
    func testTimeoutAndCrashAreNotSuccessful() async throws {
        let executable = try TestSupport.fakeLibTV()
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let home = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = LibTVProcessRunner(executableURL: executable, homeURL: home)

        let timedOut = try await runner.run(
            arguments: ["sleep", "2"],
            timeout: .milliseconds(80)
        )
        #expect(timedOut.disposition == .needsReview(.timeout))

        let crashed = try await runner.run(arguments: ["crash"], timeout: .seconds(2))
        #expect(crashed.disposition == .crashed)
    }

    @Test
    func testSameProfileRunsConcurrentlyWithinProfileAndGlobalLimits() async throws {
        let executable = try TestSupport.fakeLibTV()
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let home = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let limiter = try GlobalConcurrencyLimiter(limit: 2)
        let profile = ProfileExecutor(
            profileRef: "one",
            runner: LibTVProcessRunner(executableURL: executable, homeURL: home),
            limiter: limiter
        )
        await profile.setMaxConcurrency(2)
        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            async let first = profile.execute(jobID: "concurrent-1", arguments: ["sleep", "0.25"], timeout: .seconds(2))
            async let second = profile.execute(jobID: "concurrent-2", arguments: ["sleep", "0.25"], timeout: .seconds(2))
            _ = try await (first, second)
        }
        #expect(elapsed < .milliseconds(450))
        try await limiter.setLimit(8)
        let configuredLimit = await limiter.configuredLimit()
        #expect(configuredLimit == 8)
        await expectThrows { try await limiter.setLimit(9) }
    }

    @Test
    func testGlobalLimiterStillSerializesAConcurrentProfile() async throws {
        let executable = try TestSupport.fakeLibTV()
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let home = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let profile = ProfileExecutor(
            profileRef: "one",
            runner: LibTVProcessRunner(executableURL: executable, homeURL: home),
            limiter: try GlobalConcurrencyLimiter(limit: 1)
        )
        await profile.setMaxConcurrency(2)

        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            async let first = profile.execute(jobID: "global-1", arguments: ["sleep", "0.2"], timeout: .seconds(2))
            async let second = profile.execute(jobID: "global-2", arguments: ["sleep", "0.2"], timeout: .seconds(2))
            _ = try await (first, second)
        }
        #expect(elapsed >= .milliseconds(350))
    }

    @Test
    func testStoppingOneConcurrentJobDoesNotTerminateItsPeer() async throws {
        let executable = try TestSupport.fakeLibTV()
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let home = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let profile = ProfileExecutor(
            profileRef: "one",
            runner: LibTVProcessRunner(executableURL: executable, homeURL: home),
            limiter: try GlobalConcurrencyLimiter(limit: 2)
        )
        await profile.setMaxConcurrency(2)
        let first = Task {
            try await profile.execute(jobID: "peer-1", arguments: ["sleep", "0.25"], timeout: .seconds(2))
        }
        let second = Task {
            try await profile.execute(jobID: "peer-2", arguments: ["sleep", "1"], timeout: .seconds(2))
        }
        for _ in 0..<100 {
            if await profile.runningJobIDs().count == 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(await profile.stopTracking(jobID: "peer-2"))
        let stopped = try await second.value
        let untouched = try await first.value
        #expect(stopped.disposition == .needsReview(.requestedAfterLaunch))
        #expect(untouched.disposition == .exited)
        #expect(untouched.exitCode == 0)
    }

    @Test
    func testCancelledGlobalWaiterDoesNotLeakPermitOrLaunchCLI() async throws {
        let executable = try TestSupport.fakeLibTV()
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let firstHome = try TestSupport.temporaryDirectory()
        let secondHome = try TestSupport.temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: firstHome)
            try? FileManager.default.removeItem(at: secondHome)
        }
        let limiter = try GlobalConcurrencyLimiter(limit: 1)
        let first = ProfileExecutor(
            profileRef: "first",
            runner: LibTVProcessRunner(executableURL: executable, homeURL: firstHome),
            limiter: limiter
        )
        let second = ProfileExecutor(
            profileRef: "second",
            runner: LibTVProcessRunner(executableURL: executable, homeURL: secondHome),
            limiter: limiter
        )
        let running = Task {
            try await first.execute(jobID: "first-job", arguments: ["sleep", "0.15"])
        }
        try await Task.sleep(for: .milliseconds(20))
        let cancelled = Task {
            try await second.execute(jobID: "cancelled-job", arguments: ["crash"])
        }
        try await Task.sleep(for: .milliseconds(20))
        cancelled.cancel()
        _ = try? await cancelled.value
        _ = try await running.value
        #expect(await limiter.activeCount() == 0)

        let afterCancellation = try await second.execute(
            jobID: "next-job",
            arguments: ["running"],
            timeout: .seconds(1)
        )
        #expect(afterCancellation.exitCode == 0)
        #expect(await limiter.activeCount() == 0)
    }
}

private func expectThrows(_ expression: () async throws -> Void) async {
    do {
        try await expression()
        Issue.record("Expected error")
    } catch { }
}
