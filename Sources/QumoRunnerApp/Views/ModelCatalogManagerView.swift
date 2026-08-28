import SwiftUI

struct ModelsView: View {
    @EnvironmentObject private var store: RunnerAppStore
    @State private var searchText = ""
    @State private var statusFilter = CatalogStatusFilter.all
    @State private var modalityFilter = CatalogModalityFilter.all
    @State private var selectedModelRefs = Set<String>()
    @State private var pendingBatchOperation: PendingModelBatchOperation?
    @State private var isApplyingBatch = false

    private var accounts: [RunnerAccount] {
        store.snapshot.accounts.filter { $0.accountRef != "pending" }
    }

    private var models: [RunnerGlobalModelCatalogItem] {
        RunnerGlobalModelCatalogItem.aggregate(accounts: accounts)
    }

    private var visibleModels: [RunnerGlobalModelCatalogItem] {
        models
            .filter(statusFilter.matches)
            .filter(modalityFilter.matches)
            .filter { model in
                let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !query.isEmpty else { return true }
                return model.displayName.localizedCaseInsensitiveContains(query)
                    || model.modelRef.localizedCaseInsensitiveContains(query)
            }
    }

    private var sections: [CatalogSection] {
        Dictionary(grouping: visibleModels, by: \.primaryModality)
            .map { CatalogSection(modality: $0.key, models: $0.value) }
            .sorted { lhs, rhs in
                let lhsIndex = RunnerModelCatalogItem.modalityOrder.firstIndex(of: lhs.modality) ?? .max
                let rhsIndex = RunnerModelCatalogItem.modalityOrder.firstIndex(of: rhs.modality) ?? .max
                return lhsIndex == rhsIndex ? lhs.title < rhs.title : lhsIndex < rhsIndex
            }
    }

    private var pendingCount: Int {
        models.filter { $0.approvalState == .pending || $0.approvalState == .changed }.count
    }

    private var syncedAccountCount: Int {
        accounts.filter { $0.catalogRevision != nil || !$0.models.isEmpty }.count
    }

    private var catalogErrors: [(name: String, message: String)] {
        accounts.compactMap { account in account.catalogError.map { (account.displayName, $0) } }
    }

    private var selectedModels: [RunnerGlobalModelCatalogItem] {
        models.filter { selectedModelRefs.contains($0.modelRef) }
    }

    private var selectableModelRefs: Set<String> {
        Set(models.filter { !$0.activeOccurrences.isEmpty }.map(\.modelRef))
    }
    private var visibleModelRefs: Set<String> {
        Set(visibleModels.filter { !$0.activeOccurrences.isEmpty }.map(\.modelRef))
    }
    private var allVisibleSelected: Bool {
        !visibleModelRefs.isEmpty && visibleModelRefs.isSubset(of: selectedModelRefs)
    }
    private var batchInProgress: Bool { isApplyingBatch || store.modelBatchProgress != nil }

    var body: some View {
        VStack(spacing: 0) {
            ModelCatalogHeader(
                accounts: accounts,
                modelCount: models.count,
                pendingCount: pendingCount,
                syncedAccountCount: syncedAccountCount
            )
            Divider()
            filters
            Divider()
            catalogList
        }
        .navigationTitle("模型")
        .confirmationDialog(
            batchConfirmationTitle,
            isPresented: batchConfirmationPresented,
            titleVisibility: .visible
        ) {
            if let operation = pendingBatchOperation {
                Button(operation.action.confirmTitle, role: operation.action == .disable ? .destructive : nil) {
                    applyBatch(operation)
                }
            }
            Button("取消", role: .cancel) { pendingBatchOperation = nil }
        } message: {
            Text(batchConfirmationMessage)
        }
        .onChange(of: selectableModelRefs) { _, current in
            selectedModelRefs.formIntersection(current)
        }
    }

    private var filters: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索模型名称或标识", text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("清除搜索")
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

                Picker("状态", selection: $statusFilter) {
                    ForEach(CatalogStatusFilter.allCases) { filter in
                        Text(filter.title(models: models)).tag(filter)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 310)
            }

