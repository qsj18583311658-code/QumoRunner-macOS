import Foundation

actor RunnerAgentClient {
    static let shared = RunnerAgentClient()
    private var connection: NSXPCConnection?
    private var connectionID: UUID?

    private func makeConnection() -> NSXPCConnection {
        if let connection { return connection }
        let newConnection = NSXPCConnection(machServiceName: runnerAgentMachServiceName)
        let newConnectionID = UUID()
        newConnection.remoteObjectInterface = NSXPCInterface(with: RunnerAgentXPCProtocol.self)
        newConnection.interruptionHandler = {
            Task { self.discard(id: newConnectionID) }
        }
        newConnection.invalidationHandler = {
            Task { self.discard(id: newConnectionID) }
        }
        connectionID = newConnectionID
        newConnection.resume()
        connection = newConnection
        return newConnection
    }

    private func discard(id candidateID: UUID) {
        guard connectionID == candidateID, let activeConnection = connection else { return }
        activeConnection.interruptionHandler = nil
        activeConnection.invalidationHandler = nil
        activeConnection.invalidate()
        self.connection = nil
        connectionID = nil
    }

    func fetchSnapshot() async throws -> RunnerSnapshot {
        let connection = makeConnection()
        return try await withCheckedThrowingContinuation { continuation in
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                continuation.resume(throwing: error)
            } as? RunnerAgentXPCProtocol
            guard let proxy else {
                continuation.resume(throwing: RunnerAgentClientError.unavailable)
                return
            }
            proxy.fetchSnapshot { data in
                do { continuation.resume(returning: try JSONDecoder.runner.decode(RunnerSnapshot.self, from: data)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    func command(_ name: String, payload: [String: String] = [:]) async throws -> AgentCommandResponse {
        let connection = makeConnection()
        let data = try JSONEncoder().encode(payload)
        return try await withCheckedThrowingContinuation { continuation in
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                continuation.resume(throwing: error)
            } as? RunnerAgentXPCProtocol
            guard let proxy else {
                continuation.resume(throwing: RunnerAgentClientError.unavailable)
                return
            }
            proxy.performCommand(name, payload: data) { responseData in
                do { continuation.resume(returning: try JSONDecoder().decode(AgentCommandResponse.self, from: responseData)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}

enum RunnerAgentClientError: LocalizedError {
    case unavailable
    case invalidResponse
    case commandRejected(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: "无法连接 QumoRunnerAgent。请在设置中启动后台服务。"
        case .invalidResponse: "后台未返回完整的 Chrome 授权信息。"
        case .commandRejected(let message): message
        }
    }
}

extension JSONDecoder {
    static var runner: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
