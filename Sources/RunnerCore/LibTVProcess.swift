import Darwin
@preconcurrency import Foundation

public enum LibTVForcedStopReason: String, Equatable, Sendable {
    case timeout
    case requestedAfterLaunch
    case taskCancellationAfterLaunch
}

public enum LibTVProcessDisposition: Equatable, Sendable {
    case exited
    case crashed
    case needsReview(LibTVForcedStopReason)
}

public struct LibTVProcessResult: Equatable, Sendable {
    public let arguments: [String]
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String
    public let disposition: LibTVProcessDisposition

    public var requiresManualReview: Bool {
        if case .needsReview = disposition { return true }
        return false
    }

    /// Commander rejects malformed command lines before the LibTV submission handler runs.
    /// These failures are safe to report as failed instead of an uncertain paid submission.
    public var wasRejectedByArgumentParser: Bool {
        guard disposition == .exited, exitCode != 0 else { return false }
        let diagnostic = "\(standardError)\n\(standardOutput)".lowercased()
        return diagnostic.contains("unknown option")
            || diagnostic.contains("unknown command")
            || diagnostic.contains("missing required argument")
            || diagnostic.contains("required option")
    }
}

public enum LibTVProcessError: Error, Equatable, LocalizedError, Sendable {
    case executableMissing(String)
    case launchFailed(String)
    case duplicateProcessIdentifier(String)

    public var errorDescription: String? {
        switch self {
        case .executableMissing(let path): "LibTV executable is missing at \(path)."
        case .launchFailed(let message): "LibTV could not be launched: \(message)"
        case .duplicateProcessIdentifier(let identifier):
            "A LibTV process is already running for \(identifier)."
        }
    }
}

public enum LibTVProcessOutputStream: Sendable {
    case standardOutput
    case standardError
}

public struct LibTVProcessOutput: Sendable {
    public let stream: LibTVProcessOutputStream
    public let line: String

    public init(stream: LibTVProcessOutputStream, line: String) {
        self.stream = stream
        self.line = line
    }
}

private final class ProcessBox: @unchecked Sendable {
    let process: Process
    init(_ process: Process) { self.process = process }
}

private final class ProcessCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var stopReason: LibTVForcedStopReason?

    func requestStop(_ reason: LibTVForcedStopReason) -> Bool {
        lock.withLock {
            guard stopReason == nil else { return false }
            stopReason = reason
            return true
        }
    }

    func reason() -> LibTVForcedStopReason? {
        lock.withLock { stopReason }
    }
}

private final class TerminationAwaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var continuation: CheckedContinuation<Int32, Never>?

    func finish(_ status: Int32) {
        let continuation = lock.withLock { () -> CheckedContinuation<Int32, Never>? in
            guard self.status == nil else { return nil }
            self.status = status
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: status)
    }

    func value() async -> Int32 {
        await withCheckedContinuation { continuation in
            let completed = lock.withLock { () -> Int32? in
                if let status { return status }
                self.continuation = continuation
                return nil
            }
            if let completed { continuation.resume(returning: completed) }
        }
    }
}

