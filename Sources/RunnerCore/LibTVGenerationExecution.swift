import CryptoKit
import Foundation

public struct PreparedLibTVSubmission: Equatable, Sendable {
    public let arguments: [String]
    public let requestFingerprint: String

    public init(arguments: [String], requestFingerprint: String) {
        self.arguments = arguments
        self.requestFingerprint = requestFingerprint
    }
}

public enum LibTVNodeArgumentsError: Error, Equatable, LocalizedError, Sendable {
    case wrongModality(expected: GenerationModality, actual: GenerationModality)
    case invalidExecutionIdentifier(String)
    case inputNodeCountMismatch(expected: Int, actual: Int)
    case nonScalarSetting(String)

    public var errorDescription: String? {
        switch self {
        case .wrongModality(let expected, let actual):
            "Expected a \(expected.rawValue) generation but received \(actual.rawValue)."
        case .invalidExecutionIdentifier(let value):
            "LibTV execution identifiers must be non-empty: \(value)"
        case .inputNodeCountMismatch(let expected, let actual):
            "Expected \(expected) prepared input nodes but received \(actual)."
        case .nonScalarSetting(let key):
            "LibTV --set only accepts a validated scalar value for \(key)."
        }
    }
}

/// Command grammar for non-billable preparation steps. Keeping these arguments in a
/// pure builder prevents silent drift when the LibTV CLI changes its subcommands.
public enum LibTVPreparationArgumentsBuilder {
    public static func createGroup(name: String, projectUUID: String) -> [String] {
        ["group", "create", name, "--project", projectUUID]
    }
}

/// Pure, deterministic construction of the only paid LibTV command shape accepted in
/// production. Callers provide values that have already passed `LibTVGenerationValidator`;
/// this builder owns the command grammar and never accepts a subcommand or arbitrary arguments.
public enum LibTVNodeArgumentsBuilder {
    public static func arguments(
        for generation: ValidatedLibTVGeneration,
        projectUUID: String,
        groupName: String,
        generationNodeName: String,
        inputNodeNames: [String]
    ) throws -> [String] {
        switch generation.spec.modality {
        case .image:
            return try imageArguments(
                for: generation,
                projectUUID: projectUUID,
                groupName: groupName,
                generationNodeName: generationNodeName,
                inputNodeNames: inputNodeNames
            )
        case .video:
            return try videoArguments(
                for: generation,
                projectUUID: projectUUID,
                groupName: groupName,
                generationNodeName: generationNodeName,
                inputNodeNames: inputNodeNames
            )
        }
    }

    public static func imageArguments(
        for generation: ValidatedLibTVGeneration,
        projectUUID: String,
        groupName: String,
        generationNodeName: String,
        inputNodeNames: [String]
    ) throws -> [String] {
        guard generation.spec.modality == .image else {
            throw LibTVNodeArgumentsError.wrongModality(expected: .image, actual: generation.spec.modality)
        }
        return try nodeArguments(
            for: generation,
            projectUUID: projectUUID,
            groupName: groupName,
            generationNodeName: generationNodeName,
            inputNodeNames: inputNodeNames
        )
    }

    public static func videoArguments(
        for generation: ValidatedLibTVGeneration,
        projectUUID: String,
        groupName: String,
        generationNodeName: String,
        inputNodeNames: [String]
    ) throws -> [String] {
        guard generation.spec.modality == .video else {
            throw LibTVNodeArgumentsError.wrongModality(expected: .video, actual: generation.spec.modality)
        }
        return try nodeArguments(
            for: generation,
            projectUUID: projectUUID,
            groupName: groupName,
            generationNodeName: generationNodeName,
            inputNodeNames: inputNodeNames
        )
    }

    private static func nodeArguments(
        for generation: ValidatedLibTVGeneration,
        projectUUID: String,
        groupName: String,
        generationNodeName: String,
        inputNodeNames: [String]
    ) throws -> [String] {
        for value in [projectUUID, groupName, generationNodeName] where value.isEmpty {
            throw LibTVNodeArgumentsError.invalidExecutionIdentifier(value)
        }
        guard inputNodeNames.count == generation.spec.inputs.count else {
            throw LibTVNodeArgumentsError.inputNodeCountMismatch(
                expected: generation.spec.inputs.count,
                actual: inputNodeNames.count
            )
        }
        if let empty = inputNodeNames.first(where: \.isEmpty) {
            throw LibTVNodeArgumentsError.invalidExecutionIdentifier(empty)
        }

        var arguments = [
            "node", "create", generationNodeName,
            "--project", projectUUID,
            "--group", groupName,
            "--type", generation.spec.modality.rawValue,
            "--set", "model=\(generation.modelName)",
            "--set", "count=\(generation.spec.count)",
        ]
        if let prompt = generation.spec.prompt { arguments += ["--prompt", prompt] }
        if let mode = generation.spec.modeType { arguments += ["--set", "modeType=\(mode)"] }
        for (key, value) in generation.flattenedSettings.sorted(by: { $0.0 < $1.0 }) {
            arguments += ["--set", "\(key)=\(try cliValue(value, key: key))"]
        }
        for inputNode in inputNodeNames { arguments += ["--left", inputNode] }
        arguments.append("--run")
        return arguments
    }

    private static func cliValue(_ value: JSONPayloadValue, key: String) throws -> String {
        switch value {
        case .string(let value): return value
        case .number(let value):
            return value.rounded() == value ? String(Int64(value)) : String(value)
        case .bool(let value): return value ? "true" : "false"
        case .null: return "null"
        default: throw LibTVNodeArgumentsError.nonScalarSetting(key)
        }
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
        let projectUUID = try await ensureProject(profileRef: profileRef, executor: executor)
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
                arguments: ["node", nodeName, "--project", projectUUID, "--group", groupName],
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
                arguments: [
                    "upload", nodeName, "--file", destination.path,
                    "--type", input.kind, "--project", projectUUID, "--group", groupName,
                ],
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
            requestFingerprint: try requestFingerprint(job: job, spec: validated.spec)
        )
    }

    private func ensureProject(profileRef: String, executor: ProfileExecutor) async throws -> String {
        if let existing = await projectStore.projectUUID(profileRef: profileRef) { return existing }
        let projectName = "Qumo Runner Hidden · \(profileToken(profileRef))"
        let list = try await executor.execute(
            jobID: "project-list:\(profileToken(profileRef))",
            arguments: ["project", "list", "--name", projectName, "--page-size", "20"],
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
            jobID: "project:\(profileToken(profileRef))",
            arguments: ["project", "create", projectName],
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
                    arguments: [
                        "node", "delete", node,
                        "--project", layout.projectUUID,
                        "--group", layout.groupName,
                    ],
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
