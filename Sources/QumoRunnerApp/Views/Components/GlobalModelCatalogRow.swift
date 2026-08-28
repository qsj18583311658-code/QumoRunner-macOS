import SwiftUI

struct GlobalModelCatalogRow: View {
    @EnvironmentObject private var store: RunnerAppStore
    let model: RunnerGlobalModelCatalogItem
    let totalAccountCount: Int
    @Binding var isSelected: Bool
    let selectionDisabled: Bool
    @State private var updating = false

    var body: some View {
        HStack(spacing: 12) {
            Button { isSelected.toggle() } label: {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 17))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(selectionDisabled)
            .accessibilityLabel(isSelected ? "取消选择 \(model.displayName)" : "选择 \(model.displayName)")

            VStack(alignment: .leading, spacing: 4) {
                Text(model.displayName).font(.subheadline.weight(.medium)).lineLimit(1)
                HStack(spacing: 7) {
                    Text(model.modelRef)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                    Text("·")
                    Text(coverageText)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if model.hasSchemaConflict {
                StateBadge(title: "\(model.schemaVariantCount) 个 Schema", color: .orange)
                    .help("不同账号返回了不同 schema；启用时仍会分别绑定各账号的当前 schema。")
            }
            StateBadge(title: stateTitle, color: model.approvalState.color)
            if model.approvalState == .pending || model.approvalState == .changed {
                Button { updateApproval(true) } label: {
                    if updating { ProgressView().controlSize(.small) } else { Text("启用") }
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            } else if model.approvalState == .approved {
                Button { updateApproval(false) } label: {
                    if updating { ProgressView().controlSize(.small) } else { Text("停用") }
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
        .disabled(updating || selectionDisabled)
    }

    private var coverageText: String {
        let activeCount = model.activeOccurrences.count
        let coverage = activeCount == totalAccountCount ? "\(activeCount) 个账号" : "覆盖 \(activeCount)/\(totalAccountCount) 个账号"
        return "\(coverage)，已启用 \(model.approvedOccurrenceCount)/\(activeCount)"
    }

    private var stateTitle: String {
        if model.approvalState == .pending, model.approvedOccurrenceCount > 0 { return "部分启用" }
        return model.approvalState.title
    }

    private func updateApproval(_ approved: Bool) {
        guard !updating else { return }
        updating = true
        let expectedSchemaHashes = Dictionary(uniqueKeysWithValues: model.activeOccurrences.map {
            ($0.profileRef, $0.model.schemaHash)
        })
        Task {
            await store.setGlobalModelApproval(
                modelRef: model.modelRef,
                expectedSchemaHashes: expectedSchemaHashes,
                approved: approved
            )
            updating = false
        }
    }
}