public actor LibTVProcessRunner {
    public let executableURL: URL
    public let homeURL: URL
    public let defaultTimeout: Duration

    private var active: [String: (box: ProcessBox, completion: ProcessCompletion)] = [:]

    public init(
        executableURL: URL,
        homeURL: URL,
        defaultTimeout: Duration = .seconds(30 * 60)
    ) {
        self.executableURL = executableURL
        self.homeURL = homeURL
        self.defaultTimeout = defaultTimeout
    }

    public func run(
        processID: String = "anonymous-\(UUID().uuidString)",
        arguments: [String],
        additionalEnvironment: [String: String] = [:],
        timeout: Duration? = nil,
        onOutput: @escaping @Sendable (LibTVProcessOutput) async -> Void = { _ in }
    ) async throws -> LibTVProcessResult {
        try Task.checkCancellation()
        guard active[processID] == nil else {
            throw LibTVProcessError.duplicateProcessIdentifier(processID)
        }
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw LibTVProcessError.executableMissing(executableURL.path)
        }

        let process = Process()
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("QumoRunner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let stdoutURL = temporaryDirectory.appendingPathComponent("stdout")
        let stderrURL = temporaryDirectory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        var outputHandlesClosed = false
        defer {
            if !outputHandlesClosed {
                try? stdout.close()
                try? stderr.close()
            }
        }
        let termination = TerminationAwaiter()
        process.executableURL = executableURL
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "LIBTV_TOKEN")
        environment.removeValue(forKey: "LIBTV_CONFIG_DIR")
        environment["HOME"] = homeURL.path
        for (key, value) in additionalEnvironment where !["HOME", "LIBTV_TOKEN", "LIBTV_CONFIG_DIR"].contains(key) {
            environment[key] = value
        }
        process.environment = environment
        process.standardOutput = stdout
        process.standardError = stderr
        process.terminationHandler = { terminated in
            termination.finish(terminated.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            throw LibTVProcessError.launchFailed(error.localizedDescription)
        }

        let box = ProcessBox(process)
        let completion = ProcessCompletion()
        active[processID] = (box, completion)
        let monitor = Task {
            await Self.monitorOutput(
                standardOutputURL: stdoutURL,
                standardErrorURL: stderrURL,
                onOutput: onOutput
            )
        }
        let effectiveTimeout = timeout ?? defaultTimeout
        let watchdog = Task { [box, completion] in
            do {
                try await Task.sleep(for: effectiveTimeout)
                if completion.requestStop(.timeout), box.process.isRunning {
                    box.process.terminate()
                    Self.forceKillAfterGrace(box)
                }
            } catch { }
        }

        let exitCode = await withTaskCancellationHandler {
            await termination.value()
        } onCancel: {
            Task {
                await self.stopActive(
                    processID: processID,
                    reason: .taskCancellationAfterLaunch
                )
            }
        }
        watchdog.cancel()
        active.removeValue(forKey: processID)
        try? stdout.close()
        try? stderr.close()
        outputHandlesClosed = true
        monitor.cancel()
        await monitor.value

        // Child output is streamed directly to disk while it runs, so a verbose CLI cannot
        // fill a pipe and deadlock before the watchdog gets a chance to terminate it.
        let outputData = (try? Data(contentsOf: stdoutURL)) ?? Data()
        let errorData = (try? Data(contentsOf: stderrURL)) ?? Data()
        let output = String(decoding: outputData, as: UTF8.self)
        let errorOutput = String(decoding: errorData, as: UTF8.self)
        let disposition: LibTVProcessDisposition
        if let reason = completion.reason() {
            disposition = .needsReview(reason)
        } else if process.terminationReason == .uncaughtSignal {
            disposition = .crashed
        } else {
            disposition = .exited
        }
        return LibTVProcessResult(
            arguments: arguments,
            exitCode: exitCode,
            standardOutput: output,
            standardError: errorOutput,
            disposition: disposition
        )
    }

    /// Stopping an already launched CLI never claims that the remote task was cancelled.
    @discardableResult
    public func stopActive(
        processID: String,
        reason: LibTVForcedStopReason = .requestedAfterLaunch
    ) -> Bool {
        guard let active = active[processID] else { return false }
        if active.completion.requestStop(reason), active.box.process.isRunning {
            active.box.process.terminate()
            Self.forceKillAfterGrace(active.box)
        }
        return true
    }

    public func activeProcessIDs() -> Set<String> {
        Set(active.keys)
    }

    private nonisolated static func monitorOutput(
        standardOutputURL: URL,
        standardErrorURL: URL,
        onOutput: @escaping @Sendable (LibTVProcessOutput) async -> Void
    ) async {
        guard let stdout = try? FileHandle(forReadingFrom: standardOutputURL),
              let stderr = try? FileHandle(forReadingFrom: standardErrorURL) else { return }
        defer {
            try? stdout.close()
            try? stderr.close()
        }
        var stdoutBuffer = Data()
        var stderrBuffer = Data()

        func drain(
            _ handle: FileHandle,
            stream: LibTVProcessOutputStream,
            buffer: inout Data,
            flushRemainder: Bool = false
        ) async {
            if let data = try? handle.readToEnd(), !data.isEmpty {
                buffer.append(data)
            }
            while let newline = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[..<newline]
                buffer.removeSubrange(...newline)
                var line = String(decoding: lineData, as: UTF8.self)
                if line.last == "\r" { line.removeLast() }
                await onOutput(.init(stream: stream, line: line))
            }
            if flushRemainder, !buffer.isEmpty {
                await onOutput(.init(stream: stream, line: String(decoding: buffer, as: UTF8.self)))
                buffer.removeAll(keepingCapacity: false)
            }
        }

        while !Task.isCancelled {
            await drain(stdout, stream: .standardOutput, buffer: &stdoutBuffer)
            await drain(stderr, stream: .standardError, buffer: &stderrBuffer)
            do { try await Task.sleep(for: .milliseconds(25)) }
            catch { break }
        }
        await drain(stdout, stream: .standardOutput, buffer: &stdoutBuffer, flushRemainder: true)
        await drain(stderr, stream: .standardError, buffer: &stderrBuffer, flushRemainder: true)
    }

    private nonisolated static func forceKillAfterGrace(_ box: ProcessBox) {
        Task.detached {
            try? await Task.sleep(for: .seconds(2))
            if box.process.isRunning {
                Darwin.kill(box.process.processIdentifier, SIGKILL)
            }
        }
    }
}

