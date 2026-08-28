import CryptoKit
import Foundation
import Testing
@testable import RunnerCore

@Suite struct ArtifactArchiverTests {
    @Test
    func localFileIsHashedUploadedWithHeadersAndCompleted() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("result.png")
        let bytes = Data("artifact bytes".utf8)
        try bytes.write(to: file)
        let api = FakeArtifactTransport()
        let archived = try await ArtifactArchiver(transport: api).archive(
            jobID: "job",
            output: file.path
        )
        let expectedHash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        #expect(archived.sha256 == expectedHash)
        #expect(archived.fileSize == Int64(bytes.count))
        #expect(archived.contentURL.absoluteString == "https://canvas.test/artifacts/a1")
        let state = await api.state()
        #expect(state.uploaded)
        #expect(state.completed)
        #expect(state.headers["x-presigned"] == "required")
    }

    @Test
    func uploadInterruptionDoesNotCompleteArtifact() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("large.bin")
        try Data(repeating: 7, count: 2 * 1024 * 1024).write(to: file)
        let api = FakeArtifactTransport(failUpload: true)
        await #expect(throws: FakeUploadError.interrupted) {
            try await ArtifactArchiver(transport: api).archive(jobID: "job", output: file.path)
        }
        let state = await api.state()
        #expect(!state.completed)
    }
}

private enum FakeUploadError: Error { case interrupted }

private actor FakeArtifactTransport: ArtifactAPITransport {
    private let failUpload: Bool
    private var uploaded = false
    private var completed = false
    private var headers: [String: String] = [:]

    init(failUpload: Bool = false) { self.failUpload = failUpload }

    func initializeArtifact(jobID: String, request: ArtifactInitRequest) async throws -> ArtifactInitResponse {
        ArtifactInitResponse(
            artifactID: "a1",
            uploadURL: URL(string: "https://upload.test/a1")!,
            method: "PUT",
            headers: ["x-presigned": "required"],
            expiresInSeconds: 300
        )
    }

    func uploadArtifact(
        fileURL: URL,
        to signedURL: URL,
        method: String,
        contentType: String,
        headers: [String: String]
    ) async throws {
        self.headers = headers
        if failUpload { throw FakeUploadError.interrupted }
        uploaded = true
    }

    func completeArtifact(
        jobID: String,
        artifactID: String,
        request: ArtifactCompleteRequest
    ) async throws -> ArtifactCompleteResponse {
        completed = true
        return ArtifactCompleteResponse(
            artifactID: artifactID,
            completed: true,
            contentURL: URL(string: "https://canvas.test/artifacts/\(artifactID)")!
        )
    }

    func state() -> (uploaded: Bool, completed: Bool, headers: [String: String]) {
        (uploaded, completed, headers)
    }
}
