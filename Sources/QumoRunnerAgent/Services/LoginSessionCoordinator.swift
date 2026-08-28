import Foundation
import RunnerCore

enum LoginSessionPhase: String, Sendable {
    case waiting
    case succeeded
    case failed
    case duplicate
}

struct LoginSessionSnapshot: Sendable {
    let phase: LoginSessionPhase
    let message: String
}

final class LoginSessionCoordinator: @unchecked Sendable {
    private final class Session: @unchecked Sendable {
        let process: Process
        let pipe: Pipe
        let isNewProfile: Bool
        var buffer = Data()
        var continuation: CheckedContinuation<URL, Error>?
        var preservesTerminalOutcome = false
        init(process: Process, pipe: Pipe, isNewProfile: Bool, continuation: CheckedContinuation<URL, Error>) {
            self.process = process
            self.pipe = pipe
            self.isNewProfile = isNewProfile
            self.continuation = continuation
        }
    }

    private let lock = NSLock()
    private var sessions: [String: Session] = [:]
    private var outcomes: [String: LoginSessionSnapshot] = [:]
    private let registry: AgentProfileRegistry
    private let onLoginCompleted: @Sendable (String) -> Void
    private let onProfileDiscarded: @Sendable (String) -> Void

    init(
        registry: AgentProfileRegistry,
        onLoginCompleted: @escaping @Sendable (String) -> Void = { _ in },
        onProfileDiscarded: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.registry = registry
        self.onLoginCompleted = onLoginCompleted
        self.onProfileDiscarded = onProfileDiscarded
    }

