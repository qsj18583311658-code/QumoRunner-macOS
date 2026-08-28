import Foundation

public struct LibTVTaskSnapshot: Equatable, Sendable {
    public let taskID: String?
    public let state: RunnerJobState
    public let loading: Bool?
    public let progressPercent: Double?
    public let outputs: [String]
    public let rawStatus: String
    public let failureReason: String?

    public init(
        taskID: String?,
        state: RunnerJobState,
        loading: Bool?,
        progressPercent: Double?,
        outputs: [String],
        rawStatus: String,
        failureReason: String? = nil
    ) {
        self.taskID = taskID
        self.state = state
        self.loading = loading
        self.progressPercent = progressPercent
        self.outputs = outputs
        self.rawStatus = rawStatus
        self.failureReason = failureReason
    }
}

public enum LibTVParseError: Error, Equatable, LocalizedError, Sendable {
    case noJSONObject
    case malformedJSON
    case missingTaskInfo

    public var errorDescription: String? {
        switch self {
        case .noJSONObject: "LibTV output did not contain a JSON object."
        case .malformedJSON: "LibTV output contained malformed JSON."
        case .missingTaskInfo: "LibTV JSON did not contain data.taskInfo."
        }
    }
}

public enum LibTVOutputParser {
    /// Extracts a durable task identifier from live `node create --run` output before the
    /// command exits. LibTV 1.0.2 emits `[run] task=<id>` progress lines on stderr.
    public static func remoteTaskID(in output: String) -> String? {
        let pattern = #"(?:^|\s)task=([^\s]+)"#
        if let expression = try? NSRegularExpression(pattern: pattern),
           let match = expression.firstMatch(
               in: output,
               range: NSRange(output.startIndex..., in: output)
           ),
           let range = Range(match.range(at: 1), in: output) {
            return String(output[range])
        }
        return (try? parse(output))?.taskID
    }

    public static func parse(_ output: String) throws -> LibTVTaskSnapshot {
        let candidates = extractJSONObjects(from: output)
        guard !candidates.isEmpty else {
            if let snapshot = progressSnapshot(from: output) { return snapshot }
            throw output.contains("{") ? LibTVParseError.malformedJSON : .noJSONObject
        }

        var decodedAny = false
        for candidate in candidates.reversed() {
            guard let data = candidate.data(using: .utf8),
                  let root = try? JSONDecoder().decode(JSONValue.self, from: data) else {
                continue
            }
            decodedAny = true
            guard let payload = root["data"]?.objectValue,
                  let info = payload["taskInfo"]?.objectValue else { continue }
            return snapshot(from: info, payload: payload)
        }
        if let snapshot = progressSnapshot(from: output) { return snapshot }
        throw decodedAny ? LibTVParseError.missingTaskInfo : LibTVParseError.malformedJSON
    }

    private static func snapshot(
        from info: [String: JSONValue],
        payload: [String: JSONValue]
    ) -> LibTVTaskSnapshot {
        let taskID = info["taskId"]?.stringRepresentation
            ?? info["taskID"]?.stringRepresentation
        let progress = info["progressPercent"]?.doubleValue
        let loading = info["loading"]?.boolValue
        let status = info["status"]
        let rawStatus = status?.stringRepresentation ?? "missing"
        let failureReason = ["failedReason", "failureReason", "error", "message"]
            .lazy
            .compactMap { info[$0]?.stringValue ?? payload[$0]?.stringValue }
            .first
        var outputs = collectOutputs(info)
        outputs.append(contentsOf: collectOutputs(payload))
        var seen = Set<String>()
        outputs = outputs.filter { !$0.isEmpty && seen.insert($0).inserted }
        let state = classify(
            status: status,
            progress: progress,
            loading: loading,
            hasOutput: !outputs.isEmpty
        )
        return LibTVTaskSnapshot(
            taskID: taskID,
            state: state,
            loading: loading,
            progressPercent: progress,
            outputs: outputs,
            rawStatus: rawStatus,
            failureReason: failureReason
        )
    }

