import CryptoKit
import Foundation

public struct RunnerAPIConfiguration: Sendable {
    public let serverURL: URL
    public let apiPrefix: String

    public init(serverURL: URL, apiPrefix: String = "/api/canvas/v1") {
        self.serverURL = serverURL
        self.apiPrefix = apiPrefix
    }

    func url(path: String) -> URL {
        let components = (apiPrefix + "/" + path)
            .split(separator: "/")
            .map(String.init)
        return components.reduce(serverURL) { url, component in
            url.appendingPathComponent(component)
        }
    }
}

public struct CreateRunnerPairingRequest: Codable, Sendable {
    public let displayName: String?
    public init(displayName: String? = nil) { self.displayName = displayName }
    enum CodingKeys: String, CodingKey { case displayName = "display_name" }
}

public struct CreateRunnerPairingResponse: Codable, Sendable {
    public let pairingCode: String
    public let expiresAt: Date
    enum CodingKeys: String, CodingKey {
        case pairingCode = "pairing_code"
        case expiresAt = "expires_at"
    }
}

public struct ExchangeRunnerPairingRequest: Codable, Sendable {
    public let pairingCode: String
    public let displayName: String?
    public let hostname: String
    public let version: String
    public let capabilities: [String]
    enum CodingKeys: String, CodingKey {
        case pairingCode = "pairing_code"
        case displayName = "display_name"
        case hostname
        case version
        case capabilities
    }

    public init(
        pairingCode: String,
        displayName: String? = nil,
        hostname: String,
        version: String,
        capabilities: [String]
    ) {
        self.pairingCode = pairingCode
        self.displayName = displayName
        self.hostname = hostname
        self.version = version
        self.capabilities = capabilities
    }
}

public struct ExchangeRunnerPairingResponse: Codable, Sendable {
    public let runnerID: String
    public let deviceToken: String
    public let displayName: String
    public let workspaceID: String
    enum CodingKeys: String, CodingKey {
        case runnerID = "runner_id"
        case deviceToken = "device_token"
        case displayName = "display_name"
        case workspaceID = "workspace_id"
    }
}

public struct SyncProfilesRequest: Codable, Sendable {
    public let profiles: [RunnerProfile]
    public let replace: Bool
    public init(profiles: [RunnerProfile], replace: Bool = true) {
        self.profiles = profiles
        self.replace = replace
    }
}

public struct SyncProfilesResponse: Codable, Sendable {
    public let runnerID: String
    public let synced: Int
    public let profileRefs: [String]
    enum CodingKeys: String, CodingKey {
        case runnerID = "runner_id"
        case synced
        case profileRefs = "profile_refs"
    }
}

public struct ClaimJobRequest: Codable, Sendable {
    public let profileRef: String
    public let capabilities: [String]
    public init(profileRef: String, capabilities: [String]) {
        self.profileRef = profileRef
        self.capabilities = capabilities
    }
    enum CodingKeys: String, CodingKey {
        case profileRef = "profile_ref"
        case capabilities
    }
}

public struct CancelLeasedJobRequest: Codable, Sendable {
    public let profileRef: String
    public init(profileRef: String) { self.profileRef = profileRef }
    enum CodingKeys: String, CodingKey { case profileRef = "profile_ref" }
}

public struct ClaimedJob: Codable, Sendable {
    public let job: RunnerJob?
    public let reason: String?

    public init(job: RunnerJob?, reason: String? = nil) {
        self.job = job
        self.reason = reason
    }
}

public struct UnifiedResponse<Value: Decodable & Sendable>: Decodable, Sendable {
    public let code: Int
    public let message: String
    public let data: Value
    public let requestID: String
    enum CodingKeys: String, CodingKey {
        case code
        case message
        case data
        case requestID = "request_id"
    }
}

