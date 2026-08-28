import Foundation
import RunnerCore

private final class ReplyBox<Value>: @unchecked Sendable {
    let reply: (Value) -> Void
    init(_ reply: @escaping (Value) -> Void) { self.reply = reply }
}

final class RunnerAgentService: NSObject, RunnerAgentXPCProtocol, @unchecked Sendable {
    private let runtime: AgentRuntime
    private let login: LoginSessionCoordinator
    private let runTask: Task<Void, Never>

    @MainActor
    override init() {
        let root = AgentConfigurationStore().root
        let insights = AccountInsightCoordinator(root: root)
        let runtime = AgentRuntime(root: root, insights: insights)
        self.runtime = runtime
        self.login = LoginSessionCoordinator(
            registry: runtime.profileRegistry,
            onLoginCompleted: { profileRef in
                Task { await runtime.didCompleteLogin(profileRef: profileRef) }
            },
            onProfileDiscarded: { profileRef in
                Task { await runtime.didDiscardProfile(profileRef: profileRef) }
            }
        )
        self.runTask = Task { await runtime.runForever() }
        super.init()
    }

    deinit { runTask.cancel() }

    func fetchSnapshot(reply: @escaping (Data) -> Void) {
        let reply = ReplyBox(reply)
        Task { reply.reply(await runtime.snapshotData()) }
    }

    func performCommand(_ command: String, payload: Data, reply: @escaping (Data) -> Void) {
        let reply = ReplyBox(reply)
        let values = (try? JSONDecoder().decode([String: String].self, from: payload)) ?? [:]
        Task {
            if command == "login_status" {
                guard let profileRef = values["profile_ref"] else {
                    reply.reply(Self.encode(.init(accepted: false, message: "缺少 Profile 标识。", status: LoginSessionPhase.failed.rawValue)))
                    return
                }
                let status = login.status(profileRef: profileRef)
                reply.reply(Self.encode(.init(
                    accepted: status.phase == .waiting || status.phase == .succeeded,
                    message: status.message,
                    status: status.phase.rawValue,
                    profileRef: profileRef
                )))
                return
            }
            if command == "cancel_login" {
                guard let profileRef = values["profile_ref"] else {
                    reply.reply(Self.encode(.init(accepted: false, message: "缺少 Profile 标识。")))
                    return
                }
                login.cancel(profileRef: profileRef)
                reply.reply(Self.encode(.init(accepted: true, message: "账号授权已取消并回滚。", status: LoginSessionPhase.failed.rawValue, profileRef: profileRef)))
                return
            }
            if command == "discard_pending_profile" {
                guard let profileRef = values["profile_ref"] else {
                    reply.reply(Self.encode(.init(accepted: false, message: "缺少 Profile 标识。")))
                    return
                }
                login.cancel(profileRef: profileRef)
                do {
                    let message = try await runtime.perform(command: command, values: values)
                    reply.reply(Self.encode(.init(accepted: true, message: message, profileRef: profileRef)))
                } catch {
                    reply.reply(Self.encode(.init(accepted: false, message: error.localizedDescription, profileRef: profileRef)))
                }
                return
            }
            if command == "add_profile" || command == "relogin_profile" || command == "authorize_chrome_profile" || command == "open_web_login" {
                var prepared: (RunnerProfile, ProfilePaths)?
                do {
                    let requested = command == "add_profile" ? nil : values["profile_ref"]
                    prepared = try await runtime.ensureProfile(requestedRef: requested)
                    guard let prepared else { throw AgentRuntimeError.profileUnavailable }
                    let url = try await login.begin(profile: prepared.0, paths: prepared.1)
                    reply.reply(Self.encode(.init(
                        accepted: true,
                        message: "等待专属 Chrome 窗口完成 LibTV 官方授权。",
                        actionURL: url,
                        status: LoginSessionPhase.waiting.rawValue,
                        profileRef: prepared.0.profileRef
                    )))
                } catch {
                    if let prepared, prepared.0.accountRef == "pending" {
                        try? runtime.profileRegistry.discardPending(profileRef: prepared.0.profileRef)
                        await runtime.didDiscardProfile(profileRef: prepared.0.profileRef)
                    }
                    reply.reply(Self.encode(.init(accepted: false, message: error.localizedDescription, actionURL: nil)))
                }
                return
            }
            do {
                let message = try await runtime.perform(command: command, values: values)
                reply.reply(Self.encode(.init(accepted: true, message: message, actionURL: nil)))
            } catch {
                reply.reply(Self.encode(.init(accepted: false, message: error.localizedDescription, actionURL: nil)))
            }
        }
    }

    func ping(reply: @escaping (String) -> Void) { reply("QumoRunnerAgent/0.1.0") }

    private static func encode(_ response: AgentCommandResponse) -> Data {
        (try? JSONEncoder().encode(response)) ?? Data()
    }
}

final class RunnerAgentListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service: RunnerAgentService

    @MainActor override init() {
        service = RunnerAgentService()
        super.init()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: RunnerAgentXPCProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}
