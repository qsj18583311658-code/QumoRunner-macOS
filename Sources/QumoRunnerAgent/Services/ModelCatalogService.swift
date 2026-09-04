import CryptoKit
import Foundation
import RunnerCore

enum ModelCatalogParser {
    private struct SearchEnvelope: Decodable {
        let matches: [SearchItem]
    }

    private struct SearchItem: Decodable {
        let modelKey: String
        let modelName: String?
        let description: String?
        let estimatedTime: String?
        let labels: [String]?
        let requiresWhitelistPermission: Bool?
    }

    static func parseSearch(_ output: String, modality: String) throws -> [CatalogSearchItem] {
        let data = try jsonData(from: output)
        let envelope = try JSONDecoder().decode(SearchEnvelope.self, from: data)
        return envelope.matches.compactMap { item in
            let key = item.modelKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return nil }
            let summary: [String: Any] = [
                "modelKey": key,
                "modelName": item.modelName ?? key,
                "description": item.description ?? "",
                "estimatedTime": item.estimatedTime ?? "",
                "labels": (item.labels ?? []).sorted(),
                "requiresWhitelistPermission": item.requiresWhitelistPermission ?? false,
            ]
            return CatalogSearchItem(
                modelRef: key,
                displayName: item.modelName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? key,
                modality: modality,
                summaryHash: hashJSON(summary)
            )
        }
    }

    static func schemaHash(_ output: String) throws -> String {
        try parseSchema(output).hash
    }

    static func parseSchema(_ output: String) throws -> (hash: String, document: JSONPayloadValue) {
        let data = try jsonData(from: output)
        let document = try JSONDecoder().decode(JSONPayloadValue.self, from: data)
        return (try CanonicalJSON.sha256(document), document)
    }

    static func reconcile(existing: [StoredCatalogItem], incoming: [CatalogCandidate]) -> [StoredCatalogItem] {
        var old = Dictionary(uniqueKeysWithValues: existing.map { ($0.modelRef, $0) })
        var result = incoming.sorted { $0.modelRef < $1.modelRef }.map { candidate -> StoredCatalogItem in
            guard let previous = old.removeValue(forKey: candidate.modelRef) else {
                return StoredCatalogItem(
                    modelRef: candidate.modelRef,
                    displayName: candidate.displayName,
                    modalities: candidate.modalities.sorted(),
                    summaryHash: candidate.summaryHash,
                    schemaHash: candidate.schemaHash,
                    rawSchema: candidate.rawSchema,
                    approvalState: .pending,
                    approved: false,
                    missingRefreshCount: 0
                )
            }
            let schemaChanged = previous.schemaHash != candidate.schemaHash
            return StoredCatalogItem(
                modelRef: candidate.modelRef,
                displayName: candidate.displayName,
                modalities: candidate.modalities.sorted(),
                summaryHash: candidate.summaryHash,
                schemaHash: candidate.schemaHash,
                rawSchema: schemaChanged ? candidate.rawSchema : (candidate.rawSchema ?? previous.rawSchema),
                approvalState: schemaChanged ? .changed : (previous.approved ? .approved : .pending),
                approved: schemaChanged ? false : previous.approved,
                missingRefreshCount: 0
            )
        }
        for var missing in old.values {
            missing.missingRefreshCount += 1
            if missing.missingRefreshCount >= 2 { missing.approvalState = .removed }
            result.append(missing)
        }
        return result.sorted { $0.modelRef < $1.modelRef }
    }

    static func revision(for models: [StoredCatalogItem]) -> String {
        let rows = models.sorted { $0.modelRef < $1.modelRef }.map {
            "\($0.modelRef)|\($0.summaryHash)|\($0.schemaHash)|\($0.approvalState.rawValue)|\($0.approved)|\($0.missingRefreshCount)"
        }
        return sha256(rows.joined(separator: "\n"))
    }

    static func needsSchemaFetch(modelRef: String, summaryHash: String, existing: [StoredCatalogItem], force: Bool = false) -> Bool {
        if force { return true }
        guard let previous = existing.first(where: { $0.modelRef == modelRef }) else { return true }
        guard previous.summaryHash == summaryHash,
              !previous.schemaHash.isEmpty,
              let schema = previous.rawSchema,
              (try? CanonicalJSON.sha256(schema)) == previous.schemaHash else {
            return true
        }
        return false
    }

    private static func jsonData(from output: String) throws -> Data {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start <= end,
              let data = String(output[start...end]).data(using: .utf8) else {
            throw CatalogError.invalidJSON
        }
        return data
    }

    private static func hashJSON(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            return sha256(String(describing: value))
        }
        return sha256(data)
    }

    private static func sha256(_ value: String) -> String { sha256(Data(value.utf8)) }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct CatalogSearchItem: Hashable, Sendable {
    let modelRef: String
    let displayName: String
    let modality: String
    let summaryHash: String
}

struct ModelCatalogService: Sendable {
    static let modalities = ["image", "video", "audio", "text", "script", "storyboard"]

    func fetch(using runner: LibTVProcessRunner, existing: [StoredCatalogItem], forceSchemaRefresh: Bool = false) async throws -> [CatalogCandidate] {
        var grouped: [String: [CatalogSearchItem]] = [:]
        for modality in Self.modalities {
            let result = try await runner.run(arguments: LibTVCLIAdapter.searchModels(modality: modality), timeout: .seconds(90))
            guard result.exitCode == 0, !result.requiresManualReview else {
                throw CatalogError.commandFailed(modality, result.standardError)
            }
            for item in try ModelCatalogParser.parseSearch(result.standardOutput, modality: modality) {
                grouped[item.modelRef, default: []].append(item)
            }
        }
        var candidates: [CatalogCandidate] = []
        for key in grouped.keys.sorted() {
            guard let rows = grouped[key], let first = rows.first else { continue }
            let modalities = Array(Set(rows.map(\.modality))).sorted()
            let summarySeed = rows.sorted { $0.modality < $1.modality }.map { "\($0.modality):\($0.summaryHash)" }.joined(separator: "|")
            let summaryHash = SHA256.hash(data: Data(summarySeed.utf8)).map { String(format: "%02x", $0) }.joined()
            let schemaHash: String
            let rawSchema: JSONPayloadValue?
            if ModelCatalogParser.needsSchemaFetch(modelRef: key, summaryHash: summaryHash, existing: existing, force: forceSchemaRefresh) {
                let schema = try await runner.run(arguments: LibTVCLIAdapter.modelSchema(key), timeout: .seconds(90))
                guard schema.exitCode == 0, !schema.requiresManualReview else {
                    throw CatalogError.schemaFailed(key, schema.standardError)
                }
                let parsed = try ModelCatalogParser.parseSchema(schema.standardOutput)
                schemaHash = parsed.hash
                rawSchema = parsed.document
            } else {
                schemaHash = existing.first(where: { $0.modelRef == key })!.schemaHash
                rawSchema = existing.first(where: { $0.modelRef == key })!.rawSchema
            }
            candidates.append(CatalogCandidate(
                modelRef: key,
                displayName: first.displayName,
                modalities: modalities,
                summaryHash: summaryHash,
                schemaHash: schemaHash,
                rawSchema: rawSchema
            ))
        }
        return candidates
    }
}

enum CatalogError: LocalizedError, Sendable {
    case invalidJSON
    case commandFailed(String, String)
    case schemaFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .invalidJSON: "LibTV 模型目录返回了无法解析的 JSON。"
        case .commandFailed(let modality, let detail): "\(modality) 模型目录查询失败：\(detail)"
        case .schemaFailed(let model, let detail): "\(model) schema 查询失败：\(detail)"
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