public struct RunnerHeartbeatRequest: Codable, Sendable {
    public let state: RunnerServiceState
    public let hostname: String
    public let version: String
    public let capabilities: [String]
    public let activeJobIDs: [String]
    public let activeJobs: [RunnerActiveJobHeartbeat]
    public let globalMaxConcurrency: Int?
    public let runtimeVersion: String?
    public let runtimeSHA256: String?
    public let runtimePlatform: String?
    public let runtimeVerified: Bool?
    public let runnerProtocolVersion: String?
    public let runtime: RunnerRuntimeBundleHeartbeat?
    public let runtimeValidations: [RunnerRuntimeValidationReport]
    enum CodingKeys: String, CodingKey {
        case state
        case hostname
        case version
        case capabilities
        case activeJobIDs = "active_job_ids"
        case activeJobs = "active_jobs"
        case globalMaxConcurrency = "global_max_concurrency"
        case runtimeVersion = "runtime_version"
        case runtimeSHA256 = "runtime_sha256"
        case runtimePlatform = "runtime_platform"
        case runtimeVerified = "runtime_verified"
        case runnerProtocolVersion = "runner_protocol_version"
        case runtime
        case runtimeValidations = "runtime_validations"
    }

    public init(
        state: RunnerServiceState,
        hostname: String,
        version: String,
        capabilities: [String],
        activeJobIDs: [String],
        activeJobs: [RunnerActiveJobHeartbeat] = [],
        globalMaxConcurrency: Int? = nil,
        runtimeVersion: String? = nil,
        runtimeSHA256: String? = nil,
        runtimePlatform: String? = nil,
        runtimeVerified: Bool? = nil,
        runnerProtocolVersion: String? = nil,
        runtime: RunnerRuntimeBundleHeartbeat? = nil,
        runtimeValidations: [RunnerRuntimeValidationReport] = []
    ) {
        self.state = state
        self.hostname = hostname
        self.version = version
        self.capabilities = capabilities
        self.activeJobIDs = activeJobIDs
        self.activeJobs = activeJobs
        self.globalMaxConcurrency = globalMaxConcurrency
        self.runtimeVersion = runtimeVersion
        self.runtimeSHA256 = runtimeSHA256
        self.runtimePlatform = runtimePlatform
        self.runtimeVerified = runtimeVerified
        self.runnerProtocolVersion = runnerProtocolVersion
        self.runtime = runtime
        self.runtimeValidations = runtimeValidations
    }
}

public struct RunnerRuntimeValidationReport: Codable, Hashable, Sendable {
    public let validationID: String
    public let status: String
    public let version: String
    public let archiveSHA256: String
    public let sha256: String
    public let platform: String
    public let cdHash: String
    public let teamID: String
    public let runnerProtocolVersion: String
    public let testReport: [String: JSONPayloadValue]
    public let schemaDiff: [String: JSONPayloadValue]
    public let detail: String?
    enum CodingKeys: String, CodingKey {
        case validationID = "validation_id"
        case status, version, sha256, platform, detail
        case archiveSHA256 = "archive_sha256"
        case cdHash = "cdhash"
        case teamID = "team_id"
        case runnerProtocolVersion = "runner_protocol_version"
        case testReport = "test_report"
        case schemaDiff = "schema_diff"
    }
    public init(validationID: String, status: String, record: LibTVRuntimeRecord, testReport: [String: JSONPayloadValue] = [:], schemaDiff: [String: JSONPayloadValue] = [:], detail: String? = nil) throws {
        guard let archiveSHA256 = record.archiveSHA256,
              let cdHash = record.cdHash,
              let teamID = record.teamIdentifier else {
            throw LibTVRuntimeRegistryError.invalidRegistry("Runtime validation evidence is incomplete")
        }
        self.validationID = validationID
        self.status = status
        version = record.identity.version
        self.archiveSHA256 = archiveSHA256
        sha256 = record.identity.sha256
        platform = "macos-arm64"
        self.cdHash = cdHash
        self.teamID = teamID
        runnerProtocolVersion = "1"
        self.testReport = testReport
        self.schemaDiff = schemaDiff
        self.detail = detail
    }
}

public struct RunnerRuntimeIdentityHeartbeat: Codable, Hashable, Sendable {
    public let version: String
    public let sha256: String
    public let platform: String
    public let verified: Bool
    public let teamID: String?
    public let cdHash: String?
    public let `protocol`: String
    enum CodingKeys: String, CodingKey {
        case version, sha256, platform, verified, cdHash = "cdhash", `protocol`
        case teamID = "team_id"
    }
    public init(record: LibTVRuntimeRecord, protocolVersion: String) {
        version = record.identity.version
        sha256 = record.identity.sha256
        platform = "macos-arm64"
        verified = record.strictSignatureValid
            && record.teamIdentifier == LibTVRuntimeInstaller.officialTeamIdentifier
        teamID = record.teamIdentifier
        cdHash = record.cdHash
        `protocol` = protocolVersion
    }
}

