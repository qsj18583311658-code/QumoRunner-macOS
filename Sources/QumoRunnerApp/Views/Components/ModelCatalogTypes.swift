import Foundation

enum ModelBatchAction {
    case enable, disable
    var title: String { self == .enable ? "批量启用" : "批量停用" }
    var confirmTitle: String { self == .enable ? "确认启用" : "确认停用" }
}

struct PendingModelBatchOperation {
    let action: ModelBatchAction
    let plan: RunnerModelBatchPlan
}

enum CatalogStatusFilter: String, CaseIterable, Identifiable {
    case attention, approved, all
    var id: String { rawValue }

    func matches(_ model: RunnerGlobalModelCatalogItem) -> Bool {
        switch self {
        case .attention: model.approvalState == .pending || model.approvalState == .changed
        case .approved: model.approvalState == .approved
        case .all: true
        }
    }

    func title(models: [RunnerGlobalModelCatalogItem]) -> String {
        let count = models.filter(matches).count
        return switch self {
        case .attention: "待处理 \(count)"
        case .approved: "已启用 \(count)"
        case .all: "全部 \(models.count)"
        }
    }
}

enum CatalogModalityFilter: String, CaseIterable, Identifiable {
    case all, image, video, audio, text, script, storyboard, other
    var id: String { rawValue }

    func matches(_ model: RunnerGlobalModelCatalogItem) -> Bool {
        self == .all || model.primaryModality == rawValue
    }

    func title(models: [RunnerGlobalModelCatalogItem]) -> String {
        let count = self == .all ? models.count : models.filter(matches).count
        return "\(self == .all ? "全部类型" : RunnerModelCatalogItem.modalityTitle(rawValue)) \(count)"
    }

    static func available(for models: [RunnerGlobalModelCatalogItem]) -> [Self] {
        let values = Set(models.map(\.primaryModality))
        return allCases.filter { $0 == .all || values.contains($0.rawValue) }
    }
}

struct CatalogSection: Identifiable {
    let modality: String
    let models: [RunnerGlobalModelCatalogItem]
    var id: String { modality }
    var title: String { RunnerModelCatalogItem.modalityTitle(modality) }
    var symbol: String {
        switch modality {
        case "image": "photo"
        case "video": "video"
        case "audio": "waveform"
        case "text": "text.alignleft"
        case "script": "doc.text"
        case "storyboard": "rectangle.3.group"
        default: "square.grid.2x2"
        }
    }
}
