import Foundation
import Testing
@testable import RunnerCore

@Suite struct LibTVRuntimeTests {
    @Test
    func registryAtomicallyActivatesPersistsAndRollsBack() async throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fallbackURL = try makeExecutable(root.appending(path: "Bundled/libtv"), output: "fallback")
        let fallback = LibTVRuntimeRecord(
            identity: .init(version: "1.0.2", sha256: String(repeating: "a", count: 64)),
            executableURL: fallbackURL,
            source: .bundled,
            teamIdentifier: LibTVRuntimeInstaller.officialTeamIdentifier,
            cdHash: "fallback-cdhash",
            strictSignatureValid: true
        )
        let runtimes = root.appending(path: "Runtimes")
        let registry = LibTVRuntimeRegistry(rootURL: runtimes, bundledFallback: fallback)
        try await registry.bootstrap()
        let candidateIdentity = LibTVRuntimeIdentity(version: "1.1.0", sha256: String(repeating: "b", count: 64))
        let candidateURL = try makeExecutable(
            runtimes.appending(path: "1.1.0/\(candidateIdentity.sha256)/libtv"),
            output: "candidate"
        )
        try await registry.stageCandidate(.init(
            identity: candidateIdentity,
            executableURL: candidateURL,
            source: .downloaded,
            archiveSHA256: String(repeating: "c", count: 64),
            teamIdentifier: LibTVRuntimeInstaller.officialTeamIdentifier,
            cdHash: "candidate-cdhash",
            strictSignatureValid: true
        ))
        let staged = try await registry.snapshot()
        #expect(staged.active == fallback.identity)
        #expect(staged.candidate == candidateIdentity)
        #expect(staged.protocolVersion == "1")

        _ = try await registry.activateCandidate()
        let active = try await registry.snapshot()
        #expect(active.active == candidateIdentity)
        #expect(active.previous == fallback.identity)
        #expect(active.candidate == nil)
        #expect(active.activeTeamIdentifier == "U5N2L989V7")

