import CryptoKit
import Foundation

public enum GenerationModality: String, Codable, CaseIterable, Sendable {
    case image
    case video
}

public struct LibTVGenerationInputV1: Codable, Hashable, Sendable {
    public let artifactKey: String
    public let kind: String
    public let role: String
    public let order: Int
    public let sha256: String

    enum CodingKeys: String, CodingKey {
        case artifactKey = "artifact_key"
        case kind, role, order, sha256
    }

    public init(artifactKey: String, kind: String, role: String, order: Int, sha256: String) {
        self.artifactKey = artifactKey
        self.kind = kind
        self.role = role
        self.order = order
        self.sha256 = sha256
    }
}

/// The only accepted production generation payload. The claim envelope carries this object
/// directly in `RunnerJob.payload`; it is deliberately not nested under `spec`.
public struct LibTVGenerationSpecV1: Codable, Hashable, Sendable {
    public let version: String
    public let modality: GenerationModality
    public let modelRef: String
    public let effectiveSchemaHash: String
    public let prompt: String?
    public let count: Int
    public let modeType: String?
    public let settings: [String: JSONPayloadValue]
    public let advancedSettings: [String: JSONPayloadValue]
    public let inputs: [LibTVGenerationInputV1]

    enum CodingKeys: String, CodingKey {
        case version, modality
        case modelRef = "model_ref"
        case effectiveSchemaHash = "effective_schema_hash"
        case prompt, count
        case modeType = "mode_type"
        case settings
        case advancedSettings = "advanced_settings"
        case inputs
    }

    public init(
        version: String = "1",
        modality: GenerationModality,
        modelRef: String,
        effectiveSchemaHash: String,
        prompt: String? = nil,
        count: Int = 1,
        modeType: String? = nil,
        settings: [String: JSONPayloadValue] = [:],
        advancedSettings: [String: JSONPayloadValue] = [:],
        inputs: [LibTVGenerationInputV1] = []
    ) {
        self.version = version
        self.modality = modality
        self.modelRef = modelRef
        self.effectiveSchemaHash = effectiveSchemaHash
        self.prompt = prompt
        self.count = count
        self.modeType = modeType
        self.settings = settings
        self.advancedSettings = advancedSettings
        self.inputs = inputs
    }

    public static func decode(payload: [String: JSONPayloadValue]) throws -> Self {
        let data = try JSONEncoder().encode(JSONPayloadValue.object(payload))
        return try JSONDecoder().decode(Self.self, from: data)
    }
}

public struct LibTVModelSchemaSnapshot: Codable, Hashable, Sendable {
    public let modelRef: String
    public let modelName: String
    public let schemaHash: String
    public let rawSchema: JSONPayloadValue
    public let approved: Bool

    public init(
        modelRef: String,
        modelName: String,
        schemaHash: String,
        rawSchema: JSONPayloadValue,
        approved: Bool
    ) {
        self.modelRef = modelRef
        self.modelName = modelName
        self.schemaHash = schemaHash
        self.rawSchema = rawSchema
        self.approved = approved
    }

    public func verifiesContentHash() -> Bool {
        (try? CanonicalJSON.sha256(rawSchema)) == schemaHash.lowercased()
    }
}

