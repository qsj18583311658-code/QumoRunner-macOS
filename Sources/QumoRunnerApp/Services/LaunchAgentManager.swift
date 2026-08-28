import Foundation
@preconcurrency import ServiceManagement

@MainActor
final class LaunchAgentManager: ObservableObject {
    static let shared = LaunchAgentManager()
    private let service = SMAppService.agent(plistName: "com.qumo.runner.agent.plist")

    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published private(set) var lastError: String?

    private init() { refresh() }

    func refresh() {
        status = service.status
    }

    func register() async -> Bool {
        do {
            try service.register()
            lastError = nil
            refresh()
            return true
        } catch {
            lastError = error.localizedDescription
            refresh()
            return false
        }
    }

    func unregister() async -> Bool {
        do {
            try await service.unregister()
            lastError = nil
            refresh()
            return true
        } catch {
            lastError = error.localizedDescription
            refresh()
            return false
        }
    }

    var isRegistered: Bool { status == .enabled }

    var statusText: String {
        switch status {
        case .enabled: "已启用"
        case .requiresApproval: "需要在系统设置中批准"
        case .notFound: "未找到内嵌服务"
        case .notRegistered: "未启用"
        @unknown default: "未知"
        }
    }
}
