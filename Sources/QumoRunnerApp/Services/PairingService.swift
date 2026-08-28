import Foundation

struct PairingResult {
    let runnerID: String
    let displayName: String?
}

struct PairingService {
    private struct ExchangeRequest: Encodable {
        let pairingCode: String
        let displayName: String
        let hostname: String
        let version: String
        let capabilities: [String]

        enum CodingKeys: String, CodingKey {
            case pairingCode = "pairing_code"
            case displayName = "display_name"
            case hostname, version, capabilities
        }
    }

    private struct ExchangeResponse: Decodable {
        let runnerID: String
        let deviceToken: String
        let displayName: String?

        enum CodingKeys: String, CodingKey {
            case runnerID = "runner_id"
            case deviceToken = "device_token"
            case displayName = "display_name"
        }
    }

    private struct UnifiedResponse<Payload: Decodable>: Decodable {
        let code: Int
        let message: String
        let data: Payload
        let requestID: String?

        enum CodingKeys: String, CodingKey {
            case code, message, data
            case requestID = "request_id"
        }
    }

    func exchange(serverURL: URL, pairingCode: String) async throws -> PairingResult {
        let endpoint = serverURL.appending(path: "api/canvas/v1/runner-pairings/exchange")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        request.httpBody = try JSONEncoder().encode(ExchangeRequest(
            pairingCode: pairingCode,
            displayName: Host.current().localizedName ?? "Qumo Runner",
            hostname: ProcessInfo.processInfo.hostName,
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
            capabilities: ["libtv", "artifact_upload", "multi_profile"]
        ))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PairingError.invalidResponse }
        guard 200..<300 ~= http.statusCode else { throw PairingError.rejected(http.statusCode) }
        let envelope = try JSONDecoder().decode(UnifiedResponse<ExchangeResponse>.self, from: data)
        guard envelope.code == 0 else { throw PairingError.server(envelope.message) }
        let exchange = envelope.data
        try KeychainStore().saveDeviceToken(exchange.deviceToken, runnerID: exchange.runnerID)
        return PairingResult(runnerID: exchange.runnerID, displayName: exchange.displayName)
    }
}

enum PairingError: LocalizedError {
    case invalidResponse
    case rejected(Int)
    case server(String)
    var errorDescription: String? {
        switch self {
        case .invalidResponse: "配对服务返回无效响应"
        case .rejected(let status): status == 410 ? "配对码已过期或已使用" : "配对失败（HTTP \(status)）"
        case .server(let message): "配对失败：\(message)"
        }
    }
}
