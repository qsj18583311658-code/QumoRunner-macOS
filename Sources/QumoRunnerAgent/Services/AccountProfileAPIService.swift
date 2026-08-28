import Foundation
import RunnerCore

/// Reads account insights with the credential produced by `libtv login web`.
/// The credential stays in the isolated Profile and is never returned through XPC.
actor AccountProfileAPIService {
    private struct APIResponse: Sendable {
        let url: String
        let data: Data
    }

    private static let memberAccountURL = URL(string: "https://api2.liblib.art/api/www/member/account?isApp=false")!
    private static let memberPowerURL = URL(string: "https://api2.liblib.art/api/www/member/memberPower/list")!

    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieAcceptPolicy = .never
            configuration.httpShouldSetCookies = false
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 30
            self.session = URLSession(configuration: configuration)
        }
    }

    func load(using runner: LibTVProcessRunner) async throws -> WebPagePayload {
        let homeURL = await runner.homeURL
        let credentialsURL = homeURL
            .appendingPathComponent(".libtv", isDirectory: true)
            .appendingPathComponent("credentials.json", isDirectory: false)
        let credentials = try Self.readCredentials(at: credentialsURL)

        async let account = request(Self.memberAccountURL, token: credentials.token)
        async let memberPower = request(Self.memberPowerURL, token: credentials.token)
        let rawResponses = try await [account, memberPower]
        let responses = try rawResponses.map { response -> [String: Any] in
            guard let body = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
                throw WebInsightFailure.parse("Liblib 账号接口返回了无法解码的 JSON。")
            }
            return ["url": response.url, "body": body]
        }

        var envelope: [String: Any] = ["apiResponses": responses]
        if let accountRef = credentials.accountRef { envelope["activeAccountId"] = accountRef }
        let embedded = try JSONSerialization.data(withJSONObject: envelope)
        let bodies = responses.compactMap { response in
            (response["body"] as? [String: Any]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        }

        return WebPagePayload(
            url: Self.memberAccountURL.absoluteString,
            title: "Liblib account APIs",
            bodyText: bodies.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n"),
            embeddedJSON: String(decoding: embedded, as: UTF8.self)
        )
    }

    private func request(_ url: URL, token: String) async throws -> APIResponse {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(token, forHTTPHeaderField: "token")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw WebInsightFailure.transient("连接 Liblib 账号接口失败：\(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw WebInsightFailure.transient("Liblib 账号接口未返回 HTTP 响应。")
        }
        if http.statusCode == 401 || http.statusCode == 403 { throw WebInsightFailure.webAuthRequired }
        if http.statusCode == 429 || http.statusCode >= 500 {
            throw WebInsightFailure.transient("Liblib 账号接口返回 HTTP \(http.statusCode)。")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw WebInsightFailure.permanent("Liblib 账号接口返回 HTTP \(http.statusCode)。")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WebInsightFailure.parse("Liblib 账号接口返回了无法解码的 JSON。")
        }
        let code = (object["code"] as? NSNumber)?.intValue ?? -1
        if code == 401 { throw WebInsightFailure.webAuthRequired }
        guard code == 0 else {
            let message = object["msg"] as? String ?? "未知错误"
            throw WebInsightFailure.transient("Liblib 账号接口返回 code \(code)：\(message)")
        }
        return APIResponse(url: url.absoluteString, data: data)
    }

    private static func readCredentials(at url: URL) throws -> (token: String, accountRef: String?) {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = object["usertoken"] as? String,
              !token.isEmpty else {
            throw WebInsightFailure.webAuthRequired
        }
        let accountRef: String?
        if let value = object["activeAccountId"] as? String {
            accountRef = value
        } else if let value = object["activeAccountId"] as? NSNumber {
            accountRef = value.stringValue
        } else {
            accountRef = nil
        }
        return (token, accountRef)
    }
}
