import AppKit
import Darwin
import Foundation

@MainActor
enum ChromeAuthorizationLauncher {
    static func open(url: URL, profileRef: String) async throws -> NSRunningApplication {
        guard let chromeApp = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") else {
            throw ChromeAuthorizationError.chromeUnavailable
        }
        let profileDirectory = try browserProfileDirectory(profileRef: profileRef)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        configuration.arguments = [
            "--user-data-dir=\(profileDirectory.path)",
            "--no-first-run",
            "--no-default-browser-check",
            "--new-window",
            url.absoluteString,
        ]
        // Use AppKit's imported async API. Manually bridging the Objective-C
        // completion handler inherits MainActor isolation under Swift 6, while
        // LaunchServices may invoke that handler off the main queue.
        return try await NSWorkspace.shared.openApplication(at: chromeApp, configuration: configuration)
    }

    private static func browserProfileDirectory(profileRef: String) throws -> URL {
        guard !profileRef.isEmpty,
              profileRef.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)
              }) else {
            throw ChromeAuthorizationError.invalidProfile
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = support
            .appendingPathComponent("QumoRunner", isDirectory: true)
            .appendingPathComponent("Profiles", isDirectory: true)
            .appendingPathComponent(profileRef, isDirectory: true)
            .appendingPathComponent("chrome-auth", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard chmod(directory.path, 0o700) == 0 else {
            throw ChromeAuthorizationError.permissions(directory.path)
        }
        return directory
    }
}

enum ChromeAuthorizationError: LocalizedError {
    case chromeUnavailable
    case invalidProfile
    case permissions(String)

    var errorDescription: String? {
        switch self {
        case .chromeUnavailable:
            "未安装 Google Chrome，无法创建隔离的账号授权窗口。"
        case .invalidProfile:
            "Profile 标识无效，未打开 Chrome。"
        case .permissions(let path):
            "无法保护 Chrome 授权目录：\(path)"
        }
    }
}
