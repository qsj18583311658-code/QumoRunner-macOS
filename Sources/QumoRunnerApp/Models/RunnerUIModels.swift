import Foundation
import SwiftUI

enum ServiceState: String, Codable, CaseIterable {
    case unconfigured, connecting, idle, busy, paused, degraded, offline, authExpired

    var title: String {
        switch self {
        case .unconfigured: "未配置"
        case .connecting: "连接中"
        case .idle: "空闲"
        case .busy: "执行中"
        case .paused: "已暂停领取"
        case .degraded: "服务降级"
        case .offline: "离线"
        case .authExpired: "凭证已过期"
        }
    }

    var color: Color {
        switch self {
        case .idle: .green
        case .busy, .connecting: .blue
        case .paused: .orange
        case .degraded, .authExpired: .yellow
        case .unconfigured, .offline: .secondary
        }
    }
}

enum JobState: String, Codable, CaseIterable {
    case queued, leased, submitting, running, succeeded, failed, cancelled, needsReview = "needs_review"

    var title: String {
        switch self {
        case .queued: "排队中"
        case .leased: "已领取"
        case .submitting: "提交中"
        case .running: "运行中"
        case .succeeded: "已成功"
        case .failed: "已失败"
        case .cancelled: "已取消"
        case .needsReview: "待人工确认"
        }
    }

    var color: Color {
        switch self {
        case .succeeded: .green
        case .failed: .red
        case .cancelled: .secondary
        case .needsReview: .orange
        case .queued, .leased: .gray
        case .submitting, .running: .blue
        }
    }

    var mayCancelBeforeSubmission: Bool { self == .queued || self == .leased }
    var mayStopTracking: Bool { self == .submitting || self == .running }
}

enum LogLevel: String, Codable, CaseIterable, Identifiable {
    case debug, info, warning, error
    var id: String { rawValue }
    var title: String { rawValue.uppercased() }
    var color: Color {
        switch self { case .debug: .secondary; case .info: .blue; case .warning: .orange; case .error: .red }
    }
}

struct RunnerJob: Codable, Identifiable, Hashable {
    let id: String
    var title: String
    var state: JobState
    var progress: Double
    var profileRef: String
    var accountName: String
    var startedAt: Date?
    var finishedAt: Date?
    var artifactNames: [String]
    var errorMessage: String?
    var remoteTaskID: String?

    var elapsedText: String {
        guard let startedAt else { return "—" }
        let seconds = Int((finishedAt ?? Date()).timeIntervalSince(startedAt))
        if seconds < 60 { return "\(seconds) 秒" }
        return "\(seconds / 60) 分 \(seconds % 60) 秒"
    }
}

struct RunnerAccount: Codable, Identifiable, Hashable {
    let id: String
    var displayName: String
    var accountRef: String
    var enabled: Bool
    var healthy: Bool
    var authExpired: Bool
    var capabilities: [String]
    var currentJobTitle: String?
    var currentJobCount: Int
    var lastCheckedAt: Date?
    var insightError: String?
    var insightRefreshing: Bool
    var autoConcurrencyActivated: Bool
    var quotaState: QuotaState
    var quota: RunnerQuotaSnapshot?
    var plan: RunnerPlanSnapshot?
    var detectedMaxConcurrency: Int?
    var effectiveMaxConcurrency: Int
    var catalogRevision: String?
    var catalogRefreshedAt: Date?
    var catalogError: String?
    var catalogRefreshing: Bool
    var models: [RunnerModelCatalogItem]

    var insightStatus: AccountInsightStatus {
        if insightRefreshing { return .refreshing }
        if quotaState == .webAuthRequired || quotaState == .identityMismatch { return .webLoginRequired }
        if insightError != nil { return .failed }
        if quotaState == .available || quotaState == .zero { return .succeeded }
        return .neverRefreshed
    }

    var pendingModelCount: Int { models.filter { $0.approvalState == .pending || $0.approvalState == .changed }.count }
    var approvedModelCount: Int { models.filter { $0.approvalState == .approved }.count }
    var modelModalitySummary: [(name: String, title: String, count: Int)] {
        let counts = models.reduce(into: [String: Int]()) { result, model in
            let modality = model.primaryModality
            result[modality, default: 0] += 1
        }
        return counts.map { name, count in
            (name: name, title: RunnerModelCatalogItem.modalityTitle(name), count: count)
        }
        .sorted { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }
}

enum AccountInsightStatus: String, Hashable {
    case neverRefreshed, refreshing, failed, webLoginRequired, succeeded

