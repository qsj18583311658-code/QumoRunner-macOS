import Foundation
import RunnerCore

actor AgentRuntime {
    nonisolated static let expectedLibTVVersion = "1.0.2"
    nonisolated static let expectedLibTVSHA256 = "8605ff53e9f2185f09ba59597ba811e12d90294411ae15710e334be56a4d6e34"

    private let configurationStore = AgentConfigurationStore()
    private let keychain = AgentKeychainStore()
    private let settingsStore: AgentSettingsStore
    nonisolated let profileRegistry: AgentProfileRegistry
    private let journal: SubmissionJournal?
    private let executionCleaner: LibTVExecutionCleaner?
    private let limiter: GlobalConcurrencyLimiter?
    private let insights: AccountInsightCoordinator
    private let runnerRoot: URL
    private let schemaRegistry = LibTVSchemaRegistry()
    private let projectStore: LibTVExecutionProjectStore
    private var api: RunnerAPIClient?
    private var transport: AgentAPITransport?
    private var engine: RunnerEngine?
    private var configuration: AgentConfiguration?
    private var state: RunnerServiceState = .unconfigured
    private var serverReachable = false
    private var concurrencyLimit = 4
    private var libTVVerification: LibTVBinaryVerification?
    private var libTVVerificationError: String?
    private var registeredProfileSignature = ""
    private var registeredProfileRefs: Set<String> = []
    private var profileRunners: [String: LibTVProcessRunner] = [:]
    private var lastActiveJobs: [String: String] = [:]
    private var lastInventoryRevision: [String: String] = [:]
    private var activeJobStartedAt: [String: Date] = [:]
    private var metadataMigrationAttempted: Set<String> = []
    private var logs: [AgentLog] = []
    private var lastExecutionCleanupAt: Date = .distantPast

    init(root: URL, insights: AccountInsightCoordinator) {
        self.insights = insights
        runnerRoot = root
        projectStore = LibTVExecutionProjectStore(fileURL: root.appending(path: "execution-projects.json"))
        settingsStore = AgentSettingsStore(root: root)
        let initialLimit = min(8, max(1, (try? settingsStore.load().concurrencyLimit) ?? 4))
        concurrencyLimit = initialLimit
        profileRegistry = AgentProfileRegistry(root: root)
        let localJournal = try? SubmissionJournal(databaseURL: root.appending(path: "runner.sqlite3"))
        journal = localJournal
        executionCleaner = localJournal.map(LibTVExecutionCleaner.init(journal:))
        limiter = try? GlobalConcurrencyLimiter(limit: initialLimit)
    }

    func runForever() async {
        await verifyLibTV()
        appendLog(.info, "QumoRunnerAgent 已启动")
        if let journal, let pending = try? await journal.pendingRecoveryRecords(), !pending.isEmpty {
            appendLog(.warning, "发现 \(pending.count) 个待恢复提交；已知远端任务只会查询，不会重新提交。")
        }
        while !Task.isCancelled {
            await tick()
            try? await Task.sleep(for: .seconds(5))
        }
    }

    func reloadPairing() {
        api = nil
        transport = nil
        engine = nil
        configuration = nil
        registeredProfileSignature = ""
        registeredProfileRefs = []
        lastInventoryRevision = [:]
        state = .connecting
    }

    func ensureProfile(requestedRef: String?) async throws -> (RunnerProfile, ProfilePaths) {
        guard libTVVerification != nil else {
            throw AgentRuntimeError.libTVUnverified(libTVVerificationError ?? "完整性校验尚未完成")
        }
        if let requestedRef, let active = await engine?.snapshot().activeJobs,
           active.values.contains(requestedRef) {
            throw AgentRuntimeError.profileBusy
        }
        return try profileRegistry.prepare(profileRef: requestedRef)
    }

    func didCompleteLogin(profileRef: String) async {
        registeredProfileSignature = ""
        await insights.activateAutoConcurrency(profileRef: profileRef)
        await insights.refresh(profileRef: profileRef, reason: .login, includeCatalog: true)
    }

    func didDiscardProfile(profileRef: String) async {
        await insights.remove(profileRef: profileRef)
        profileRunners.removeValue(forKey: profileRef)
        metadataMigrationAttempted.remove(profileRef)
        registeredProfileSignature = ""
        registeredProfileRefs.remove(profileRef)
        lastInventoryRevision.removeValue(forKey: profileRef)
    }

    func perform(command: String, values: [String: String]) async throws -> String {
        switch command {
        case "pause_claiming": await engine?.pause(); state = .paused; return "已暂停领取新任务；正在运行的任务会继续。"
        case "resume_claiming": await engine?.resume(); state = .idle; return "已恢复领取新任务。"
        case "set_concurrency":
            let value = min(8, max(1, Int(values["value"] ?? "4") ?? 4))
            do {
                try await limiter?.setLimit(value)
                try await engine?.setGlobalMaxConcurrency(value)
                try settingsStore.saveConcurrency(value)
                concurrencyLimit = value
                registeredProfileSignature = ""
                return "全局并发已更新为 \(value)。"
            }
            catch { return "无法更新并发：\(error.localizedDescription)" }
        case "disable_profile", "enable_profile":
            if let profileRef = values["profile_ref"] {
                try? profileRegistry.setEnabled(profileRef: profileRef, enabled: command == "enable_profile")
                registeredProfileSignature = ""
            }
            return command == "enable_profile" ? "账号已启用。" : "账号已停止领取新任务；运行中的任务继续。"
        case "discard_pending_profile":
            guard let profileRef = values["profile_ref"] else { throw AgentRuntimeError.profileUnavailable }
            try profileRegistry.discardPending(profileRef: profileRef)
            await didDiscardProfile(profileRef: profileRef)
            return "未完成的账号 Profile 已移除。"
        case "health_check_profile", "refresh_account_insights":
            guard let profileRef = values["profile_ref"] else { throw AgentRuntimeError.profileUnavailable }
            await insights.refresh(profileRef: profileRef, reason: .manual, includeCatalog: false)
            return "已开始使用此 Profile 的官方授权刷新积分与套餐；失败时不会误判为零余额。"
        case "refresh_model_catalog":
            guard let profileRef = values["profile_ref"] else { throw AgentRuntimeError.profileUnavailable }
            await insights.refresh(profileRef: profileRef, reason: .manual, includeCatalog: true)
            return "已开始查询六种模态模型目录；新增或 schema 变化的模型需人工启用。"
        case "approve_model", "disable_model":
            guard let profileRef = values["profile_ref"], let modelRef = values["model_ref"] else { throw AgentRuntimeError.profileUnavailable }
            guard let transport else { throw AgentRuntimeError.serverUnavailable }
            let schemaHash = try await insights.schemaHash(profileRef: profileRef, modelRef: modelRef)
            guard let expectedSchemaHash = values["expected_schema_hash"], expectedSchemaHash == schemaHash else {
                throw AgentRuntimeError.modelSchemaChanged
            }
            let response = try await transport.setProfileModelApproval(
                profileRef: profileRef,
                modelRef: modelRef,
                request: ProfileModelApprovalRequest(approved: command == "approve_model", schemaHash: schemaHash)
            )
            let expectedApprovalState = command == "approve_model" ? "approved" : "pending"
            guard response.modelRef == modelRef,
                  response.schemaHash == schemaHash,
                  response.approvalState == expectedApprovalState else {
                throw AgentRuntimeError.modelApprovalResponseMismatch
            }
            try await insights.approveModel(
                profileRef: profileRef,
                modelRef: modelRef,
                expectedSchemaHash: schemaHash,
                approved: command == "approve_model"
            )
            registeredProfileSignature = ""
            return command == "approve_model" ? "当前 schema 已在服务端审批并在本机启用。" : "模型已在服务端和本机停用，不再参与调度。"
        case "stop_tracking":
            guard let jobID = values["job_id"], let engine else { throw AgentRuntimeError.jobUnavailable }
            try await engine.stopTracking(jobID: jobID)
            return "已停止本地跟踪；远端任务未取消，任务将进入待人工确认。"
        case "cancel_before_submission":
            guard let jobID = values["job_id"], let engine else { throw AgentRuntimeError.jobUnavailable }
            _ = try await engine.cancelBeforeSubmission(jobID: jobID)
            return "已取消尚未提交的任务；不会启动 LibTV 进程。"
        case "reload_pairing": reloadPairing(); return "后台服务已加载新配对。"
        case "libtv_diagnostic":
            await verifyLibTV()
            return libTVVerification.map { "LibTV \($0.version) 的 SHA-256 与严格代码签名校验通过。" } ?? "LibTV 校验失败：\(libTVVerificationError ?? "未知错误")"
        case "prepare_shutdown": await engine?.pause(); state = .paused; return "后台服务已准备退出。"
        default: return "命令已由后台服务接收。"
        }
    }

    func snapshotData() async -> Data {
        let profiles = profileRegistry.all()
        let engineSnapshot = await engine?.snapshot()
        let active = engineSnapshot?.activeJobs ?? [:]
        let knownJobs = await transport?.jobsSnapshot() ?? []
        let now = Date()
        for jobID in active.keys where activeJobStartedAt[jobID] == nil { activeJobStartedAt[jobID] = now }
        activeJobStartedAt = activeJobStartedAt.filter { active.keys.contains($0.key) }
        let accountNames = Dictionary(uniqueKeysWithValues: profiles.map { ($0.profileRef, $0.displayName) })
        var agentAccounts: [AgentAccount] = []
        for profile in profiles {
            let currentID = active.first(where: { $0.value == profile.profileRef })?.key
            let currentJobCount = active.values.filter { $0 == profile.profileRef }.count
            let insight = await insights.view(profileRef: profile.profileRef, globalLimit: concurrencyLimit)
            agentAccounts.append(AgentAccount(
                id: profile.profileRef,
                displayName: profile.displayName,
                accountRef: profile.accountRef,
                enabled: profile.enabled,
                healthy: profile.healthy,
                authExpired: !profile.healthy && profile.accountRef != "pending",
                capabilities: profile.capabilities,
                currentJobTitle: currentID.map { "生成任务 \($0.prefix(8))" },
                currentJobCount: currentJobCount,
                lastCheckedAt: insight.lastAttemptAt,
                insightError: insight.refreshError,
                insightRefreshing: insight.refreshing,
                autoConcurrencyActivated: insight.autoConcurrencyActivated,
                quotaState: insight.quotaState.rawValue,
                quota: insight.quota,
                plan: insight.plan,
                detectedMaxConcurrency: insight.detectedMaxConcurrency,
                effectiveMaxConcurrency: insight.effectiveMaxConcurrency,
                catalogRevision: insight.catalogRevision,
                catalogRefreshedAt: insight.catalogRefreshedAt,
                catalogError: insight.catalogError,
                catalogRefreshing: insight.catalogRefreshing,
                models: insight.models
            ))
        }
        let snapshot = AgentSnapshot(
            serviceState: state.rawValue,
            serverReachable: serverReachable,
            serverURL: configuration?.serverURL.absoluteString,
            libTVVersion: libTVVerification?.version,
            libTVVerified: libTVVerification != nil,
            activeConcurrency: active.count,
            concurrencyLimit: concurrencyLimit,
            todaySucceeded: knownJobs.filter { $0.state == .succeeded && Calendar.current.isDateInToday($0.updatedAt) }.count,
            todayFailed: knownJobs.filter { $0.state == .failed && Calendar.current.isDateInToday($0.updatedAt) }.count,
            jobs: knownJobs.map { job in
                let profileRef = job.executionProfileRef ?? "—"
                return AgentJob(id: job.id, title: "生成任务 \(job.id.prefix(8))", state: job.state.rawValue, progress: Self.progress(from: job.result), profileRef: profileRef, accountName: accountNames[profileRef] ?? "未知账号", startedAt: activeJobStartedAt[job.id] ?? job.createdAt, finishedAt: job.state.isTerminal ? job.updatedAt : nil, artifactNames: job.resultArtifactID.map { [$0] } ?? [], errorMessage: job.error, remoteTaskID: job.remoteTaskID)
            },
            accounts: agentAccounts,
            logs: await persistedLogs()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(snapshot)) ?? Data("{}".utf8)
    }

    private func tick() async {
        do {
            try await connectIfNeeded()
            guard let engine else { return }
            await insights.tick(profiles: profileRegistry.all())
            try await rebuildProfilesIfSafe(engine)
            await syncInventoriesIfNeeded()
            let before = await engine.snapshot().activeJobs
            for (jobID, profileRef) in lastActiveJobs where before[jobID] == nil {
                await insights.refresh(profileRef: profileRef, reason: .taskFinished, includeCatalog: false)
            }
            try await engine.tick()
            await cleanupExecutionsIfNeeded(engine)
            await applyServiceCommands(await transport?.consumeServiceCommands() ?? [])
            lastActiveJobs = await engine.snapshot().activeJobs
            serverReachable = true
            let engineState = await engine.snapshot().state
            state = libTVVerification == nil ? .degraded : engineState
        } catch {
            serverReachable = false
            if case RunnerAPIError.http(let status, _) = error, status == 401 || status == 403 { state = .authExpired }
            else { state = configuration == nil ? .unconfigured : .offline }
            appendLog(.error, "后台轮询失败：\(error.localizedDescription)")
        }
    }

    private func cleanupExecutionsIfNeeded(_ engine: RunnerEngine) async {
        guard Date().timeIntervalSince(lastExecutionCleanupAt) >= 60 * 60,
              (await engine.snapshot()).activeJobs.isEmpty,
              let executionCleaner else { return }
        do {
            let cleaned = try await executionCleaner.cleanupExpired(executors: await engine.maintenanceExecutors())
            if !cleaned.isEmpty { appendLog(.info, "已清理 \(cleaned.count) 个过期的 LibTV 隐藏执行分组。") }
            lastExecutionCleanupAt = .now
        } catch {
            appendLog(.warning, "LibTV 隐藏执行空间清理失败，将在下次维护周期重试：\(error.localizedDescription)")
        }
    }

    private func connectIfNeeded() async throws {
        guard engine == nil else { return }
        guard let loaded = try configurationStore.load() else { state = .unconfigured; return }
        configuration = loaded
        guard let token = try keychain.deviceToken(runnerID: loaded.runnerID), !token.isEmpty else { state = .authExpired; return }
        guard let journal, let limiter else { state = .degraded; throw AgentRuntimeError.storageUnavailable }
        state = .connecting
        let client = RunnerAPIClient(configuration: .init(serverURL: loaded.serverURL), runnerID: loaded.runnerID, deviceToken: token)
        let observingTransport = AgentAPITransport(base: client)
        api = client
        transport = observingTransport
        let preparer = LibTVGenerationPreparer(
            registry: schemaRegistry,
            projectStore: projectStore,
            materializer: observingTransport,
            stagingRoot: runnerRoot.appending(path: "input-staging"),
            journal: journal
        )
        engine = RunnerEngine(
            api: observingTransport,
            journal: journal,
            generationPreparer: preparer,
            globalMaxConcurrency: concurrencyLimit,
            hostname: ProcessInfo.processInfo.hostName,
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0",
            preSubmissionDelay: .seconds(8)
        )
        registeredProfileSignature = ""
        _ = limiter
    }

    private func rebuildProfilesIfSafe(_ engine: RunnerEngine) async throws {
        await repairLegacyProfileMetadata()
        let storedProfiles = profileRegistry.all()
        var profiles: [RunnerProfile] = []
        var signatureRows: [String] = []
        for var profile in storedProfiles {
            let insight = await insights.view(profileRef: profile.profileRef, globalLimit: concurrencyLimit)
            if insight.quotaState == .webAuthRequired || insight.quotaState == .identityMismatch {
                profile.healthy = false
            }
            let schemas = await insights.generationSchemas(profileRef: profile.profileRef)
            schemaRegistry.replace(profileRef: profile.profileRef, schemas: schemas)
            profile.detectedMaxConcurrency = insight.detectedMaxConcurrency
            profile.maxConcurrency = insight.effectiveMaxConcurrency
            profile.planName = insight.plan?.name
            profile.quotaState = insight.quotaState.inventoryValue(snapshot: insight.quota)
            profile.catalogRevision = insight.catalogRevision
            profiles.append(profile)
            if registeredProfileRefs.contains(profile.profileRef) {
                let liveLimit = profile.enabled && profile.healthy ? profile.maxConcurrency : 0
                try? await engine.setProfileMaxConcurrency(liveLimit, profileRef: profile.profileRef)
            }
            signatureRows.append("\(profile.profileRef):\(profile.enabled):\(profile.healthy):\(profile.detectedMaxConcurrency ?? -1):\(profile.maxConcurrency):\(profile.planName ?? "-"):\(profile.quotaState ?? "-"):\(profile.catalogRevision ?? "-"):\(profile.capabilities.joined(separator: ","))")
        }
        let signature = signatureRows.sorted().joined(separator: "|")
        guard signature != registeredProfileSignature else { return }
        guard (await engine.snapshot()).activeJobs.isEmpty else { return }
        guard libTVVerification != nil, let limiter else {
            registeredProfileSignature = signature
            return
        }
        for profile in profiles {
            let paths = try profileRegistry.prepare(profileRef: profile.profileRef).1
            let runner = profileRunners[profile.profileRef] ?? LibTVProcessRunner(executableURL: AgentBundleLayout.libTVExecutableURL, homeURL: paths.home)
            profileRunners[profile.profileRef] = runner
            await insights.register(profile: profile, runner: runner)
            let executor = ProfileExecutor(profileRef: profile.profileRef, runner: runner, limiter: limiter)
            await engine.register(profile: profile, executor: executor)
        }
        let currentRefs = Set(profiles.map(\.profileRef))
        for removed in registeredProfileRefs.subtracting(currentRefs) {
            await engine.unregister(profileRef: removed)
            profileRunners.removeValue(forKey: removed)
        }
        registeredProfileRefs = currentRefs
        _ = try await engine.synchronizeProfiles()
        registeredProfileSignature = signature
    }

    private func repairLegacyProfileMetadata() async {
        guard libTVVerification != nil else { return }
        for profile in profileRegistry.all()
        where profile.accountRef == profile.profileRef && metadataMigrationAttempted.insert(profile.profileRef).inserted {
            do {
                let paths = try profileRegistry.prepare(profileRef: profile.profileRef).1
                let runner = profileRunners[profile.profileRef]
                    ?? LibTVProcessRunner(executableURL: AgentBundleLayout.libTVExecutableURL, homeURL: paths.home, defaultTimeout: .seconds(60))
                profileRunners[profile.profileRef] = runner
                let result = try await runner.run(arguments: ["account", "info"])
                guard result.exitCode == 0 else { continue }
                let metadata = LibTVAccountMetadataParser.parse(
                    output: result.standardOutput,
                    fallbackAccountRef: profile.accountRef,
                    fallbackDisplayName: profile.displayName
                )
                guard metadata.accountRef != profile.accountRef else { continue }
                try profileRegistry.markLogin(
                    profileRef: profile.profileRef,
                    accountRef: metadata.accountRef,
                    displayName: metadata.displayName,
                    capabilities: profile.capabilities,
                    healthy: true
                )
                registeredProfileSignature = ""
                appendLog(.info, "已修复旧 Profile 的 LibTV 账号标识。", profileRef: profile.profileRef)
            } catch {
                appendLog(.warning, "旧 Profile 账号标识迁移失败，将保留原值：\(error.localizedDescription)", profileRef: profile.profileRef)
            }
        }
    }

    private func syncInventoriesIfNeeded() async {
        guard let transport, configuration != nil else { return }
        for profile in profileRegistry.all() where profile.accountRef != "pending" {
            let request = await insights.inventory(profileRef: profile.profileRef, globalLimit: concurrencyLimit)
            guard lastInventoryRevision[profile.profileRef] != request.inventoryRevision else { continue }
            do {
                let response = try await transport.syncProfileInventory(profileRef: profile.profileRef, request: request)
                for required in response.requiredSchemaUploads ?? [] {
                    let upload = try await insights.schemaUpload(profileRef: profile.profileRef, required: required)
                    let uploaded = try await transport.uploadProfileModelSchema(profileRef: profile.profileRef, request: upload)
                    guard uploaded.modelRef == required.modelRef,
                          uploaded.schemaHash == required.schemaHash else {
                        throw AgentRuntimeError.modelSchemaUploadResponseMismatch
                    }
                }
                lastInventoryRevision[profile.profileRef] = request.inventoryRevision
            } catch {
                appendLog(.warning, "账号 \(profile.displayName) 的用量/模型目录同步失败：\(error.localizedDescription)", profileRef: profile.profileRef)
            }
        }
    }

    private func applyServiceCommands(_ commands: [RunnerControlCommand]) async {
        for command in commands {
            switch command.kind {
            case .refreshProfiles:
                registeredProfileSignature = ""
            case .refreshInventory:
                lastInventoryRevision = [:]
                for profile in profileRegistry.all() where profile.accountRef != "pending" {
                    await insights.refresh(profileRef: profile.profileRef, reason: .manual, includeCatalog: true)
                }
            case .healthCheck:
                for profile in profileRegistry.all() where profile.accountRef != "pending" {
                    await insights.refresh(profileRef: profile.profileRef, reason: .manual, includeCatalog: false)
                }
            case .diagnostics:
                await verifyLibTV()
            default:
                break
            }
        }
    }

    private func verifyLibTV() async {
        do {
            try Self.verifyArchitectureAndTeam(executableURL: AgentBundleLayout.libTVExecutableURL)
            libTVVerification = try LibTVBinaryVerifier.verify(executableURL: AgentBundleLayout.libTVExecutableURL, expectedVersion: Self.expectedLibTVVersion, expectedSHA256: Self.expectedLibTVSHA256)
            libTVVerificationError = nil
            registeredProfileSignature = ""
            appendLog(.info, "LibTV 1.0.2 完整性校验通过")
        } catch {
            libTVVerification = nil
            libTVVerificationError = error.localizedDescription
            state = .degraded
            appendLog(.error, "LibTV 完整性校验失败：\(error.localizedDescription)")
        }
    }

    private nonisolated static func verifyArchitectureAndTeam(executableURL: URL) throws {
        let architecture = try toolOutput(executable: "/usr/bin/lipo", arguments: ["-archs", executableURL.path], mergeStandardError: false)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard architecture == "arm64" else { throw AgentRuntimeError.libTVMetadata("架构必须是 thin arm64，实际为 \(architecture)") }
        let signature = try toolOutput(executable: "/usr/bin/codesign", arguments: ["-dv", "--verbose=4", executableURL.path], mergeStandardError: true)
        guard signature.contains("TeamIdentifier=U5N2L989V7") else { throw AgentRuntimeError.libTVMetadata("Developer ID Team 不匹配") }
    }

    private nonisolated static func toolOutput(executable: String, arguments: [String], mergeStandardError: Bool) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        if mergeStandardError { process.standardError = pipe }
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else { throw AgentRuntimeError.libTVMetadata(output) }
        return output
    }

    private func appendLog(_ level: AgentLogLevel, _ message: String, jobID: String? = nil, profileRef: String? = nil) {
        let message = Self.redact(message)
        logs.insert(AgentLog(id: UUID(), timestamp: .now, level: level.rawValue, message: message, jobID: jobID, profileRef: profileRef), at: 0)
        if logs.count > 1_000 { logs.removeLast(logs.count - 1_000) }
        if let journal {
            Task { try? await journal.appendLog(level: level.rawValue, message: message, jobID: jobID, profileRef: profileRef) }
        }
    }

    private func persistedLogs() async -> [AgentLog] {
        guard let journal, let records = try? await journal.logs(limit: 500), !records.isEmpty else { return Array(logs.prefix(500)) }
        return records.map { AgentLog(id: UUID(), timestamp: $0.timestamp, level: $0.level, message: $0.message, jobID: $0.jobID, profileRef: $0.profileRef) }
    }

    private nonisolated static func progress(from result: JSONPayloadValue?) -> Double {
        guard case .object(let object) = result,
              case .number(let value) = object["progress_percent"] else { return 0 }
        return min(1, max(0, value / 100))
    }

    private nonisolated static func redact(_ value: String) -> String {
        value.replacingOccurrences(
            of: "(?i)(x-runner-token|authorization|token|password|secret)\\s*[:=]\\s*[^\\s,;]+",
            with: "$1=[REDACTED]",
            options: .regularExpression
        ).replacingOccurrences(
            of: "(?i)bearer\\s+[A-Za-z0-9._~+/-]+",
            with: "Bearer [REDACTED]",
            options: .regularExpression
        )
    }
}