            HStack {
                Picker("模型类型", selection: $modalityFilter) {
                    ForEach(CatalogModalityFilter.available(for: models)) { filter in
                        Text(filter.title(models: models)).tag(filter)
                    }
                }
                .pickerStyle(.menu)
                Text("显示 \(visibleModels.count) 个结果")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let firstError = catalogErrors.first {
                    Label("\(firstError.name)：\(firstError.message)", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .help(catalogErrors.map { "\($0.name)：\($0.message)" }.joined(separator: "\n"))
                }
            }

            HStack(spacing: 10) {
                Button {
                    if allVisibleSelected { selectedModelRefs.subtract(visibleModelRefs) }
                    else { selectedModelRefs.formUnion(visibleModelRefs) }
                } label: {
                    Label(
                        allVisibleSelected ? "取消选择当前结果" : "全选当前结果",
                        systemImage: allVisibleSelected ? "checkmark.square.fill" : "checkmark.square"
                    )
                }
                .disabled(visibleModelRefs.isEmpty || batchInProgress || store.isPerformingOperation)

                if !selectedModelRefs.isEmpty {
                    Button("清除选择") { selectedModelRefs.removeAll() }
                        .disabled(batchInProgress)
                }

                Spacer()
                if !selectedModelRefs.isEmpty {
                    if batchInProgress { ProgressView().controlSize(.small) }
                    Text(store.modelBatchProgress?.title ?? "已选 \(selectedModelRefs.count) 个模型")
                        .font(.subheadline.weight(.medium))
                    Button("批量停用 \(disableModelCount)") { prepareBatch(.disable) }
                        .disabled(disableTargetCount == 0 || batchInProgress || store.isPerformingOperation)
                    Button("批量启用 \(enableModelCount)") { prepareBatch(.enable) }
                        .buttonStyle(.borderedProminent)
                        .disabled(enableTargetCount == 0 || batchInProgress || store.isPerformingOperation)
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var catalogList: some View {
        if sections.isEmpty {
            ContentUnavailableView(
                models.isEmpty ? "尚未同步模型" : "没有匹配的模型",
                systemImage: models.isEmpty ? "square.grid.2x2" : "magnifyingglass",
                description: Text(models.isEmpty ? "点击“刷新全部目录”，从 LibTV 读取模型目录。" : "尝试更换状态、模型类型或搜索关键词。")
            )
        } else {
            List {
                ForEach(sections) { section in
                    Section {
                        ForEach(section.models) { model in
                            GlobalModelCatalogRow(
                                model: model,
                                totalAccountCount: accounts.count,
                                isSelected: selectionBinding(for: model.modelRef),
                                selectionDisabled: model.activeOccurrences.isEmpty || batchInProgress || store.isPerformingOperation
                            )
                        }
                    } header: {
                        Label("\(section.title) · \(section.models.count)", systemImage: section.symbol)
                            .font(.subheadline.weight(.semibold))
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private var enableTargetCount: Int {
        selectedModels.reduce(0) { count, model in
            count + model.activeOccurrences.filter {
                $0.model.approvalState == .pending || $0.model.approvalState == .changed
            }.count
        }
    }

    private var disableTargetCount: Int {
        selectedModels.reduce(0) { count, model in
            count + model.activeOccurrences.filter { $0.model.approvalState == .approved }.count
        }
    }

    private var enableModelCount: Int {
        selectedModels.filter { model in
            model.activeOccurrences.contains {
                $0.model.approvalState == .pending || $0.model.approvalState == .changed
            }
        }.count
    }

    private var disableModelCount: Int {
        selectedModels.filter { $0.approvedOccurrenceCount > 0 }.count
    }

    private var batchConfirmationPresented: Binding<Bool> {
        Binding(
            get: { pendingBatchOperation != nil },
            set: { if !$0 { pendingBatchOperation = nil } }
        )
    }

    private var batchConfirmationTitle: String {
        guard let operation = pendingBatchOperation else { return "确认批量操作？" }
        return "\(operation.action.title) \(operation.plan.modelCount) 个模型？"
    }

    private var batchConfirmationMessage: String {
        guard let operation = pendingBatchOperation else { return "" }
        let conflict = operation.plan.schemaConflictCount > 0 ? "其中 \(operation.plan.schemaConflictCount) 个模型存在多个 Schema。" : ""
        return "将更新 \(operation.plan.configurationCount) 项账号模型配置。\(conflict)每项仍会校验确认时的 Schema；部分失败时成功项不会回滚。"
    }

    private func selectionBinding(for modelRef: String) -> Binding<Bool> {
        Binding(
            get: { selectedModelRefs.contains(modelRef) },
            set: { selected in
                if selected { selectedModelRefs.insert(modelRef) }
                else { selectedModelRefs.remove(modelRef) }
            }
        )
    }

    private func prepareBatch(_ action: ModelBatchAction) {
        pendingBatchOperation = PendingModelBatchOperation(
            action: action,
            plan: RunnerModelBatchPlan.make(models: selectedModels, approved: action == .enable)
        )
    }

    private func applyBatch(_ operation: PendingModelBatchOperation) {
        pendingBatchOperation = nil
        isApplyingBatch = true
        Task {
            let result = await store.setGlobalModelApprovals(
                expectedSchemaHashesByModel: operation.plan.expectedSchemaHashesByModel,
                approved: operation.action == .enable
            )
            selectedModelRefs.subtract(result.requestedModelRefs.subtracting(result.failedModelRefs))
            selectedModelRefs.formIntersection(selectableModelRefs)
            isApplyingBatch = false
        }
    }
}
