import Darwin
import Foundation
import RunnerCore

actor AccountInsightStore {
    private let fileURL: URL
    private var state: StoredAccountInsights

    init(root: URL) {
        fileURL = root.appending(path: "account-insights.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        state = (try? Data(contentsOf: fileURL)).flatMap { try? decoder.decode(StoredAccountInsights.self, from: $0) } ?? StoredAccountInsights()
    }

    func profile(_ profileRef: String) -> StoredProfileInsight {
        if let value = state.profiles[profileRef] { return value }
        let value = StoredProfileInsight.empty()
        state.profiles[profileRef] = value
        try? persist()
        return value
    }

    func update(_ profileRef: String, _ body: (inout StoredProfileInsight) throws -> Void) throws {
        var value = state.profiles[profileRef] ?? .empty()
        try body(&value)
        let previous = state.profiles[profileRef]
        state.profiles[profileRef] = value
        do { try persist() }
        catch { state.profiles[profileRef] = previous; throw error }
    }

    func remove(_ profileRef: String) throws {
        guard state.profiles.removeValue(forKey: profileRef) != nil else { return }
        try persist()
    }

    func approve(profileRef: String, modelRef: String, expectedSchemaHash: String, approved: Bool) throws {
        try update(profileRef) { profile in
            guard let index = profile.catalog.firstIndex(where: { $0.modelRef == modelRef }),
                  profile.catalog[index].approvalState != .removed else {
                throw AccountInsightStoreError.modelUnavailable
            }
            guard profile.catalog[index].schemaHash == expectedSchemaHash else {
                throw AccountInsightStoreError.modelSchemaChanged
            }
            profile.catalog[index].approved = approved
            profile.catalog[index].approvalState = approved ? .approved : .pending
            profile.catalogRevision = ModelCatalogParser.revision(for: profile.catalog)
        }
    }

    func reconcileCatalog(profileRef: String, incoming: [CatalogCandidate], runtimePath: String? = nil) throws {
        try update(profileRef) { profile in
            let reconciled = ModelCatalogParser.reconcile(existing: profile.catalog, incoming: incoming)
            profile.catalog = reconciled
            profile.catalogRevision = ModelCatalogParser.revision(for: reconciled)
            profile.catalogRefreshedAt = .now
            profile.catalogError = nil
            profile.catalogRuntimePath = runtimePath
        }
    }

    func schemaHash(profileRef: String, modelRef: String) throws -> String {
        guard let profile = state.profiles[profileRef],
              let model = profile.catalog.first(where: { $0.modelRef == modelRef }),
              model.approvalState != .removed else {
            throw AccountInsightStoreError.modelUnavailable
        }
        return model.schemaHash
    }

    func catalogReady(profileRef: String, runtimePath: String) -> Bool {
        state.profiles[profileRef]?.catalogRuntimePath == runtimePath
    }

    func generationSchemas(profileRef: String, runtimePath: String? = nil) -> [LibTVModelSchemaSnapshot] {
        if let runtimePath, !catalogReady(profileRef: profileRef, runtimePath: runtimePath) { return [] }
        guard let profile = state.profiles[profileRef] else { return [] }
        return profile.catalog.compactMap { model in
            guard model.approvalState != .removed, let rawSchema = model.rawSchema else { return nil }
            return LibTVModelSchemaSnapshot(
                modelRef: model.modelRef,
                modelName: model.displayName,
                schemaHash: model.schemaHash,
                rawSchema: rawSchema,
                approved: model.approved && model.approvalState == .approved
            )
        }
    }

    func schemaUpload(
        profileRef: String,
        required: RequiredSchemaUpload
    ) throws -> ProfileModelSchemaUploadRequest {
        guard let profile = state.profiles[profileRef],
              let model = profile.catalog.first(where: {
                  $0.modelRef == required.modelRef && $0.schemaHash == required.schemaHash
              }),
              let schema = model.rawSchema,
              (try? CanonicalJSON.sha256(schema)) == required.schemaHash else {
            throw AccountInsightStoreError.schemaUnavailable
        }
        return ProfileModelSchemaUploadRequest(
            modelRef: model.modelRef,
            schemaHash: model.schemaHash,
            schema: schema
        )
    }

    private func persist() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: fileURL, options: .atomic)
        guard chmod(fileURL.path, 0o600) == 0 else { throw AgentConfigurationError.permissions(fileURL.path) }
    }
}

enum AccountInsightStoreError: LocalizedError {
    case modelUnavailable
    case modelSchemaChanged
    case schemaUnavailable

    var errorDescription: String? {
        switch self {
        case .modelUnavailable: "模型不存在或已被移除，无法批准。"
        case .modelSchemaChanged: "模型 Schema 已变化，当前操作未写入本地状态。"
        case .schemaUnavailable: "本地没有与服务端请求哈希一致的原始 schema。"
        }
    }
}