public struct RunnerRuntimeBundleHeartbeat: Codable, Hashable, Sendable {
    public let active: RunnerRuntimeIdentityHeartbeat
    public let previous: RunnerRuntimeIdentityHeartbeat?
    public let candidate: RunnerRuntimeIdentityHeartbeat?
    public let bundledFallback: RunnerRuntimeIdentityHeartbeat?
    enum CodingKeys: String, CodingKey {
        case active, previous, candidate
        case bundledFallback = "bundled_fallback"
    }
    public init(metadata: RunnerRuntimeHeartbeat) {
        let fallbackActive = LibTVRuntimeRecord(
            identity: metadata.active,
            executableURL: URL(fileURLWithPath: "/unavailable"),
            source: .downloaded,
            teamIdentifier: metadata.activeTeamIdentifier,
            cdHash: metadata.activeCDHash,
            strictSignatureValid: metadata.activeStrictSignatureValid
        )
        active = .init(record: metadata.activeRecord ?? fallbackActive, protocolVersion: metadata.protocolVersion)
        previous = metadata.previousRecord.map { .init(record: $0, protocolVersion: metadata.protocolVersion) }
        candidate = metadata.candidateRecord.map { .init(record: $0, protocolVersion: metadata.protocolVersion) }
        bundledFallback = metadata.bundledFallbackRecord.map { .init(record: $0, protocolVersion: metadata.protocolVersion) }
    }
}

public struct RunnerActiveJobHeartbeat: Codable, Hashable, Sendable {
    public let jobID: String
    public let profileRef: String
    public let remoteTaskID: String?

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case profileRef = "profile_ref"
        case remoteTaskID = "remote_task_id"
    }

    public init(
        jobID: String,
        profileRef: String,
        remoteTaskID: String? = nil
    ) {
        self.jobID = jobID
        self.profileRef = profileRef
        self.remoteTaskID = remoteTaskID
    }
}

public struct RunnerHeartbeatResponse: Codable, Sendable {
    public let ok: Bool
    public let serverTime: Date
    public let leaseSeconds: Int
    public let commands: [RunnerControlCommand]
    public let renewedJobIDs: [String]?
    public let runtimeValidations: [RunnerRuntimeValidationAcknowledgement]?
    /// Server-suggested global concurrency. Runner should sync to this value if different.
    public let globalMaxConcurrency: Int?
    enum CodingKeys: String, CodingKey {
        case ok
        case serverTime = "server_time"
        case leaseSeconds = "lease_seconds"
        case commands
        case renewedJobIDs = "renewed_job_ids"
        case runtimeValidations = "runtime_validations"
        case globalMaxConcurrency = "global_max_concurrency"
    }

    public init(
        ok: Bool,
        serverTime: Date,
        leaseSeconds: Int,
        commands: [RunnerControlCommand],
        renewedJobIDs: [String]? = nil,
        runtimeValidations: [RunnerRuntimeValidationAcknowledgement]? = nil,
        globalMaxConcurrency: Int? = nil
    ) {
        self.ok = ok
        self.serverTime = serverTime
        self.leaseSeconds = leaseSeconds
        self.commands = commands
        self.renewedJobIDs = renewedJobIDs
        self.runtimeValidations = runtimeValidations
        self.globalMaxConcurrency = globalMaxConcurrency
    }
}

public struct RunnerRuntimeValidationAcknowledgement: Codable, Hashable, Sendable {
    public let id: String
    public let status: String
    public let detail: String?
}

public struct ProfileInventoryRequest: Codable, Hashable, Sendable {
    public let inventoryRevision: String
    public let catalogRevision: String?
    public let quota: ProfileQuotaSnapshot?
    public let plan: ProfilePlanSnapshot?
    public let models: [ProfileModelInventory]?

    enum CodingKeys: String, CodingKey {
        case inventoryRevision = "inventory_revision"
        case catalogRevision = "catalog_revision"
        case quota, plan, models
    }

