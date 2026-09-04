import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var store: RunnerAppStore
    private var activeJobs: [RunnerJob] { store.snapshot.jobs.filter { [.leased, .submitting, .running].contains($0.state) } }
    private var enabledAccounts: [RunnerAccount] { store.snapshot.accounts.filter(\.enabled) }
    private var zeroBalanceAccounts: Int { enabledAccounts.filter { $0.quotaState == .zero }.count }
    private var authorizationAccounts: Int { enabledAccounts.filter { $0.quotaState == .webAuthRequired || $0.quotaState == .identityMismatch }.count }
    private var pendingModels: Int {
        RunnerGlobalModelCatalogItem.aggregate(accounts: enabledAccounts)
            .filter { $0.approvalState == .pending || $0.approvalState == .changed }
            .count
    }
    private var effectiveCapacity: Int { enabledAccounts.reduce(0) { $0 + $1.effectiveMaxConcurrency } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    SectionHeader(title: "运行总览", subtitle: "本机 Runner 与多账号执行状态")
                    Spacer()
                    StateBadge(title: store.snapshot.serviceState.title, color: store.snapshot.serviceState.color)
                }
                if store.snapshot.libTVUpdate?.availableVersion(current: store.snapshot.libTVVersion) != nil
                    || store.snapshot.libTVUpdate?.isBusy == true
                    || store.snapshot.libTVUpdate?.phase == "failed" {
                    CLIUpdateView(compact: true).padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                    MetricCard(title: "服务器", value: store.snapshot.serverReachable ? "已连接" : "未连接", detail: store.snapshot.serverURL ?? "尚未配对", icon: "network", tint: store.snapshot.serverReachable ? .green : .orange)
                    MetricCard(title: "LibTV CLI", value: store.snapshot.libTVVersion ?? "未检测", detail: store.snapshot.libTVVerified ? "版本、签名与 SHA-256 已验证" : "等待完整性校验", icon: "terminal", tint: store.snapshot.libTVVerified ? .green : .orange)
                    MetricCard(title: "启用账号", value: "\(enabledAccounts.count)", detail: zeroBalanceAccounts == 0 ? "套餐并发会按 Profile 自动限制" : "\(zeroBalanceAccounts) 个账号积分确认为零", icon: "person.crop.circle.badge.checkmark", tint: zeroBalanceAccounts == 0 ? .accentColor : .orange)
                    MetricCard(title: "当前并发", value: "\(store.snapshot.activeConcurrency) / \(store.snapshot.concurrencyLimit)", detail: "Profile 有效容量 \(effectiveCapacity)，受全局上限约束", icon: "arrow.triangle.branch")
                    MetricCard(title: "今日成功", value: "\(store.snapshot.todaySucceeded)", detail: "已完成并闭环上传产物", icon: "checkmark.circle", tint: .green)
                    MetricCard(title: "今日失败", value: "\(store.snapshot.todayFailed)", detail: "不包含待人工确认", icon: "xmark.octagon", tint: store.snapshot.todayFailed == 0 ? .secondary : .red)
                }

                if authorizationAccounts > 0 || pendingModels > 0 || store.snapshot.jobs.contains(where: { $0.state == .needsReview }) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("需要处理").font(.headline)
                        if authorizationAccounts > 0 {
                            Label("\(authorizationAccounts) 个 Profile 需要 Chrome 授权或账号校验；其他 Profile 不受影响。", systemImage: "person.crop.circle.badge.exclamationmark")
                        }
                        if pendingModels > 0 {
                            Label("\(pendingModels) 个新增或 schema 变更的模型等待人工启用。", systemImage: "square.stack.3d.up.badge.a")
                        }
                        let reviewCount = store.snapshot.jobs.filter { $0.state == .needsReview }.count
                        if reviewCount > 0 {
                            Label("\(reviewCount) 个任务 needs_review，不会自动重试未知提交。", systemImage: "exclamationmark.triangle")
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("正在执行").font(.headline)
                    if activeJobs.isEmpty {
                        EmptyStateView(icon: "moon.zzz", title: "当前没有运行中的任务", message: store.snapshot.serviceState == .paused ? "Runner 已暂停领取新任务；恢复后才会继续领取。" : "Runner 会按各 Profile 串行领取任务。")
                            .frame(height: 190)
                    } else {
                        ForEach(activeJobs.prefix(5)) { job in
                            ActiveJobRow(job: job)
                        }
                    }
                }
            }
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct ActiveJobRow: View {
    let job: RunnerJob
    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(job.title).fontWeight(.medium)
                Text("\(job.accountName) · \(job.elapsedText)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            ProgressView(value: job.progress).frame(width: 150)
            Text(job.progress, format: .percent.precision(.fractionLength(0))).monospacedDigit().frame(width: 42, alignment: .trailing)
            StateBadge(title: job.state.title, color: job.state.color)
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
    }
}