private enum AgentLogLevel: String { case debug, info, warning, error }

enum AgentRuntimeError: LocalizedError, Sendable {
    case storageUnavailable
    case libTVUnverified(String)
    case libTVMetadata(String)
    case jobUnavailable
    case profileUnavailable
    case profileBusy
    case serverUnavailable
    case modelSchemaChanged
    case modelApprovalResponseMismatch
    case modelSchemaUploadResponseMismatch
    var errorDescription: String? {
        switch self {
        case .storageUnavailable: "Runner SQLite 或并发控制器初始化失败。"
        case .libTVUnverified(let detail): "LibTV 未通过完整性校验：\(detail)"
        case .libTVMetadata(let detail): "LibTV 架构或签名元数据校验失败：\(detail)"
        case .jobUnavailable: "任务当前不在本机租约中，无法取消。"
        case .profileUnavailable: "缺少有效的 Profile 或模型标识。"
        case .profileBusy: "该 Profile 正在运行任务，请等待完成后再重新登录。"
        case .serverUnavailable: "Runner 尚未连接服务器，模型审批未保存。"
        case .modelSchemaChanged: "模型 Schema 已在操作期间变化，请刷新模型目录后重新确认。"
        case .modelApprovalResponseMismatch: "服务端返回的模型审批结果与请求不一致，本地状态未更新。"
        case .modelSchemaUploadResponseMismatch: "服务端确认的模型 Schema 与请求不一致，本次目录同步不会标记完成。"
        }
    }
}