    public init(
        inventoryRevision: String,
        catalogRevision: String? = nil,
        quota: ProfileQuotaSnapshot? = nil,
        plan: ProfilePlanSnapshot? = nil,
        models: [ProfileModelInventory]? = nil
    ) {
        self.inventoryRevision = inventoryRevision
        self.catalogRevision = catalogRevision
        self.quota = quota
        self.plan = plan
        self.models = models
    }

    public static func contentRevision(
        catalogRevision: String?,
        quota: ProfileQuotaSnapshot?,
        plan: ProfilePlanSnapshot?,
        models: [ProfileModelInventory]?
    ) -> String {
        let seed = Self(
            inventoryRevision: "",
            catalogRevision: catalogRevision,
            quota: quota,
            plan: plan,
            models: models
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(seed)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct ProfileQuotaSnapshot: Codable, Hashable, Sendable {
    public let state: String
    public let observedAt: Date
    public let staleAt: Date?
    public let totalBalance: String?
    public let membershipPoints: String?
    public let rechargePoints: String?
    public let modelCardPoints: String?
    public let freePoints: String?

    enum CodingKeys: String, CodingKey {
        case state
        case observedAt = "observed_at"
        case staleAt = "stale_at"
        case totalBalance = "total_balance"
        case membershipPoints = "membership_points"
        case rechargePoints = "recharge_points"
        case modelCardPoints = "model_card_points"
        case freePoints = "free_points"
    }

    public init(
        state: String,
        observedAt: Date,
        staleAt: Date? = nil,
        totalBalance: String? = nil,
        membershipPoints: String? = nil,
        rechargePoints: String? = nil,
        modelCardPoints: String? = nil,
        freePoints: String? = nil
    ) {
        self.state = state
        self.observedAt = observedAt
        self.staleAt = staleAt
        self.totalBalance = totalBalance
        self.membershipPoints = membershipPoints
        self.rechargePoints = rechargePoints
        self.modelCardPoints = modelCardPoints
        self.freePoints = freePoints
    }
}

public struct ProfilePlanSnapshot: Codable, Hashable, Sendable {
    public let observedAt: Date
    public let planName: String?
    public let detectedMaxConcurrency: Int?
    public let maxConcurrency: Int

    enum CodingKeys: String, CodingKey {
        case observedAt = "observed_at"
        case planName = "plan_name"
        case detectedMaxConcurrency = "detected_max_concurrency"
        case maxConcurrency = "max_concurrency"
    }

    public init(observedAt: Date, planName: String? = nil, detectedMaxConcurrency: Int? = nil, maxConcurrency: Int) {
        self.observedAt = observedAt
        self.planName = planName
        self.detectedMaxConcurrency = detectedMaxConcurrency
        self.maxConcurrency = maxConcurrency
    }
}

public struct ProfileModelInventory: Codable, Hashable, Sendable {
    public let modelRef: String
    public let displayName: String
    public let modality: String
    public let summaryHash: String
    public let schemaHash: String
    public let capabilities: [String]

    enum CodingKeys: String, CodingKey {
        case modelRef = "model_ref"
        case displayName = "display_name"
        case modality
        case summaryHash = "summary_hash"
        case schemaHash = "schema_hash"
        case capabilities
    }

    public init(modelRef: String, displayName: String, modality: String, summaryHash: String, schemaHash: String, capabilities: [String]) {
        self.modelRef = modelRef
        self.displayName = displayName
        self.modality = modality
        self.summaryHash = summaryHash
        self.schemaHash = schemaHash
        self.capabilities = capabilities
    }
}

public struct ProfileInventoryResponse: Codable, Sendable {
    public let runnerID: String
    public let profileRef: String
    public let inventoryRevision: String
    public let idempotent: Bool
    public let detectedMaxConcurrency: Int?
    public let maxConcurrency: Int
    public let planName: String?
    public let quotaState: String?
    public let catalogRevision: String?
    public let requiredSchemaUploads: [RequiredSchemaUpload]?

    enum CodingKeys: String, CodingKey {
        case runnerID = "runner_id"
        case profileRef = "profile_ref"
        case inventoryRevision = "inventory_revision"
        case idempotent
        case detectedMaxConcurrency = "detected_max_concurrency"
        case maxConcurrency = "max_concurrency"
        case planName = "plan_name"
        case quotaState = "quota_state"
        case catalogRevision = "catalog_revision"
        case requiredSchemaUploads = "required_schema_uploads"
    }
}

public struct RequiredSchemaUpload: Codable, Hashable, Sendable {
    public let modelRef: String
    public let schemaHash: String

    enum CodingKeys: String, CodingKey {
        case modelRef = "model_ref"
        case schemaHash = "schema_hash"
    }

    public init(modelRef: String, schemaHash: String) {
        self.modelRef = modelRef
        self.schemaHash = schemaHash
    }
}

public struct ProfileModelSchemaUploadRequest: Codable, Hashable, Sendable {
    public let modelRef: String
    public let schemaHash: String
    public let schema: JSONPayloadValue

    enum CodingKeys: String, CodingKey {
        case modelRef = "model_ref"
        case schemaHash = "schema_hash"
        case schema
    }

    public init(modelRef: String, schemaHash: String, schema: JSONPayloadValue) {
        self.modelRef = modelRef
        self.schemaHash = schemaHash
        self.schema = schema
    }
}

public struct ProfileModelSchemaUploadResponse: Codable, Hashable, Sendable {
    public let modelRef: String
    public let schemaHash: String
    public let idempotent: Bool

    enum CodingKeys: String, CodingKey {
        case modelRef = "model_ref"
        case schemaHash = "schema_hash"
        case idempotent
    }
}

public struct ProfileModelApprovalRequest: Codable, Hashable, Sendable {
    public let approved: Bool
    public let schemaHash: String

    enum CodingKeys: String, CodingKey {
        case approved
        case schemaHash = "schema_hash"
    }

    public init(approved: Bool, schemaHash: String) {
        self.approved = approved
        self.schemaHash = schemaHash
    }
}

public struct ProfileModelApprovalResponse: Codable, Hashable, Sendable {
    public let modelRef: String
    public let schemaHash: String
    public let approvalState: String

    enum CodingKeys: String, CodingKey {
        case modelRef = "model_ref"
        case schemaHash = "schema_hash"
        case approvalState = "approval_state"
    }
}

public struct CommandAcknowledgement: Codable, Sendable {
    public let status: String
    public let detail: String?
    public let runtimeVersion: String?
    public let runtimeSHA256: String?
    public let runtimePlatform: String?
    public let runtimeVerified: Bool?
    public let runnerProtocolVersion: String?
    enum CodingKeys: String, CodingKey {
        case status, detail
        case runtimeVersion = "runtime_version"
        case runtimeSHA256 = "runtime_sha256"
        case runtimePlatform = "runtime_platform"
        case runtimeVerified = "runtime_verified"
        case runnerProtocolVersion = "runner_protocol_version"
    }
    public init(
        status: String = "completed",
        detail: String? = nil,
        runtimeVersion: String? = nil,
        runtimeSHA256: String? = nil,
        runtimePlatform: String? = nil,
        runtimeVerified: Bool? = nil,
        runnerProtocolVersion: String? = nil
    ) {
        self.status = status
        self.detail = detail
        self.runtimeVersion = runtimeVersion
        self.runtimeSHA256 = runtimeSHA256
        self.runtimePlatform = runtimePlatform
        self.runtimeVerified = runtimeVerified
        self.runnerProtocolVersion = runnerProtocolVersion
    }
}

public struct JobEventRequest: Codable, Sendable {
    public let profileRef: String
    public let status: RunnerJobState
    public let remoteTaskID: String?
    public let result: JSONPayloadValue?
    public let error: String?
    enum CodingKeys: String, CodingKey {
        case profileRef = "profile_ref"
        case status
        case remoteTaskID = "remote_task_id"
        case result
        case error
    }

    public init(
        profileRef: String,
        status: RunnerJobState,
        remoteTaskID: String? = nil,
        result: JSONPayloadValue? = nil,
        error: String? = nil
    ) {
        self.profileRef = profileRef
        self.status = status
        self.remoteTaskID = remoteTaskID
        self.result = result
        self.error = error
    }
}

public struct ArtifactInitRequest: Codable, Sendable {
    public let fileName: String
    public let mimeType: String
    public let fileSize: Int64
    public let sha256: String
    enum CodingKeys: String, CodingKey {
        case fileName = "file_name"
        case mimeType = "mime_type"
        case fileSize = "file_size"
        case sha256
    }

    public init(fileName: String, mimeType: String, fileSize: Int64, sha256: String) {
        self.fileName = fileName
        self.mimeType = mimeType
        self.fileSize = fileSize
        self.sha256 = sha256
    }
}

public struct ArtifactInitResponse: Codable, Sendable {
    public let artifactID: String
    public let uploadURL: URL
    public let method: String
    public let headers: [String: String]
    public let expiresInSeconds: Int
    enum CodingKeys: String, CodingKey {
        case artifactID = "artifact_id"
        case uploadURL = "upload_url"
        case method
        case headers
        case expiresInSeconds = "expires_in_seconds"
    }
}

public struct ArtifactCompleteRequest: Codable, Sendable {
    public let fileSize: Int64
    public let sha256: String
    enum CodingKeys: String, CodingKey {
        case fileSize = "file_size"
        case sha256
    }
    public init(fileSize: Int64, sha256: String) {
        self.fileSize = fileSize
        self.sha256 = sha256
    }
}

public struct ArtifactCompleteResponse: Codable, Sendable {
    public let artifactID: String
    public let completed: Bool
    public let contentURL: URL
    enum CodingKeys: String, CodingKey {
        case artifactID = "artifact_id"
        case completed
        case contentURL = "content_url"
    }
}

public struct GenerationInputDownloadRequest: Codable, Hashable, Sendable {
    public let artifactKey: String
    public let sha256: String
    enum CodingKeys: String, CodingKey {
        case artifactKey = "artifact_key"
        case sha256
    }
    public init(artifactKey: String, sha256: String) {
        self.artifactKey = artifactKey
        self.sha256 = sha256
    }
}

public struct GenerationInputDownloadResponse: Codable, Sendable {
    public let downloadURL: URL
    public let headers: [String: String]
    public let expiresInSeconds: Int
    enum CodingKeys: String, CodingKey {
        case downloadURL = "download_url"
        case headers
        case expiresInSeconds = "expires_in_seconds"
    }
}

public enum RunnerAPIError: Error, LocalizedError, Sendable {
    case invalidResponse
    case missingDeviceConfiguration
    case http(status: Int, body: String)
    case service(code: Int, message: String, requestID: String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "Runner API returned an invalid response."
        case .missingDeviceConfiguration: "Runner ID and device token must both be configured."
        case .http(let status, let body): "Runner API returned HTTP \(status): \(body)"
        case .service(let code, let message, let requestID):
            "Runner API error \(code) (request \(requestID)): \(message)"
        }
    }
}

public protocol RunnerAPITransport: Sendable {
    func syncProfiles(_ profiles: [RunnerProfile]) async throws -> SyncProfilesResponse
    func claim(profileRef: String, capabilities: [String]) async throws -> ClaimedJob
    func heartbeat(_ request: RunnerHeartbeatRequest) async throws -> RunnerHeartbeatResponse
    func acknowledge(commandID: String, acknowledgement: CommandAcknowledgement) async throws
    func postJobEvent(jobID: String, event: JobEventRequest) async throws
    func cancelLeasedJob(jobID: String, profileRef: String) async throws -> RunnerJob
}

public protocol ArtifactAPITransport: Sendable {
    func initializeArtifact(jobID: String, request: ArtifactInitRequest) async throws -> ArtifactInitResponse
    func uploadArtifact(
        fileURL: URL,
        to signedURL: URL,
        method: String,
        contentType: String,
        headers: [String: String]
    ) async throws
    func completeArtifact(
        jobID: String,
        artifactID: String,
        request: ArtifactCompleteRequest
    ) async throws -> ArtifactCompleteResponse
}

public protocol ProfileInventoryAPITransport: Sendable {
    func syncProfileInventory(profileRef: String, request: ProfileInventoryRequest) async throws -> ProfileInventoryResponse
    func uploadProfileModelSchema(
        profileRef: String,
        request: ProfileModelSchemaUploadRequest
    ) async throws -> ProfileModelSchemaUploadResponse
}

public protocol ProfileModelApprovalAPITransport: Sendable {
    func setProfileModelApproval(
        profileRef: String,
        modelRef: String,
        request: ProfileModelApprovalRequest
    ) async throws -> ProfileModelApprovalResponse
}

public actor RunnerAPIClient: RunnerAPITransport, ArtifactAPITransport, ProfileInventoryAPITransport, ProfileModelApprovalAPITransport, GenerationInputMaterializing {
    private let configuration: RunnerAPIConfiguration
    private let session: URLSession
    private var runnerID: String?
    private var deviceToken: String?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        configuration: RunnerAPIConfiguration,
        runnerID: String? = nil,
        deviceToken: String? = nil,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.runnerID = runnerID
        self.deviceToken = deviceToken
        self.session = session
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) { return date }
            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
            if let date = standard.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Invalid ISO-8601 date: \(value)"
            )
        }
    }

    public func configureDevice(runnerID: String, deviceToken: String) {
        self.runnerID = runnerID
        self.deviceToken = deviceToken
    }

    public func createPairing(
        request: CreateRunnerPairingRequest,
        adminBearerToken: String
    ) async throws -> CreateRunnerPairingResponse {
        try await send(
            path: "runner-pairings",
            body: request,
            authorization: "Bearer \(adminBearerToken)",
            includeDeviceToken: false
        )
    }

    public func exchangePairing(
        _ request: ExchangeRunnerPairingRequest
    ) async throws -> ExchangeRunnerPairingResponse {
        try await send(
            path: "runner-pairings/exchange",
            body: request,
            includeDeviceToken: false
        )
    }

    public func revokeRunner(adminBearerToken: String) async throws {
        let runnerID = try requiredRunnerID()
        let _: EmptyResponse? = try await send(
            path: "runners/\(runnerID)/revoke",
            body: EmptyRequest(),
            authorization: "Bearer \(adminBearerToken)",
            includeDeviceToken: false
        )
    }

    public func syncProfiles(_ profiles: [RunnerProfile]) async throws -> SyncProfilesResponse {
        try await deviceSend(path: "profiles/sync", body: SyncProfilesRequest(profiles: profiles))
    }

    public func claim(profileRef: String, capabilities: [String]) async throws -> ClaimedJob {
        try await deviceSend(
            path: "claim",
            body: ClaimJobRequest(profileRef: profileRef, capabilities: capabilities)
        )
    }

    public func syncProfileInventory(profileRef: String, request: ProfileInventoryRequest) async throws -> ProfileInventoryResponse {
        try await deviceSend(path: "profiles/\(profileRef)/inventory", body: request)
    }

    public func uploadProfileModelSchema(
        profileRef: String,
        request: ProfileModelSchemaUploadRequest
    ) async throws -> ProfileModelSchemaUploadResponse {
        try await deviceSend(path: "profiles/\(profileRef)/model-schemas", body: request)
    }

    public func setProfileModelApproval(
        profileRef: String,
        modelRef: String,
        request: ProfileModelApprovalRequest
    ) async throws -> ProfileModelApprovalResponse {
        try await deviceSend(
            // The model key may contain '/'. The backend uses a trailing `{model_ref:path}`
            // converter, so `approval` must precede the model key in the URL.
            path: "profiles/\(profileRef)/models/approval/\(modelRef)",
            body: request
        )
    }

    public func heartbeat(_ request: RunnerHeartbeatRequest) async throws -> RunnerHeartbeatResponse {
        try await deviceSend(path: "heartbeat", body: request)
    }

    public func acknowledge(
        commandID: String,
        acknowledgement: CommandAcknowledgement = .init()
    ) async throws {
        let _: EmptyResponse? = try await deviceSend(
            path: "commands/\(commandID)/ack",
            body: acknowledgement
        )
    }

    public func postJobEvent(jobID: String, event: JobEventRequest) async throws {
        let _: EmptyResponse? = try await deviceSend(
            path: "jobs/\(jobID)/events",
            body: event
        )
    }

    public func cancelLeasedJob(jobID: String, profileRef: String) async throws -> RunnerJob {
        try await deviceSend(
            path: "jobs/\(jobID)/cancel",
            body: CancelLeasedJobRequest(profileRef: profileRef)
        )
    }

    public func initializeArtifact(
        jobID: String,
        request: ArtifactInitRequest
    ) async throws -> ArtifactInitResponse {
        try await deviceSend(path: "jobs/\(jobID)/artifacts/init", body: request)
    }

    public func completeArtifact(
        jobID: String,
        artifactID: String,
        request: ArtifactCompleteRequest
    ) async throws -> ArtifactCompleteResponse {
        try await deviceSend(
            path: "jobs/\(jobID)/artifacts/\(artifactID)/complete",
            body: request
        )
    }

    public func uploadArtifact(
        data: Data,
        to signedURL: URL,
        contentType: String,
        headers: [String: String] = [:]
    ) async throws {
        var request = URLRequest(url: signedURL)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (_, response) = try await session.upload(for: request, from: data)
        try Self.validate(response: response, data: Data())
    }

    public func materialize(
        jobID: String,
        input: LibTVGenerationInputV1,
        destinationURL: URL
    ) async throws {
        let signed: GenerationInputDownloadResponse = try await deviceSend(
            path: "jobs/\(jobID)/inputs/download",
            body: GenerationInputDownloadRequest(artifactKey: input.artifactKey, sha256: input.sha256)
        )
        guard signed.expiresInSeconds > 0, Self.isAllowedInputDownloadURL(signed.downloadURL) else {
            throw RunnerAPIError.invalidResponse
        }
        var request = URLRequest(url: signed.downloadURL)
        request.httpMethod = "GET"
        for (key, value) in signed.headers { request.setValue(value, forHTTPHeaderField: key) }
        let (temporaryURL, response) = try await session.download(for: request)
        try Self.validate(response: response, data: Data())
        let parent = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
    }

    /// Production object storage must use HTTPS. Plain HTTP is accepted only for the three exact
    /// loopback host spellings used by local MinIO development; lookalike and private-network
    /// hosts remain rejected.
    nonisolated static func isAllowedInputDownloadURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else {
            return false
        }
        if scheme == "https" { return true }
        guard scheme == "http" else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    public func uploadArtifact(
        fileURL: URL,
        to signedURL: URL,
        method: String = "PUT",
        contentType: String,
        headers: [String: String] = [:]
    ) async throws {
        var request = URLRequest(url: signedURL)
        request.httpMethod = method
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (_, response) = try await session.upload(for: request, fromFile: fileURL)
        try Self.validate(response: response, data: Data())
    }

    private func deviceSend<Request: Encodable & Sendable, Response: Decodable & Sendable>(
        path: String,
        body: Request
    ) async throws -> Response {
        let runnerID = try requiredRunnerID()
        return try await send(
            path: "runners/\(runnerID)/\(path)",
            body: body,
            includeDeviceToken: true
        )
    }

    private func send<Request: Encodable & Sendable, Response: Decodable & Sendable>(
        path: String,
        body: Request,
        authorization: String? = nil,
        includeDeviceToken: Bool
    ) async throws -> Response {
        var request = URLRequest(url: configuration.url(path: path))
        request.httpMethod = "POST"
        request.httpBody = try encoder.encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        if includeDeviceToken {
            guard let deviceToken, !deviceToken.isEmpty else {
                throw RunnerAPIError.missingDeviceConfiguration
            }
            request.setValue(deviceToken, forHTTPHeaderField: "X-Runner-Token")
        }
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)
        let status = try decoder.decode(UnifiedStatusResponse.self, from: data)
        guard status.code == 0 else {
            throw RunnerAPIError.service(
                code: status.code,
                message: status.message,
                requestID: status.requestID
            )
        }
        let envelope = try decoder.decode(UnifiedResponse<Response>.self, from: data)
        return envelope.data
    }

    private func requiredRunnerID() throws -> String {
        guard let runnerID, !runnerID.isEmpty else { throw RunnerAPIError.invalidResponse }
        return runnerID
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let response = response as? HTTPURLResponse else { throw RunnerAPIError.invalidResponse }
        guard (200...299).contains(response.statusCode) else {
            throw RunnerAPIError.http(
                status: response.statusCode,
                body: String(decoding: data, as: UTF8.self)
            )
        }
    }
}

private struct EmptyRequest: Encodable, Sendable { }
private struct EmptyResponse: Decodable, Sendable { }
private struct UnifiedStatusResponse: Decodable, Sendable {
    let code: Int
    let message: String
    let requestID: String
    enum CodingKeys: String, CodingKey {
        case code
        case message
        case requestID = "request_id"
    }
}
