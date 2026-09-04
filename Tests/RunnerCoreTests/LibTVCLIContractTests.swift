import Foundation
import SQLite3
import Testing
@testable import RunnerCore

@Suite struct LibTVCLIContractTests {
    struct Fixture: Decodable, Sendable {
        let version: String
        let sha256: String
        let help: [String: String]
        var runtime: LibTVRuntimeIdentity { .init(version: version, sha256: sha256) }
    }

    private func fixture(_ version: String = "1.0.2") throws -> Fixture {
        let url = try #require(Bundle.module.url(forResource: "cli-contract-\(version)", withExtension: "json", subdirectory: "Resources"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }
    private static func result(_ output: String, arguments: [String] = [], exitCode: Int32 = 0) -> LibTVProcessResult {
        .init(arguments: arguments, exitCode: exitCode, standardOutput: output, standardError: "", disposition: .exited)
    }

    @Test(arguments: ["1.0.2", "1.1.3"])
    func capturedOfficialHelpSupportsV1Dialect(version: String) async throws {
        let fixture = try fixture(version)
        let report = try await LibTVCLIContract.verify(runtime: fixture.runtime) { arguments in
            #expect(arguments == ["--version"] || arguments.last == "--help")
            let output = arguments == ["--version"] ? fixture.version : fixture.help[arguments.dropLast().joined(separator: " ")]!
            return Self.result(output, arguments: arguments)
        }
        #expect(report.objectValue?["adapter_id"]?.stringValue == "libtv-cli-v1")
        #expect(report.objectValue?["runtime_sha256"]?.stringValue == fixture.sha256)
        #expect(report.objectValue?["help_fingerprints"]?.objectValue?.count == 11)
    }

    @Test
    func missingRenamedAndChangedArityOptionsFailClosed() throws {
        let fixture = try fixture()
        let probe = LibTVCLIContract.probes[0]
        let original = try #require(fixture.help[probe.key])
        let mutations = [
            original.replacingOccurrences(of: "--set <pair>", with: "--params <pair>"),
            original.replacingOccurrences(of: "--set <pair>", with: "--set [pair]"),
            original.replacingOccurrences(of: "--set <pair>", with: "--set       "),
            original.replacingOccurrences(of: "--run ", with: "--run <value> "),
            original.replacingOccurrences(of: "[options] <node>", with: "[options] <canvas> <node>"),
        ]
        for mutation in mutations {
            #expect(throws: LibTVCLIContractError.self) { try probe.validate(Self.result(mutation)) }
        }
        // The old option still occurs in descriptive prose after its definition was renamed.
        #expect(mutations[0].contains("--set"))
        #expect(throws: LibTVCLIContractError.self) { try probe.validate(Self.result(original, exitCode: 1)) }
    }

    @Test
    func documentationChangesDoNotForceAnAdapterRelease() throws {
        let fixture = try fixture()
        let probe = LibTVCLIContract.probes[0]
        let original = try #require(fixture.help[probe.key])
        let changed = original + "\n文档新增说明，允许不影响命令语法的更新。\n"
        #expect(try probe.validate(Self.result(original)) == probe.validate(Self.result(changed)))
    }

    @Test
    func versionMismatchStopsBeforeAnyCommandProbe() async throws {
        let fixture = try fixture()
        await #expect(throws: LibTVCLIContractError.self) {
            try await LibTVCLIContract.verify(runtime: fixture.runtime) { arguments in
                #expect(arguments == ["--version"])
                return Self.result("9.0.0")
            }
        }
    }

    @Test
    func adapterBindingSurvivesRestartAndRejectsDifferentDialect() async throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appending(path: "journal.sqlite")
        let journal = try SubmissionJournal(databaseURL: path)
        try await journal.bindCLIAdapter(jobID: "old-job")
        let reopened = try SubmissionJournal(databaseURL: path)
        try await reopened.bindCLIAdapter(jobID: "old-job")
        var db: OpaquePointer?
        #expect(sqlite3_open(path.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, "UPDATE job_cli_adapters SET adapter_id='libtv-cli-v2' WHERE job_id='old-job';", nil, nil, nil) == SQLITE_OK)
        await #expect(throws: LibTVCLIContractError.self) { try await reopened.bindCLIAdapter(jobID: "old-job") }
        await #expect(throws: LibTVCLIContractError.self) { try await reopened.bindCLIAdapter(jobID: "new-job", adapterID: "unknown") }
    }

    @Test
    func contractProbesUsePinnedExecutableAndNeverFallback() async throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaultBinary = root.appending(path: "default")
        let incompatibleBinary = root.appending(path: "candidate")
        try "#!/bin/sh\necho default >> \"$HOME/default-called\"\nexit 1\n".write(to: defaultBinary, atomically: true, encoding: .utf8)
        try "#!/bin/sh\necho incompatible >> \"$HOME/probes\"\necho 9.0.0\n".write(to: incompatibleBinary, atomically: true, encoding: .utf8)
        for file in [defaultBinary, incompatibleBinary] {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
        let profile = ProfileExecutor(profileRef: "profile", runner: LibTVProcessRunner(executableURL: defaultBinary, homeURL: root), limiter: try GlobalConcurrencyLimiter(limit: 1))
        try await profile.bindRuntime(jobID: "job", executableURL: incompatibleBinary)
        let runtime = LibTVRuntimeIdentity(version: "1.0.2", sha256: String(repeating: "a", count: 64))
        for _ in 0..<2 {
            await #expect(throws: LibTVCLIContractError.self) { try await profile.verifyCLIContract(jobID: "job", runtime: runtime) }
        }
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "default-called").path))
        #expect(try String(contentsOf: root.appending(path: "probes"), encoding: .utf8).split(separator: "\n").count == 2)
    }
}
