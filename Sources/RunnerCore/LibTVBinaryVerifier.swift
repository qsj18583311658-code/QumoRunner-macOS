import CryptoKit
import Foundation
import Security

public struct LibTVBinaryVerification: Equatable, Sendable {
    public let version: String
    public let sha256: String
    public let signatureValid: Bool
}

public enum LibTVBinaryVerificationError: Error, Equatable, LocalizedError, Sendable {
    case missing
    case notExecutable
    case checksumMismatch(expected: String, actual: String)
    case versionInvocationFailed(String)
    case versionMismatch(expected: String, actual: String)
    case unsupportedArchitecture(String)
    case invalidCodeSignature(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .missing: "Bundled LibTV CLI is missing."
        case .notExecutable: "Bundled LibTV CLI is not executable."
        case .checksumMismatch(let expected, let actual):
            "LibTV checksum mismatch (expected \(expected), got \(actual))."
        case .versionInvocationFailed(let value): "Unable to read LibTV version: \(value)"
        case .versionMismatch(let expected, let actual):
            "LibTV version mismatch (expected \(expected), got \(actual))."
        case .unsupportedArchitecture(let value):
            "LibTV binary does not contain the required arm64 architecture (reported: \(value))."
        case .invalidCodeSignature(let status): "LibTV code signature is invalid (OSStatus \(status))."
        }
    }
}

public enum LibTVBinaryVerifier {
    public static func verify(
        executableURL: URL,
        expectedVersion: String = "1.0.2",
        expectedSHA256: String,
        versionArguments: [String] = ["--version"]
    ) throws -> LibTVBinaryVerification {
        guard FileManager.default.fileExists(atPath: executableURL.path) else {
            throw LibTVBinaryVerificationError.missing
        }
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw LibTVBinaryVerificationError.notExecutable
        }
        let digest = try SHA256.hash(data: Data(contentsOf: executableURL))
            .map { String(format: "%02x", $0) }
            .joined()
        guard digest.caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
            throw LibTVBinaryVerificationError.checksumMismatch(
                expected: expectedSHA256.lowercased(),
                actual: digest
            )
        }

        let process = Process()
        let output = Pipe()
        process.executableURL = executableURL
        process.arguments = versionArguments
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw LibTVBinaryVerificationError.versionInvocationFailed(error.localizedDescription)
        }
        let versionOutput = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw LibTVBinaryVerificationError.versionInvocationFailed(versionOutput)
        }
        guard versionOutput.range(of: expectedVersion) != nil else {
            throw LibTVBinaryVerificationError.versionMismatch(
                expected: expectedVersion,
                actual: versionOutput
            )
        }

        let architectureOutput = try architectures(of: executableURL)
        guard architectureOutput.split(whereSeparator: \.isWhitespace).contains(where: {
            $0 == "arm64" || $0 == "arm64e"
        }) else {
            throw LibTVBinaryVerificationError.unsupportedArchitecture(architectureOutput)
        }

        var staticCode: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(
            executableURL as CFURL,
            SecCSFlags(),
            &staticCode
        )
        if status == errSecSuccess, let staticCode {
            status = SecStaticCodeCheckValidity(
                staticCode,
                SecCSFlags(rawValue: kSecCSStrictValidate),
                nil
            )
        }
        guard status == errSecSuccess else {
            throw LibTVBinaryVerificationError.invalidCodeSignature(status)
        }
        return LibTVBinaryVerification(
            version: versionOutput,
            sha256: digest,
            signatureValid: true
        )
    }

    private static func architectures(of executableURL: URL) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lipo")
        process.arguments = ["-archs", executableURL.path]
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw LibTVBinaryVerificationError.versionInvocationFailed(error.localizedDescription)
        }
        let value = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw LibTVBinaryVerificationError.unsupportedArchitecture(value)
        }
        return value
    }
}