public enum CanonicalJSON {
    public static func data(_ value: JSONPayloadValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    public static func sha256(_ value: JSONPayloadValue) throws -> String {
        SHA256.hash(data: try data(value)).map { String(format: "%02x", $0) }.joined()
    }
}

public enum GenerationSpecError: Error, Equatable, LocalizedError, Sendable {
    case invalidPayload(String)
    case unsupportedVersion(String)
    case modelMismatch
    case modalityMismatch
    case unapprovedModel
    case baseSchemaMismatch
    case patchVersionMissing
    case effectiveSchemaMismatch
    case invalidSchemaSnapshot
    case effectiveSchemaHashMissing
    case invalidCount
    case unsupportedModeType(String)
    case invalidInput(String)
    case unknownSetting(String)
    case reservedSettingDestination(String)
    case duplicateSettingDestination(String)
    case invalidSettingValue(String)
    case rulesRejected(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPayload(let detail): "Invalid LibTVGenerationSpecV1 payload: \(detail)"
        case .unsupportedVersion(let value): "Unsupported generation spec version: \(value)"
        case .modelMismatch: "The claimed model does not match the locally registered schema."
        case .modalityMismatch: "The requested modality does not match the local LibTV model schema."
        case .unapprovedModel: "The model is not in the local approved whitelist."
        case .baseSchemaMismatch: "The job base_schema_hash does not match the local LibTV schema."
        case .patchVersionMissing: "The job patch_version must identify a published effective schema."
        case .effectiveSchemaMismatch: "The job effective_schema_hash does not match its generation spec."
        case .invalidSchemaSnapshot: "The local LibTV schema snapshot failed its content hash check."
        case .effectiveSchemaHashMissing: "effective_schema_hash must be a lowercase SHA-256 value."
        case .invalidCount: "The requested output count is not allowed by the local schema."
        case .unsupportedModeType(let value): "The local schema does not support mode_type \(value)."
        case .invalidInput(let detail): "Invalid generation input: \(detail)"
        case .unknownSetting(let key): "The setting \(key) is not whitelisted by the local schema."
        case .reservedSettingDestination(let key): "The schema maps a setting onto reserved generation field \(key)."
        case .duplicateSettingDestination(let key): "More than one setting maps onto LibTV field \(key)."
        case .invalidSettingValue(let key): "The value for \(key) violates the local schema."
        case .rulesRejected(let detail): "The local LibTV generation rules rejected the job: \(detail)"
        }
    }
}

/// Thread-safe in-memory view of schemas that were fetched from the same LibTV profile.
/// Approval and the original hash are checked again for every claimed job.
public final class LibTVSchemaRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: [String: LibTVModelSchemaSnapshot]] = [:]

    public init() { }

    public func replace(profileRef: String, schemas: [LibTVModelSchemaSnapshot]) {
        lock.withLock {
            values[profileRef] = Dictionary(uniqueKeysWithValues: schemas.map { ($0.modelRef, $0) })
        }
    }

    public func schema(profileRef: String, modelRef: String) -> LibTVModelSchemaSnapshot? {
        lock.withLock { values[profileRef]?[modelRef] }
    }
}

public struct ValidatedLibTVGeneration: Equatable, Sendable {
    public let spec: LibTVGenerationSpecV1
    public let modelName: String
    public let flattenedSettings: [(String, JSONPayloadValue)]
    public let seedanceCompliancePreflight: SeedanceCompliancePreflight

    public init(
        spec: LibTVGenerationSpecV1,
        modelName: String,
        flattenedSettings: [(String, JSONPayloadValue)],
        seedanceCompliancePreflight: SeedanceCompliancePreflight = .notRequired()
    ) {
        self.spec = spec
        self.modelName = modelName
        self.flattenedSettings = flattenedSettings
        self.seedanceCompliancePreflight = seedanceCompliancePreflight
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.spec == rhs.spec && lhs.modelName == rhs.modelName &&
            lhs.flattenedSettings.map(SettingPair.init) == rhs.flattenedSettings.map(SettingPair.init) &&
            lhs.seedanceCompliancePreflight == rhs.seedanceCompliancePreflight
    }

    private struct SettingPair: Equatable {
        let key: String
        let value: JSONPayloadValue
        init(_ pair: (String, JSONPayloadValue)) { key = pair.0; value = pair.1 }
    }
}

public enum SeedanceCompliancePreflightStatus: String, Codable, Equatable, Sendable {
    case pending
    case notRequired = "not_required"
    case skipped
    case checking
    case passed
    case exempt
    case rejected
    case retryableError = "retryable_error"
    case unknown
}

/// A deliberately redacted description of Seedance's CLI-owned portrait compliance phase.
/// Input order is sufficient for the UI to identify the affected slot; artifact identity,
/// URLs, checksums and the LibTV profile must never cross this boundary.
public struct SeedanceCompliancePreflight: Equatable, Sendable {
    public let status: SeedanceCompliancePreflightStatus
    public let inputOrders: [Int]

    public init(status: SeedanceCompliancePreflightStatus, inputOrders: [Int]) {
        self.status = status
        self.inputOrders = Array(Set(inputOrders)).sorted()
    }