        let reopened = LibTVRuntimeRegistry(rootURL: runtimes, bundledFallback: fallback)
        try await reopened.bootstrap()
        #expect(try await reopened.activeRuntime().identity == candidateIdentity)
        #expect(try await reopened.rollback().identity == fallback.identity)
        #expect(try await reopened.snapshot().previous == candidateIdentity)
    }

    @Test
    func remoteRecheckKeepsPersistedRuntimeAndLegacyUsesBundledFallback() async throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fallbackURL = try makeExecutable(root.appending(path: "Bundled/libtv"), output: "fallback")
        let fallback = LibTVRuntimeRecord(
            identity: .init(version: "1.0.2", sha256: String(repeating: "a", count: 64)),
            executableURL: fallbackURL,
            source: .bundled
        )
        let runtimes = root.appending(path: "Runtimes")
        let registry = LibTVRuntimeRegistry(rootURL: runtimes, bundledFallback: fallback)
        try await registry.bootstrap()
        let newer = LibTVRuntimeIdentity(version: "1.1.0", sha256: String(repeating: "b", count: 64))
        let newerURL = try makeExecutable(runtimes.appending(path: "1.1.0/\(newer.sha256)/libtv"), output: "new")
        try await registry.stageCandidate(.init(identity: newer, executableURL: newerURL, source: .downloaded))
        _ = try await registry.activateCandidate()

        let persisted = try await registry.resolveRuntime(requirement: nil, persisted: fallback.identity, remoteTaskExists: true)
        let legacy = try await registry.resolveRuntime(requirement: nil, persisted: nil, remoteTaskExists: true)
        let migratedLegacy = try await registry.resolveRuntime(
            requirement: .init(version: "1.0.2"),
            persisted: nil,
            remoteTaskExists: true
        )
        let newJob = try await registry.resolveRuntime(requirement: nil, persisted: nil, remoteTaskExists: false)
        #expect(persisted.identity == fallback.identity)
        #expect(legacy.identity == fallback.identity)
        #expect(migratedLegacy.identity == fallback.identity)
        #expect(newJob.identity == newer)
        await #expect(throws: LibTVRuntimeRegistryError.self) {
            _ = try await registry.resolveRuntime(
                requirement: .init(version: "1.1.0", sha256: newer.sha256),
                persisted: fallback.identity,
                remoteTaskExists: true
            )
        }
    }

    @Test
    func zipSlipSymlinkAndUnofficialDownloadsAreRejected() throws {
        for entry in ["../libtv", "/tmp/libtv", "safe/../../libtv", "C:/libtv", "safe\\libtv"] {
            #expect(throws: LibTVRuntimeInstallError.self) {
                try LibTVRuntimeInstaller.validateArchiveEntries([entry])
            }
        }
        #expect(throws: LibTVRuntimeInstallError.self) {
            try LibTVRuntimeInstaller.validateArchiveEntryModes([
                "lrwxr-xr-x  3.0 unx  8 bx stor 1-Jan-26 00:00 escape",
                "-rwxr-xr-x  3.0 unx 10 tx defN 1-Jan-26 00:00 escape/libtv",
            ])
        }
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fallbackURL = try makeExecutable(root.appending(path: "libtv"), output: "fallback")
        let registry = LibTVRuntimeRegistry(
            rootURL: root.appending(path: "Runtimes"),
            bundledFallback: .init(
                identity: .init(version: "1.0.2", sha256: String(repeating: "a", count: 64)),
                executableURL: fallbackURL,
                source: .bundled
            )
        )
        let installer = LibTVRuntimeInstaller(registry: registry)
        try installer.validateOfficialVersionedURL(
            URL(string: "https://liblibai-web-static.liblib.cloud/cli/1.1.0/libtv-macos-arm64.zip")!,
            version: "1.1.0"
        )
        #expect(throws: LibTVRuntimeInstallError.self) {
            try installer.validateOfficialVersionedURL(
                URL(string: "https://example.com/cli/1.1.0/libtv-macos-arm64.zip")!,
                version: "1.1.0"
            )
        }
    }

    @Test
    func profileExecutionUsesTheRuntimeBoundAbsolutePath() async throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fallback = try makeExecutable(root.appending(path: "fallback/libtv"), output: "fallback")
        let candidate = try makeExecutable(root.appending(path: "candidate/libtv"), output: "candidate")
        let profile = ProfileExecutor(
            profileRef: "profile",
            runner: LibTVProcessRunner(executableURL: fallback, homeURL: root),
            limiter: try GlobalConcurrencyLimiter(limit: 1)
        )
        await profile.setMaxConcurrency(1)
        try await profile.bindRuntime(jobID: "job-pinned", executableURL: candidate)
        let result = try await profile.execute(jobID: "job-pinned:prepare", arguments: [])
        #expect(result.standardOutput == "candidate")
        await profile.unbindRuntime(jobID: "job-pinned")
        let defaultResult = try await profile.execute(jobID: "job-default", arguments: [])
        #expect(defaultResult.standardOutput == "fallback")
    }

    @Test
    func validationReportsPersistUntilTerminalServerAcknowledgement() async throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fallbackURL = try makeExecutable(root.appending(path: "Bundled/libtv"), output: "fallback")
        let record = LibTVRuntimeRecord(
            identity: .init(version: "1.1.0", sha256: String(repeating: "b", count: 64)),
            executableURL: fallbackURL,
            source: .downloaded,
            archiveSHA256: String(repeating: "c", count: 64),
            teamIdentifier: "U5N2L989V7",
            cdHash: "cdhash",
            strictSignatureValid: true
        )
        let fallback = LibTVRuntimeRecord(
            identity: .init(version: "1.0.2", sha256: String(repeating: "a", count: 64)),
            executableURL: fallbackURL,
            source: .bundled
        )
        let registry = LibTVRuntimeRegistry(rootURL: root.appending(path: "Runtimes"), bundledFallback: fallback)
        try await registry.bootstrap()
        let running = try RunnerRuntimeValidationReport(validationID: "validation-1", status: "running", record: record)
        try await registry.upsertRuntimeValidationReport(running)
        await registry.acknowledgeRuntimeValidationReports([.init(id: "validation-1", status: "running", detail: nil)])
        #expect(await registry.pendingRuntimeValidationReports().count == 1)
        let passed = try RunnerRuntimeValidationReport(validationID: "validation-1", status: "passed", record: record)
        try await registry.upsertRuntimeValidationReport(passed)
        await registry.acknowledgeRuntimeValidationReports([.init(id: "validation-1", status: "passed", detail: nil)])
        #expect(await registry.pendingRuntimeValidationReports().isEmpty)
    }

    private func makeExecutable(_ url: URL, output: String) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nprintf '%s' '\(output)'\n".utf8).write(to: url)
        _ = chmod(url.path, 0o700)
        return url
    }
}
