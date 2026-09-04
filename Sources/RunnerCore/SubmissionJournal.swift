import Foundation
import SQLite3

public enum SubmissionPhase: String, Codable, Sendable {
    case intentRecorded = "intent_recorded"
    case remoteKnown = "remote_known"
    case terminal
    case needsReview = "needs_review"
}

public struct SubmissionRecord: Equatable, Sendable {
    public let jobID: String
    public let profileRef: String
    public let requestFingerprint: String
    public let phase: SubmissionPhase
    public let remoteTaskID: String?
    public let terminalState: RunnerJobState?
    public let runtimeVersion: String?
    public let runtimeSHA256: String?
    public let createdAt: Date
    public let updatedAt: Date

    public var runtimeIdentity: LibTVRuntimeIdentity? {
        guard let runtimeVersion, let runtimeSHA256 else { return nil }
        return .init(version: runtimeVersion, sha256: runtimeSHA256)
    }
}

public enum SubmissionRecoveryAction: Equatable, Sendable {
    case submitNew
    case queryRemote(taskID: String)
    case alreadyTerminal(RunnerJobState)
    case needsReview
}

public struct RunnerLogRecord: Equatable, Sendable {
    public let id: Int64
    public let timestamp: Date
    public let level: String
    public let message: String
    public let jobID: String?
    public let profileRef: String?
}

public struct LibTVExecutionLayoutRecord: Equatable, Sendable {
    public let jobID: String
    public let profileRef: String
    public let projectUUID: String
    public let groupName: String
    public let inputNodeNames: [String]
    public let generationNodeName: String
    public let createdAt: Date
}

public enum SubmissionJournalError: Error, LocalizedError, Sendable {
    case open(String)
    case sqlite(code: Int32, message: String)
    case invalidStoredValue(String)
    case missingSubmission(String)
    case conflictingRemoteTaskID(stored: String, requested: String)
    case conflictingRuntime(stored: LibTVRuntimeIdentity, requested: LibTVRuntimeIdentity)

    public var errorDescription: String? {
        switch self {
        case .open(let message): "Unable to open Runner database: \(message)"
        case .sqlite(let code, let message): "SQLite error \(code): \(message)"
        case .invalidStoredValue(let value): "Invalid value in Runner database: \(value)"
        case .missingSubmission(let jobID): "No local submission record exists for job \(jobID)."
        case .conflictingRemoteTaskID(let stored, let requested):
            "Remote task identity conflict: stored \(stored), requested \(requested)."
        case .conflictingRuntime(let stored, let requested):
            "LibTV Runtime identity conflict: stored \(stored.version)/\(stored.sha256), requested \(requested.version)/\(requested.sha256)."
        }
    }
}

private final class SQLiteHandle: @unchecked Sendable {
    let pointer: OpaquePointer
    init(_ pointer: OpaquePointer) { self.pointer = pointer }
    deinit { sqlite3_close(pointer) }
}

