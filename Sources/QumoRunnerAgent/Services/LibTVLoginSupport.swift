import Foundation

enum LibTVProcessTimeoutPolicy {
    // Metadata commands should fail quickly so a broken login cannot stall the agent loop.
    static let metadata: Duration = .seconds(60)

    // `libtv node --run` is synchronous and may legitimately wait for a remote image or video.
    // Keep this separate from metadata timeouts: profile runners are also reused for generation.
    static let generation: Duration = .seconds(30 * 60)
}

struct LibTVAccountMetadata: Equatable, Sendable {
    let accountRef: String
    let displayName: String
}

enum LibTVAccountMetadataParser {
    static func parse(output: String, fallbackAccountRef: String, fallbackDisplayName: String) -> LibTVAccountMetadata {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start <= end,
              let data = String(output[start...end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .init(accountRef: fallbackAccountRef, displayName: fallbackDisplayName)
        }
        let active = object["activeAccount"] as? [String: Any]
        let user = object["user"] as? [String: Any]
        return .init(
            accountRef: scalarString(active?["accountId"]) ?? scalarString(object["accountId"]) ?? fallbackAccountRef,
            displayName: nonEmptyString(active?["accountName"]) ?? nonEmptyString(user?["nickname"]) ?? fallbackDisplayName
        )
    }

    private static func scalarString(_ value: Any?) -> String? {
        if let value = value as? String { return value.isEmpty ? nil : value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }
}

enum LibTVLoginURLValidator {
    private static let allowedDomains = ["liblib.art", "liblib.tv", "liblib.ai"]

    static func firstOfficialURL(in text: String) -> URL? {
        guard let regex = try? NSRegularExpression(pattern: "https?://[^\\s\\\"'<>]+") else { return nil }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches {
            guard let range = Range(match.range, in: text),
                  let url = URL(string: String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: ").,;"))),
                  url.scheme?.lowercased() == "https",
                  let host = url.host?.lowercased(),
                  allowedDomains.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) else {
                continue
            }
            return url
        }
        return nil
    }
}
