import AppKit
import Foundation
import SwiftUI

@MainActor
final class RunnerAppStore: ObservableObject {
    enum LoadingState: Equatable { case loading, loaded, failed(String) }

    @Published var snapshot = RunnerSnapshot.empty
    @Published var loadingState: LoadingState = .loading
    @Published var operationMessage: String?
    @Published var selectedJobID: String?
    @Published var selectedAccountID: String?
    @Published var isPerformingOperation = false
    @Published var isStartingAccountAuthorization = false
    @Published var pendingLoginProfileRef: String?
    @Published var loginStatusMessage: String?
    @Published private(set) var modelBatchProgress: RunnerModelBatchProgress?

    var isAuthorizingAccount: Bool { isStartingAccountAuthorization || pendingLoginProfileRef != nil }

    @AppStorage("runner.notifications.enabled") var notificationsEnabled = true
    @AppStorage("runner.autostart.enabled") var autoStartEnabled = true
    @AppStorage("runner.server.url") var savedServerURL = ""
    @AppStorage("runner.id") var runnerID = ""
    @AppStorage("runner.data.directory") var dataDirectory = ""
    @AppStorage("runner.concurrency.limit") var concurrencyLimit = 4

    private let client = RunnerAgentClient.shared
    private var refreshTask: Task<Void, Never>?
    private var authorizationChrome: NSRunningApplication?
    private var cancelledLoginProfileRefs: Set<String> = []
    private var accountAuthorizationWasCancelled = false

    init() {
        if dataDirectory.isEmpty {
            dataDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appending(path: "QumoRunner").path
        }
    }

