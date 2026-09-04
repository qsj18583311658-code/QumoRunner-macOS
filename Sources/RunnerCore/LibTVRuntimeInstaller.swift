import Darwin
import Foundation

public struct LibTVRuntimeRelease: Codable, Hashable, Sendable {
    public let version: String
    public let archiveURL: URL
    public let archiveSHA256: String?
    public let executableSHA256: String?

    public init(
        version: String,
        archiveURL: URL,
        archiveSHA256: String? = nil,
        executableSHA256: String? = nil
    ) {
        self.version = version
        self.archiveURL = archiveURL
        self.archiveSHA256 = archiveSHA256?.lowercased()
        self.executableSHA256 = executableSHA256?.lowercased()
    }
}

public enum LibTVRuntimeInstallError: Error, Equatable, LocalizedError, Sendable {
    case unofficialURL(String)
    case unversionedURL(String)
    case invalidHTTPStatus(Int)
    case archiveTooLarge(Int64)
    case archiveChecksumMismatch(expected: String, actual: String)
    case archiveListingFailed(String)
    case archiveExtractionFailed(String)
    case unsafeArchiveEntry(String)
    case unsafeExtractedItem(String)
    case executableCount(Int)
    case immutableRuntimeConflict(String)

    public var errorDescription: String? {
        switch self {
        case .unofficialURL(let value): "LibTV Runtime download URL is not an approved official HTTPS host: \(value)"
        case .unversionedURL(let value): "LibTV Runtime ZIP URL is not pinned to the requested version: \(value)"
        case .invalidHTTPStatus(let status): "LibTV Runtime download returned HTTP \(status)."
        case .archiveTooLarge(let size): "LibTV Runtime archive exceeds the size limit (\(size) bytes)."
        case .archiveChecksumMismatch(let expected, let actual):
            "LibTV Runtime ZIP checksum mismatch (expected \(expected), got \(actual))."
        case .archiveListingFailed(let message): "Unable to inspect LibTV Runtime ZIP: \(message)"
        case .archiveExtractionFailed(let message): "Unable to extract LibTV Runtime ZIP: \(message)"
        case .unsafeArchiveEntry(let entry): "Unsafe LibTV Runtime ZIP entry rejected: \(entry)"
        case .unsafeExtractedItem(let item): "Unsafe extracted LibTV Runtime item rejected: \(item)"
        case .executableCount(let count): "LibTV Runtime ZIP must contain exactly one regular file named libtv (found \(count))."
        case .immutableRuntimeConflict(let path): "Installed LibTV Runtime content conflicts at \(path)."
        }
    }
}

/// Downloads an official version-pinned ZIP with URLSession, preflights every archive entry,
/// extracts without a shell, verifies the final executable, and only then stages it as candidate.
public struct LibTVRuntimeInstaller: Sendable {
    public static let officialTeamIdentifier = "U5N2L989V7"

    private let registry: LibTVRuntimeRegistry
    private let session: URLSession
    private let officialHosts: Set<String>
    private let maximumArchiveBytes: Int64
    private let maximumExtractedBytes: Int64

    public init(
        registry: LibTVRuntimeRegistry,
        session: URLSession = .shared,
        officialHosts: Set<String> = ["liblibai-web-static.liblib.cloud"],
        maximumArchiveBytes: Int64 = 256 * 1_024 * 1_024,
        maximumExtractedBytes: Int64 = 512 * 1_024 * 1_024
    ) {
        self.registry = registry
        self.session = session
        self.officialHosts = Set(officialHosts.map { $0.lowercased() })
        self.maximumArchiveBytes = maximumArchiveBytes
        self.maximumExtractedBytes = maximumExtractedBytes
    }

