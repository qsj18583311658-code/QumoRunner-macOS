import Foundation
import RunnerCore

struct AgentSnapshot: Codable, Sendable {
    var serviceState: String
    var serverReachable: Bool
    var serverURL: String?
    var libTVVersion: String?
    var libTVUpdate: LibTVUpdateStatus? = nil
    var libTVVerified: Bool
    var activeConcurrency: Int
    var concurrencyLimit: Int
    var todaySucceeded: Int
    var todayFailed: Int
    var jobs: [AgentJob]
    var accounts: [AgentAccount]
    var logs: [AgentLog]
}

struct AgentJob: Codable, Sendable {
    let id: String
    let title: String
    let state: String
    let progress: Double
    let profileRef: String
    let accountName: String
    let startedAt: Date?
    let finishedAt: Date?
    let artifactNames: [String]
    let errorMessage: String?
    let remoteTaskID: String?
}

struct AgentAccount: Codable, Sendable {
    let id: String
    let displayName: String
    let accountRef: String
    let enabled: Bool
    let healthy: Bool
    let authExpired: Bool
    let capabilities: [String]
    let currentJobTitle: String?
    let currentJobCount: Int
    let lastCheckedAt: Date?
    let insightError: String?
    let insightRefreshing: Bool
    let autoConcurrencyActivated: Bool
    let quotaState: String
    let quota: AgentQuotaSnapshot?
    let plan: AgentPlanSnapshot?
    let detectedMaxConcurrency: Int?
    let effectiveMaxConcurrency: Int
    let catalogRevision: String?
    let catalogRefreshedAt: Date?
    let catalogError: String?
    let catalogRefreshing: Bool
    let models: [AgentModelCatalogItem]
}

struct AgentQuotaSnapshot: Codable, Sendable {
    let total: Double
    let membership: Double
    let recharge: Double
    let modelCard: Double
    let free: Double
    let fetchedAt: Date
    let stale: Bool
}

struct AgentPlanSnapshot: Codable, Sendable {
    let name: String?
    let detectedMaxConcurrency: Int?
    let unlimitedConcurrency: Bool
    let fetchedAt: Date
    let stale: Bool
    let detectionNote: String
}

struct AgentModelCatalogItem: Codable, Sendable {
    let modelRef: String
    let displayName: String
    let modalities: [String]
    let summaryHash: String
    let schemaHash: String
    let approvalState: String
    let approved: Bool
    let missingRefreshCount: Int
}

struct AgentLog: Codable, Sendable {
    let id: UUID
    let timestamp: Date
    let level: String
    let message: String
    let jobID: String?
    let profileRef: String?
}