    /// LibTV writes live run diagnostics to stderr. Some terminal failures do not emit a JSON
    /// snapshot on stdout, but the diagnostic still contains the durable task id and state.
    private static func progressSnapshot(from output: String) -> LibTVTaskSnapshot? {
        let pattern = #"task=([^\s]+)\s+status=(-?\d+)\s+progress=([0-9]+(?:\.[0-9]+)?)%"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.matches(
                in: output,
                range: NSRange(output.startIndex..., in: output)
              ).last,
              let taskRange = Range(match.range(at: 1), in: output),
              let statusRange = Range(match.range(at: 2), in: output),
              let progressRange = Range(match.range(at: 3), in: output),
              let status = Int(String(output[statusRange])),
              let progress = Double(String(output[progressRange])) else { return nil }
        return LibTVTaskSnapshot(
            taskID: String(output[taskRange]),
            state: classify(status: .number(Double(status)), progress: progress, loading: nil, hasOutput: false),
            loading: nil,
            progressPercent: progress,
            outputs: [],
            rawStatus: String(status)
        )
    }

    private static func classify(
        status: JSONValue?,
        progress: Double?,
        loading: Bool?,
        hasOutput: Bool
    ) -> RunnerJobState {
        if let number = status?.intValue {
            switch number {
            case 0, 1:
                return .running
            case 2:
                if (progress ?? 0) >= 100, hasOutput { return .succeeded }
                if loading == true || (progress ?? 0) < 100 { return .running }
                return .needsReview
            case 3, 4:
                return .failed
            case 5:
                return .cancelled
            default:
                return .needsReview
            }
        }

        let normalized = status?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        switch normalized {
        case "queued", "pending", "leased", "submitting", "submitted", "running", "processing", "in_progress":
            return .running
        case "success", "succeeded", "completed", "complete", "done", "finished":
            return hasOutput ? .succeeded : .needsReview
        case "failed", "failure", "error", "errored":
            return .failed
        case "cancelled", "canceled":
            return .cancelled
        default:
            return .needsReview
        }
    }

    private static func collectOutputs(_ info: [String: JSONValue]) -> [String] {
        let keys = ["outputs", "output", "result", "results", "urls", "url"]
        var values: [String] = []
        for key in keys {
            guard let value = info[key] else { continue }
            collectStrings(value, into: &values)
        }
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func collectStrings(_ value: JSONValue, into result: inout [String]) {
        switch value {
        case .string(let string):
            result.append(string)
        case .array(let values):
            for value in values { collectStrings(value, into: &result) }
        case .object(let object):
            let preferredKeys = ["url", "uri", "path", "downloadUrl", "outputUrl"]
            let preferred = preferredKeys.compactMap { object[$0] }
            for value in preferred.isEmpty ? Array(object.values) : preferred {
                collectStrings(value, into: &result)
            }
        default:
            break
        }
    }

    /// Extracts balanced JSON objects while ignoring braces inside quoted strings.
    static func extractJSONObjects(from text: String) -> [String] {
        var results: [String] = []
        var start: String.Index?
        var depth = 0
        var isInString = false
        var isEscaped = false

        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if isInString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    isInString = false
                }
            } else {
                if character == "\"" {
                    isInString = true
                } else if character == "{" {
                    if depth == 0 { start = index }
                    depth += 1
                } else if character == "}", depth > 0 {
                    depth -= 1
                    if depth == 0, let start {
                        results.append(String(text[start...index]))
                    }
                    if depth == 0 { start = nil }
                }
            }
            index = text.index(after: index)
        }
        return results
    }
}

private enum JSONValue: Codable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    subscript(key: String) -> JSONValue? { objectValue?[key] }
    var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }
    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }
    var doubleValue: Double? {
        switch self {
        case .number(let value): value
        case .string(let value): Double(value)
        default: nil
        }
    }
    var intValue: Int? {
        guard let doubleValue, doubleValue.rounded() == doubleValue else { return nil }
        return Int(doubleValue)
    }
    var boolValue: Bool? {
        switch self {
        case .bool(let value): value
        case .string(let value): Bool(value)
        default: nil
        }
    }
    var stringRepresentation: String? {
        switch self {
        case .string(let value): value
        case .number(let value):
            value.rounded() == value ? String(Int(value)) : String(value)
        case .bool(let value): String(value)
        default: nil
        }
    }
}
