import SwiftUI

struct JobsView: View {
    enum Scope: String, CaseIterable, Identifiable { case active = "当前任务", recent = "最近任务"; var id: String { rawValue } }
    @EnvironmentObject private var store: RunnerAppStore
    @State private var scope: Scope = .active
    @State private var searchText = ""
    @State private var pendingAction: JobAction?

    private var jobs: [RunnerJob] {
        store.snapshot.jobs.filter { job in
            let inScope = scope == .active ? [.queued, .leased, .submitting, .running, .needsReview].contains(job.state) : [.succeeded, .failed, .cancelled].contains(job.state)
            return inScope && (searchText.isEmpty || job.title.localizedCaseInsensitiveContains(searchText) || job.accountName.localizedCaseInsensitiveContains(searchText) || job.id.localizedCaseInsensitiveContains(searchText))
        }
    }

    private var selectedJob: RunnerJob? {
        store.snapshot.jobs.first { $0.id == store.selectedJobID }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Picker("范围", selection: $scope) { ForEach(Scope.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 260)
                    Spacer()
                }
                .padding(14)
                Divider()
                if jobs.isEmpty {
                    EmptyStateView(icon: scope == .active ? "tray" : "clock", title: scope == .active ? "没有当前任务" : "没有最近任务", message: searchText.isEmpty ? "任务被领取后会显示在这里。" : "没有符合筛选条件的任务。")
                } else {
                    List(jobs, selection: $store.selectedJobID) { job in
                        JobListRow(job: job).tag(job.id)
                    }
                    .listStyle(.inset)
                }
            }
            .frame(minWidth: 390, idealWidth: 470)
            .searchable(text: $searchText, prompt: "搜索任务、账号或 ID")

            if let selectedJob {
                JobDetailView(job: selectedJob, pendingAction: $pendingAction)
                    .frame(minWidth: 400)
            } else {
                EmptyStateView(icon: "cursorarrow.click.2", title: "选择一个任务", message: "查看进度、账号、耗时、产物和人工确认状态。")
                    .frame(minWidth: 400)
            }
        }
        .navigationTitle("任务")
        .confirmationDialog(pendingAction?.title ?? "", isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } })) {
            if let action = pendingAction {
                Button(action.buttonTitle, role: action.role) { perform(action) }
                Button("返回", role: .cancel) { pendingAction = nil }
            }
        } message: {
            Text(pendingAction?.message ?? "")
        }
    }

    private func perform(_ action: JobAction) {
        pendingAction = nil
        Task {
            switch action.kind {
            case .cancel: await store.cancelBeforeSubmission(job: action.job)
            case .stopTracking: await store.stopTracking(job: action.job)
            case .resolveSuccess: await store.resolveReview(job: action.job, resolution: "succeeded")
            case .resolveFailure: await store.resolveReview(job: action.job, resolution: "failed")
            }
        }
    }
}

private struct JobListRow: View {
    let job: RunnerJob
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text(job.title).fontWeight(.medium).lineLimit(1); Spacer(); StateBadge(title: job.state.title, color: job.state.color) }
            if job.state == .running || job.state == .submitting { ProgressView(value: job.progress) }
            HStack { Text(job.accountName); Spacer(); Text(job.elapsedText) }
                .font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 5)
    }
}

private struct JobDetailView: View {
    let job: RunnerJob
    @Binding var pendingAction: JobAction?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) { Text(job.title).font(.title2.weight(.semibold)); Text(job.id).font(.caption.monospaced()).foregroundStyle(.secondary) }
                    Spacer(); StateBadge(title: job.state.title, color: job.state.color)
                }
                if job.state == .running || job.state == .submitting {
                    VStack(alignment: .leading, spacing: 7) { HStack { Text("进度"); Spacer(); Text(job.progress, format: .percent.precision(.fractionLength(0))) }; ProgressView(value: job.progress) }
                }
                GroupBox("执行信息") {
                    LabeledContent("账号", value: job.accountName)
                    LabeledContent("Profile", value: job.profileRef)
                    LabeledContent("耗时", value: job.elapsedText)
                    LabeledContent("远端任务 ID", value: job.remoteTaskID ?? "尚未提交")
                }
                if let error = job.errorMessage {
                    GroupBox("错误") { Text(error).foregroundStyle(.red).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                }
                GroupBox("产物") {
                    if job.artifactNames.isEmpty { Text("暂无已闭环产物").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
                    else { ForEach(job.artifactNames, id: \.self) { Label($0, systemImage: "paperclip") } }
                }
                controls
            }.padding(22)
        }
    }

    @ViewBuilder private var controls: some View {
        if job.state.mayCancelBeforeSubmission {
            Button("取消（尚未提交）", role: .destructive) { pendingAction = .init(kind: .cancel, job: job) }
            Text("仅提交前可真正取消，不会消耗 LibTV 额度。 ").font(.caption).foregroundStyle(.secondary)
        } else if job.state.mayStopTracking {
            Button("停止跟踪…", role: .destructive) { pendingAction = .init(kind: .stopTracking, job: job) }
            Text("远端任务无法可靠取消。停止本地进程只会停止跟踪，并把任务标为待人工确认。").font(.caption).foregroundStyle(.orange)
        } else if job.state == .needsReview {
            VStack(alignment: .leading, spacing: 10) {
                Label("结果不确定，系统不会自动重试或重新提交。", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                HStack {
                    Button("确认远端成功…") { pendingAction = .init(kind: .resolveSuccess, job: job) }
                    Button("确认远端失败…") { pendingAction = .init(kind: .resolveFailure, job: job) }
                }
            }
        }
    }
}

struct JobAction {
    enum Kind { case cancel, stopTracking, resolveSuccess, resolveFailure }
    let kind: Kind
    let job: RunnerJob
    var title: String { kind == .stopTracking ? "停止跟踪远端任务？" : "确认任务状态？" }
    var buttonTitle: String { switch kind { case .cancel: "确认取消"; case .stopTracking: "停止跟踪并转人工确认"; case .resolveSuccess: "确认成功"; case .resolveFailure: "确认失败" } }
    var role: ButtonRole? { kind == .resolveSuccess ? nil : .destructive }
    var message: String { kind == .stopTracking ? "这不会取消 LibTV 远端任务，也不会触发重新提交。任务将进入待人工确认。" : "此操作会写入人工确认记录，请先核对 LibTV 远端结果。" }
}
