import CryptoKit
import Foundation

public struct PreparedLibTVSubmission: Equatable, Sendable {
    public let arguments: [String]
    public let requestFingerprint: String
    public let parameterDiagnostics: JSONPayloadValue
    public let seedanceCompliancePreflight: SeedanceCompliancePreflight

    public init(
        arguments: [String],
        requestFingerprint: String,
        parameterDiagnostics: JSONPayloadValue = .object([:]),
        seedanceCompliancePreflight: SeedanceCompliancePreflight = .notRequired()
    ) {
        self.arguments = arguments
        self.requestFingerprint = requestFingerprint
        self.parameterDiagnostics = parameterDiagnostics
        self.seedanceCompliancePreflight = seedanceCompliancePreflight
    }
}

public enum SeedanceComplianceCLIErrorClassification: String, Equatable, Sendable {
    case rejected
    case retryableError = "retryable_error"
    case uncertain
    case unrelated
}

/// Pure classifier for failures emitted before LibTV exposes an immutable remote task ID.
/// It is intentionally scoped to explicit compliance context so ordinary generation/model
/// failures can never be treated as a compliance rejection or Runtime health signal.
public enum SeedanceComplianceCLIErrorClassifier {
    public static func classify(standardOutput: String, standardError: String) -> SeedanceComplianceCLIErrorClassification {
        let diagnostic = "\(standardError)\n\(standardOutput)"
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !diagnostic.isEmpty, hasComplianceContext(diagnostic) else { return .unrelated }

        if containsAny(diagnostic, retryablePhrases) { return .retryableError }
        if containsAny(diagnostic, rejectedPhrases) { return .rejected }
        if containsAny(diagnostic, uncertainPhrases) { return .uncertain }
        return .unrelated
    }

    private static func hasComplianceContext(_ value: String) -> Bool {
        containsAny(value, [
            "合规", "真人", "肖像", "人物授权", "真人授权", "人物认证", "真人认证",
            "compliance", "portrait", "human authorization", "person authorization",
        ])
    }

    private static func containsAny(_ value: String, _ phrases: [String]) -> Bool {
        phrases.contains(where: value.contains)
    }

    private static let rejectedPhrases = [
        "合规检测未通过", "合规校验未通过", "合规不通过", "未通过合规", "素材不合规", "不符合合规",
        "未经授权", "未获得授权", "没有授权", "授权失败", "未授权真人", "真人未授权", "人物未授权", "肖像未授权",
        "真人认证失败", "人物认证失败", "compliance rejected", "compliance check rejected",
        "not compliant", "compliance violation", "unauthorized portrait", "portrait is not authorized",
        "portrait not authorized", "human is not authorized", "authorization failed",
    ]

    private static let retryablePhrases = [
        "合规检测服务暂时不可用", "合规校验服务暂时不可用", "合规服务暂时不可用",
        "检测服务异常", "检测服务繁忙", "合规服务异常", "合规服务繁忙", "稍后重试",
        "compliance service temporarily unavailable", "compliance check service temporarily unavailable",
        "compliance service unavailable", "compliance service busy", "portrait service unavailable",
        "try again later", "temporarily unavailable", "service timeout", "request timeout", "timed out",
        "network error", "econnreset", "etimedout",
    ]

    private static let uncertainPhrases = [
        "合规检测失败", "合规校验失败", "真人检测失败", "肖像检测失败",
        "compliance check failed", "portrait check failed", "portrait detection failed",
    ]
}

