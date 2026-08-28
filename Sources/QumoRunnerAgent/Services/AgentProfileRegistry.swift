import Darwin
import Foundation
import RunnerCore

enum AgentProfileRegistryError: LocalizedError, Equatable {
    case duplicateAccount(accountRef: String, existingProfileRef: String)
    case unresolvedAccount

    var errorDescription: String? {
        switch self {
        case .duplicateAccount:
            "Chrome 当前登录的 Liblib 账号已经添加。请先在 Chrome 切换到另一个 Liblib 账号后重试。"
        case .unresolvedAccount:
            "LibTV 授权完成，但未能识别当前账号。新 Profile 已安全回滚，请重试。"
        }
    }
}

final class AgentProfileRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private let storage: ProfileStorage
    private let registryURL: URL
    private var profiles: [RunnerProfile]

    init(root: URL) {
        storage = ProfileStorage(applicationSupportRoot: root)
        registryURL = root.appending(path: "profiles.json")
        profiles = (try? JSONDecoder().decode([RunnerProfile].self, from: Data(contentsOf: registryURL))) ?? []
    }

    func all() -> [RunnerProfile] { lock.withLock { profiles } }

    func prepare(profileRef requested: String?) throws -> (RunnerProfile, ProfilePaths) {
        let profileRef = requested ?? UUID().uuidString.lowercased()
        let paths = try storage.prepare(profileRef: profileRef)
        return try lock.withLock {
            if let existing = profiles.first(where: { $0.profileRef == profileRef }) { return (existing, paths) }
            let profile = RunnerProfile(profileRef: profileRef, accountRef: "pending", displayName: "登录中…", capabilities: [], healthy: false)
            profiles.append(profile)
            try persistLocked()
            return (profile, paths)
        }
    }

    func setEnabled(profileRef: String, enabled: Bool) throws {
        try lock.withLock {
            guard let index = profiles.firstIndex(where: { $0.profileRef == profileRef }) else { return }
            profiles[index].enabled = enabled
            try persistLocked()
        }
    }

    func markLogin(profileRef: String, accountRef: String, displayName: String, capabilities: [String], healthy: Bool) throws {
        guard accountRef != "pending", !accountRef.isEmpty else { throw AgentProfileRegistryError.unresolvedAccount }
        try storage.secureCredentials(for: profileRef)
        try lock.withLock {
            guard let index = profiles.firstIndex(where: { $0.profileRef == profileRef }) else { return }
            if let duplicate = profiles.first(where: { $0.profileRef != profileRef && $0.accountRef == accountRef }) {
                throw AgentProfileRegistryError.duplicateAccount(accountRef: accountRef, existingProfileRef: duplicate.profileRef)
            }
            profiles[index].accountRef = accountRef
            profiles[index].displayName = displayName
            profiles[index].capabilities = capabilities
            profiles[index].healthy = healthy
            try persistLocked()
        }
    }

    func discardPending(profileRef: String) throws {
        let shouldRemoveDirectory = try lock.withLock { () -> Bool in
            if let index = profiles.firstIndex(where: { $0.profileRef == profileRef && $0.accountRef == "pending" }) {
                profiles.remove(at: index)
                try persistLocked()
                return true
            }
            return !profiles.contains(where: { $0.profileRef == profileRef })
        }
        if shouldRemoveDirectory {
            try storage.remove(profileRef: profileRef)
            scheduleOrphanCleanup(profileRef: profileRef)
        }
    }

    private func scheduleOrphanCleanup(profileRef: String) {
        Task { [weak self] in
            for delay in [2, 10] {
                try? await Task.sleep(for: .seconds(delay))
                guard let self else { return }
                let remainsDiscarded = self.lock.withLock {
                    !self.profiles.contains(where: { $0.profileRef == profileRef })
                }
                guard remainsDiscarded else { return }
                try? self.storage.remove(profileRef: profileRef)
            }
        }
    }

    private func persistLocked() throws {
        try FileManager.default.createDirectory(at: registryURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(profiles).write(to: registryURL, options: .atomic)
        guard chmod(registryURL.path, 0o600) == 0 else {
            throw ProfileStorageError.unableToSetPermissions(path: registryURL.path, errno: errno)
        }
    }
}
