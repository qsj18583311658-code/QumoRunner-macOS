import Darwin
import Foundation

public enum ProfileStorageError: Error, Equatable, LocalizedError, Sendable {
    case invalidProfileReference
    case unableToSetPermissions(path: String, errno: Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidProfileReference:
            "Profile references may contain only letters, numbers, period, underscore and hyphen."
        case .unableToSetPermissions(let path, let code):
            "Unable to secure \(path) (errno \(code))."
        }
    }
}

public struct ProfilePaths: Equatable, Sendable {
    public let root: URL
    public let home: URL
    public let credentials: URL
}

public struct ProfileStorage: Sendable {
    public let applicationSupportRoot: URL

    public init(applicationSupportRoot: URL? = nil) {
        if let applicationSupportRoot {
            self.applicationSupportRoot = applicationSupportRoot
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
            self.applicationSupportRoot = support.appendingPathComponent("QumoRunner", isDirectory: true)
        }
    }

    @discardableResult
    public func prepare(profileRef: String) throws -> ProfilePaths {
        guard Self.isValid(profileRef) else { throw ProfileStorageError.invalidProfileReference }
        let root = applicationSupportRoot
            .appendingPathComponent("Profiles", isDirectory: true)
            .appendingPathComponent(profileRef, isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let libtv = home.appendingPathComponent(".libtv", isDirectory: true)
        let credentials = libtv.appendingPathComponent("credentials.json", isDirectory: false)
        for directory in [applicationSupportRoot, root.deletingLastPathComponent(), root, home, libtv] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try setMode(0o700, at: directory)
        }
        if FileManager.default.fileExists(atPath: credentials.path) {
            try setMode(0o600, at: credentials)
        }
        return ProfilePaths(root: root, home: home, credentials: credentials)
    }

    public func secureCredentials(for profileRef: String) throws {
        let paths = try prepare(profileRef: profileRef)
        if FileManager.default.fileExists(atPath: paths.credentials.path) {
            try setMode(0o600, at: paths.credentials)
        }
    }

    public func remove(profileRef: String) throws {
        guard Self.isValid(profileRef) else { throw ProfileStorageError.invalidProfileReference }
        let profilesRoot = applicationSupportRoot.appendingPathComponent("Profiles", isDirectory: true)
        let root = profilesRoot.appendingPathComponent(profileRef, isDirectory: true)
        guard root.deletingLastPathComponent().standardizedFileURL == profilesRoot.standardizedFileURL else {
            throw ProfileStorageError.invalidProfileReference
        }
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    private func setMode(_ mode: mode_t, at url: URL) throws {
        guard chmod(url.path, mode) == 0 else {
            throw ProfileStorageError.unableToSetPermissions(path: url.path, errno: errno)
        }
    }

    private static func isValid(_ value: String) -> Bool {
        guard !value.isEmpty, value != ".", value != ".." else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)
        }
    }
}
