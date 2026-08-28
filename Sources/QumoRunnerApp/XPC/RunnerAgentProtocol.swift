import Foundation

let runnerAgentMachServiceName = "com.qumo.runner.agent.service"

@objc protocol RunnerAgentXPCProtocol {
    func fetchSnapshot(reply: @escaping (Data) -> Void)
    func performCommand(_ command: String, payload: Data, reply: @escaping (Data) -> Void)
    func ping(reply: @escaping (String) -> Void)
}

struct AgentCommandResponse: Codable {
    let accepted: Bool
    let message: String
    let actionURL: URL?
    let status: String?
    let profileRef: String?

    init(accepted: Bool, message: String, actionURL: URL? = nil, status: String? = nil, profileRef: String? = nil) {
        self.accepted = accepted
        self.message = message
        self.actionURL = actionURL
        self.status = status
        self.profileRef = profileRef
    }
}