    public static func notRequired(inputOrders: [Int] = []) -> Self {
        .init(status: .notRequired, inputOrders: inputOrders)
    }

    public var requiresCheck: Bool { status == .checking }

    public func payload(status override: SeedanceCompliancePreflightStatus? = nil) -> JSONPayloadValue {
        let reportedStatus = override ?? status
        let checked: Int
        switch reportedStatus {
        case .passed, .exempt:
            checked = inputOrders.count
        case .pending, .checking, .rejected, .retryableError, .unknown, .skipped, .notRequired:
            checked = 0
        }
        var result: [String: JSONPayloadValue] = [
            "type": .string("seedance_compliance"),
            "status": .string(reportedStatus.rawValue),
            "checked": .number(Double(checked)),
            "total": .number(Double(inputOrders.count)),
        ]
        // A CLI-level rejection or service error does not identify the rejected image. Omitting
        // the list prevents the UI from falsely attributing a failure to every input slot.
        if ![.rejected, .retryableError, .unknown].contains(reportedStatus) {
            result["inputs"] = .array(inputOrders.map { order in
                .object([
                    "order": .number(Double(order)),
                    "status": .string(reportedStatus.rawValue),
                ])
            })
        }
        return .object(result)
    }
}

public enum LibTVGenerationValidator {
    public static func validate(
        job: RunnerJob,
        profileRef: String,
        registry: LibTVSchemaRegistry
    ) throws -> ValidatedLibTVGeneration {
        let spec: LibTVGenerationSpecV1
        do { spec = try .decode(payload: job.payload) }
        catch { throw GenerationSpecError.invalidPayload(error.localizedDescription) }
        guard spec.version == "1" else { throw GenerationSpecError.unsupportedVersion(spec.version) }
        guard isSHA256(spec.effectiveSchemaHash) else { throw GenerationSpecError.effectiveSchemaHashMissing }
        guard let patchVersion = job.patchVersion, patchVersion > 0 else {
            throw GenerationSpecError.patchVersionMissing
        }
        guard job.effectiveSchemaHash == spec.effectiveSchemaHash else {
            throw GenerationSpecError.effectiveSchemaMismatch
        }
        guard job.requiredModelRef == nil || job.requiredModelRef == spec.modelRef else {
            throw GenerationSpecError.modelMismatch
        }
        guard let snapshot = registry.schema(profileRef: profileRef, modelRef: spec.modelRef) else {
            throw GenerationSpecError.modelMismatch
        }
        guard snapshot.approved else { throw GenerationSpecError.unapprovedModel }
        guard snapshot.verifiesContentHash() else { throw GenerationSpecError.invalidSchemaSnapshot }
        guard job.baseSchemaHash == snapshot.schemaHash else { throw GenerationSpecError.baseSchemaMismatch }
        guard spec.count > 0 else { throw GenerationSpecError.invalidCount }

        let schema = schemaObject(snapshot.rawSchema)
        let schemaRoot = snapshot.rawSchema.objectValue ?? [:]
        if let schemaModality = schemaRoot["modality"]?.stringValue,
           schemaModality != spec.modality.rawValue {
            throw GenerationSpecError.modalityMismatch
        }
        let properties = schema["properties"]?.objectValue ?? [:]
        try validateCount(spec.count, property: properties["count"])
        try validateModeAndInputs(spec, schema: schema, properties: properties)
        try validateRules(spec, schema: schema)

        let allowedSettings = configuredKeys(schema["config"]?.objectValue?["settings"], mode: spec.modeType)
        let allowedAdvanced = configuredKeys(schema["config"]?.objectValue?["advancedSettings"], mode: spec.modeType)
        let basic = try validatedSettings(spec.settings, allowed: allowedSettings, properties: properties)
        let advanced = try validatedSettings(spec.advancedSettings, allowed: allowedAdvanced, properties: properties)
        var destinations = Set<String>()
        for (key, _) in basic + advanced where !destinations.insert(key).inserted {
            throw GenerationSpecError.duplicateSettingDestination(key)
        }
        return ValidatedLibTVGeneration(
            spec: spec,
            modelName: snapshot.modelName,
            flattenedSettings: (basic + advanced).sorted { $0.0 < $1.0 },
            seedanceCompliancePreflight: seedanceCompliancePreflight(
                spec: spec,
                properties: properties
            )
        )
    }