public enum LibTVParameterDiagnosticsBuilder {
    /// Builds a prompt-free, artifact-free description of what the Runner actually validated
    /// and expanded for LibTV. This can be persisted with the task without exposing media keys.
    public static func build(
        job: RunnerJob,
        validated: ValidatedLibTVGeneration
    ) throws -> JSONPayloadValue {
        let runnerFingerprint = try CanonicalJSON.sha256(.object(job.payload))
        let serverFingerprint = job.result?.objectValue?["parameter_diagnostics"]?
            .objectValue?["server_spec_fingerprint"]?.stringValue
        let flattenedSettings = Dictionary(
            uniqueKeysWithValues: validated.flattenedSettings.map { ($0.0, $0.1) }
        )
        let inputs = validated.spec.inputs
            .sorted(by: { $0.order < $1.order })
            .map { input in
                JSONPayloadValue.object([
                    "kind": .string(input.kind),
                    "role": .string(input.role),
                    "order": .number(Double(input.order)),
                ])
            }
        var diagnostics: [String: JSONPayloadValue] = [
            "contract_version": .string("libtv-generation-spec-v1"),
            "cli_adapter_id": .string(LibTVCLIAdapter.id),
            "status": .string(serverFingerprint == nil ? "runner_verified" : (serverFingerprint == runnerFingerprint ? "matched" : "mismatch")),
            "runner_spec_fingerprint": .string(runnerFingerprint),
            "model_ref": .string(validated.spec.modelRef),
            "model_name": .string(validated.modelName),
            "modality": .string(validated.spec.modality.rawValue),
            "count": .number(Double(validated.spec.count)),
            "mode_type": validated.spec.modeType.map(JSONPayloadValue.string) ?? .null,
            "base_schema_hash": job.baseSchemaHash.map(JSONPayloadValue.string) ?? .null,
            "effective_schema_hash": .string(validated.spec.effectiveSchemaHash),
            "patch_version": job.patchVersion.map { .number(Double($0)) } ?? .null,
            "settings": .object(validated.spec.settings),
            "advanced_settings": .object(validated.spec.advancedSettings),
            "flattened_settings": .object(flattenedSettings),
            "inputs": .array(inputs),
            "prompt_present": .bool(!(validated.spec.prompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)),
        ]
        if let serverFingerprint {
            diagnostics["server_spec_fingerprint"] = .string(serverFingerprint)
            diagnostics["fingerprints_match"] = .bool(serverFingerprint == runnerFingerprint)
        }
        return .object(diagnostics)
    }
}

public protocol GenerationJobPreparing: Sendable {
    func prepare(
        job: RunnerJob,
        profileRef: String,
        executor: ProfileExecutor
    ) async throws -> PreparedLibTVSubmission
}

public protocol GenerationInputMaterializing: Sendable {
    /// Implementations obtain a task-scoped credential from Qumo and write only the requested
    /// artifact to `destinationURL`. The generation spec itself never carries a URL.
    func materialize(
        jobID: String,
        input: LibTVGenerationInputV1,
        destinationURL: URL
    ) async throws
}

public enum GenerationInputMaterializationError: Error, Equatable, LocalizedError, Sendable {
    case unavailable
    case checksumMismatch(artifactKey: String)
    case unsafeFileKind(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable: "The Runner has no task-scoped input materializer configured."
        case .checksumMismatch(let key): "Downloaded input \(key) failed SHA-256 verification."
        case .unsafeFileKind(let kind): "Input kind \(kind) is not supported."
        }
    }
}

public struct UnavailableGenerationInputMaterializer: GenerationInputMaterializing {
    public init() { }
    public func materialize(jobID: String, input: LibTVGenerationInputV1, destinationURL: URL) async throws {
        throw GenerationInputMaterializationError.unavailable
    }
}

public actor LibTVExecutionProjectStore {
    private struct State: Codable { var projects: [String: String] = [:] }
    private let fileURL: URL
    private var state: State

    public init(fileURL: URL) {
        self.fileURL = fileURL
        state = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
    }

    public func projectUUID(profileRef: String) -> String? { state.projects[profileRef] }

    public func setProjectUUID(_ uuid: String, profileRef: String) throws {
        state.projects[profileRef] = uuid
        let parent = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: fileURL, options: .atomic)
        _ = chmod(fileURL.path, 0o600)
    }
}

public enum LibTVExecutionPreparationError: Error, Equatable, LocalizedError, Sendable {
    case commandFailed(String)
    case invalidProjectResponse

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let detail): "LibTV preparation failed: \(detail)"
        case .invalidProjectResponse: "LibTV project create did not return a project UUID."
        }
    }
}

