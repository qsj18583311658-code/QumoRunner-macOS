import SwiftUI

struct AccountsView: View {
    @EnvironmentObject private var store: RunnerAppStore
    @State private var showAddConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                SectionHeader(title: "账号", subtitle: "Chrome 官方授权写入隔离 Profile；远端任务并发由套餐与全局上限共同决定")
                Spacer()
                if store.isAuthorizingAccount {
                    ProgressView().controlSize(.small)
                    Text(store.loginStatusMessage ?? "等待 Chrome 授权…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button { showAddConfirmation = true } label: {
                    Label(store.isAuthorizingAccount ? "授权进行中" : "添加账号", systemImage: "plus")
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isAuthorizingAccount)
            }
            .padding(22)
            Divider()

            if store.snapshot.accounts.isEmpty {
                EmptyStateView(icon: "person.crop.circle.badge.plus", title: "还没有 LibTV 账号", message: "添加账号将在 Chrome 打开 LibTV 官方授权。凭证只保存在该 Profile 的隔离目录中。", actionTitle: "添加第一个账号") { showAddConfirmation = true }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 470), spacing: 14)], spacing: 14) {
                        ForEach(store.snapshot.accounts) { account in
                            if account.accountRef == "pending" {
                                PendingAccountCard(account: account)
                            } else {
                                AccountCard(account: account)
                            }
                        }
                    }
                    .padding(22)
                }
            }
        }
        .navigationTitle("账号")
        .confirmationDialog("添加 LibTV 账号", isPresented: $showAddConfirmation) {
            Button("打开独立 Chrome 授权窗口") { Task { await store.loginAccount() } }
                .disabled(store.isAuthorizingAccount)
            Button("取消", role: .cancel) {}
        } message: {
            Text("每个 Qumo Profile 使用独立的 Chrome 登录目录。请在新窗口登录要添加的 Liblib 账号；不会复用日常 Chrome 或其他 Profile 的会话。")
        }
    }
}

private struct PendingAccountCard: View {
    @EnvironmentObject private var store: RunnerAppStore
    let account: RunnerAccount

    var body: some View {
        HStack(spacing: 14) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 4) {
                Text("等待 LibTV 账号授权").font(.headline)
                Text(store.pendingLoginProfileRef == account.id
                     ? store.loginStatusMessage ?? "请在此 Profile 专属的 Chrome 窗口完成登录。"
                     : "这是一条未完成的旧授权记录，可以安全移除后重新添加。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(account.id).font(.caption2.monospaced()).foregroundStyle(.tertiary)
            }
            Spacer()
            Button(store.pendingLoginProfileRef == account.id ? "取消授权" : "移除") {
                Task { await store.cancelOrRemovePendingAccount(account) }
            }
            .buttonStyle(.bordered)
        }
        .padding(17)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.orange.opacity(0.5)))
    }
}

private struct AccountCard: View {
    @EnvironmentObject private var store: RunnerAppStore
    let account: RunnerAccount
    @State private var confirmDisable = false

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top) {
                Image(systemName: "person.crop.circle.fill").font(.system(size: 34)).foregroundStyle(account.healthy ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(account.displayName).font(.headline)
                    Text(account.accountRef).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                StateBadge(title: account.authExpired ? "登录已过期" : account.healthy ? "健康" : "异常", color: account.authExpired ? .orange : account.healthy ? .green : .red)
            }
            AccountInsightSection(account: account)

            Divider()
            LabeledContent("Profile", value: account.id)
            LabeledContent("套餐", value: account.plan?.name ?? "未识别")
            LabeledContent("自动并发", value: concurrencyText)
            LabeledContent("当前任务", value: currentJobsText)
            VStack(alignment: .leading, spacing: 6) {
                Text("能力范围").font(.caption).foregroundStyle(.secondary)
                if account.capabilities.isEmpty { Text("尚未同步").font(.caption).foregroundStyle(.secondary) }
                else { FlowLayout(spacing: 5) { ForEach(account.capabilities, id: \.self) { Text($0).font(.caption).padding(.horizontal, 7).padding(.vertical, 3).background(.quaternary, in: Capsule()) } } }
            }
            HStack {
                insightActions
                if account.authExpired { Button("CLI 重新登录") { Task { await store.loginAccount(profileRef: account.id) } }.buttonStyle(.borderedProminent) }
                Spacer()
                Toggle("启用", isOn: Binding(get: { account.enabled }, set: { enabled in
                    if enabled { Task { await store.toggleAccount(account) } } else { confirmDisable = true }
                })).toggleStyle(.switch)
            }
        }
        .padding(17)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.7)))
        .confirmationDialog("停用 \(account.displayName)？", isPresented: $confirmDisable) {
            Button("停止领取新任务", role: .destructive) { Task { await store.toggleAccount(account) } }
            Button("取消", role: .cancel) {}
        } message: { Text("该账号将停止领取新任务；已运行任务会继续跟踪，不会被误称为取消。") }
    }

    private var concurrencyText: String {
        if account.quotaState == .zero { return "0（积分确认为零，暂停新 Claim）" }
        if !account.autoConcurrencyActivated { return "\(account.effectiveMaxConcurrency)（迁移保护，首次成功检测前为 1）" }
        if account.plan?.unlimitedConcurrency == true { return "\(account.effectiveMaxConcurrency)（套餐无限，受全局上限限制）" }
        if let detected = account.detectedMaxConcurrency { return "\(account.effectiveMaxConcurrency)（套餐检测 \(detected)）" }
        return "\(account.effectiveMaxConcurrency)（未解析，回退 2）"
    }

    private var currentJobsText: String {
        guard account.currentJobCount > 0 else { return "空闲" }
        if account.currentJobCount == 1, let title = account.currentJobTitle { return "1 个 · \(title)" }
        return "\(account.currentJobCount) 个任务"
    }

    @ViewBuilder
    private var insightActions: some View {
        if account.authExpired || account.insightStatus == .webLoginRequired {
            chromeSyncButton.buttonStyle(.borderedProminent)
        } else {
            chromeSyncButton.buttonStyle(.bordered)
        }
    }

    private var chromeSyncButton: some View {
        Button {
            Task { await store.authorizeOrSyncFromChrome(account) }
        } label: {
            Label(
                chromeSyncTitle,
                systemImage: account.insightRefreshing ? "arrow.triangle.2.circlepath" : account.insightStatus == .webLoginRequired ? "globe" : "arrow.clockwise"
            )
        }
        .disabled(account.insightRefreshing)
    }

    private var chromeSyncTitle: String {
        if account.insightRefreshing { return "正在同步" }
        if account.authExpired || account.insightStatus == .webLoginRequired { return "使用 Chrome 授权并同步" }
        if account.insightStatus == .failed { return "重试账号数据" }
        return "同步积分/套餐"
    }

}