    @discardableResult
    public func downloadAndStage(_ release: LibTVRuntimeRelease) async throws -> LibTVRuntimeRecord {
        try validateOfficialVersionedURL(release.archiveURL, version: release.version)
        let operationURL = registry.stagingURL.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: operationURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: operationURL) }

        let (temporaryDownload, response) = try await session.download(from: release.archiveURL)
        guard let http = response as? HTTPURLResponse else {
            throw LibTVRuntimeInstallError.invalidHTTPStatus(-1)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LibTVRuntimeInstallError.invalidHTTPStatus(http.statusCode)
        }
        if let finalURL = response.url {
            try validateOfficialVersionedURL(finalURL, version: release.version)
        }
        if response.expectedContentLength > maximumArchiveBytes {
            throw LibTVRuntimeInstallError.archiveTooLarge(response.expectedContentLength)
        }
        let archiveURL = operationURL.appending(path: "runtime.zip")
        try FileManager.default.moveItem(at: temporaryDownload, to: archiveURL)
        let archiveSize = try fileSize(archiveURL)
        guard archiveSize <= maximumArchiveBytes else {
            throw LibTVRuntimeInstallError.archiveTooLarge(archiveSize)
        }
        let archiveHash = try LibTVBinaryVerifier.sha256(of: archiveURL)
        if let expectedArchiveHash = release.archiveSHA256,
           archiveHash.caseInsensitiveCompare(expectedArchiveHash) != .orderedSame {
            throw LibTVRuntimeInstallError.archiveChecksumMismatch(
                expected: expectedArchiveHash,
                actual: archiveHash
            )
        }

        let entries = try zipEntries(archiveURL)
        try Self.validateArchiveEntries(entries)
        try Self.validateArchiveEntryModes(try zipLongListing(archiveURL))
        let extractionURL = operationURL.appending(path: "extracted", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: extractionURL, withIntermediateDirectories: false)
        try extractZIP(archiveURL, to: extractionURL)
        try validateExtractedTree(extractionURL)

        let executables = try regularFiles(in: extractionURL).filter { $0.lastPathComponent == "libtv" }
        guard executables.count == 1, let extractedExecutable = executables.first else {
            throw LibTVRuntimeInstallError.executableCount(executables.count)
        }
        _ = chmod(extractedExecutable.path, 0o700)
        let verification = try verify(extractedExecutable, release: release)
        let identity = LibTVRuntimeIdentity(version: release.version, sha256: verification.sha256)
        let destination = try await registry.immutableDestination(for: identity)
        let installed = try installImmutable(
            extractedExecutable,
            destination: destination,
            release: release
        )
        let record = LibTVRuntimeRecord(
            identity: identity,
            executableURL: installed,
            source: .downloaded,
            archiveSHA256: archiveHash,
            teamIdentifier: verification.teamIdentifier,
            cdHash: verification.cdHash,
            strictSignatureValid: verification.strictSignatureValid
        )
        try await registry.stageCandidate(record)
        return record
    }

    public func validateOfficialVersionedURL(_ url: URL, version: String) throws {
        guard url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil,
              (url.port == nil || url.port == 443),
              let host = url.host?.lowercased(), officialHosts.contains(host) else {
            throw LibTVRuntimeInstallError.unofficialURL(url.absoluteString)
        }
        let expectedPath = "/cli/\(version)/libtv-macos-arm64.zip"
        guard url.path == expectedPath, url.query == nil, url.fragment == nil else {
            throw LibTVRuntimeInstallError.unversionedURL(url.absoluteString)
        }
    }

    public static func validateArchiveEntries(_ entries: [String]) throws {
        guard !entries.isEmpty else { throw LibTVRuntimeInstallError.archiveListingFailed("empty archive") }
        for entry in entries {
            guard !entry.isEmpty, !entry.contains("\0"), !entry.contains("\\") else {
                throw LibTVRuntimeInstallError.unsafeArchiveEntry(entry)
            }
            guard !entry.hasPrefix("/"), !entry.hasPrefix("~"),
                  entry.range(of: #"^[A-Za-z]:"#, options: .regularExpression) == nil else {
                throw LibTVRuntimeInstallError.unsafeArchiveEntry(entry)
            }
            let components = entry.split(separator: "/", omittingEmptySubsequences: false)
            guard components.allSatisfy({ $0 != ".." && $0 != "." }),
                  components.dropLast().allSatisfy({ !$0.isEmpty }) else {
                throw LibTVRuntimeInstallError.unsafeArchiveEntry(entry)
            }
        }
    }

    /// `zipinfo -1` contains only names. The long listing is checked before extraction so an
    /// archive cannot first create a symlink and then write a nested child through that link.
    public static func validateArchiveEntryModes(_ lines: [String]) throws {
        for line in lines {
            guard let first = line.first, first == "-" || first == "d" else { continue }
            // A Unix entry line starts with ten mode characters. Only regular files/directories
            // are accepted; symlinks (`l`) and all special file types are rejected.
            let prefix = line.prefix(10)
            guard prefix.count == 10, first == "-" || first == "d" else {
                throw LibTVRuntimeInstallError.unsafeArchiveEntry(line)
            }
        }
        if lines.contains(where: { $0.first == "l" }) {
            throw LibTVRuntimeInstallError.unsafeArchiveEntry("symbolic link entry")
        }
        let special = lines.first { line in
            guard let first = line.first else { return false }
            return ["b", "c", "p", "s"].contains(first)
        }
        if let special { throw LibTVRuntimeInstallError.unsafeArchiveEntry(special) }
    }

    private func verify(
        _ executableURL: URL,
        release: LibTVRuntimeRelease
    ) throws -> LibTVBinaryVerification {
        let actualHash = try LibTVBinaryVerifier.sha256(of: executableURL)
        return try LibTVBinaryVerifier.verify(
            executableURL: executableURL,
            expectedVersion: release.version,
            expectedSHA256: release.executableSHA256 ?? actualHash,
            requireThinArm64: true,
            expectedTeamIdentifier: Self.officialTeamIdentifier
        )
    }

    private func installImmutable(
        _ source: URL,
        destination: URL,
        release: LibTVRuntimeRelease
    ) throws -> URL {
        let fileManager = FileManager.default
        let finalDirectory = destination.deletingLastPathComponent()
        if fileManager.fileExists(atPath: destination.path) {
            do {
                _ = try verify(destination, release: release)
                return destination
            } catch {
                throw LibTVRuntimeInstallError.immutableRuntimeConflict(destination.path)
            }
        }
        let versionDirectory = finalDirectory.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: versionDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let temporaryDirectory = versionDirectory.appending(
            path: ".install-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: false)
        do {
            let temporaryExecutable = temporaryDirectory.appending(path: "libtv")
            try fileManager.copyItem(at: source, to: temporaryExecutable)
            _ = chmod(temporaryExecutable.path, 0o700)
            _ = try verify(temporaryExecutable, release: release)
            try fileManager.moveItem(at: temporaryDirectory, to: finalDirectory)
            _ = chmod(finalDirectory.path, 0o700)
            _ = try verify(destination, release: release)
            return destination
        } catch {
            try? fileManager.removeItem(at: temporaryDirectory)
            throw error
        }
    }

    private func zipEntries(_ archiveURL: URL) throws -> [String] {
        let result = try runTool("/usr/bin/zipinfo", arguments: ["-1", archiveURL.path])
        guard result.status == 0 else {
            throw LibTVRuntimeInstallError.archiveListingFailed(result.output)
        }
        guard result.output.utf8.count <= 4 * 1_024 * 1_024 else {
            throw LibTVRuntimeInstallError.archiveListingFailed("entry listing exceeds limit")
        }
        return result.output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            .filter { !$0.isEmpty }
    }

    private func zipLongListing(_ archiveURL: URL) throws -> [String] {
        let result = try runTool("/usr/bin/zipinfo", arguments: ["-l", archiveURL.path])
        guard result.status == 0 else { throw LibTVRuntimeInstallError.archiveListingFailed(result.output) }
        guard result.output.utf8.count <= 8 * 1_024 * 1_024 else { throw LibTVRuntimeInstallError.archiveListingFailed("long listing exceeds limit") }
        return result.output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private func extractZIP(_ archiveURL: URL, to destination: URL) throws {
        let result = try runTool(
            "/usr/bin/ditto",
            arguments: ["-x", "-k", "--noqtn", archiveURL.path, destination.path]
        )
        guard result.status == 0 else {
            throw LibTVRuntimeInstallError.archiveExtractionFailed(result.output)
        }
    }

    private func validateExtractedTree(_ root: URL) throws {
        let rootPath = root.standardizedFileURL.path + "/"
        var total: Int64 = 0
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
            options: []
        ) else { throw LibTVRuntimeInstallError.archiveExtractionFailed("cannot enumerate extraction") }
        for case let item as URL in enumerator {
            let values = try item.resourceValues(forKeys: [
                .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
            ])
            guard values.isSymbolicLink != true else {
                throw LibTVRuntimeInstallError.unsafeExtractedItem(item.path)
            }
            let resolved = item.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolved.hasPrefix(rootPath), values.isRegularFile == true || values.isDirectory == true else {
                throw LibTVRuntimeInstallError.unsafeExtractedItem(item.path)
            }
            if values.isRegularFile == true { total += Int64(values.fileSize ?? 0) }
            guard total <= maximumExtractedBytes else {
                throw LibTVRuntimeInstallError.archiveTooLarge(total)
            }
        }
    }

    private func regularFiles(in root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ) else { return [] }
        var result: [URL] = []
        for case let item as URL in enumerator {
            let values = try item.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isRegularFile == true, values.isSymbolicLink != true { result.append(item) }
        }
        return result
    }

    private func fileSize(_ url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func runTool(_ executable: String, arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