    func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task {
            await refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await refresh(showLoading: false)
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func refresh(showLoading: Bool = true) async {
        if showLoading && loadingState != .loaded { loadingState = .loading }
        do {
            let previous = snapshot
            let current = try await client.fetchSnapshot()
            snapshot = current
            if isStartingAccountAuthorization,
               pendingLoginProfileRef == nil,
               let pending = current.accounts.first(where: { $0.accountRef == "pending" }) {
                pendingLoginProfileRef = pending.id
                loginStatusMessage = "正在获取 LibTV 官方登录链接…"
            }
            concurrencyLimit = current.concurrencyLimit
            loadingState = .loaded
            RunnerNotificationService.shared.evaluate(previous: previous, current: current, enabled: notificationsEnabled)
        } catch {
            if snapshot.jobs.isEmpty && snapshot.accounts.isEmpty {
                loadingState = .failed(error.localizedDescription)
            } else if showLoading {
                operationMessage = "刷新失败：\(error.localizedDescription)"
            }
        }
    }

    func setCLINightly(_ enabled: Bool) async {
        await execute(command: "set_cli_nightly", payload: ["enabled": String(enabled)], showSuccessMessage: false)
    }
    func checkCLIUpdate() async { await execute(command: "check_cli_update") }
    func updateCLI(version: String? = nil) async {
        await execute(command: "update_cli", payload: version.map { ["version": $0] } ?? [:])
    }
    func rollbackCLI() async { await execute(command: "rollback_cli") }

    func setPaused(_ paused: Bool) async {
        await execute(command: paused ? "pause_claiming" : "resume_claiming")
    }

    func cancelBeforeSubmission(job: RunnerJob) async {
        guard job.state.mayCancelBeforeSubmission else {
            operationMessage = "该任务已经开始提交，不能再标记为已取消。"
            return
        }
        await execute(command: "cancel_before_submission", payload: ["job_id": job.id])
    }

    func stopTracking(job: RunnerJob) async {
        guard job.state.mayStopTracking else { return }
        await execute(command: "stop_tracking", payload: ["job_id": job.id])
    }

    func resolveReview(job: RunnerJob, resolution: String) async {
        await execute(command: "resolve_review", payload: ["job_id": job.id, "resolution": resolution])
    }

    func toggleAccount(_ account: RunnerAccount) async {
        await execute(command: account.enabled ? "disable_profile" : "enable_profile", payload: ["profile_ref": account.id])
    }

    func authorizeOrSyncFromChrome(_ account: RunnerAccount) async {
        if account.authExpired || account.insightStatus == .webLoginRequired {
            await beginBrowserAuthorization(command: "authorize_chrome_profile", payload: ["profile_ref": account.id])
        } else {
            await execute(command: "refresh_account_insights", payload: ["profile_ref": account.id], showSuccessMessage: false)
        }
    }

    func refreshModelCatalog(_ account: RunnerAccount) async {
        await execute(command: "refresh_model_catalog", payload: ["profile_ref": account.id], showSuccessMessage: false)
    }

    func refreshAllModelCatalogs() async {
        let accounts = snapshot.accounts.filter { $0.accountRef != "pending" }
        guard !accounts.isEmpty else {
            operationMessage = "请先添加 LibTV 账号，再同步模型目录。"
            return
        }
        isPerformingOperation = true
        defer { isPerformingOperation = false }
        var failures: [String] = []
        var succeeded = 0
        for account in accounts {
            do {
                let response = try await client.command("refresh_model_catalog", payload: ["profile_ref": account.id])
                if response.accepted { succeeded += 1 }
                else { failures.append("\(account.displayName)：\(response.message)") }
            } catch {
                failures.append("\(account.displayName)：\(error.localizedDescription)")
            }
        }
        await refresh(showLoading: false)
        operationMessage = failures.isEmpty
            ? "已刷新 \(succeeded) 个账号的模型目录。"
            : "已刷新 \(succeeded)/\(accounts.count) 个账号；失败：\(failures.prefix(3).joined(separator: "；"))"
    }

    func setModelApproval(_ model: RunnerModelCatalogItem, account: RunnerAccount, approved: Bool) async {
        await execute(
            command: approved ? "approve_model" : "disable_model",
            payload: [
                "profile_ref": account.id,
                "model_ref": model.modelRef,
                "expected_schema_hash": model.schemaHash,
            ]
        )
    }

    func setGlobalModelApproval(modelRef: String, expectedSchemaHashes: [String: String], approved: Bool) async {
        _ = await setGlobalModelApprovals(
            expectedSchemaHashesByModel: [modelRef: expectedSchemaHashes],
            approved: approved
        )
    }

    @discardableResult
    func setGlobalModelApprovals(
        expectedSchemaHashesByModel: [String: [String: String]],
        approved: Bool
    ) async -> RunnerModelBatchResult {
        let requestedModelRefs = Set(expectedSchemaHashesByModel.keys)
        guard !isPerformingOperation else {
            operationMessage = "另一个操作正在进行，请完成后再批量管理模型。"
            return RunnerModelBatchResult(
                requestedModelRefs: requestedModelRefs,
                failedModelRefs: requestedModelRefs,
                completedConfigurationCount: 0,
                totalConfigurationCount: 0
            )
        }

        let accounts = snapshot.accounts
            .filter { $0.accountRef != "pending" }
            .sorted { $0.id < $1.id }
        var targets: [(modelRef: String, account: RunnerAccount, expectedSchemaHash: String)] = []
        for modelRef in expectedSchemaHashesByModel.keys.sorted() {
            guard let hashes = expectedSchemaHashesByModel[modelRef] else { continue }
            for account in accounts {
                guard let expectedSchemaHash = hashes[account.id],
                      let model = account.models.first(where: { $0.modelRef == modelRef }) else { continue }
                let needsChange = approved
                    ? model.approvalState == .pending || model.approvalState == .changed
                    : model.approvalState == .approved
                if needsChange { targets.append((modelRef, account, expectedSchemaHash)) }
            }
        }

        guard !targets.isEmpty else {
            operationMessage = approved ? "所选模型均已启用。" : "所选模型当前均未启用。"
            return RunnerModelBatchResult(
                requestedModelRefs: requestedModelRefs,
                failedModelRefs: [],
                completedConfigurationCount: 0,
                totalConfigurationCount: 0
            )
        }

        isPerformingOperation = true
        modelBatchProgress = RunnerModelBatchProgress(approved: approved, completed: 0, total: targets.count)
        defer {
            modelBatchProgress = nil
            isPerformingOperation = false
        }
        var failures: [String] = []
        var failedModelRefs = Set<String>()
        var succeeded = 0
        for (index, target) in targets.enumerated() {
            do {
                let response = try await client.command(
                    approved ? "approve_model" : "disable_model",
                    payload: [
                        "profile_ref": target.account.id,
                        "model_ref": target.modelRef,
                        "expected_schema_hash": target.expectedSchemaHash,
                    ]
                )
                if response.accepted { succeeded += 1 }
                else {
                    failedModelRefs.insert(target.modelRef)
                    failures.append("\(target.modelRef) / \(target.account.displayName)：\(response.message)")
                }
            } catch {
                failedModelRefs.insert(target.modelRef)
                failures.append("\(target.modelRef) / \(target.account.displayName)：\(error.localizedDescription)")
            }
            modelBatchProgress = RunnerModelBatchProgress(approved: approved, completed: index + 1, total: targets.count)
        }
        await refresh(showLoading: false)
        if failures.isEmpty {
            operationMessage = "已批量\(approved ? "启用" : "停用") \(requestedModelRefs.count) 个模型，共更新 \(succeeded) 项账号配置。"
        } else {
            operationMessage = "已完成 \(succeeded)/\(targets.count) 项账号配置；失败：\(failures.prefix(3).joined(separator: "；"))"
        }
        return RunnerModelBatchResult(
            requestedModelRefs: requestedModelRefs,
            failedModelRefs: failedModelRefs,
            completedConfigurationCount: succeeded,
            totalConfigurationCount: targets.count
        )
    }

    func loginAccount(profileRef: String? = nil) async {
        var payload: [String: String] = [:]
        if let profileRef { payload["profile_ref"] = profileRef }
        await beginBrowserAuthorization(command: profileRef == nil ? "add_profile" : "relogin_profile", payload: payload)
    }

    func cancelOrRemovePendingAccount(_ account: RunnerAccount) async {
        let command = pendingLoginProfileRef == account.id ? "cancel_login" : "discard_pending_profile"
        do {
            if pendingLoginProfileRef == account.id {
                cancelledLoginProfileRefs.insert(account.id)
                accountAuthorizationWasCancelled = true
            }
            await terminateAuthorizationChrome()
            let response = try await client.command(command, payload: ["profile_ref": account.id])
            guard response.accepted else { throw RunnerAgentClientError.commandRejected(response.message) }
            if pendingLoginProfileRef == account.id {
                pendingLoginProfileRef = nil
                loginStatusMessage = nil
            }
            await refresh(showLoading: false)
        } catch {
            operationMessage = error.localizedDescription
        }
    }

    private func beginBrowserAuthorization(command: String, payload: [String: String]) async {
        guard !isAuthorizingAccount else {
            operationMessage = "已有账号正在等待专属 Chrome 窗口授权。"
            return
        }
        if let pending = snapshot.accounts.first(where: { $0.accountRef == "pending" }) {
            pendingLoginProfileRef = pending.id
            loginStatusMessage = "请先继续或取消这次未完成的授权。"
            operationMessage = "检测到未完成的账号授权，请先处理它。"
            return
        }
        isStartingAccountAuthorization = true
        isPerformingOperation = true
        accountAuthorizationWasCancelled = false
        loginStatusMessage = "正在获取 LibTV 官方登录链接…"
        defer {
            isStartingAccountAuthorization = false
            isPerformingOperation = false
            pendingLoginProfileRef = nil
            loginStatusMessage = nil
            authorizationChrome = nil
            accountAuthorizationWasCancelled = false
        }
        do {
            let response = try await client.command(command, payload: payload)
            guard response.accepted else { throw RunnerAgentClientError.commandRejected(response.message) }
            guard let url = response.actionURL, let profileRef = response.profileRef else {
                throw RunnerAgentClientError.invalidResponse
            }
            pendingLoginProfileRef = profileRef
            loginStatusMessage = "等待专属 Chrome 窗口完成 LibTV 登录…"
            do {
                authorizationChrome = try await ChromeAuthorizationLauncher.open(url: url, profileRef: profileRef)
            } catch {
                _ = try? await client.command("cancel_login", payload: ["profile_ref": profileRef])
                throw error
            }
            await refresh(showLoading: false)
            try await waitForLoginResult(profileRef: profileRef)
        } catch {
            let failedProfileRef = pendingLoginProfileRef
            await terminateAuthorizationChrome()
            if let failedProfileRef {
                _ = try? await client.command("discard_pending_profile", payload: ["profile_ref": failedProfileRef])
            }
            if !accountAuthorizationWasCancelled {
                operationMessage = error.localizedDescription
            }
        }
    }

    private func terminateAuthorizationChrome() async {
        guard let chrome = authorizationChrome else { return }
        _ = chrome.terminate()
        for _ in 0..<20 {
            if chrome.isTerminated { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        if !chrome.isTerminated { _ = chrome.forceTerminate() }
        authorizationChrome = nil
    }

    private func waitForLoginResult(profileRef: String) async throws {
        while !Task.isCancelled {
            try await Task.sleep(for: .seconds(1))
            if cancelledLoginProfileRefs.remove(profileRef) != nil { return }
            let response = try await client.command("login_status", payload: ["profile_ref": profileRef])
            loginStatusMessage = response.message
            await refresh(showLoading: false)
            switch response.status {
            case "succeeded":
                return
            case "duplicate", "failed":
                throw RunnerAgentClientError.commandRejected(response.message)
            default:
                continue
            }
        }
        throw CancellationError()
    }

    func updateConcurrency(_ value: Int) async {
        let clamped = min(8, max(1, value))
        concurrencyLimit = clamped
        await execute(command: "set_concurrency", payload: ["value": String(clamped)])
    }

    func runLibTVDiagnostic() async {
        await execute(command: "libtv_diagnostic")
    }

    func pair(serverURLText: String, pairingCode: String) async -> Bool {
        guard let url = validatedServerURL(serverURLText) else {
            operationMessage = "请输入有效的 HTTPS 服务器地址（本机开发可使用 HTTP）。"
            return false
        }
        let code = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.count >= 6 else {
            operationMessage = "配对码格式不正确。"
            return false
        }
        isPerformingOperation = true
        defer { isPerformingOperation = false }
        do {
            let result = try await PairingService().exchange(serverURL: url, pairingCode: code)
            do {
                try RunnerConfigurationStore().save(serverURL: url, runnerID: result.runnerID)
            } catch {
                try? KeychainStore().deleteDeviceToken(runnerID: result.runnerID)
                throw error
            }
            savedServerURL = url.absoluteString
            runnerID = result.runnerID
            operationMessage = "设备配对成功。设备 Token 已安全存入 Keychain。"
            _ = try? await client.command("reload_pairing")
            await refresh(showLoading: false)
            return true
        } catch {
            operationMessage = error.localizedDescription
            return false
        }
    }

    func exportDiagnostics() {
        do {
            if let url = try DiagnosticExporter.export(snapshot: snapshot) {
                operationMessage = "诊断 ZIP 已导出到 \(url.path)"
            }
        } catch { operationMessage = error.localizedDescription }
    }

    private func execute(command: String, payload: [String: String] = [:], showSuccessMessage: Bool = true) async {
        isPerformingOperation = true
        defer { isPerformingOperation = false }
        do {
            let response = try await client.command(command, payload: payload)
            guard response.accepted else { throw RunnerAgentClientError.commandRejected(response.message) }
            if showSuccessMessage { operationMessage = response.message }
            await refresh(showLoading: false)
        } catch { operationMessage = error.localizedDescription }
    }

    private func validatedServerURL(_ text: String) -> URL? {
        guard let components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), ["https", "http"].contains(scheme),
              components.host != nil else { return nil }
        if scheme == "http", components.host != "localhost", components.host != "127.0.0.1" { return nil }
        return components.url
    }
}