private struct AccountInsightSection: View {
    let account: RunnerAccount

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                StateBadge(title: account.insightStatus.title, color: account.insightStatus.color)
                if account.insightStatus == .succeeded || account.quotaState == .stale {
                    StateBadge(title: account.quotaState.title, color: account.quotaState.color)
                }
                if account.insightRefreshing { ProgressView().controlSize(.small) }
                Spacer()
                Text(lastAttemptText).font(.caption).foregroundStyle(.secondary)
            }
            statusPanel
            if let quota = account.quota { quotaPanel(quota) }
        }
    }

    private var statusPanel: some View {
        let color = account.insightStatus.color
        return HStack(alignment: .top, spacing: 9) {
            Image(systemName: statusIcon).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                Text(statusMessage).font(.caption)
                if let error = account.insightError,
                   account.insightStatus == .failed || account.insightStatus == .webLoginRequired {
                    Text(error).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func quotaPanel(_ quota: RunnerQuotaSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text("总余额").font(.caption).foregroundStyle(.secondary)
                Text(points(quota.total)).font(.title2.weight(.semibold)).monospacedDigit()
                if quota.stale { Text("陈旧").font(.caption).foregroundStyle(.orange) }
                Spacer()
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 7) {
                BalanceCell(title: "会员订阅", value: quota.membership)
                BalanceCell(title: "通用充值", value: quota.recharge)
                BalanceCell(title: "模型卡", value: quota.modelCard)
                BalanceCell(title: "免费积分", value: quota.free)
            }
        }
        .padding(11)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
    }

    private var statusIcon: String {
        switch account.insightStatus {
        case .neverRefreshed: "clock.badge.questionmark"
        case .refreshing: "arrow.triangle.2.circlepath"
        case .failed: "exclamationmark.triangle.fill"
        case .webLoginRequired: "person.crop.circle.badge.exclamationmark"
        case .succeeded: "checkmark.circle.fill"
        }
    }

    private var statusMessage: String {
        switch account.insightStatus {
        case .neverRefreshed: "尚未同步积分与套餐。Runner 会使用此 Profile 的官方授权读取可验证数据。"
        case .refreshing: "正在通过 LibTV 官方授权同步积分与套餐，请稍候。"
        case .failed: account.quota == nil ? "本次刷新失败，积分仍为未知；不会把失败误判为零余额。" : "本次刷新失败，当前显示的是最近一次可用数据。"
        case .webLoginRequired: account.quotaState == .identityMismatch ? "授权账号与当前 Profile 不一致，请用 Chrome 重新授权正确账号。" : "此 Profile 的官方授权已过期；Chrome 当前已登录时可一键重新授权。"
        case .succeeded: "积分与套餐已成功刷新。"
        }
    }

    private var lastAttemptText: String {
        guard let date = account.lastCheckedAt else { return account.insightRefreshing ? "首次刷新中" : "从未刷新" }
        let prefix = account.insightStatus == .succeeded ? "最后成功" : "最后尝试"
        return "\(prefix)：\(date.formatted(date: .abbreviated, time: .shortened))"
    }

    private func points(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...2))) }
}

private struct BalanceCell: View {
    let title: String
    let value: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Text(value.formatted(.number.precision(.fractionLength(0...2)))).font(.subheadline.weight(.medium)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FlowLayout: Layout {
    let spacing: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: ProposedViewSize(width: bounds.width, height: proposal.height), subviews: subviews)
        for (index, point) in result.points.enumerated() { subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified) }
    }
    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        var points: [CGPoint] = []
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth { x = 0; y += lineHeight + spacing; lineHeight = 0 }
            points.append(CGPoint(x: x, y: y)); x += size.width + spacing; lineHeight = max(lineHeight, size.height)
        }
        return (CGSize(width: maxWidth.isFinite ? maxWidth : x, height: y + lineHeight), points)
    }
}
