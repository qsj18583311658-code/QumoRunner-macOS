import Darwin
import Foundation
import Security

struct AgentConfiguration: Codable, Sendable {
    let serverURL: URL
    let runnerID: String

    enum CodingKeys: String, CodingKey {
        case serverURL = "server_url"
        case runnerID = "runner_id"
    }
}

struct AgentConfigurationStore: Sendable {
    let root: URL
    let configurationURL: URL

    init() {
        root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "QumoRunner", directoryHint: .isDirectory)
        configurationURL = root.appending(path: "runner-config.json")
    }

    func load() throws -> AgentConfiguration? {
        guard FileManager.default.fileExists(atPath: configurationURL.path) else { return nil }
        return try JSONDecoder().decode(AgentConfiguration.self, from: Data(contentsOf: configurationURL))
    }
}

struct AgentSettings: Codable, Sendable {
    var concurrencyLimit: Int
    enum CodingKeys: String, CodingKey { case concurrencyLimit = "concurrency_limit" }
}

struct AgentSettingsStore: Sendable {
    let fileURL: URL
    init(root: URL = AgentConfigurationStore().root) { fileURL = root.appending(path: "agent-settings.json") }

    func load() throws -> AgentSettings {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return AgentSettings(concurrencyLimit: 4) }
        return try JSONDecoder().decode(AgentSettings.self, from: Data(contentsOf: fileURL))
    }

    func saveConcurrency(_ value: Int) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(AgentSettings(concurrencyLimit: value)).write(to: fileURL, options: .atomic)
        guard chmod(fileURL.path, 0o600) == 0 else { throw AgentConfigurationError.permissions(fileURL.path) }
    }
}

struct AgentKeychainStore: Sendable {
    private let service = "com.qumo.runner.device-token"

    func deviceToken(runnerID: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: runnerID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            throw AgentConfigurationError.keychain(status)
        }
        return token
    }
}

enum AgentConfigurationError: LocalizedError, Sendable {
    case keychain(OSStatus)
    case permissions(String)
    var errorDescription: String? {
        switch self {
        case .keychain(let status): "设备 Token Keychain 读取失败（\(status)）"
        case .permissions(let path): "无法保护 Agent 设置权限：\(path)"
        }
    }
}

enum AgentBundleLayout {
    private static var executableURL: URL {
        var capacity: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &capacity)
        var buffer = [CChar](repeating: 0, count: Int(capacity))
        let result = buffer.withUnsafeMutableBufferPointer { pointer in
            _NSGetExecutablePath(pointer.baseAddress, &capacity)
        }
        guard result == 0 else {
            return URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self)).standardizedFileURL
    }

    static var libTVExecutableURL: URL {
        var contents = executableURL.deletingLastPathComponent()
        while contents.lastPathComponent != "Contents", contents.path != "/" {
            contents.deleteLastPathComponent()
        }
        return contents.appending(path: "Resources/Tools/libtv")
    }
}
