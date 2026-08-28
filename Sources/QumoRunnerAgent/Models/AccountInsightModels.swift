import Foundation
import RunnerCore

enum AccountQuotaState: String, Codable, Sendable {
    case unknown
    case refreshing
    case available
    case zero
    case stale
    case webAuthRequired = "web_auth_required"
    case identityMismatch = "identity_mismatch"

    func inventoryValue(snapshot: AgentQuotaSnapshot?) -> String {
        switch self {
        case .zero: return "exhausted"
        case .available: return "available"
        case .webAuthRequired: return "webAuthRequired"
        case .stale:
            guard let snapshot else { return "unknown" }
            return snapshot.total == 0 ? "exhausted" : "available"
        case .refreshing, .identityMismatch, .unknown: return "unknown"
        }
    }
}

enum ModelApprovalState: String, Codable, Sendable {
    case approved
    case pending
    case changed
    case removed
}

struct ParsedQuota: Codable, Equatable, Sendable {
    let total: Double
    let membership: Double
    let recharge: Double
    let modelCard: Double
    let free: Double
    let accountRef: String?
}

struct ParsedPlan: Codable, Equatable, Sendable {
    let name: String?
    let maxConcurrency: Int?
    let unlimited: Bool
    let evidence: String
}

struct StoredQuota: Codable, Sendable {
    var state: AccountQuotaState
    var snapshot: AgentQuotaSnapshot?
    var error: String?
    var observedAt: Date

    init(state: AccountQuotaState, snapshot: AgentQuotaSnapshot?, error: String?, observedAt: Date) {
        self.state = state
        self.snapshot = snapshot
        self.error = error
        self.observedAt = observedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try container.decode(AccountQuotaState.self, forKey: .state)
        snapshot = try container.decodeIfPresent(AgentQuotaSnapshot.self, forKey: .snapshot)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        observedAt = try container.decodeIfPresent(Date.self, forKey: .observedAt) ?? snapshot?.fetchedAt ?? .now
    }
}

struct StoredCatalogItem: Codable, Hashable, Sendable {
    var modelRef: String
    var displayName: String
    var modalities: [String]
    var summaryHash: String
    var schemaHash: String
    var rawSchema: JSONPayloadValue?
    var approvalState: ModelApprovalState
    var approved: Bool
    var missingRefreshCount: Int

    init(
        modelRef: String,
        displayName: String,
        modalities: [String],
        summaryHash: String,
        schemaHash: String,
        rawSchema: JSONPayloadValue? = nil,
        approvalState: ModelApprovalState,
        approved: Bool,
        missingRefreshCount: Int
    ) {
        self.modelRef = modelRef
        self.displayName = displayName
        self.modalities = modalities
        self.summaryHash = summaryHash
        self.schemaHash = schemaHash
        self.rawSchema = rawSchema
        self.approvalState = approvalState
        self.approved = approved
        self.missingRefreshCount = missingRefreshCount
    }

    var agentValue: AgentModelCatalogItem {
        AgentModelCatalogItem(
            modelRef: modelRef,
            displayName: displayName,
            modalities: modalities,
            summaryHash: summaryHash,
            schemaHash: schemaHash,
            approvalState: approvalState.rawValue,
            approved: approved,
            missingRefreshCount: missingRefreshCount
        )
    }
}

struct StoredProfileInsight: Codable, Sendable {
    var webDataStoreID: UUID
    var quota: StoredQuota
    var plan: AgentPlanSnapshot?
    var planError: String?
    var autoConcurrencyActivated: Bool
    var catalog: [StoredCatalogItem]
    var catalogRevision: String?
    var catalogRefreshedAt: Date?
    var catalogError: String?

    static func empty() -> Self {
        Self(
            webDataStoreID: UUID(),
            quota: StoredQuota(state: .unknown, snapshot: nil, error: nil, observedAt: .now),
            plan: nil,
            planError: nil,
            autoConcurrencyActivated: false,
            catalog: [],
            catalogRevision: nil,
            catalogRefreshedAt: nil,
            catalogError: nil
        )
    }

    enum CodingKeys: String, CodingKey {
        case webDataStoreID, quota, plan, planError, autoConcurrencyActivated, catalog, catalogRevision, catalogRefreshedAt, catalogError
    }

