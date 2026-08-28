import CryptoKit
import Foundation
import UniformTypeIdentifiers

public struct ArchivedArtifact: Equatable, Sendable {
    public let artifactID: String
    public let contentURL: URL
    public let fileName: String
    public let fileSize: Int64
    public let sha256: String
}

public enum ArtifactArchiverError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedOutput(String)
    case unreadableFile(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedOutput(let value): "Unsupported LibTV output location: \(value)"
        case .unreadableFile(let value): "Unable to read generated artifact: \(value)"
        }
    }
}

public actor ArtifactArchiver {
    private let transport: any ArtifactAPITransport
    private let session: URLSession

    public init(
        transport: any ArtifactAPITransport,
        session: URLSession = .shared
    ) {
        self.transport = transport
        self.session = session
    }

    public func archive(jobID: String, output: String) async throws -> ArchivedArtifact {
        let resolved = try await resolve(output)
        defer {
            if resolved.isTemporary { try? FileManager.default.removeItem(at: resolved.url) }
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: resolved.url.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw ArtifactArchiverError.unreadableFile(resolved.url.path)
        }
        let fileSize = size.int64Value
        let sha256 = try Self.sha256(of: resolved.url)
        let fileName = resolved.suggestedFileName ?? resolved.url.lastPathComponent
        let mimeType = resolved.mimeType
            ?? UTType(filenameExtension: resolved.url.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        let initialized = try await transport.initializeArtifact(
            jobID: jobID,
            request: ArtifactInitRequest(
                fileName: fileName,
                mimeType: mimeType,
                fileSize: fileSize,
                sha256: sha256
            )
        )
        try await transport.uploadArtifact(
            fileURL: resolved.url,
            to: initialized.uploadURL,
            method: initialized.method,
            contentType: mimeType,
            headers: initialized.headers
        )
        let completed = try await transport.completeArtifact(
            jobID: jobID,
            artifactID: initialized.artifactID,
            request: ArtifactCompleteRequest(fileSize: fileSize, sha256: sha256)
        )
        return ArchivedArtifact(
            artifactID: completed.artifactID,
            contentURL: completed.contentURL,
            fileName: fileName,
            fileSize: fileSize,
            sha256: sha256
        )
    }

    private func resolve(_ output: String) async throws -> ResolvedArtifact {
        if let url = URL(string: output), ["http", "https"].contains(url.scheme?.lowercased()) {
            let (temporaryURL, response) = try await session.download(from: url)
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("QumoRunner-artifact-\(UUID().uuidString)")
                .appendingPathExtension(response.suggestedFilename?.split(separator: ".").last.map(String.init) ?? "bin")
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
            return ResolvedArtifact(
                url: destination,
                isTemporary: true,
                suggestedFileName: response.suggestedFilename,
                mimeType: response.mimeType
            )
        }
        let url: URL
        if let parsed = URL(string: output), parsed.isFileURL {
            url = parsed
        } else if output.hasPrefix("/") {
            url = URL(fileURLWithPath: output)
        } else {
            throw ArtifactArchiverError.unsupportedOutput(output)
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw ArtifactArchiverError.unreadableFile(url.path)
        }
        return ResolvedArtifact(url: url, isTemporary: false, suggestedFileName: nil, mimeType: nil)
    }

    private nonisolated static func sha256(of url: URL) throws -> String {
        guard let stream = InputStream(url: url) else {
            throw ArtifactArchiverError.unreadableFile(url.path)
        }
        stream.open()
        defer { stream.close() }
        var hasher = SHA256()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024 * 1024)
        defer { buffer.deallocate() }
        while true {
            let count = stream.read(buffer, maxLength: 1024 * 1024)
            if count < 0 { throw stream.streamError ?? ArtifactArchiverError.unreadableFile(url.path) }
            if count == 0 { break }
            hasher.update(data: Data(bytesNoCopy: buffer, count: count, deallocator: .none))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private struct ResolvedArtifact: Sendable {
    let url: URL
    let isTemporary: Bool
    let suggestedFileName: String?
    let mimeType: String?
}