    var title: String {
        switch self {
        case .neverRefreshed: "尚未刷新"
        case .refreshing: "刷新中"
        case .failed: "刷新失败"
        case .webLoginRequired: "需 Chrome 授权"
        case .succeeded: "已刷新"
        }
    }

    var color: Color {
        switch self {
        case .neverRefreshed: .secondary
        case .refreshing: .blue
        case .failed: .red
        case .webLoginRequired: .orange
        case .succeeded: .green
        }
    }
}

enum QuotaState: String, Codable, Hashable {
    case unknown, refreshing, available, zero, stale
    case webAuthRequired = "web_auth_required"
    case identityMismatch = "identity_mismatch"

    var title: String {
        switch self {
        case .unknown: "积分未知"
        case .refreshing: "积分刷新中"
        case .available: "积分可用"
        case .zero: "积分为零"
        case .stale: "积分已陈旧"
        case .webAuthRequired: "需 Chrome 授权"
        case .identityMismatch: "授权身份不一致"
        }
    }

    var color: Color {
        switch self {
        case .available: .green
        case .refreshing: .blue
        case .zero, .webAuthRequired, .identityMismatch: .orange
        case .stale: .yellow
        case .unknown: .secondary
        }
    }
}

struct RunnerQuotaSnapshot: Codable, Hashable {
    let total: Double
    let membership: Double
    let recharge: Double
    let modelCard: Double
    let free: Double
    let fetchedAt: Date
    let stale: Bool
}

struct RunnerPlanSnapshot: Codable, Hashable {
    let name: String?
    let detectedMaxConcurrency: Int?
    let unlimitedConcurrency: Bool
    let fetchedAt: Date
    let stale: Bool
    let detectionNote: String
}

enum ModelApprovalState: String, Codable, Hashable {
    case approved, pending, changed, removed
    var title: String {
        switch self { case .approved: "已启用"; case .pending: "待确认"; case .changed: "Schema 已变化"; case .removed: "已移除" }
    }
    var color: Color {
        switch self { case .approved: .green; case .pending: .blue; case .changed: .orange; case .removed: .secondary }
    }
}

struct RunnerModelCatalogItem: Codable, Identifiable, Hashable {
    var id: String { modelRef }
    let modelRef: String
    let displayName: String
    let modalities: [String]
    let summaryHash: String
    let schemaHash: String
    let approvalState: ModelApprovalState
    let approved: Bool
    let missingRefreshCount: Int

    var primaryModality: String {
        let normalized = modalities.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        return Self.modalityOrder.first(where: normalized.contains) ?? normalized.first ?? "other"
    }

    static let modalityOrder = ["image", "video", "audio", "text", "script", "storyboard"]

    static func modalityTitle(_ modality: String) -> String {
        switch modality {
        case "image": "图片"
        case "video": "视频"
        case "audio": "音频"
        case "text": "文本"
        case "script": "脚本"
        case "storyboard": "分镜"
        default: "其他"
        }
    }
}

struct RunnerProfileModelOccurrence: Hashable {
    let profileRef: String
    let profileName: String
    let model: RunnerModelCatalogItem
}

struct RunnerGlobalModelCatalogItem: Identifiable, Hashable {
    let modelRef: String
    let displayName: String
    let modalities: [String]
    let occurrences: [RunnerProfileModelOccurrence]

    var id: String { modelRef }

    var activeOccurrences: [RunnerProfileModelOccurrence] {
        occurrences.filter { $0.model.approvalState != .removed }
    }

    var approvedOccurrenceCount: Int {
        activeOccurrences.filter { $0.model.approvalState == .approved }.count
    }

    var schemaVariantCount: Int {
        Set(activeOccurrences.map(\.model.schemaHash).filter { !$0.isEmpty }).count
    }

    var hasSchemaConflict: Bool { schemaVariantCount > 1 }

    var approvalState: ModelApprovalState {
        let active = activeOccurrences
        if active.isEmpty { return .removed }
        if active.contains(where: { $0.model.approvalState == .changed }) { return .changed }
        if active.allSatisfy({ $0.model.approvalState == .approved }) { return .approved }
        return .pending
    }

    var primaryModality: String {
        let normalized = modalities.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        return RunnerModelCatalogItem.modalityOrder.first(where: normalized.contains) ?? normalized.first ?? "other"
    }