    private static func seedanceCompliancePreflight(
        spec: LibTVGenerationSpecV1,
        properties: [String: JSONPayloadValue]
    ) -> SeedanceCompliancePreflight {
        guard spec.modality == .video else { return .notRequired() }
        let imageOrders = spec.inputs
            .filter { $0.kind == "image" }
            .map(\.order)
            .sorted()
        guard !imageOrders.isEmpty else { return .notRequired() }
        guard schemaBoolean(properties["portrait"]) == true,
              schemaBoolean(properties["autoCompliance"]?.objectValue?["enable"]) == true else {
            return .notRequired(inputOrders: imageOrders)
        }
        if explicitlyDisabled(spec.advancedSettings["autoCompliance"]) {
            return .init(status: .skipped, inputOrders: imageOrders)
        }
        return .init(status: .checking, inputOrders: imageOrders)
    }

    private static func schemaBoolean(_ value: JSONPayloadValue?) -> Bool? {
        switch value {
        case .bool(let value): value
        case .number(let value) where value == 0 || value == 1: value == 1
        default: nil
        }
    }

    private static func explicitlyDisabled(_ value: JSONPayloadValue?) -> Bool {
        switch value {
        case .bool(false), .number(0): true
        default: false
        }
    }

    private static func schemaObject(_ raw: JSONPayloadValue) -> [String: JSONPayloadValue] {
        let root = raw.objectValue ?? [:]
        return root["schema"]?.objectValue ?? root
    }

    private static func validateCount(_ count: Int, property: JSONPayloadValue?) throws {
        guard let property else { return }
        let allowed: [Double]
        if let array = property.arrayValue { allowed = array.compactMap(\.numberValue) }
        else { allowed = property.objectValue?["enum"]?.arrayValue?.compactMap(enumValue).compactMap(\.numberValue) ?? [] }
        if !allowed.isEmpty && !allowed.contains(Double(count)) { throw GenerationSpecError.invalidCount }
    }

    private static func validateModeAndInputs(
        _ spec: LibTVGenerationSpecV1,
        schema: [String: JSONPayloadValue],
        properties: [String: JSONPayloadValue]
    ) throws {
        var seenOrders = Set<Int>()
        for input in spec.inputs {
            guard !input.artifactKey.isEmpty, !input.kind.isEmpty, !input.role.isEmpty,
                  input.order >= 0, seenOrders.insert(input.order).inserted,
                  isSHA256(input.sha256) else {
                throw GenerationSpecError.invalidInput(input.artifactKey)
            }
            guard ["image", "video", "audio"].contains(input.kind) else {
                throw GenerationSpecError.invalidInput("unsupported kind \(input.kind)")
            }
        }
        guard let modeItems = properties["modeType"]?.objectValue?["items"]?.objectValue else {
            if spec.modeType != nil { throw GenerationSpecError.unsupportedModeType(spec.modeType!) }
            return
        }
        if spec.modality == .image, spec.modeType == nil, spec.inputs.isEmpty { return }
        if spec.modality == .video, spec.modeType == nil, spec.inputs.isEmpty,
           schema["config"]?.objectValue?["generateTypes"]?.objectValue?["text"]?.numberValue != nil {
            return
        }
        guard let mode = spec.modeType, let bounds = modeItems[mode]?.arrayValue,
              bounds.count == 2, let minimum = bounds[0].numberValue, let maximum = bounds[1].numberValue else {
            throw GenerationSpecError.unsupportedModeType(spec.modeType ?? "<missing>")
        }
        let mediaCount = spec.inputs.count
        guard Double(mediaCount) >= minimum, Double(mediaCount) <= maximum else {
            throw GenerationSpecError.invalidInput("mode \(mode) allows \(Int(minimum))...\(Int(maximum)) media inputs")
        }
    }

