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
    private var runtimeRegistry: LibTVRuntimeRegistry?
    private var runtimeInstaller: LibTVRuntimeInstaller?
    private var cliUpdate = LibTVUpdateStatus()
    private var lastUpdateAttempt: Date = .distantPast
    private var checkingCLIUpdate = false
    private var localUpdateTask: Task<Void, Never>?
    private var runtimeCommandInProgress = false
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
    private var pendingRuntimeValidationCommand: (command: RunnerControlCommand, record: LibTVRuntimeRecord?, startedAt: Date)?

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
        if let data = try? Data(contentsOf: root.appending(path: "cli-update.json")),
           var saved = try? JSONDecoder().decode(LibTVUpdateStatus.self, from: data) {
            if saved.isBusy {
                saved.phase = "failed"
                saved.message = "上次更新被服务重启中断，请检查当前版本后重试。"
            }
            cliUpdate = saved
        }
    }

    func runForever() async {
        await verifyLibTV()
        appendLog(.info, "QumoRunnerAgent 已启动")
        if let journal, let pending = try? await journal.pendingRecoveryRecords() {
            if !pending.isEmpty { appendLog(.warning, "发现 \(pending.count) 个待恢复提交；已知远端任务只会查询，不会重新提交。") }
            let retained = (try? await journal.retainedRuntimeIdentities()) ?? Set(pending.compactMap(\.runtimeIdentity))
            _ = try? await runtimeRegistry?.prune(retaining: retained)
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
        if localUpdateTask != nil && ["install_runtime_candidate", "activate_runtime_candidate", "rollback_runtime", "reload_pairing", "libtv_diagnostic"].contains(command) {
            throw LibTVUpdateError.busy
        }
        let mutatesRuntime = ["install_runtime_candidate", "activate_runtime_candidate", "rollback_runtime"].contains(command)
        if mutatesRuntime {
            guard !runtimeCommandInProgress, pendingRuntimeValidationCommand == nil else { throw LibTVUpdateError.busy }
            runtimeCommandInProgress = true
        }
        defer { if mutatesRuntime { runtimeCommandInProgress = false } }
        switch command {
        case "set_cli_nightly":
            cliUpdate.nightlyEnabled = values["enabled"] == "true"
            saveCLIUpdate()
            return cliUpdate.nightlyEnabled == true ? "已启用每晚 03:00–04:00 的 CLI 更新窗口。" : "已关闭夜间自动更新，仍会检查并提醒新版。"
        case "check_cli_update":
            Task { await self.checkCLIUpdate() }
            return "正在检查官方 CLI 版本清单。"
        case "update_cli", "rollback_cli":
            guard localUpdateTask == nil, !runtimeCommandInProgress, pendingRuntimeValidationCommand == nil,
                  await runtimeRegistry?.pendingRuntimeValidationReports().contains(where: { $0.status == "running" }) != true else { throw LibTVUpdateError.busy }
            guard localUpdateTask == nil, !runtimeCommandInProgress else { throw LibTVUpdateError.busy }
            let target = values["version"] ?? cliUpdate.availableVersion(current: libTVVerification?.version)
            if command == "update_cli" {
                guard let target else { throw LibTVUpdateError.invalidVersion }
                _ = try LibTVReleaseVersion.release(target)
                guard let current = libTVVerification?.version, LibTVReleaseVersion.isNewer(target, than: current) else { throw LibTVUpdateError.notNewer }
            }
            cliUpdate.targetVersion = target
            cliUpdate.phase = command == "rollback_cli" ? "waiting" : "downloading"
            cliUpdate.message = command == "rollback_cli" ? "等待现有任务结束后回滚…" : "正在下载官方 CLI，并验证签名、完整性和命令兼容性…"
            saveCLIUpdate()
            localUpdateTask = Task { await self.performCLIUpdate(version: target, rollback: command == "rollback_cli", scheduled: values["scheduled"] == "true") }
            return cliUpdate.message ?? "已开始更新。"
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
        case "install_runtime_candidate":
            guard let runtimeInstaller,
                  let version = values["version"],
                  let rawURL = values["url"],
                  let url = URL(string: rawURL) else { throw AgentRuntimeError.libTVMetadata("Runtime 参数不完整") }
            let record = try await runtimeInstaller.downloadAndStage(.init(
                version: version,
                archiveURL: url,
                archiveSHA256: values["archive_sha256"],
                executableSHA256: values["sha256"]
            ))
            return "LibTV \(record.identity.version) 候选版本已完成下载、签名与完整性验证，尚未启用。"
        case "activate_runtime_candidate":
            guard let runtimeRegistry else { throw AgentRuntimeError.libTVUnverified("Runtime Registry 未就绪") }
            guard (await engine?.snapshot().activeJobs.isEmpty) != false else { throw AgentRuntimeError.profileBusy }
            guard let candidate = try await runtimeRegistry.snapshot().candidateRecord else {
                throw LibTVRuntimeRegistryError.candidateUnavailable
            }
            _ = try await verifyRuntimeContract(candidate)
            guard (await engine?.snapshot().activeJobs.isEmpty) != false else { throw AgentRuntimeError.profileBusy }
            let record = try await runtimeRegistry.activateCandidate(expected: candidate.identity)
            do { libTVVerification = try Self.verifyRuntime(record) }
            catch { _ = try? await runtimeRegistry.rollback(); throw error }
            profileRunners = [:]; registeredProfileSignature = ""
            return "LibTV \(record.identity.version) 已原子切换为 active。"
        case "rollback_runtime":
            guard (await engine?.snapshot().activeJobs.isEmpty) != false else { throw AgentRuntimeError.profileBusy }
            let record = try await rollbackRuntime()
            profileRunners = [:]; registeredProfileSignature = ""
            return "已回滚到 LibTV \(record.identity.version)。"
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
            libTVUpdate: cliUpdate,
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
        if !checkingCLIUpdate && Date().timeIntervalSince(lastUpdateAttempt) >= 6 * 60 * 60 {
            Task { await self.checkCLIUpdate() }
        }
        cliUpdate.previousVersion = try? await runtimeRegistry?.snapshot().previous?.version
        do {
            try await connectIfNeeded()
            guard let engine else { return }
            await scheduleNightlyUpdateIfNeeded(engine)
            await insights.tick(profiles: profileRegistry.all())
            try await rebuildProfilesIfSafe(engine)
            await syncInventoriesIfNeeded()
            await refreshRuntimeValidationReports()
            await advanceRuntimeValidationMaintenance()
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

    private func saveCLIUpdate() {
        if let data = try? JSONEncoder().encode(cliUpdate) {
            try? data.write(to: runnerRoot.appending(path: "cli-update.json"), options: .atomic)
        }
    }

    private func checkCLIUpdate() async {
        guard !checkingCLIUpdate else { return }
        checkingCLIUpdate = true
        lastUpdateAttempt = .now
        defer { checkingCLIUpdate = false; saveCLIUpdate() }
        do {
            let discovery = try await LibTVUpdateClient().latestVersion()
            cliUpdate.channelVersion = discovery.version
            cliUpdate.websiteVersion = discovery.websiteVersion
            cliUpdate.manifestVersion = discovery.manifestVersion
            cliUpdate.sourceNote = discovery.note
            cliUpdate.checkedAt = .now
            cliUpdate.checkError = nil
        } catch {
            cliUpdate.checkError = "检查失败：\(error.localizedDescription)；保留上次检查结果。"
            appendLog(.warning, cliUpdate.checkError!)
        }
    }

    private func scheduleNightlyUpdateIfNeeded(_ engine: RunnerEngine) async {
        guard cliUpdate.nightlyEnabled ?? true, localUpdateTask == nil, serverReachable,
              cliUpdate.checkError == nil,
              let version = cliUpdate.availableVersion(current: libTVVerification?.version),
              LibTVMaintenanceWindow.shouldAttempt(now: .now, lastAttempt: cliUpdate.lastNightlyAttempt, checkedAt: cliUpdate.checkedAt) else { return }
        let snapshot = await engine.snapshot()
        guard snapshot.activeJobs.isEmpty, !snapshot.paused else {
            cliUpdate.scheduleNote = "当前有任务或已手动暂停，等本次窗口内空闲再更新；04:00 后顺延下一晚。"
            return
        }
        do {
            _ = try await perform(command: "update_cli", values: ["version": version, "scheduled": "true"])
            cliUpdate.lastNightlyAttempt = .now
            cliUpdate.scheduleNote = "本晚已发起一次更新；失败后等待下一晚或手动重试。"
            saveCLIUpdate()
        } catch { cliUpdate.scheduleNote = "暂不能开始夜间更新：\(error.localizedDescription)" }
    }

    private func performCLIUpdate(version: String?, rollback: Bool, scheduled: Bool) async {
        let maintenanceEngine = engine
        let originalRuntime = try? await runtimeRegistry?.activeRuntime()
        do {
            try await LibTVUpdateDeadline.run(for: .seconds(45 * 60)) {
                try await self.executeCLIUpdate(version: version, rollback: rollback, scheduled: scheduled, engine: maintenanceEngine)
            }
            cliUpdate.phase = "completed"
            cliUpdate.message = "已\(rollback ? "回滚" : "更新")到 LibTV \(libTVVerification?.version ?? "未知")，模型参数验证完成。"
            appendLog(.info, cliUpdate.message!)
        } catch {
            if let originalRuntime, let runtimeRegistry,
               let current = try? await runtimeRegistry.snapshot(), current.active != originalRuntime.identity,
               current.previous == originalRuntime.identity {
                do {
                    try await LibTVUpdateDeadline.run(for: .seconds(120)) {
                        try await self.restoreRuntime(originalRuntime, engine: maintenanceEngine)
                    }
                } catch {
                    await maintenanceEngine?.pause()
                    appendLog(.error, "更新恢复尚未完成，已暂停领取，请运行诊断：\(error.localizedDescription)")
                }
            }
            cliUpdate.phase = "failed"
            cliUpdate.message = "CLI \(rollback ? "回滚" : "更新")失败：\(error.localizedDescription) 当前版本：\(libTVVerification?.version ?? "未知")。"
            appendLog(.error, cliUpdate.message!)
        }
        await maintenanceEngine?.endRuntimeMaintenance()
        cliUpdate.previousVersion = try? await runtimeRegistry?.snapshot().previous?.version
        saveCLIUpdate()
        localUpdateTask = nil
    }

    private func executeCLIUpdate(version: String?, rollback: Bool, scheduled: Bool, engine: RunnerEngine?) async throws {
        guard let runtimeRegistry, let runtimeInstaller else { throw AgentRuntimeError.libTVUnverified("Runtime Registry 未就绪") }
        let candidate: LibTVRuntimeRecord?
        if rollback { candidate = nil }
        else {
            guard let version else { throw LibTVUpdateError.invalidVersion }
            candidate = try await runtimeInstaller.downloadAndStage(LibTVReleaseVersion.release(version))
        }
        try Task.checkCancellation()
        if scheduled && !LibTVMaintenanceWindow.contains(.now) { throw LibTVUpdateError.windowClosed }
        await engine?.beginRuntimeMaintenance()
        cliUpdate.phase = "waiting"
        cliUpdate.message = "等待现有任务结束；已暂停领取新任务…"
        saveCLIUpdate()
        let deadline = Date().addingTimeInterval(30 * 60)
        if let engine {
            while !(await engine.runtimeSwitchReady()) {
                if scheduled && !LibTVMaintenanceWindow.contains(.now) { throw LibTVUpdateError.windowClosed }
                guard Date() < deadline else { throw LibTVUpdateError.drainTimeout }
                try await Task.sleep(for: .seconds(1))
            }
        }
        cliUpdate.phase = "activating"
        cliUpdate.message = "正在切换 CLI…"
        saveCLIUpdate()
        let record: LibTVRuntimeRecord
        if rollback { record = try await rollbackRuntime() }
        else {
            guard let candidate else { throw LibTVRuntimeRegistryError.candidateUnavailable }
            _ = try await verifyRuntimeContract(candidate)
            try Task.checkCancellation()
            if scheduled && !LibTVMaintenanceWindow.contains(.now) { throw LibTVUpdateError.windowClosed }
            record = try await runtimeRegistry.activateCandidate(expected: candidate.identity)
            libTVVerification = try Self.verifyRuntime(record)
        }
        try Task.checkCancellation()
        cliUpdate.phase = "validating"
        cliUpdate.message = "正在验证新版模型参数，完成前保持暂停领取…"
        saveCLIUpdate()
        try await bindAndValidateRuntime(record, engine: engine)
    }

    private func bindAndValidateRuntime(_ record: LibTVRuntimeRecord, engine: RunnerEngine?) async throws {
        profileRunners = [:]; registeredProfileSignature = ""; lastInventoryRevision = [:]
        if let engine { try await rebuildProfilesIfSafe(engine) }
        let refs = profileRegistry.all().filter { $0.enabled && $0.healthy && $0.accountRef != "pending" }.map(\.profileRef)
        // No registered engine means this is an unpaired installation with no schedulable work.
        if engine != nil {
            try await insights.waitForRuntimeCatalogs(profileRefs: refs, runtimePath: record.executablePath)
            try Task.checkCancellation()
            registeredProfileSignature = ""
            if let engine { try await rebuildProfilesIfSafe(engine) }
        }
    }

    private func restoreRuntime(_ original: LibTVRuntimeRecord, engine: RunnerEngine?) async throws {
        guard let runtimeRegistry else { throw AgentRuntimeError.libTVUnverified("Runtime Registry 未就绪") }
        let restored = try await runtimeRegistry.rollback(expected: original.identity)
        do { libTVVerification = try Self.verifyRuntime(restored) }
        catch { libTVVerification = nil; throw error }
        try await bindAndValidateRuntime(restored, engine: engine)
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
        guard engine == nil, localUpdateTask == nil else { return }
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
            runtimeProvider: runtimeRegistry,
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
            // A stale schema must never be used for claims after a runtime switch or restart.
            profile.maxConcurrency = await insights.catalogReady(profileRef: profile.profileRef) ? insight.effectiveMaxConcurrency : 0
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
        guard let activeRuntime = try await runtimeRegistry?.activeRuntime() else {
            throw AgentRuntimeError.libTVUnverified("active Runtime 不可用")
        }
        for profile in profiles {
            let paths = try profileRegistry.prepare(profileRef: profile.profileRef).1
            let runner = profileRunners[profile.profileRef] ?? LibTVProcessRunner(executableURL: activeRuntime.executableURL, homeURL: paths.home)
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
        guard let activeRuntime = try? await runtimeRegistry?.activeRuntime() else { return }
        for profile in profileRegistry.all()
        where profile.accountRef == profile.profileRef && metadataMigrationAttempted.insert(profile.profileRef).inserted {
            do {
                let paths = try profileRegistry.prepare(profileRef: profile.profileRef).1
                let runner = profileRunners[profile.profileRef]
                    ?? LibTVProcessRunner(executableURL: activeRuntime.executableURL, homeURL: paths.home, defaultTimeout: .seconds(60))
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
            do {
                var evidence: LibTVRuntimeRecord?
                var deferAcknowledgement = false
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
                case .runtimeValidate:
                    guard localUpdateTask == nil, !runtimeCommandInProgress else { throw LibTVUpdateError.busy }
                    runtimeCommandInProgress = true
                    defer { runtimeCommandInProgress = false }
                    if let pending = pendingRuntimeValidationCommand, pending.command.id == command.id {
                        evidence = pending.record
                        deferAcknowledgement = true
                    } else if (await engine?.snapshot().activeJobs.isEmpty) == false {
                        // Stop claiming normal work server-side and let every
                        // already-running task finish on its pinned Runtime.
                        pendingRuntimeValidationCommand = (command, nil, .now)
                        deferAcknowledgement = true
                    } else {
                        evidence = try await prepareRuntimeValidation(command)
                    }
                case .runtimeActivate:
                    guard localUpdateTask == nil, !runtimeCommandInProgress else { throw LibTVUpdateError.busy }
                    runtimeCommandInProgress = true
                    defer { runtimeCommandInProgress = false }
                    evidence = try await activateRuntime(command)
                case .runtimeRollback:
                    guard localUpdateTask == nil, !runtimeCommandInProgress else { throw LibTVUpdateError.busy }
                    runtimeCommandInProgress = true
                    defer { runtimeCommandInProgress = false }
                    guard (await engine?.snapshot().activeJobs.isEmpty) != false else { throw AgentRuntimeError.profileBusy }
                    evidence = try await rollbackRuntime()
                    profileRunners = [:]; registeredProfileSignature = ""
                case .runtimeDiscover, .runtimeApprove:
                    evidence = try await runtimeRegistry?.activeRuntime()
                default:
                    break
                }
                if !deferAcknowledgement {
                    try await transport?.acknowledge(
                        commandID: command.id,
                        acknowledgement: runtimeAcknowledgement(status: "completed", detail: nil, record: evidence)
                    )
                }
            } catch {
                let active: LibTVRuntimeRecord?
                if let runtimeRegistry { active = try? await runtimeRegistry.activeRuntime() }
                else { active = nil }
                try? await transport?.acknowledge(
                    commandID: command.id,
                    acknowledgement: runtimeAcknowledgement(
                        status: "failed",
                        detail: error.localizedDescription,
                        record: active
                    )
                )
                appendLog(.error, "服务命令 \(command.kind.rawValue) 执行失败：\(error.localizedDescription)")
            }
        }
    }

    private func advanceRuntimeValidationMaintenance() async {
        guard let pending = pendingRuntimeValidationCommand, let engine, let transport else { return }
        let activeJobs = await engine.snapshot().activeJobs
        if Date().timeIntervalSince(pending.startedAt) >= 30 * 60 {
            let detail = "等待现有任务自然排空超过 30 分钟；未取消任何运行中任务。"
            if let validationID = pending.command.payload["validation_id"]?.stringValue,
               let record = pending.record,
               let failed = try? RunnerRuntimeValidationReport(
                   validationID: validationID,
                   status: "failed",
                   record: record,
                   detail: detail
               ) { try? await runtimeRegistry?.upsertRuntimeValidationReport(failed) }
            do {
                try await transport.acknowledge(
                    commandID: pending.command.id,
                    acknowledgement: runtimeAcknowledgement(status: "failed", detail: detail, record: pending.record)
                )
                pendingRuntimeValidationCommand = nil
            } catch {
                appendLog(.warning, "Runtime 维护窗超时，失败 ACK 将在下一轮重试：\(error.localizedDescription)")
            }
            return
        }
        if activeJobs.isEmpty {
            do {
                let record = try await prepareRuntimeValidation(pending.command)
                try await transport.acknowledge(
                    commandID: pending.command.id,
                    acknowledgement: runtimeAcknowledgement(status: "completed", detail: nil, record: record)
                )
                pendingRuntimeValidationCommand = nil
            } catch {
                appendLog(.warning, "Runtime 维护窗完成，但命令 ACK 将在下一轮重试：\(error.localizedDescription)")
            }
            return
        }
    }

    private func installRuntimeCandidate(_ command: RunnerControlCommand) async throws -> LibTVRuntimeRecord {
        guard let runtimeInstaller,
              let version = command.payload["version"]?.stringValue,
              let rawURL = command.payload["download_url"]?.stringValue,
              let url = URL(string: rawURL) else {
            throw AgentRuntimeError.libTVMetadata("Runtime command payload 不完整")
        }
        return try await runtimeInstaller.downloadAndStage(.init(
            version: version,
            archiveURL: url,
            archiveSHA256: command.payload["archive_sha256"]?.stringValue,
            executableSHA256: command.payload["sha256"]?.stringValue
        ))
    }

    private func prepareRuntimeValidation(_ command: RunnerControlCommand) async throws -> LibTVRuntimeRecord {
        guard let validationID = command.payload["validation_id"]?.stringValue,
              let profileRef = command.payload["validation_profile_ref"]?.stringValue,
              let runtimeRegistry else {
            throw AgentRuntimeError.libTVMetadata("Runtime validation_id 或隔离 Profile 缺失")
        }
        let record = try await installRuntimeCandidate(command)
        let paths = try profileRegistry.prepare(profileRef: profileRef).1
        let candidateRunner = LibTVProcessRunner(executableURL: record.executableURL, homeURL: paths.home)

        let cliContract = try await LibTVCLIContract.verify(runtime: record.identity) { arguments in
            try await candidateRunner.run(arguments: arguments, timeout: .seconds(15))
        }
        let account = try await candidateRunner.run(arguments: ["account", "info"], timeout: .seconds(90))
        guard account.exitCode == 0, !account.requiresManualReview else {
            throw AgentRuntimeError.libTVMetadata("候选 Runtime 无法读取隔离账号：\(account.standardError)")
        }
        let accountList = try await candidateRunner.run(arguments: ["account", "list"], timeout: .seconds(90))
        guard accountList.exitCode == 0, !accountList.requiresManualReview else {
            throw AgentRuntimeError.libTVMetadata("候选 Runtime 无法读取账号列表：\(accountList.standardError)")
        }

        let candidates = try await ModelCatalogService().fetch(
            using: candidateRunner,
            existing: [],
            forceSchemaRefresh: true
        )
        let production = await insights.generationSchemas(profileRef: profileRef)
        let schemaDiff = Self.runtimeSchemaDiff(production: production, candidate: candidates)
        try Self.persistCandidateSchemas(
            candidates,
            validationID: validationID,
            stagingRoot: runtimeRegistry.stagingURL
        )
        let testReport: [String: JSONPayloadValue] = [
            "cli_contract": cliContract,
            "checks": .object([
                "version": .bool(true),
                "login": .bool(true),
                "account": .bool(true),
                "model_catalog": .bool(true),
                "schema_snapshot": .bool(true),
            ]),
            "validation_profile_ref": .string(profileRef),
            "candidate_model_count": .number(Double(candidates.count)),
            "production_model_count": .number(Double(production.count)),
        ]
        try await runtimeRegistry.upsertRuntimeValidationReport(
            RunnerRuntimeValidationReport(
                validationID: validationID,
                status: "running",
                record: record,
                testReport: testReport,
                schemaDiff: schemaDiff
            )
        )
        return record
    }

    private nonisolated static func runtimeSchemaDiff(
        production: [LibTVModelSchemaSnapshot],
        candidate: [CatalogCandidate]
    ) -> [String: JSONPayloadValue] {
        let old = Dictionary(uniqueKeysWithValues: production.map { ($0.modelRef, $0.schemaHash) })
        let new = Dictionary(uniqueKeysWithValues: candidate.map { ($0.modelRef, $0.schemaHash) })
        let added = new.keys.filter { old[$0] == nil }.sorted().map(JSONPayloadValue.string)
        let removed = old.keys.filter { new[$0] == nil }.sorted().map(JSONPayloadValue.string)
        let changed = new.keys.compactMap { modelRef -> JSONPayloadValue? in
            guard let oldHash = old[modelRef], let newHash = new[modelRef], oldHash != newHash else { return nil }
            return .object([
                "model_ref": .string(modelRef),
                "previous_schema_hash": .string(oldHash),
                "candidate_schema_hash": .string(newHash),
            ])
        }.sorted { ($0.objectValue?["model_ref"]?.stringValue ?? "") < ($1.objectValue?["model_ref"]?.stringValue ?? "") }
        return ["added": .array(added), "removed": .array(removed), "changed": .array(changed)]
    }

    private nonisolated static func persistCandidateSchemas(
        _ candidates: [CatalogCandidate],
        validationID: String,
        stagingRoot: URL
    ) throws {
        guard UUID(uuidString: validationID) != nil else {
            throw AgentRuntimeError.libTVMetadata("Runtime validation_id 非法")
        }
        let directory = stagingRoot
            .appending(path: validationID, directoryHint: .isDirectory)
            .appending(path: "schemas", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        for candidate in candidates {
            guard candidate.modelRef.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil,
                  let schema = candidate.rawSchema else { continue }
            let data = try JSONEncoder().encode(schema)
            let url = directory.appending(path: "\(candidate.modelRef).json")
            try data.write(to: url, options: .atomic)
            guard chmod(url.path, 0o600) == 0 else {
                throw AgentRuntimeError.libTVMetadata("无法保护候选 Schema 文件权限")
            }
        }
    }

    private func activateRuntime(_ command: RunnerControlCommand) async throws -> LibTVRuntimeRecord {
        guard let runtimeRegistry else { throw AgentRuntimeError.libTVUnverified("Runtime Registry 未就绪") }
        guard (await engine?.snapshot().activeJobs.isEmpty) != false else { throw AgentRuntimeError.profileBusy }
        let requestedVersion = command.payload["version"]?.stringValue
        let requestedHash = command.payload["sha256"]?.stringValue
        let snapshot = try await runtimeRegistry.snapshot()
        if snapshot.candidate?.version != requestedVersion
            || (requestedHash != nil && snapshot.candidate?.sha256 != requestedHash) {
            _ = try await installRuntimeCandidate(command)
        }
        guard let candidate = try await runtimeRegistry.snapshot().candidateRecord else {
            throw LibTVRuntimeRegistryError.candidateUnavailable
        }
        let contract = try await verifyRuntimeContract(candidate)
        if let expectedAdapter = command.payload["cli_adapter_id"]?.stringValue,
           contract.objectValue?["adapter_id"]?.stringValue != expectedAdapter {
            throw LibTVCLIContractError.unsupportedAdapter(expectedAdapter)
        }
        guard (await engine?.snapshot().activeJobs.isEmpty) != false else { throw AgentRuntimeError.profileBusy }
        let activated = try await runtimeRegistry.activateCandidate(expected: candidate.identity)
        do {
            libTVVerification = try Self.verifyRuntime(activated)
        } catch {
            _ = try? await runtimeRegistry.rollback()
            await verifyLibTV()
            throw error
        }
        profileRunners = [:]
        registeredProfileSignature = ""
        return activated
    }

    private func rollbackRuntime() async throws -> LibTVRuntimeRecord {
        guard let runtimeRegistry else { throw AgentRuntimeError.libTVUnverified("Runtime Registry 未就绪") }
        guard let previous = try await runtimeRegistry.snapshot().previousRecord else {
            throw LibTVRuntimeRegistryError.previousUnavailable
        }
        _ = try await verifyRuntimeContract(previous)
        guard (await engine?.snapshot().activeJobs.isEmpty) != false else { throw AgentRuntimeError.profileBusy }
        let rolledBack = try await runtimeRegistry.rollback(expected: previous.identity)
        do {
            libTVVerification = try Self.verifyRuntime(rolledBack)
            return rolledBack
        } catch {
            _ = try? await runtimeRegistry.rollback()
            await verifyLibTV()
            throw error
        }
    }

    private func refreshRuntimeValidationReports() async {
        guard let runtimeRegistry, let transport else { return }
        let jobs = await transport.jobsSnapshot()
        for report in await runtimeRegistry.pendingRuntimeValidationReports() where report.status == "running" {
            let matching = jobs.filter {
                $0.payload["runtime_validation_id"]?.stringValue == report.validationID
            }
            let image = matching.first { $0.payload["modality"]?.stringValue == "image" }
            let video = matching.first { $0.payload["modality"]?.stringValue == "video" }
            guard let image, let video else { continue }
            if [image, video].contains(where: { $0.state.isTerminal && $0.state != .succeeded }) {
                if let record = try? await runtimeRegistry.resolveRuntime(
                    requirement: .init(version: report.version, sha256: report.sha256),
                    persisted: nil,
                    remoteTaskExists: false
                ), let failed = try? RunnerRuntimeValidationReport(
                    validationID: report.validationID,
                    status: "failed",
                    record: record,
                    detail: "Runtime canary image/video task failed or needs review."
                ) { try? await runtimeRegistry.upsertRuntimeValidationReport(failed) }
                continue
            }
            guard image.state == .succeeded, video.state == .succeeded,
                  image.resultArtifactID != nil, video.resultArtifactID != nil,
                  let record = try? await runtimeRegistry.resolveRuntime(
                    requirement: .init(version: report.version, sha256: report.sha256),
                    persisted: nil,
                    remoteTaskExists: false
                  ) else { continue }
            let videoSettings = video.payload["settings"]?.objectValue ?? [:]
            let canaryReport: [String: JSONPayloadValue] = [
                "image": .object(validationEvidence(for: image)),
                "video": .object(validationEvidence(for: video).merging([
                    "duration_seconds": videoSettings["duration"] ?? videoSettings["duration_seconds"] ?? .number(5),
                    "resolution": videoSettings["resolution"] ?? .string("720p"),
                    "audio": videoSettings["audio"] ?? videoSettings["generate_audio"] ?? .bool(false),
                ]) { _, new in new }),
            ]
            let testReport = report.testReport.merging(canaryReport) { _, new in new }
            if let passed = try? RunnerRuntimeValidationReport(
                validationID: report.validationID,
                status: "passed",
                record: record,
                testReport: testReport,
                schemaDiff: report.schemaDiff
            ) { try? await runtimeRegistry.upsertRuntimeValidationReport(passed) }
        }
    }

    private func validationEvidence(for job: RunnerJob) -> [String: JSONPayloadValue] {
        let result = job.result?.objectValue ?? [:]
        let diagnostics = result["parameter_diagnostics"]?.objectValue ?? [:]
        return [
            "job_id": .string(job.id),
            "status": .string(job.state.rawValue),
            "remote_task_id": .string(job.remoteTaskID ?? ""),
            "artifact_archived": .bool(job.resultArtifactID != nil),
            "artifact_downloaded": .bool(job.resultArtifactID != nil),
            "parameter_fingerprint_status": diagnostics["status"] ?? .string("missing"),
            "progress_percent": result["progress_percent"] ?? .null,
        ]
    }

    private func runtimeAcknowledgement(
        status: String,
        detail: String?,
        record: LibTVRuntimeRecord?
    ) -> CommandAcknowledgement {
        guard let record else { return .init(status: status, detail: detail) }
        return .init(
            status: status,
            detail: detail,
            runtimeVersion: record.identity.version,
            runtimeSHA256: record.identity.sha256,
            runtimePlatform: "macos-arm64",
            runtimeVerified: record.strictSignatureValid
                && record.teamIdentifier == LibTVRuntimeInstaller.officialTeamIdentifier,
            runnerProtocolVersion: "1"
        )
    }

    private func verifyLibTV() async {
        do {
            let bundledVerification = try LibTVBinaryVerifier.verify(
                executableURL: AgentBundleLayout.libTVExecutableURL,
                expectedVersion: Self.expectedLibTVVersion,
                expectedSHA256: Self.expectedLibTVSHA256,
                requireThinArm64: true,
                expectedTeamIdentifier: LibTVRuntimeInstaller.officialTeamIdentifier
            )
            if runtimeRegistry == nil {
                let fallback = LibTVRuntimeRecord(
                    identity: .init(version: Self.expectedLibTVVersion, sha256: Self.expectedLibTVSHA256),
                    executableURL: AgentBundleLayout.libTVExecutableURL,
                    source: .bundled,
                    teamIdentifier: bundledVerification.teamIdentifier,
                    cdHash: bundledVerification.cdHash,
                    strictSignatureValid: bundledVerification.strictSignatureValid
                )
                let registry = LibTVRuntimeRegistry(
                    rootURL: runnerRoot.appending(path: "Runtimes", directoryHint: .isDirectory),
                    bundledFallback: fallback
                )
                try await registry.bootstrap()
                runtimeRegistry = registry
                runtimeInstaller = LibTVRuntimeInstaller(registry: registry)
            }
            guard let runtimeRegistry else { throw AgentRuntimeError.libTVUnverified("Runtime Registry 未就绪") }
            var active = try await runtimeRegistry.activeRuntime()
            do {
                libTVVerification = try Self.verifyRuntime(active)
                _ = try await verifyRuntimeContract(active)
            } catch {
                active = try await runtimeRegistry.recoverToBundledFallback()
                libTVVerification = try Self.verifyRuntime(active)
                _ = try await verifyRuntimeContract(active)
                appendLog(.warning, "active Runtime 校验失败，已原子回退到 App 内置 1.0.2：\(error.localizedDescription)")
            }
            libTVVerificationError = nil
            registeredProfileSignature = ""
            appendLog(.info, "LibTV \(active.identity.version) Runtime 完整性校验通过")
        } catch {
            libTVVerification = nil
            libTVVerificationError = error.localizedDescription
            state = .degraded
            appendLog(.error, "LibTV 完整性校验失败：\(error.localizedDescription)")
        }
    }

    private func verifyRuntimeContract(_ record: LibTVRuntimeRecord) async throws -> JSONPayloadValue {
        _ = try Self.verifyRuntime(record)
        let home = FileManager.default.temporaryDirectory.appending(path: "QumoCLIContract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = LibTVProcessRunner(executableURL: record.executableURL, homeURL: home)
        return try await LibTVCLIContract.verify(runtime: record.identity) { arguments in
            try await runner.run(arguments: arguments, timeout: .seconds(15))
        }
    }

    private nonisolated static func verifyRuntime(_ record: LibTVRuntimeRecord) throws -> LibTVBinaryVerification {
        try LibTVBinaryVerifier.verify(
            executableURL: record.executableURL,
            expectedVersion: record.identity.version,
            expectedSHA256: record.identity.sha256,
            requireThinArm64: true,
            expectedTeamIdentifier: LibTVRuntimeInstaller.officialTeamIdentifier
        )
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
