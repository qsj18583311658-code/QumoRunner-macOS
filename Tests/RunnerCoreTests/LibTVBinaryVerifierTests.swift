import CryptoKit
import Foundation
import Testing
@testable import RunnerCore

@Suite struct LibTVBinaryVerifierTests {
    @Test
    func checksumMismatchIsRejectedBeforeExecution() throws {
        #expect(throws: LibTVBinaryVerificationError.self) {
            try LibTVBinaryVerifier.verify(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                expectedSHA256: String(repeating: "0", count: 64)
            )
        }
    }

    @Test
    func signedArm64SystemBinaryPassesIntegrityArchitectureAndSignatureChecks() throws {
        let url = URL(fileURLWithPath: "/bin/echo")
        let digest = try SHA256.hash(data: Data(contentsOf: url))
            .map { String(format: "%02x", $0) }
            .joined()
        let verification = try LibTVBinaryVerifier.verify(
            executableURL: url,
            expectedVersion: "test-version",
            expectedSHA256: digest,
            versionArguments: ["test-version"]
        )
        #expect(verification.sha256 == digest)
        #expect(verification.signatureValid)
    }

    @Test
    func pinnedVersionMismatchIsRejected() throws {
        let url = URL(fileURLWithPath: "/usr/bin/true")
        let digest = try SHA256.hash(data: Data(contentsOf: url))
            .map { String(format: "%02x", $0) }
            .joined()
        #expect(throws: LibTVBinaryVerificationError.self) {
            try LibTVBinaryVerifier.verify(
                executableURL: url,
                expectedVersion: "1.0.2",
                expectedSHA256: digest
            )
        }
    }
}
