import Foundation

/// Official discovery is independent of the bundled recovery binary. Never infer
/// "latest" from a failed request, or downgrade when the channel manifest lags.
public struct LibTVUpdateStatus: Codable, Sendable, Equatable {
    public var channelVersion: String?
    public var websiteVersion: String?
    public var manifestVersion: String?
    public var sourceNote: String?
    public var checkedAt: Date?
    public var checkError: String?
    public var phase: String = "idle"
    public var targetVersion: String?
    public var message: String?
    public var previousVersion: String?

    public init() {}
    public var isBusy: Bool { ["downloading", "waiting", "activating"].contains(phase) }
    public func availableVersion(current: String?) -> String? {
        guard let channelVersion, let current,
              LibTVReleaseVersion.isNewer(channelVersion, than: current) else { return nil }
        return channelVersion
    }
}

public enum LibTVReleaseVersion {
    public static func components(_ value: String) -> [Int]? {
        guard value.range(of: #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$"#, options: .regularExpression) != nil else { return nil }
        let values = value.split(separator: ".").compactMap { Int($0) }
        return values.count == 3 ? values : nil
    }

    public static func isNewer(_ value: String, than current: String) -> Bool {
        guard let lhs = components(value), let rhs = components(current) else { return false }
        return rhs.lexicographicallyPrecedes(lhs)
    }

    public static func release(_ version: String) throws -> LibTVRuntimeRelease {
        guard components(version) != nil else {
            throw LibTVUpdateError.invalidVersion
        }
        return LibTVRuntimeRelease(version: version, archiveURL: URL(string:
            "https://liblibai-web-static.liblib.cloud/cli/\(version)/libtv-macos-arm64.zip")!)
    }
}

public enum LibTVUpdateError: Error, LocalizedError {
    case invalidVersion, invalidManifest, busy, notNewer, drainTimeout
    public var errorDescription: String? {
        switch self {
        case .invalidVersion: "请输入官方稳定版本号，例如 1.1.3。"
        case .invalidManifest: "官方版本清单不可用或格式不正确；无法确认最新版本。"
        case .busy: "CLI 更新或版本验证正在进行，请等待完成。"
        case .notNewer: "目标版本必须高于当前版本；需要降级时请使用回滚。"
        case .drainTimeout: "等待任务结束超过 30 分钟，更新已取消；现有任务继续使用原版本。"
        }
    }
}

public struct LibTVUpdateClient: Sendable {
    public static let manifestURL = URL(string: "https://liblibai-web-static.liblib.cloud/cli/latest/manifest.json")!
    public init() {}

    public static func parseManifest(_ data: Data) throws -> String {
        struct Manifest: Decodable { let version: String }
        guard data.count <= 65536,
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              LibTVReleaseVersion.components(manifest.version) != nil else {
            throw LibTVUpdateError.invalidManifest
        }
        return manifest.version
    }

    public static let websiteURL = URL(string: "https://www.liblib.tv/cli")!

    /// Only accept explicitly versioned CLI download links on the official page,
    /// never analytics/app versions or instructions embedded in arbitrary scripts.
    public static func parseWebsite(_ data: Data) throws -> String? {
        guard data.count <= 4 * 1024 * 1024, let html = String(data: data, encoding: .utf8),
              html.contains("LibTV"), html.contains("/cli/") else { throw LibTVUpdateError.invalidManifest }
        let pattern = #"https://liblibai-web-static\.liblib\.cloud/cli/([0-9]+\.[0-9]+\.[0-9]+)/libtv-macos-arm64\.zip(?:[\s\"'<>]|$)"#
        let regex = try NSRegularExpression(pattern: pattern)
        let normalized = html.replacingOccurrences(of: #"\/"#, with: "/")
        let source = normalized as NSString
        return regex.matches(in: normalized, range: NSRange(location: 0, length: source.length))
            .compactMap { match -> String? in
                let version = source.substring(with: match.range(at: 1))
                return LibTVReleaseVersion.components(version) == nil ? nil : version
            }.max { LibTVReleaseVersion.isNewer($1, than: $0) }
    }

    public struct Discovery: Sendable {
        public let version: String
        public let websiteVersion: String?
        public let manifestVersion: String?
        public let note: String
    }

    public func latestVersion() async throws -> Discovery {
        async let websiteResult = fetch(Self.websiteURL)
        async let manifestResult = fetch(Self.manifestURL)
        let webData = await websiteResult
        let manifestData = await manifestResult
        let website = try? webData.get()
        let manifest = try? manifestData.get()
        let webVersion = website.flatMap { try? Self.parseWebsite($0) }
        let manifestVersion = manifest.flatMap { try? Self.parseManifest($0) }
        guard let version = [webVersion, manifestVersion].compactMap({ $0 })
            .max(by: { LibTVReleaseVersion.isNewer($1, than: $0) }) else { throw LibTVUpdateError.invalidManifest }
        var notes: [String] = []
        if webVersion == nil {
            notes.append(website == nil ? "官网访问失败，使用下载清单。" : "官网未提供可识别的独立 CLI 版本号，使用下载清单。")
        }
        if manifestVersion == nil { notes.append("下载清单不可用，使用官网版本链接。") }
        if let webVersion, let manifestVersion, webVersion != manifestVersion {
            notes.append("官网与下载清单不同步，提供较新版本；安装时验证官方安装包。")
        }
        return Discovery(version: version, websiteVersion: webVersion, manifestVersion: manifestVersion,
                         note: notes.joined(separator: " "))
    }

    private func fetch(_ url: URL) async -> Result<Data, Error> {
        do {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  http.url == url else { throw LibTVUpdateError.invalidManifest }
            return .success(data)
        } catch { return .failure(error) }
    }
}
