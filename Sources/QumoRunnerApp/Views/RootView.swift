import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: RunnerAppStore
    @EnvironmentObject private var launchAgent: LaunchAgentManager
    @State private var selection: SidebarItem? = .overview

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.title, systemImage: item.icon).tag(item)
            }
            .navigationTitle("Qumo Runner")
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 8) {
                    Circle().fill(store.snapshot.serviceState.color).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(store.snapshot.serviceState.title).font(.caption.weight(.medium))
                        Text(launchAgent.statusText).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(12)
                .background(.bar)
            }
        } detail: {
            content
                .toolbar { toolbarContent }
        }
        .navigationSplitViewStyle(.balanced)
        .alert("Qumo Runner", isPresented: messageIsPresented) {
            Button("好") { store.operationMessage = nil }
        } message: {
            Text(store.operationMessage ?? "")
        }
    }

    @ViewBuilder private var content: some View {
        if selection == .settings {
            SettingsView()
        } else {
            switch store.loadingState {
            case .loading:
                LoadingStateView(message: "正在连接后台服务…")
            case .failed(let message):
                ErrorStateView(message: message) { Task { await store.refresh() } }
            case .loaded:
                loadedContent
            }
        }
    }

    @ViewBuilder private var loadedContent: some View {
            switch selection ?? .overview {
            case .overview: OverviewView()
            case .jobs: JobsView()
            case .accounts: AccountsView()
            case .models: ModelsView()
            case .logs: LogsView()
            case .settings: SettingsView()
            }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if store.isPerformingOperation { ProgressView().controlSize(.small) }
            Button {
                Task { await store.setPaused(store.snapshot.serviceState != .paused) }
            } label: {
                Label(store.snapshot.serviceState == .paused ? "继续领取" : "暂停领取", systemImage: store.snapshot.serviceState == .paused ? "play.fill" : "pause.fill")
            }
            .help(store.snapshot.serviceState == .paused ? "恢复领取新任务" : "只停止领取新任务，已运行任务继续")
            Button { Task { await store.refresh() } } label: { Label("刷新", systemImage: "arrow.clockwise") }
        }
    }

    private var messageIsPresented: Binding<Bool> {
        Binding(get: { store.operationMessage != nil }, set: { if !$0 { store.operationMessage = nil } })
    }
}
