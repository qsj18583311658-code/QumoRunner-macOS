import CryptoKit
import Foundation

/// Append-only command dialect. Model values remain governed by approved model schemas.
/// Breaking grammar/output changes require a new adapter ID, fixtures and queue canary tests.
public enum LibTVCLIAdapter {
    public static let id = "libtv-cli-v1"

    public static func queryNode(_ node: String, project: String, group: String) -> [String] {
        ["node", node, "--project", project, "--group", group]
    }
    public static func upload(_ node: String, file: String, kind: String, project: String, group: String) -> [String] {
        ["upload", node, "--file", file, "--type", kind, "--project", project, "--group", group]
    }
    public static func listProjects(name: String) -> [String] {
        ["project", "list", "--name", name, "--page-size", "20"]
    }
    public static func createProject(name: String) -> [String] { ["project", "create", name] }
    public static func deleteNode(_ node: String, project: String, group: String) -> [String] {
        ["node", "delete", node, "--project", project, "--group", group]
    }
    public static func searchModels(modality: String) -> [String] { ["model", "search", "--type", modality] }
    public static func modelSchema(_ model: String) -> [String] { ["model", model] }
    public static func parse(_ output: String) throws -> LibTVTaskSnapshot { try LibTVOutputParser.parse(output) }
    public static func remoteTaskID(in output: String) -> String? { LibTVOutputParser.remoteTaskID(in: output) }
}

public enum LibTVCLIContractError: Error, Equatable, LocalizedError, Sendable {
    case incompatible(String)
    case unsupportedAdapter(String)
    public var errorDescription: String? {
        switch self {
        case .incompatible(let detail): "LibTV CLI 与适配器 \(LibTVCLIAdapter.id) 不兼容：\(detail)。请保留稳定版本并更新适配器后重新验证。"
        case .unsupportedAdapter(let id): "任务锁定的 CLI 适配器 \(id) 不受当前 Runner 支持，禁止换适配器重新提交。"
        }
    }
}

public struct LibTVCLIHelpProbe: Sendable {
    public let command: [String]
    /// Exact positional arguments in the usage line, ignoring [options]/[command].
    public let positional: [String]
    /// true = required option value; false = boolean switch.
    public let options: [String: Bool]
    public var key: String { command.joined(separator: " ") }

    public func validate(_ result: LibTVProcessResult) throws -> String {
        guard result.disposition == .exited, result.exitCode == 0 else {
            throw LibTVCLIContractError.incompatible("\(key) --help 执行失败")
        }
        let text = result.standardOutput.replacingOccurrences(
            of: #"\x1B\[[0-9;]*[A-Za-z]"#, with: "", options: .regularExpression
        )
        let lines = text.components(separatedBy: .newlines)
        guard let usage = lines.first(where: { $0.contains("libtv \(key)") }) else {
            throw LibTVCLIContractError.incompatible("\(key) 缺少用法声明")
        }
        // Command aliases in Commander usage (e.g. list|ls) do not change the dialect.
        let suffix = String(usage.components(separatedBy: "libtv \(key)").last ?? "")
            .replacingOccurrences(of: #"^\|[^\s]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "[options]", with: "")
            .replacingOccurrences(of: "[command]", with: "")
            .split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard suffix == positional else {
            throw LibTVCLIContractError.incompatible("\(key) 位置参数变化")
        }
        // Match definitions only: an option mentioned in prose is not evidence it exists.
        let regex = try NSRegularExpression(pattern: #"^\s+(?:-[A-Za-z],\s+)?(--[a-z][a-z0-9-]*)(?:[ \t]+(<[^>]+>|\[[^\]]+\]))?"#)
        var declared: [String: String] = [:]
        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  let flagRange = Range(match.range(at: 1), in: line) else { continue }
            let value = Range(match.range(at: 2), in: line).map { String(line[$0]) } ?? ""
            declared[String(line[flagRange])] = value.isEmpty ? "flag" : (value.hasPrefix("<") ? "required" : "optional")
        }
        for (flag, takesValue) in options {
            guard declared[flag] == (takesValue ? "required" : "flag") else {
                throw LibTVCLIContractError.incompatible("\(key) 的 \(flag) 缺失或取值方式变化")
            }
        }
        let normalized = ([key] + positional + declared.keys.sorted().map { "\($0)=\(declared[$0]!)" }).joined(separator: "\n")
        return SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public enum LibTVCLIContract {
    public static let probes: [LibTVCLIHelpProbe] = [
        .init(command: ["node", "create"], positional: ["<node>"], options: ["--project": true, "--group": true, "--type": true, "--set": true, "--prompt": true, "--left": true, "--run": false]),
        .init(command: ["node"], positional: ["[node]"], options: ["--project": true, "--group": true, "--run": false]),
        .init(command: ["node", "delete"], positional: ["<node>"], options: ["--project": true, "--group": true]),
        .init(command: ["group", "create"], positional: ["<group>"], options: ["--project": true]),
        .init(command: ["project", "create"], positional: ["<project>"], options: [:]),
        .init(command: ["project", "list"], positional: [], options: ["--name": true, "--page-size": true]),
        .init(command: ["upload"], positional: ["<node>"], options: ["--file": true, "--type": true, "--project": true, "--group": true]),
        .init(command: ["model", "search"], positional: ["[name...]"], options: ["--type": true]),
        .init(command: ["model"], positional: ["[name...]"], options: [:]),
        .init(command: ["account", "info"], positional: [], options: [:]),
        .init(command: ["account", "list"], positional: [], options: [:]),
    ]

    /// Read-only syntax gate, NOT proof of model/output semantics. Production promotion also
    /// requires the existing image/video queue tests, schema review and administrator approval.
    public static func verify(
        runtime: LibTVRuntimeIdentity,
        run: @Sendable ([String]) async throws -> LibTVProcessResult
    ) async throws -> JSONPayloadValue {
        let version = try await run(["--version"])
        let observed = version.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard version.disposition == .exited, version.exitCode == 0,
              observed == runtime.version || observed == "libtv \(runtime.version)" else {
            throw LibTVCLIContractError.incompatible("CLI 自报版本与任务锁定版本不一致")
        }
        var fingerprints: [String: JSONPayloadValue] = [:]
        for probe in probes {
            fingerprints[probe.key] = .string(try probe.validate(await run(probe.command + ["--help"])))
        }
        return .object([
            "adapter_id": .string(LibTVCLIAdapter.id),
            "runtime_version": .string(runtime.version),
            "runtime_sha256": .string(runtime.sha256),
            "status": .string("passed"),
            "help_fingerprints": .object(fingerprints),
        ])
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