public actor ProfileExecutor {
    public let profileRef: String
    private let runner: LibTVProcessRunner
    private let limiter: GlobalConcurrencyLimiter
    private var maxConcurrency = 1
    private var activeCount = 0
    private var activeJobIDs = Set<String>()
    private var waiterOrder: [UUID] = []
    private var profileWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]

    public init(
        profileRef: String,
        runner: LibTVProcessRunner,
        limiter: GlobalConcurrencyLimiter
    ) {
        self.profileRef = profileRef
        self.runner = runner
        self.limiter = limiter
    }

    public func execute(
        jobID: String,
        arguments: [String],
        additionalEnvironment: [String: String] = [:],
        timeout: Duration? = nil,
        onOutput: @escaping @Sendable (LibTVProcessOutput) async -> Void = { _ in }
    ) async throws -> LibTVProcessResult {
        try await acquireProfile()
        do {
            try await limiter.acquire()
        } catch {
            releaseProfile()
            throw error
        }
        activeJobIDs.insert(jobID)
        do {
            let result = try await runner.run(
                processID: jobID,
                arguments: arguments,
                additionalEnvironment: additionalEnvironment,
                timeout: timeout,
                onOutput: onOutput
            )
            await limiter.release()
            activeJobIDs.remove(jobID)
            releaseProfile()
            return result
        } catch {
            await limiter.release()
            activeJobIDs.remove(jobID)
            releaseProfile()
            throw error
        }
    }

    public func execute(
        arguments: [String],
        additionalEnvironment: [String: String] = [:],
        timeout: Duration? = nil
    ) async throws -> LibTVProcessResult {
        try await execute(
            jobID: "anonymous-\(UUID().uuidString)",
            arguments: arguments,
            additionalEnvironment: additionalEnvironment,
            timeout: timeout
        )
    }

    @discardableResult
    public func stopTracking(jobID: String) async -> Bool {
        guard activeJobIDs.contains(jobID) else { return false }
        return await runner.stopActive(processID: jobID, reason: .requestedAfterLaunch)
    }

    /// Shrinking is drain-only: existing executions keep their permits and new waiters resume
    /// only after the active count drops below the new limit.
    public func setMaxConcurrency(_ newValue: Int) {
        maxConcurrency = min(8, max(0, newValue))
        resumeEligibleProfileWaiters()
    }

    public func configuredMaxConcurrency() -> Int { maxConcurrency }

    public func runningJobIDs() -> Set<String> { activeJobIDs }

    private func acquireProfile() async throws {
        if activeCount < maxConcurrency {
            activeCount += 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiterOrder.append(id)
                    profileWaiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelProfileWaiter(id) }
        }
    }

    private func releaseProfile() {
        precondition(activeCount > 0)
        activeCount -= 1
        resumeEligibleProfileWaiters()
    }

    private func resumeEligibleProfileWaiters() {
        while activeCount < maxConcurrency, !waiterOrder.isEmpty {
            let id = waiterOrder.removeFirst()
            guard let continuation = profileWaiters.removeValue(forKey: id) else { continue }
            activeCount += 1
            continuation.resume()
        }
    }

    private func cancelProfileWaiter(_ id: UUID) {
        guard let continuation = profileWaiters.removeValue(forKey: id) else { return }
        waiterOrder.removeAll { $0 == id }
        continuation.resume(throwing: CancellationError())
    }
}