    func begin(profile: RunnerProfile, paths: ProfilePaths) async throws -> URL {
        let executable = AgentBundleLayout.libTVExecutableURL
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw LoginError.missingLibTV(executable.path) }
        let isNewProfile = profile.accountRef == "pending"
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = executable
            process.arguments = ["login", "web"]
            var environment = ProcessInfo.processInfo.environment
            for key in ["LIBTV_TOKEN", "LIBTV_CONFIG_DIR", "LIBTV_LOGIN_WEB_URL", "LIBTV_LOGIN_WEB_PATH"] {
                environment.removeValue(forKey: key)
            }
            environment["HOME"] = paths.home.path
            process.environment = environment
            process.standardOutput = pipe
            process.standardError = pipe
            let session = Session(process: process, pipe: pipe, isNewProfile: isNewProfile, continuation: continuation)
            let accepted = lock.withLock { () -> Bool in
                if sessions[profile.profileRef] != nil { return false }
                if isNewProfile, sessions.values.contains(where: \.isNewProfile) { return false }
                sessions[profile.profileRef] = session
                outcomes[profile.profileRef] = .init(phase: .waiting, message: "正在获取 LibTV 官方登录链接…")
                return true
            }
            guard accepted else {
                if isNewProfile { discardPending(profileRef: profile.profileRef) }
                continuation.resume(throwing: LoginError.alreadyInProgress)
                return
            }
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                self?.ingest(handle.availableData, profileRef: profile.profileRef)
            }
            process.terminationHandler = { [weak self] process in
                self?.finish(profile: profile, paths: paths, status: process.terminationStatus)
            }
            do { try process.run() }
            catch {
                _ = lock.withLock { sessions.removeValue(forKey: profile.profileRef) }
                record(profileRef: profile.profileRef, phase: .failed, message: error.localizedDescription)
                if isNewProfile { discardPending(profileRef: profile.profileRef) }
                continuation.resume(throwing: error)
            }
        }
    }

    func status(profileRef: String) -> LoginSessionSnapshot {
        lock.withLock {
            outcomes[profileRef] ?? .init(phase: .failed, message: "找不到这次账号授权记录，请重试。")
        }
    }

    func cancel(profileRef: String) {
        var isNewProfile = false
        lock.withLock {
            guard let session = sessions[profileRef] else { return }
            isNewProfile = session.isNewProfile
            session.preservesTerminalOutcome = true
            session.continuation?.resume(throwing: CancellationError())
            session.continuation = nil
            if session.process.isRunning { session.process.terminate() }
        }
        record(profileRef: profileRef, phase: .failed, message: "账号授权已取消。")
        if isNewProfile { discardPending(profileRef: profileRef) }
    }

    private func ingest(_ data: Data, profileRef: String) {
        guard !data.isEmpty else { return }
        var continuation: CheckedContinuation<URL, Error>?
        var url: URL?
        lock.withLock {
            guard let session = sessions[profileRef] else { return }
            session.buffer.append(data)
            if session.buffer.count > 65_536 { session.buffer = session.buffer.suffix(65_536) }
            let text = String(decoding: session.buffer, as: UTF8.self)
            if let detected = LibTVLoginURLValidator.firstOfficialURL(in: text), let pending = session.continuation {
                session.continuation = nil
                continuation = pending
                url = detected
            }
        }
        if let continuation, let url {
            record(profileRef: profileRef, phase: .waiting, message: "等待 Chrome 完成 LibTV 官方授权。")
            continuation.resume(returning: url)
        }
    }

    private func finish(profile: RunnerProfile, paths: ProfilePaths, status: Int32) {
        let remaining = lock.withLock { sessions[profile.profileRef]?.pipe.fileHandleForReading.readDataToEndOfFile() }
        if let remaining, !remaining.isEmpty { ingest(remaining, profileRef: profile.profileRef) }
        var continuation: CheckedContinuation<URL, Error>?
        var preservesTerminalOutcome = false
        lock.withLock {
            guard let session = sessions.removeValue(forKey: profile.profileRef) else { return }
            session.pipe.fileHandleForReading.readabilityHandler = nil
            continuation = session.continuation
            preservesTerminalOutcome = session.preservesTerminalOutcome
            session.continuation = nil
        }
        continuation?.resume(throwing: LoginError.endedBeforeURL(status))
        if preservesTerminalOutcome { return }
        guard status == 0 else {
            record(profileRef: profile.profileRef, phase: .failed, message: "LibTV 授权进程退出（\(status)）。")
            if profile.accountRef == "pending" { discardPending(profileRef: profile.profileRef) }
            return
        }
        Task { await inspectAccount(profile: profile, paths: paths) }
    }

    private func inspectAccount(profile: RunnerProfile, paths: ProfilePaths) async {
        let runner = LibTVProcessRunner(executableURL: AgentBundleLayout.libTVExecutableURL, homeURL: paths.home, defaultTimeout: .seconds(60))
        var lastFailure = AgentProfileRegistryError.unresolvedAccount.localizedDescription
        for attempt in 0..<5 {
            do {
                let info = try await runner.run(arguments: ["account", "info"])
                guard info.exitCode == 0, !info.requiresManualReview else {
                    throw LoginError.accountInspectionFailed(info.exitCode)
                }
                let metadata = LibTVAccountMetadataParser.parse(
                    output: info.standardOutput,
                    fallbackAccountRef: "",
                    fallbackDisplayName: "LibTV 账号"
                )
                try registry.markLogin(
                    profileRef: profile.profileRef,
                    accountRef: metadata.accountRef,
                    displayName: metadata.displayName,
                    capabilities: profile.capabilities,
                    healthy: true
                )
                _ = try? await runner.run(arguments: ["account", "list"])
                record(profileRef: profile.profileRef, phase: .succeeded, message: "LibTV 账号已添加并完成同步。")
                onLoginCompleted(profile.profileRef)
                return
            } catch let error as AgentProfileRegistryError {
                if case .duplicateAccount = error {
                    if profile.accountRef == "pending" { discardPending(profileRef: profile.profileRef) }
                    record(profileRef: profile.profileRef, phase: .duplicate, message: error.localizedDescription)
                    return
                }
                lastFailure = error.localizedDescription
            } catch {
                lastFailure = error.localizedDescription
            }
            if attempt < 4 { try? await Task.sleep(for: .milliseconds(500)) }
        }
        if profile.accountRef == "pending" {
            discardPending(profileRef: profile.profileRef)
        } else {
            try? registry.markLogin(
                profileRef: profile.profileRef,
                accountRef: profile.accountRef,
                displayName: profile.displayName,
                capabilities: profile.capabilities,
                healthy: false
            )
        }
        record(profileRef: profile.profileRef, phase: .failed, message: "账号授权未完成：\(lastFailure)")
    }

    private func record(profileRef: String, phase: LoginSessionPhase, message: String) {
        lock.withLock { outcomes[profileRef] = .init(phase: phase, message: message) }
    }

    private func discardPending(profileRef: String) {
        do {
            try registry.discardPending(profileRef: profileRef)
            onProfileDiscarded(profileRef)
        } catch {
            record(profileRef: profileRef, phase: .failed, message: "失败 Profile 回滚不完整：\(error.localizedDescription)")
        }
    }

}

enum LoginError: LocalizedError {
    case missingLibTV(String), endedBeforeURL(Int32), alreadyInProgress, accountInspectionFailed(Int32)
    var errorDescription: String? {
        switch self {
        case .missingLibTV(let path): "未找到内嵌 LibTV 1.0.2：\(path)"
        case .endedBeforeURL(let status): "LibTV 登录进程在输出链接前退出（\(status)）。"
        case .alreadyInProgress: "已有账号正在等待 Chrome 授权，请完成或稍后重试。"
        case .accountInspectionFailed(let status): "LibTV 账号识别失败（退出码 \(status)）。"
        }
    }
}
