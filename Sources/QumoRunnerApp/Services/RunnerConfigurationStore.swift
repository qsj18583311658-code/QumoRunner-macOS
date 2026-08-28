import Darwin
import Foundation

struct RunnerConfigurationStore {
    struct Configuration: Codable {
        let serverURL: URL
        let runnerID: String

        enum CodingKeys: String, CodingKey {
            case serverURL = "server_url"
            case runnerID = "runner_id"
        }
    }

    let fileURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        fileURL = support.appending(path: "QumoRunner/runner-config.json")
    }

    func save(serverURL: URL, runnerID: String) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard chmod(directory.path, 0o700) == 0 else { throw ConfigurationStoreError.permissions(directory.path) }
        let data = try JSONEncoder().encode(Configuration(serverURL: serverURL, runnerID: runnerID))
        try data.write(to: fileURL, options: .atomic)
        guard chmod(fileURL.path, 0o600) == 0 else { throw ConfigurationStoreError.permissions(fileURL.path) }
    }

    func remove() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}

enum ConfigurationStoreError: LocalizedError {
    case permissions(String)
    var errorDescription: String? { switch self { case .permissions(let path): "无法保护 Runner 配置权限：\(path)" } }
}