enum LibTVProjectResponseParser {
    static func projectUUID(from output: String, named expectedName: String? = nil) -> String? {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"),
              let data = String(output[start...end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return findProjectUUID(in: object, named: expectedName)
    }

    private static func findProjectUUID(in value: Any, named expectedName: String?) -> String? {
        if let object = value as? [String: Any] {
            let nameMatches = expectedName == nil || (object["name"] as? String) == expectedName
            if nameMatches {
                for key in ["uuid", "projectUuid", "project_uuid"] {
                    if let candidate = object[key] as? String,
                       isValidProjectUUID(candidate) {
                        return candidate
                    }
                }
            }
            for child in object.values {
                if let candidate = findProjectUUID(in: child, named: expectedName) {
                    return candidate
                }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let candidate = findProjectUUID(in: child, named: expectedName) {
                    return candidate
                }
            }
        }
        return nil
    }

    private static func isValidProjectUUID(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (16...128).contains(normalized.count) else { return false }
        return normalized.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
        }
    }
}

/// Builds the hidden LibTV execution space using only CLI commands documented by LibTV.
/// Preparation is idempotent by deterministic names plus query-before-upload. Only the returned
/// final `node ... --run` command may start a paid remote generation.
public actor LibTVGenerationPreparer: GenerationJobPreparing {
    private let registry: LibTVSchemaRegistry
    private let projectStore: LibTVExecutionProjectStore
    private let materializer: any GenerationInputMaterializing
    private let stagingRoot: URL
    private let journal: SubmissionJournal

    public init(
        registry: LibTVSchemaRegistry,
        projectStore: LibTVExecutionProjectStore,
        materializer: any GenerationInputMaterializing = UnavailableGenerationInputMaterializer(),
        stagingRoot: URL,
        journal: SubmissionJournal
    ) {
        self.registry = registry
        self.projectStore = projectStore
        self.materializer = materializer
        self.stagingRoot = stagingRoot
        self.journal = journal
    }

    public func prepare(
        job: RunnerJob,
        profileRef: String,
        executor: ProfileExecutor
    ) async throws -> PreparedLibTVSubmission {
        let validated = try LibTVGenerationValidator.validate(job: job, profileRef: profileRef, registry: registry)
        let projectUUID = try await ensureProject(jobID: job.id, profileRef: profileRef, executor: executor)
        let groupName = deterministicName(prefix: "qumo-job", seed: job.id)
        let generationNode = deterministicName(prefix: "generate", seed: job.id)
        let groupResult = try await executor.execute(
            jobID: "\(job.id):prepare-group",
            arguments: LibTVPreparationArgumentsBuilder.createGroup(
                name: groupName,
                projectUUID: projectUUID
            ),
            timeout: .seconds(90)
        )
        try requireSuccess(groupResult)

        let stagingDirectory = stagingRoot
            .appendingPathComponent(profileToken(profileRef), isDirectory: true)
            .appendingPathComponent(jobToken(job.id), isDirectory: true)
        try FileManager.default.createDirectory(
            at: stagingDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }

        var inputNodeNames: [String] = []
        for input in validated.spec.inputs.sorted(by: { $0.order < $1.order }) {
            let nodeName = deterministicName(prefix: "input-\(input.order)", seed: input.artifactKey)
            inputNodeNames.append(nodeName)
            let query = try await executor.execute(
                jobID: "\(job.id):query-input-\(input.order)",
                arguments: LibTVCLIAdapter.queryNode(nodeName, project: projectUUID, group: groupName),
                timeout: .seconds(45)
            )
            if query.exitCode == 0 && !query.requiresManualReview { continue }

            let destination = stagingDirectory.appendingPathComponent("\(input.order).\(try extensionForKind(input.kind))")
            try await materializer.materialize(jobID: job.id, input: input, destinationURL: destination)
            guard try sha256(destination) == input.sha256 else {
                throw GenerationInputMaterializationError.checksumMismatch(artifactKey: input.artifactKey)
            }
            let upload = try await executor.execute(
                jobID: "\(job.id):upload-input-\(input.order)",
                arguments: LibTVCLIAdapter.upload(nodeName, file: destination.path, kind: input.kind, project: projectUUID, group: groupName),
                timeout: .seconds(10 * 60)
            )
            try requireSuccess(upload)
        }

        try await journal.recordExecutionLayout(
            jobID: job.id,
            profileRef: profileRef,
            projectUUID: projectUUID,
            groupName: groupName,
            inputNodeNames: inputNodeNames,
            generationNodeName: generationNode
        )

        let arguments = try LibTVNodeArgumentsBuilder.arguments(
            for: validated,
            projectUUID: projectUUID,
            groupName: groupName,
            generationNodeName: generationNode,
            inputNodeNames: inputNodeNames
        )
        return PreparedLibTVSubmission(
            arguments: arguments,
            requestFingerprint: try requestFingerprint(job: job, spec: validated.spec),
            parameterDiagnostics: try LibTVParameterDiagnosticsBuilder.build(job: job, validated: validated),
            seedanceCompliancePreflight: validated.seedanceCompliancePreflight
        )
    }

    private func ensureProject(jobID: String, profileRef: String, executor: ProfileExecutor) async throws -> String {
        if let existing = await projectStore.projectUUID(profileRef: profileRef) { return existing }
        let projectName = "Qumo Runner Hidden · \(profileToken(profileRef))"
        let list = try await executor.execute(
            jobID: "\(jobID):project-list",
            arguments: LibTVCLIAdapter.listProjects(name: projectName),
            timeout: .seconds(90)
        )
        try requireSuccess(list)
        if let existing = LibTVProjectResponseParser.projectUUID(
            from: list.standardOutput,
            named: projectName
        ) {
            try await projectStore.setProjectUUID(existing, profileRef: profileRef)
            return existing
        }
        let result = try await executor.execute(
            jobID: "\(jobID):project-create",
            arguments: LibTVCLIAdapter.createProject(name: projectName),
            timeout: .seconds(90)
        )
        try requireSuccess(result)
        guard let uuid = LibTVProjectResponseParser.projectUUID(from: result.standardOutput) else {
            throw LibTVExecutionPreparationError.invalidProjectResponse
        }
        try await projectStore.setProjectUUID(uuid, profileRef: profileRef)
        return uuid
    }

    private func requireSuccess(_ pending: LibTVProcessResult) throws {
        guard pending.exitCode == 0, !pending.requiresManualReview else {
            throw LibTVExecutionPreparationError.commandFailed(pending.standardError)
        }
    }

    private func requestFingerprint(job: RunnerJob, spec: LibTVGenerationSpecV1) throws -> String {
        let data = try JSONEncoder().encode(spec)
        let specHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return "\(job.idempotencyKey):\(job.baseSchemaHash ?? "missing"):\(spec.effectiveSchemaHash):\(specHash)"
    }

    private func extensionForKind(_ kind: String) throws -> String {
        switch kind {
        case "image": "img"
        case "video": "mp4"
        case "audio": "m4a"
        default: throw GenerationInputMaterializationError.unsafeFileKind(kind)
        }
    }

    private func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hasher.update(data: data) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func deterministicName(prefix: String, seed: String) -> String {
        "\(prefix)-\(shortHash(seed))"
    }

    private func profileToken(_ value: String) -> String { shortHash("profile:\(value)") }
    private func jobToken(_ value: String) -> String { shortHash("job:\(value)") }
    private func shortHash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
    }
}

