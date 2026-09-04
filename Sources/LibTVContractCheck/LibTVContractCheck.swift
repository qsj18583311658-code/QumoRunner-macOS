import Foundation
import Darwin
import RunnerCore

/// Developer-only syntax check. Does not install, activate, log in, or generate media.
@main struct LibTVContractCheck {
    static func main() async {
        do { try await check() }
        catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }

    static func check() async throws {
        guard CommandLine.arguments.count == 2, CommandLine.arguments[1].hasPrefix("/") else {
            throw LibTVCLIContractError.incompatible("用法：libtv-contract-check /absolute/path/to/libtv")
        }
        let binary = URL(fileURLWithPath: CommandLine.arguments[1])
        let home = FileManager.default.temporaryDirectory.appending(path: "QumoContractCheck-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = LibTVProcessRunner(executableURL: binary, homeURL: home)
        let version = try await runner.run(arguments: ["--version"], timeout: .seconds(15))
        guard version.exitCode == 0, version.disposition == .exited else {
            throw LibTVCLIContractError.incompatible("无法读取 CLI 版本")
        }
        let raw = version.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let identity = LibTVRuntimeIdentity(version: raw.hasPrefix("libtv ") ? String(raw.dropFirst(6)) : raw,
                                           sha256: try LibTVBinaryVerifier.sha256(of: binary))
        let report = try await LibTVCLIContract.verify(runtime: identity) { arguments in
            try await runner.run(arguments: arguments, timeout: .seconds(15))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(report), as: UTF8.self))
    }
}
