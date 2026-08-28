import Foundation
import UserNotifications

final class RunnerNotificationService: @unchecked Sendable {
    static let shared = RunnerNotificationService()
    private let center = UNUserNotificationCenter.current()
    private var stableQuotaStates: [String: QuotaState] = [:]

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func notify(title: String, body: String, identifier: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    func evaluate(previous: RunnerSnapshot, current: RunnerSnapshot, enabled: Bool) {
        guard enabled else { return }
        if previous.serviceState != .offline, current.serviceState == .offline {
            notify(title: "Qumo Runner 已离线", body: "无法连接 Canvas API，请检查网络或服务器。", identifier: "runner-offline")
        }
        if previous.serviceState != .authExpired, current.serviceState == .authExpired {
            notify(title: "Runner 凭证已过期", body: "请打开 Qumo Runner 重新配对。", identifier: "runner-auth-expired")
        }
        let previouslyExpired = Set(previous.accounts.filter(\.authExpired).map(\.id))
        for account in current.accounts where account.authExpired && !previouslyExpired.contains(account.id) {
            notify(title: "LibTV 账号登录已过期", body: "\(account.displayName) 需要重新登录，其他 Profile 不受影响。", identifier: "account-auth-\(account.id)")
        }
        let previousAccounts = Dictionary(uniqueKeysWithValues: previous.accounts.map { ($0.id, $0) })
        for account in current.accounts {
            let previousAccount = previousAccounts[account.id]
            let previousStable = stableQuotaStates[account.id] ?? previousAccount?.quotaState
            if account.quotaState != .refreshing, previousStable != account.quotaState {
                switch account.quotaState {
                case .zero:
                    notify(title: "LibTV 账号积分为零", body: "\(account.displayName) 已暂停新 Claim，已运行任务不受影响。", identifier: "account-quota-zero-\(account.id)")
                case .stale:
                    notify(title: "LibTV 积分数据已陈旧", body: "\(account.displayName) 暂时保留最近成功值，有效窗口为 10 分钟。", identifier: "account-quota-stale-\(account.id)")
                case .webAuthRequired:
                    notify(title: "LibTV 需要重新授权", body: "\(account.displayName) 可在 Chrome 中重新完成官方授权，其他 Profile 不受影响。", identifier: "account-web-auth-\(account.id)")
                case .identityMismatch:
                    notify(title: "LibTV 授权身份不匹配", body: "\(account.displayName) 的授权账号与 CLI Profile 不一致，已拒绝使用该余额。", identifier: "account-identity-\(account.id)")
                case .unknown, .refreshing, .available:
                    break
                }
            }
            if account.quotaState != .refreshing { stableQuotaStates[account.id] = account.quotaState }
            let oldPending = previousAccount?.pendingModelCount ?? 0
            if account.pendingModelCount > oldPending {
                let delta = account.pendingModelCount - oldPending
                notify(title: "模型等待审批", body: "\(account.displayName) 新增 \(delta) 个待确认模型；未批准前不会用于调度。", identifier: "account-model-approval-\(account.id)-\(account.pendingModelCount)")
            }
        }
        stableQuotaStates = stableQuotaStates.filter { id, _ in current.accounts.contains { $0.id == id } }
        let oldReviewIDs = Set(previous.jobs.filter { $0.state == .needsReview }.map(\.id))
        for job in current.jobs where job.state == .needsReview && !oldReviewIDs.contains(job.id) {
            notify(title: "任务待人工确认", body: "\(job.title) 的远端结果不确定，请勿重复提交。", identifier: "review-\(job.id)")
        }
    }
}
