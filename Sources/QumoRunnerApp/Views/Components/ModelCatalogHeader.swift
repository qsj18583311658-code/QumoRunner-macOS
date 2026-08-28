import SwiftUI

struct ModelCatalogHeader: View {
    @EnvironmentObject private var store: RunnerAppStore
    let accounts: [RunnerAccount]
    let modelCount: Int
    let pendingCount: Int
    let syncedAccountCount: Int

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            SectionHeader(title: "模型", subtitle: "按模型统一管理；启停会安全同步到所有包含该模型的账号")
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text("\(modelCount) 个模型 · 已同步 \(syncedAccountCount)/\(accounts.count) 个账号")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if pendingCount > 0 {
                    Text("\(pendingCount) 个模型待处理")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            if accounts.contains(where: \.catalogRefreshing) { ProgressView().controlSize(.small) }
            Button { Task { await store.refreshAllModelCatalogs() } } label: {
                Label("刷新全部目录", systemImage: "arrow.clockwise")
            }
            .disabled(accounts.isEmpty || accounts.contains(where: \.catalogRefreshing) || store.isPerformingOperation)
        }
        .padding(22)
    }
}