public actor SubmissionJournal {
    private let handle: SQLiteHandle
    private var database: OpaquePointer { handle.pointer }

    public init(databaseURL: URL) throws {
        let parent = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var database: OpaquePointer?
        let result = sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let database { sqlite3_close(database) }
            throw SubmissionJournalError.open(message)
        }
        self.handle = SQLiteHandle(database)
        try Self.execute(database, "PRAGMA journal_mode=WAL;")
        try Self.execute(database, "PRAGMA foreign_keys=ON;")
        try Self.execute(database, """
            CREATE TABLE IF NOT EXISTS submissions (
                job_id TEXT PRIMARY KEY NOT NULL,
                profile_ref TEXT NOT NULL,
                request_fingerprint TEXT NOT NULL,
                phase TEXT NOT NULL,
                remote_task_id TEXT,
                terminal_state TEXT,
                runtime_version TEXT,
                runtime_sha256 TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            """)
        try Self.ensureColumn(database, table: "submissions", name: "runtime_version", definition: "TEXT")
        try Self.ensureColumn(database, table: "submissions", name: "runtime_sha256", definition: "TEXT")
        try Self.execute(database, """
            CREATE TABLE IF NOT EXISTS diagnostic_logs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp REAL NOT NULL,
                level TEXT NOT NULL,
                message TEXT NOT NULL,
                job_id TEXT,
                profile_ref TEXT
            );
            """)
        try Self.execute(database, """
            CREATE TABLE IF NOT EXISTS execution_layouts (
                job_id TEXT PRIMARY KEY NOT NULL,
                profile_ref TEXT NOT NULL,
                project_uuid TEXT NOT NULL,
                group_name TEXT NOT NULL,
                input_node_names TEXT NOT NULL,
                generation_node_name TEXT NOT NULL,
                created_at REAL NOT NULL
            );
            """)
        try Self.execute(database, """
            CREATE TABLE IF NOT EXISTS job_runtime_bindings (
                job_id TEXT PRIMARY KEY NOT NULL,
                runtime_version TEXT NOT NULL,
                runtime_sha256 TEXT NOT NULL,
                selected_at REAL NOT NULL
            );
            """)
        _ = chmod(databaseURL.path, 0o600)
    }

    /// Atomically establishes idempotency before a LibTV submission can start.
    /// `false` means this job was already observed and must not be submitted again.
    @discardableResult
    public func recordSubmissionIntent(
        jobID: String,
        profileRef: String,
        requestFingerprint: String,
        runtime: LibTVRuntimeIdentity? = nil,
        at date: Date = .now
    ) throws -> Bool {
        if let runtime { try bindJobRuntime(jobID: jobID, runtime: runtime, at: date) }
        let sql = """
            INSERT OR IGNORE INTO submissions
                (job_id, profile_ref, request_fingerprint, phase, runtime_version,
                 runtime_sha256, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(jobID, to: 1, in: statement)
        bind(profileRef, to: 2, in: statement)
        bind(requestFingerprint, to: 3, in: statement)
        bind(SubmissionPhase.intentRecorded.rawValue, to: 4, in: statement)
        bindOptional(runtime?.version, to: 5, in: statement)
        bindOptional(runtime?.sha256, to: 6, in: statement)
        sqlite3_bind_double(statement, 7, date.timeIntervalSince1970)
        sqlite3_bind_double(statement, 8, date.timeIntervalSince1970)
        try stepDone(statement)
        let inserted = sqlite3_changes(database) == 1
        if !inserted, let runtime { try bindRuntime(jobID: jobID, runtime: runtime, at: date) }
        return inserted
    }

    /// Runtime identity is write-once per job. Legacy rows without identity may be upgraded, but
    /// an existing version/hash can never be silently changed after active Runtime switches.
    public func bindRuntime(
        jobID: String,
        runtime: LibTVRuntimeIdentity,
        at date: Date = .now
    ) throws {
        guard let existing = try record(for: jobID) else {
            throw SubmissionJournalError.missingSubmission(jobID)
        }
        if let stored = existing.runtimeIdentity, stored != runtime {
            throw SubmissionJournalError.conflictingRuntime(stored: stored, requested: runtime)
        }
        guard existing.runtimeIdentity == nil else { return }
        let statement = try prepare("UPDATE submissions SET runtime_version = ?, runtime_sha256 = ?, updated_at = ? WHERE job_id = ?;")
        defer { sqlite3_finalize(statement) }
        bind(runtime.version, to: 1, in: statement)
        bind(runtime.sha256, to: 2, in: statement)
        sqlite3_bind_double(statement, 3, date.timeIntervalSince1970)
        bind(jobID, to: 4, in: statement)
        try stepDone(statement)
    }

    /// Persists Runtime selection before any preparation CLI command can run. This table is
    /// independent from paid-submission intent, so preparing a job does not make a safe retry look
    /// like an uncertain paid submission.
    public func bindJobRuntime(
        jobID: String,
        runtime: LibTVRuntimeIdentity,
        at date: Date = .now
    ) throws {
        if let stored = try runtimeIdentity(for: jobID), stored != runtime {
            throw SubmissionJournalError.conflictingRuntime(stored: stored, requested: runtime)
        }
        let statement = try prepare("""
            INSERT OR IGNORE INTO job_runtime_bindings
                (job_id, runtime_version, runtime_sha256, selected_at)
            VALUES (?, ?, ?, ?);
            """)
        defer { sqlite3_finalize(statement) }
        bind(jobID, to: 1, in: statement)
        bind(runtime.version, to: 2, in: statement)
        bind(runtime.sha256, to: 3, in: statement)
        sqlite3_bind_double(statement, 4, date.timeIntervalSince1970)
        try stepDone(statement)
    }

    public func runtimeIdentity(for jobID: String) throws -> LibTVRuntimeIdentity? {
        let statement = try prepare("SELECT runtime_version, runtime_sha256 FROM job_runtime_bindings WHERE job_id = ? LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        bind(jobID, to: 1, in: statement)
        let code = sqlite3_step(statement)
        if code == SQLITE_ROW {
            return .init(version: text(statement, 0) ?? "", sha256: text(statement, 1) ?? "")
        }
        guard code == SQLITE_DONE else { throw sqliteError(code) }
        return try record(for: jobID)?.runtimeIdentity
    }

    public func retainedRuntimeIdentities() throws -> Set<LibTVRuntimeIdentity> {
        let statement = try prepare("""
            SELECT DISTINCT b.runtime_version, b.runtime_sha256
            FROM job_runtime_bindings b
            LEFT JOIN submissions s ON s.job_id = b.job_id
            WHERE s.job_id IS NULL OR s.terminal_state IS NULL OR s.terminal_state = 'needs_review';
            """)
        defer { sqlite3_finalize(statement) }
        var values = Set<LibTVRuntimeIdentity>()
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return values }
            guard code == SQLITE_ROW else { throw sqliteError(code) }
            values.insert(.init(version: text(statement, 0) ?? "", sha256: text(statement, 1) ?? ""))
        }
    }

    public func attachRemoteTask(
        jobID: String,
        remoteTaskID: String,
        at date: Date = .now
    ) throws {
        try update(
            sql: "UPDATE submissions SET remote_task_id = ?, phase = ?, updated_at = ? WHERE job_id = ?;",
            bindings: [remoteTaskID, SubmissionPhase.remoteKnown.rawValue, date.timeIntervalSince1970, jobID]
        )
    }

    /// Reopens a terminal local record for an explicit server-authorized, query-only review.
    /// The paid remote identity is immutable; a conflicting ID is never overwritten.
    public func resumeRemoteQuery(
        jobID: String,
        profileRef: String,
        remoteTaskID: String,
        at date: Date = .now
    ) throws {
        guard let existing = try record(for: jobID) else {
            throw SubmissionJournalError.missingSubmission(jobID)
        }
        if let stored = existing.remoteTaskID, stored != remoteTaskID {
            throw SubmissionJournalError.conflictingRemoteTaskID(
                stored: stored,
                requested: remoteTaskID
            )
        }
        try update(
            sql: """
                UPDATE submissions
                SET profile_ref = ?, remote_task_id = ?, terminal_state = NULL,
                    phase = ?, updated_at = ?
                WHERE job_id = ?;
                """,
            bindings: [
                profileRef, remoteTaskID, SubmissionPhase.remoteKnown.rawValue,
                date.timeIntervalSince1970, jobID,
            ]
        )
    }

    public func markTerminal(
        jobID: String,
        state: RunnerJobState,
        at date: Date = .now
    ) throws {
        precondition(state.isTerminal)
        let phase: SubmissionPhase = state == .needsReview ? .needsReview : .terminal
        try update(
            sql: "UPDATE submissions SET terminal_state = ?, phase = ?, updated_at = ? WHERE job_id = ?;",
            bindings: [state.rawValue, phase.rawValue, date.timeIntervalSince1970, jobID]
        )
    }

    public func record(for jobID: String) throws -> SubmissionRecord? {
        let statement = try prepare("""
            SELECT job_id, profile_ref, request_fingerprint, phase, remote_task_id,
                   terminal_state, runtime_version, runtime_sha256, created_at, updated_at
            FROM submissions WHERE job_id = ? LIMIT 1;
            """)
        defer { sqlite3_finalize(statement) }
        bind(jobID, to: 1, in: statement)
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { return nil }
        guard code == SQLITE_ROW else { throw sqliteError(code) }
        return try decodeRecord(statement)
    }

    public func recoveryAction(for jobID: String) throws -> SubmissionRecoveryAction {
        guard let record = try record(for: jobID) else { return .submitNew }
        if let state = record.terminalState { return .alreadyTerminal(state) }
        if let remoteTaskID = record.remoteTaskID { return .queryRemote(taskID: remoteTaskID) }
        // An intent record is deliberately treated as an uncertain submission after restart.
        return .needsReview
    }

    public func pendingRecoveryRecords() throws -> [SubmissionRecord] {
        let statement = try prepare("""
            SELECT job_id, profile_ref, request_fingerprint, phase, remote_task_id,
                   terminal_state, runtime_version, runtime_sha256, created_at, updated_at
            FROM submissions WHERE phase IN ('intent_recorded', 'remote_known', 'needs_review')
            ORDER BY created_at ASC;
            """)
        defer { sqlite3_finalize(statement) }
        var values: [SubmissionRecord] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return values }
            guard code == SQLITE_ROW else { throw sqliteError(code) }
            values.append(try decodeRecord(statement))
        }
    }

    /// Persists every hidden LibTV object name before the paid `--run` command is launched.
    /// The deterministic upsert also makes preparation safe to repeat after a local interruption.
    public func recordExecutionLayout(
        jobID: String,
        profileRef: String,
        projectUUID: String,
        groupName: String,
        inputNodeNames: [String],
        generationNodeName: String,
        at date: Date = .now
    ) throws {
        let names = String(data: try JSONEncoder().encode(inputNodeNames), encoding: .utf8) ?? "[]"
        let statement = try prepare("""
            INSERT INTO execution_layouts
                (job_id, profile_ref, project_uuid, group_name, input_node_names,
                 generation_node_name, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(job_id) DO UPDATE SET
                profile_ref=excluded.profile_ref,
                project_uuid=excluded.project_uuid,
                group_name=excluded.group_name,
                input_node_names=excluded.input_node_names,
                generation_node_name=excluded.generation_node_name;
            """)
        defer { sqlite3_finalize(statement) }
        bind(jobID, to: 1, in: statement)
        bind(profileRef, to: 2, in: statement)
        bind(projectUUID, to: 3, in: statement)
        bind(groupName, to: 4, in: statement)
        bind(names, to: 5, in: statement)
        bind(generationNodeName, to: 6, in: statement)
        sqlite3_bind_double(statement, 7, date.timeIntervalSince1970)
        try stepDone(statement)
    }

    public func executionLayout(jobID: String) throws -> LibTVExecutionLayoutRecord? {
        let statement = try prepare("""
            SELECT job_id, profile_ref, project_uuid, group_name, input_node_names,
                   generation_node_name, created_at
            FROM execution_layouts WHERE job_id = ? LIMIT 1;
            """)
        defer { sqlite3_finalize(statement) }
        bind(jobID, to: 1, in: statement)
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { return nil }
        guard code == SQLITE_ROW else { throw sqliteError(code) }
        return try decodeExecutionLayout(statement)
    }

    /// Succeeded execution nodes are retained for 24 hours. Failed, cancelled and needs-review
    /// nodes are retained for seven days. Non-terminal work is never returned for cleanup.
    public func expiredExecutionLayouts(at date: Date = .now) throws -> [LibTVExecutionLayoutRecord] {
        let succeededCutoff = date.addingTimeInterval(-24 * 60 * 60).timeIntervalSince1970
        let diagnosticCutoff = date.addingTimeInterval(-7 * 24 * 60 * 60).timeIntervalSince1970
        let statement = try prepare("""
            SELECT e.job_id, e.profile_ref, e.project_uuid, e.group_name,
                   e.input_node_names, e.generation_node_name, e.created_at
            FROM execution_layouts e
            JOIN submissions s ON s.job_id = e.job_id
            WHERE (s.terminal_state = 'succeeded' AND s.updated_at <= ?)
               OR (s.terminal_state IN ('failed', 'cancelled', 'needs_review') AND s.updated_at <= ?)
            ORDER BY e.created_at ASC;
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, succeededCutoff)
        sqlite3_bind_double(statement, 2, diagnosticCutoff)
        var values: [LibTVExecutionLayoutRecord] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return values }
            guard code == SQLITE_ROW else { throw sqliteError(code) }
            values.append(try decodeExecutionLayout(statement))
        }
    }

    public func markExecutionLayoutCleaned(jobID: String) throws {
        let statement = try prepare("DELETE FROM execution_layouts WHERE job_id = ?;")
        defer { sqlite3_finalize(statement) }
        bind(jobID, to: 1, in: statement)
        try stepDone(statement)
    }

    public func appendLog(
        level: String,
        message: String,
        jobID: String? = nil,
        profileRef: String? = nil,
        at date: Date = .now
    ) throws {
        let statement = try prepare("""
            INSERT INTO diagnostic_logs (timestamp, level, message, job_id, profile_ref)
            VALUES (?, ?, ?, ?, ?);
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
        bind(level, to: 2, in: statement)
        bind(SensitiveDataRedactor.redact(message), to: 3, in: statement)
        bindOptional(jobID, to: 4, in: statement)
        bindOptional(profileRef, to: 5, in: statement)
        try stepDone(statement)
    }

    public func logs(
        jobID: String? = nil,
        profileRef: String? = nil,
        minimumID: Int64 = 0,
        limit: Int = 500
    ) throws -> [RunnerLogRecord] {
        let safeLimit = max(1, min(limit, 5_000))
        let statement = try prepare("""
            SELECT id, timestamp, level, message, job_id, profile_ref
            FROM diagnostic_logs
            WHERE id > ? AND (? IS NULL OR job_id = ?) AND (? IS NULL OR profile_ref = ?)
            ORDER BY id DESC LIMIT ?;
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, minimumID)
        bindOptional(jobID, to: 2, in: statement)
        bindOptional(jobID, to: 3, in: statement)
        bindOptional(profileRef, to: 4, in: statement)
        bindOptional(profileRef, to: 5, in: statement)
        sqlite3_bind_int(statement, 6, Int32(safeLimit))
        var result: [RunnerLogRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(RunnerLogRecord(
                id: sqlite3_column_int64(statement, 0),
                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                level: text(statement, 2) ?? "unknown",
                message: text(statement, 3) ?? "",
                jobID: text(statement, 4),
                profileRef: text(statement, 5)
            ))
        }
        return result
    }

    private func decodeRecord(_ statement: OpaquePointer?) throws -> SubmissionRecord {
        let phaseRaw = text(statement, 3) ?? ""
        guard let phase = SubmissionPhase(rawValue: phaseRaw) else {
            throw SubmissionJournalError.invalidStoredValue(phaseRaw)
        }
        let stateRaw = text(statement, 5)
        let state = stateRaw.flatMap(RunnerJobState.init(rawValue:))
        if let stateRaw, state == nil {
            throw SubmissionJournalError.invalidStoredValue(stateRaw)
        }
        return SubmissionRecord(
            jobID: text(statement, 0) ?? "",
            profileRef: text(statement, 1) ?? "",
            requestFingerprint: text(statement, 2) ?? "",
            phase: phase,
            remoteTaskID: text(statement, 4),
            terminalState: state,
            runtimeVersion: text(statement, 6),
            runtimeSHA256: text(statement, 7),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 8)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 9))
        )
    }

    private func decodeExecutionLayout(_ statement: OpaquePointer?) throws -> LibTVExecutionLayoutRecord {
        let encoded = Data((text(statement, 4) ?? "[]").utf8)
        let names: [String]
        do { names = try JSONDecoder().decode([String].self, from: encoded) }
        catch { throw SubmissionJournalError.invalidStoredValue(String(decoding: encoded, as: UTF8.self)) }
        return LibTVExecutionLayoutRecord(
            jobID: text(statement, 0) ?? "",
            profileRef: text(statement, 1) ?? "",
            projectUUID: text(statement, 2) ?? "",
            groupName: text(statement, 3) ?? "",
            inputNodeNames: names,
            generationNodeName: text(statement, 5) ?? "",
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))
        )
    }

    private func update(sql: String, bindings: [Any]) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case let string as String: bind(string, to: index, in: statement)
            case let double as Double: sqlite3_bind_double(statement, index, double)
            default: preconditionFailure("Unsupported SQLite binding")
            }
        }
        try stepDone(statement)
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard code == SQLITE_OK else { throw sqliteError(code) }
        return statement
    }

    private func stepDone(_ statement: OpaquePointer?) throws {
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE else { throw sqliteError(code) }
    }

    private func sqliteError(_ code: Int32) -> SubmissionJournalError {
        let message = String(cString: sqlite3_errmsg(database))
        return .sqlite(code: code, message: message)
    }

    private func bind(_ value: String, to index: Int32, in statement: OpaquePointer?) {
        sqlite3_bind_text(statement, index, value, -1, Self.sqliteTransient)
    }

    private func bindOptional(_ value: String?, to index: Int32, in statement: OpaquePointer?) {
        if let value { bind(value, to: index, in: statement) }
        else { sqlite3_bind_null(statement, index) }
    }

    private func text(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }

    private static let sqliteTransient = unsafeBitCast(
        -1,
        to: sqlite3_destructor_type.self
    )

    private static func execute(_ database: OpaquePointer, _ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard code == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errorMessage)
            throw SubmissionJournalError.sqlite(code: code, message: message)
        }
    }

    private static func ensureColumn(
        _ database: OpaquePointer,
        table: String,
        name: String,
        definition: String
    ) throws {
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(database, "PRAGMA table_info(\(table));", -1, &statement, nil)
        guard code == SQLITE_OK else {
            throw SubmissionJournalError.sqlite(code: code, message: String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if let value = sqlite3_column_text(statement, 1), String(cString: value) == name { return }
        }
        try execute(database, "ALTER TABLE \(table) ADD COLUMN \(name) \(definition);")
    }
}

public enum SensitiveDataRedactor {
    public static func redact(_ value: String) -> String {
        var redacted = value
        let patterns = [
            #"(?i)(bearer\s+)[A-Za-z0-9._~+/=-]+"#,
            #"(?i)((?:device[_-]?token|token|password|secret|credential)[\"']?\s*[:=]\s*[\"']?)[^\s,\"'}]+"#,
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(redacted.startIndex..., in: redacted)
            redacted = expression.stringByReplacingMatches(
                in: redacted,
                range: range,
                withTemplate: "$1<redacted>"
            )
        }
        return redacted
    }
}