    private static func validateRules(
        _ spec: LibTVGenerationSpecV1,
        schema: [String: JSONPayloadValue]
    ) throws {
        guard let rules = schema["rules"]?.arrayValue else { return }
        let hasPrompt = !(spec.prompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let kinds = Set(spec.inputs.map(\.kind))
        for ruleValue in rules {
            guard let rule = ruleValue.objectValue,
                  let requirements = rule["require"]?.arrayValue?.compactMap(\.stringValue),
                  !requirements.isEmpty else { continue }
            if let modes = rule["forModeTypes"]?.arrayValue?.compactMap(\.stringValue),
               !modes.isEmpty, !modes.contains(spec.modeType ?? "") { continue }
            let checks = requirements.map { requirement in
                switch requirement {
                case "prompt": hasPrompt
                case "image", "video", "audio": kinds.contains(requirement)
                case "media": !kinds.isEmpty
                default: false
                }
            }
            let passes = rule["mode"]?.stringValue == "any" ? checks.contains(true) : !checks.contains(false)
            if !passes { throw GenerationSpecError.rulesRejected(rule["message"]?.stringValue ?? requirements.joined(separator: ",")) }
        }
    }

    private static func configuredKeys(_ value: JSONPayloadValue?, mode: String?) -> Set<String> {
        if let keys = value?.arrayValue?.compactMap(\.stringValue) { return Set(keys) }
        let object = value?.objectValue ?? [:]
        let selected = object[mode ?? ""]?.arrayValue
            ?? (mode == nil ? object["default"]?.arrayValue : nil)
            ?? (mode == nil ? object["*"]?.arrayValue : nil)
            ?? (mode == nil ? object["text2image"]?.arrayValue : nil)
            ?? (mode == nil ? object["text2video"]?.arrayValue : nil)
            ?? []
        return Set(selected.compactMap(\.stringValue))
    }

    private static func validatedSettings(
        _ settings: [String: JSONPayloadValue],
        allowed: Set<String>,
        properties: [String: JSONPayloadValue]
    ) throws -> [(String, JSONPayloadValue)] {
        try settings.map { key, value in
            guard allowed.contains(key), let property = properties[key]?.objectValue else {
                throw GenerationSpecError.unknownSetting(key)
            }
            guard isScalar(value), enumAllows(value, property: property), rangeAllows(value, property: property) else {
                throw GenerationSpecError.invalidSettingValue(key)
            }
            let original = property["originalField"]?.stringValue ?? key
            guard safeFieldName(original) else { throw GenerationSpecError.unknownSetting(key) }
            guard !reservedSettingDestinations.contains(original) else {
                throw GenerationSpecError.reservedSettingDestination(original)
            }
            return (original, value)
        }
    }

    private static func enumAllows(_ value: JSONPayloadValue, property: [String: JSONPayloadValue]) -> Bool {
        guard let values = property["enum"]?.arrayValue, !values.isEmpty else { return true }
        return values.map(enumValue).contains { allowed in
            allowed == value || switchValuesAreEquivalent(allowed, value)
        }
    }

    /// LibTV switch schemas commonly declare 0/1 while clients serialize false/true.
    /// Treat only those exact pairs as equivalent; no other enum coercion is allowed.
    private static func switchValuesAreEquivalent(_ lhs: JSONPayloadValue, _ rhs: JSONPayloadValue) -> Bool {
        switch (lhs, rhs) {
        case (.number(0), .bool(false)), (.bool(false), .number(0)),
             (.number(1), .bool(true)), (.bool(true), .number(1)):
            true
        default:
            false
        }
    }

    private static func enumValue(_ value: JSONPayloadValue) -> JSONPayloadValue {
        value.objectValue?["value"] ?? value
    }

    private static func rangeAllows(_ value: JSONPayloadValue, property: [String: JSONPayloadValue]) -> Bool {
        guard let number = value.numberValue else { return true }
        if let minimum = property["min"]?.numberValue, number < minimum { return false }
        if let maximum = property["max"]?.numberValue, number > maximum { return false }
        return true
    }

    private static func isScalar(_ value: JSONPayloadValue) -> Bool {
        switch value { case .string, .number, .bool, .null: true; default: false }
    }

    private static func safeFieldName(_ value: String) -> Bool {
        !value.isEmpty && value.range(of: #"^[A-Za-z][A-Za-z0-9_]{0,63}$"#, options: .regularExpression) != nil
    }

    private static let reservedSettingDestinations: Set<String> = [
        "model", "count", "modeType", "prompt",
    ]

    private static func isSHA256(_ value: String) -> Bool {
        value.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
    }
}