public actor LibTVExecutionCleaner {
    private let journal: SubmissionJournal

    public init(journal: SubmissionJournal) { self.journal = journal }

    /// Deletes only deterministic objects recorded for expired jobs. A partial CLI failure leaves
    /// the layout in SQLite so the next maintenance pass retries without broad project deletion.
    @discardableResult
    public func cleanupExpired(
        executors: [String: ProfileExecutor],
        at date: Date = .now
    ) async throws -> [String] {
        var cleaned: [String] = []
        for layout in try await journal.expiredExecutionLayouts(at: date) {
            guard let executor = executors[layout.profileRef] else { continue }
            let children = [layout.generationNodeName] + layout.inputNodeNames.reversed()
            var successful = true
            for node in children {
                let result = try await executor.execute(
                    jobID: "\(layout.jobID):cleanup",
                    arguments: LibTVCLIAdapter.deleteNode(node, project: layout.projectUUID, group: layout.groupName),
                    timeout: .seconds(90)
                )
                if result.requiresManualReview || result.exitCode != 0 { successful = false; break }
            }
            guard successful else { continue }
            // LibTV 1.0.2 exposes no documented group-delete operation, and `node delete`
            // explicitly rejects group nodes. Remove the recorded children only; the empty,
            // deterministic diagnostic group is harmless and can be reused for the same job.
            try await journal.markExecutionLayoutCleaned(jobID: layout.jobID)
            cleaned.append(layout.jobID)
        }
        return cleaned
    }
}