    static func aggregate(accounts: [RunnerAccount]) -> [Self] {
        let realAccounts = accounts.filter { $0.accountRef != "pending" }
        var grouped: [String: [RunnerProfileModelOccurrence]] = [:]
        for account in realAccounts {
            for model in account.models {
                grouped[model.modelRef, default: []].append(
                    RunnerProfileModelOccurrence(profileRef: account.id, profileName: account.displayName, model: model)
                )
            }
        }

        return grouped.map { modelRef, occurrences in
            let displayName = occurrences
                .map(\.model.displayName)
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .first ?? modelRef
            let modalitySet = Set(occurrences.flatMap(\.model.modalities).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }.filter { !$0.isEmpty })
            let modalities = modalitySet.sorted { lhs, rhs in
                let lhsIndex = RunnerModelCatalogItem.modalityOrder.firstIndex(of: lhs) ?? .max
                let rhsIndex = RunnerModelCatalogItem.modalityOrder.firstIndex(of: rhs) ?? .max
                return lhsIndex == rhsIndex ? lhs < rhs : lhsIndex < rhsIndex
            }
            return Self(
                modelRef: modelRef,
                displayName: displayName,
                modalities: modalities,
                occurrences: occurrences.sorted { $0.profileRef < $1.profileRef }
            )
        }
        .sorted { lhs, rhs in
            lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }
}

struct RunnerModelBatchProgress: Equatable {
    let approved: Bool
    let completed: Int
    let total: Int

    var title: String {
        "正在\(approved ? "启用" : "停用") \(completed)/\(total)"
    }
}

struct RunnerModelBatchResult: Equatable {
    let requestedModelRefs: Set<String>
    let failedModelRefs: Set<String>
    let completedConfigurationCount: Int
    let totalConfigurationCount: Int

    var allSucceeded: Bool { failedModelRefs.isEmpty }
}

struct RunnerModelBatchPlan: Equatable {
    let expectedSchemaHashesByModel: [String: [String: String]]
    let modelCount: Int
    let configurationCount: Int
    let schemaConflictCount: Int

    static func make(models: [RunnerGlobalModelCatalogItem], approved: Bool) -> Self {
        var requests: [String: [String: String]] = [:]
        var configurationCount = 0
        var conflictCount = 0
        for model in models {
            let eligible = model.activeOccurrences.filter { occurrence in
                approved
                    ? occurrence.model.approvalState == .pending || occurrence.model.approvalState == .changed
                    : occurrence.model.approvalState == .approved
            }
            guard !eligible.isEmpty else { continue }
            requests[model.modelRef] = Dictionary(uniqueKeysWithValues: eligible.map {
                ($0.profileRef, $0.model.schemaHash)
            })
            configurationCount += eligible.count
            if model.hasSchemaConflict { conflictCount += 1 }
        }
        return Self(
            expectedSchemaHashesByModel: requests,
            modelCount: requests.count,
            configurationCount: configurationCount,
            schemaConflictCount: conflictCount
        )
    }
}

struct RunnerLogEntry: Codable, Identifiable, Hashable {
    let id: UUID
    let timestamp: Date
    let level: LogLevel
    let message: String
    let jobID: String?
    let profileRef: String?
}

struct RunnerSnapshot: Codable {
    var serviceState: ServiceState
    var serverReachable: Bool
    var serverURL: String?
    var libTVVersion: String?
    var libTVVerified: Bool
    var activeConcurrency: Int
    var concurrencyLimit: Int
    var todaySucceeded: Int
    var todayFailed: Int
    var jobs: [RunnerJob]
    var accounts: [RunnerAccount]
    var logs: [RunnerLogEntry]

    static let empty = RunnerSnapshot(
        serviceState: .unconfigured,
        serverReachable: false,
        serverURL: nil,
        libTVVersion: nil,
        libTVVerified: false,
        activeConcurrency: 0,
        concurrencyLimit: 4,
        todaySucceeded: 0,
        todayFailed: 0,
        jobs: [],
        accounts: [],
        logs: []
    )
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case overview, jobs, accounts, models, logs, settings
    var id: String { rawValue }
    var title: String {
        switch self { case .overview: "总览"; case .jobs: "任务"; case .accounts: "账号"; case .models: "模型"; case .logs: "日志"; case .settings: "设置" }
    }
    var icon: String {
        switch self { case .overview: "rectangle.3.group"; case .jobs: "list.bullet.rectangle"; case .accounts: "person.2"; case .models: "square.grid.2x2"; case .logs: "doc.text.magnifyingglass"; case .settings: "gearshape" }
    }
}