    init(
        webDataStoreID: UUID,
        quota: StoredQuota,
        plan: AgentPlanSnapshot?,
        planError: String? = nil,
        autoConcurrencyActivated: Bool,
        catalog: [StoredCatalogItem],
        catalogRevision: String?,
        catalogRefreshedAt: Date?,
        catalogError: String?
    ) {
        self.webDataStoreID = webDataStoreID
        self.quota = quota
        self.plan = plan
        self.planError = planError
        self.autoConcurrencyActivated = autoConcurrencyActivated
        self.catalog = catalog
        self.catalogRevision = catalogRevision
        self.catalogRefreshedAt = catalogRefreshedAt
        self.catalogError = catalogError
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        webDataStoreID = try container.decode(UUID.self, forKey: .webDataStoreID)
        quota = try container.decode(StoredQuota.self, forKey: .quota)
        plan = try container.decodeIfPresent(AgentPlanSnapshot.self, forKey: .plan)
        planError = try container.decodeIfPresent(String.self, forKey: .planError)
        autoConcurrencyActivated = try container.decodeIfPresent(Bool.self, forKey: .autoConcurrencyActivated) ?? false
        catalog = try container.decodeIfPresent([StoredCatalogItem].self, forKey: .catalog) ?? []
        catalogRevision = try container.decodeIfPresent(String.self, forKey: .catalogRevision)
        catalogRefreshedAt = try container.decodeIfPresent(Date.self, forKey: .catalogRefreshedAt)
        catalogError = try container.decodeIfPresent(String.self, forKey: .catalogError)
    }
}

enum AccountConcurrencyPolicy {
    static func effective(
        autoActivated: Bool,
        quotaState: AccountQuotaState,
        detected: Int?,
        unlimited: Bool,
        globalLimit: Int
    ) -> Int {
        if quotaState == .zero { return 0 }
        if !autoActivated { return min(globalLimit, 1) }
        if unlimited { return globalLimit }
        return min(globalLimit, max(0, detected ?? 2))
    }
}

struct StoredAccountInsights: Codable, Sendable {
    var version = 1
    var profiles: [String: StoredProfileInsight] = [:]
}

struct WebPagePayload: Codable, Sendable {
    let url: String
    let title: String
    let bodyText: String
    let embeddedJSON: String?
}

enum WebInsightFailure: Error, LocalizedError, Sendable {
    case webAuthRequired
    case identityMismatch
    case parse(String)
    case transient(String)
    case permanent(String)

    var errorDescription: String? {
        switch self {
        case .webAuthRequired: "LibTV 官方授权已过期，请使用 Chrome 重新授权。"
        case .identityMismatch: "授权身份与当前 LibTV Profile 不一致。"
        case .parse(let message), .transient(let message), .permanent(let message): message
        }
    }

    var preservesRecentQuota: Bool {
        if case .transient = self { return true }
        return false
    }
}

struct CatalogCandidate: Hashable, Sendable {
    let modelRef: String
    let displayName: String
    let modalities: [String]
    let summaryHash: String
    let schemaHash: String
    let rawSchema: JSONPayloadValue?

    init(
        modelRef: String,
        displayName: String,
        modalities: [String],
        summaryHash: String,
        schemaHash: String,
        rawSchema: JSONPayloadValue? = nil
    ) {
        self.modelRef = modelRef
        self.displayName = displayName
        self.modalities = modalities
        self.summaryHash = summaryHash
        self.schemaHash = schemaHash
        self.rawSchema = rawSchema
    }
}

struct AccountInsightView: Sendable {
    let refreshing: Bool
    let autoConcurrencyActivated: Bool
    let quotaState: AccountQuotaState
    let quota: AgentQuotaSnapshot?
    let plan: AgentPlanSnapshot?
    let lastAttemptAt: Date?
    let refreshError: String?
    let detectedMaxConcurrency: Int?
    let effectiveMaxConcurrency: Int
    let catalogRevision: String?
    let catalogRefreshedAt: Date?
    let catalogError: String?
    let catalogRefreshing: Bool
    let models: [AgentModelCatalogItem]
}

enum AccountInsightRefreshReason: String, Sendable {
    case startup, scheduled, login, manual, taskFinished
}
