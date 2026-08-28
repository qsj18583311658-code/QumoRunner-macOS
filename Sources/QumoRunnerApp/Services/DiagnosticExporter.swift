import AppKit
import Foundation
import UniformTypeIdentifiers

enum DiagnosticExporter {
    @MainActor
    static func export(snapshot: RunnerSnapshot) throws -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "QumoRunner-Diagnostics-\(dateStamp()).zip"
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return nil }

        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory.appending(path: "QumoRunnerDiagnostics-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fileManager.removeItem(at: staging) }

        let summary: [String: Any] = [
            "generated_at": ISO8601DateFormatter().string(from: Date()),
            "service_state": snapshot.serviceState.rawValue,
            "server_configured": snapshot.serverURL != nil,
            "server_reachable": snapshot.serverReachable,
            "libtv_version": snapshot.libTVVersion ?? "unknown",
            "libtv_verified": snapshot.libTVVerified,
            "accounts": snapshot.accounts.count,
            "jobs": snapshot.jobs.count
        ]
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
            .write(to: staging.appending(path: "summary.json"), options: .atomic)

        let logText = snapshot.logs.map { entry in
            let message = redact(entry.message)
            return "\(ISO8601DateFormatter().string(from: entry.timestamp)) [\(entry.level.title)] \(message)"
        }.joined(separator: "\n")
        try Data(logText.utf8).write(to: staging.appending(path: "runner.log"), options: .atomic)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", staging.path, destination.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw DiagnosticError.archiveFailed(process.terminationStatus) }
        return destination
    }

    static func redact(_ value: String) -> String {
        let fieldRedacted = value.replacingOccurrences(
            of: "(?i)(x-runner-token|authorization|token|password|secret)\\s*[:=]\\s*[^\\s,;]+",
            with: "$1=[REDACTED]",
            options: .regularExpression
        )
        return fieldRedacted.replacingOccurrences(
            of: "(?i)bearer\\s+[A-Za-z0-9._~+/-]+",
            with: "Bearer [REDACTED]",
            options: .regularExpression
        )
    }

    private static func dateStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

enum DiagnosticError: LocalizedError {
    case archiveFailed(Int32)
    var errorDescription: String? { "诊断 ZIP 生成失败（退出码 \(code)）" }
    private var code: Int32 { switch self { case .archiveFailed(let code): code } }
}
