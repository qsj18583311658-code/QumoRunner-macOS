import Foundation

public enum RunnerServiceState: String, Codable, CaseIterable, Sendable {
    case unconfigured
    case connecting
    case idle
    case busy
    case paused
    case degraded
    case offline
    case authExpired
}

public enum RunnerJobState: String, Codable, CaseIterable, Sendable {
    case queued
    case leased
    case submitting
    case running
    case succeeded
    case failed
    case cancelled
    case needsReview = "needs_review"

    public var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled, .needsReview: true
        default: false
        }
    }
}

public enum JSONPayloadValue: Codable, Hashable, Sendable {
    case object([String: JSONPayloadValue])
    case array([JSONPayloadValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONPayloadValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONPayloadValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
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

    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }
    public var arrayValue: [JSONPayloadValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    public var objectValue: [String: JSONPayloadValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    public var numberValue: Double? {
        guard case .number(let value) = self else { return nil }
        return value
    }

    public var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }
}

public struct RunnerJob: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let canvasKey: String?
    public let sourceNodeID: String?
    public var resultNodeID: String?
    public let idempotencyKey: String
    public let capability: String
    public let requiredModelRef: String?
    public let baseSchemaHash: String?
    public let patchVersion: Int?
    public let effectiveSchemaHash: String?
    public let payload: [String: JSONPayloadValue]
    public var status: RunnerJobState
    public let runnerID: String?
    public var executionProfileRef: String?
    public var remoteTaskID: String?
    public var result: JSONPayloadValue?
    public var error: String?
    public var resultArtifactID: String?
    public var leaseExpiresAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public var state: RunnerJobState {
        get { status }
        set { status = newValue }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case canvasKey = "canvas_key"
        case sourceNodeID = "source_node_id"
        case resultNodeID = "result_node_id"
        case idempotencyKey = "idempotency_key"
        case capability
        case requiredModelRef = "required_model_ref"
        case baseSchemaHash = "base_schema_hash"
        case patchVersion = "patch_version"
        case effectiveSchemaHash = "effective_schema_hash"
        case payload
        case status
        case runnerID = "runner_id"
        case executionProfileRef = "execution_profile_ref"
        case remoteTaskID = "remote_task_id"
        case result
        case error
        case resultArtifactID = "result_artifact_id"
        case leaseExpiresAt = "lease_expires_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(
        id: String,
        state: RunnerJobState = .queued,
        canvasKey: String? = nil,
        sourceNodeID: String? = nil,
        idempotencyKey: String? = nil,
        capability: String = "generation",
        requiredModelRef: String? = nil,
        baseSchemaHash: String? = nil,
        patchVersion: Int? = nil,
        effectiveSchemaHash: String? = nil,
        payload: [String: JSONPayloadValue] = [:],
        runnerID: String? = nil,
        executionProfileRef: String? = nil,
        remoteTaskID: String? = nil,
        resultNodeID: String? = nil,
        result: JSONPayloadValue? = nil,
        error: String? = nil,
        resultArtifactID: String? = nil,
        leaseExpiresAt: Date? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.canvasKey = canvasKey
        self.sourceNodeID = sourceNodeID
        self.resultNodeID = resultNodeID
        self.idempotencyKey = idempotencyKey ?? id
        self.capability = capability
        self.requiredModelRef = requiredModelRef
        self.baseSchemaHash = baseSchemaHash
        self.patchVersion = patchVersion
        self.effectiveSchemaHash = effectiveSchemaHash
        self.payload = payload
        self.status = state
        self.runnerID = runnerID
        self.executionProfileRef = executionProfileRef
        self.remoteTaskID = remoteTaskID
        self.result = result
        self.error = error
        self.resultArtifactID = resultArtifactID
        self.leaseExpiresAt = leaseExpiresAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct RunnerProfile: Codable, Identifiable, Hashable, Sendable {
    public var id: String { profileRef }
    public let profileRef: String
    public var accountRef: String
    public var displayName: String
    public var capabilities: [String]
    public var healthy: Bool
    public var enabled: Bool
    public var detectedMaxConcurrency: Int?
    public var maxConcurrency: Int
    public var planName: String?
    public var quotaState: String?
    public var catalogRevision: String?

    enum CodingKeys: String, CodingKey {
        case profileRef = "profile_ref"
        case accountRef = "account_ref"
        case displayName = "display_name"
        case capabilities
        case healthy
        case enabled
        case detectedMaxConcurrency = "detected_max_concurrency"
        case maxConcurrency = "max_concurrency"
        case planName = "plan_name"
        case quotaState = "quota_state"
        case catalogRevision = "catalog_revision"
    }

    public init(
        profileRef: String,
        accountRef: String,
        displayName: String,
        capabilities: [String] = [],
        healthy: Bool = true,
        enabled: Bool = true,
        detectedMaxConcurrency: Int? = nil,
        maxConcurrency: Int = 1,
        planName: String? = nil,
        quotaState: String? = nil,
        catalogRevision: String? = nil
    ) {
        self.profileRef = profileRef
        self.accountRef = accountRef
        self.displayName = displayName
        self.capabilities = capabilities
        self.healthy = healthy
        self.enabled = enabled
        self.detectedMaxConcurrency = detectedMaxConcurrency
        self.maxConcurrency = maxConcurrency
        self.planName = planName
        self.quotaState = quotaState
        self.catalogRevision = catalogRevision
    }
}

public enum RunnerControlCommandKind: String, Codable, Sendable {
    case pause
    case resume
    case stopTracking = "stop_tracking"
    case healthCheck = "health_check"
    case refreshProfiles = "refresh_profiles"
    case refreshInventory = "refresh_inventory"
    case diagnostics
}

public struct RunnerControlCommand: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let command: RunnerControlCommandKind
    public let payload: [String: JSONPayloadValue]
    public let createdAt: Date

    public var kind: RunnerControlCommandKind { command }
    public var jobID: String? { payload["job_id"]?.stringValue }
    public var profileRef: String? { payload["profile_ref"]?.stringValue }

    enum CodingKeys: String, CodingKey {
        case id
        case command
        case payload
        case createdAt = "created_at"
    }

    public init(
        id: String,
        kind: RunnerControlCommandKind,
        jobID: String? = nil,
        profileRef: String? = nil,
        payload: [String: JSONPayloadValue] = [:],
        createdAt: Date = .now
    ) {
        self.id = id
        self.command = kind
        var merged = payload
        if let jobID { merged["job_id"] = .string(jobID) }
        if let profileRef { merged["profile_ref"] = .string(profileRef) }
        self.payload = merged
        self.createdAt = createdAt
    }
}
