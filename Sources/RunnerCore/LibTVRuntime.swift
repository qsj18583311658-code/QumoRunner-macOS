import Foundation
import SQLite3

public struct LibTVRuntimeIdentity: Codable, Hashable, Sendable {
    public let version: String
    public let sha256: String
    public init(version: String, sha256: String) {
        self.version = version
        self.sha256 = sha256.lowercased()
    }
}

public struct LibTVRuntimeRequirement: Codable, Hashable, Sendable {
    public let version: String?
    public let sha256: String?
    public init(version: String? = nil, sha256: String? = nil) {
        self.version = version
        self.sha256 = sha256?.lowercased()
    }
    public var isEmpty: Bool { version == nil && sha256 == nil }
}

public enum LibTVRuntimeSource: String, Codable, Hashable, Sendable { case bundled, downloaded }

public struct LibTVRuntimeRecord: Codable, Hashable, Sendable {
    public let identity: LibTVRuntimeIdentity
    public let executablePath: String
    public let source: LibTVRuntimeSource
    public let installedAt: Date
    public let verifiedAt: Date
    public let archiveSHA256: String?
    public let teamIdentifier: String?
    public let cdHash: String?
    public let strictSignatureValid: Bool
    public init(
        identity: LibTVRuntimeIdentity,
        executableURL: URL,
        source: LibTVRuntimeSource,
        installedAt: Date = .now,
        verifiedAt: Date = .now,
        archiveSHA256: String? = nil,
        teamIdentifier: String? = nil,
        cdHash: String? = nil,
        strictSignatureValid: Bool = false
    ) {
        self.identity = identity
        executablePath = executableURL.standardizedFileURL.path
        self.source = source
        self.installedAt = installedAt
        self.verifiedAt = verifiedAt
        self.archiveSHA256 = archiveSHA256?.lowercased()
        self.teamIdentifier = teamIdentifier
        self.cdHash = cdHash?.lowercased()
        self.strictSignatureValid = strictSignatureValid
    }
    public var executableURL: URL { URL(fileURLWithPath: executablePath) }
}

public struct RunnerRuntimeHeartbeat: Codable, Hashable, Sendable {
    public let active: LibTVRuntimeIdentity
    public let previous: LibTVRuntimeIdentity?
    public let candidate: LibTVRuntimeIdentity?
    public let bundledFallback: LibTVRuntimeIdentity
    public let protocolVersion: String
    public let activeArchiveSHA256: String?
    public let activeTeamIdentifier: String?
    public let activeCDHash: String?
    public let activeStrictSignatureValid: Bool
    public let activeVerified: Bool
    public let candidateArchiveSHA256: String?
    public let activeRecord: LibTVRuntimeRecord?
    public let previousRecord: LibTVRuntimeRecord?
    public let candidateRecord: LibTVRuntimeRecord?
    public let bundledFallbackRecord: LibTVRuntimeRecord?
    enum CodingKeys: String, CodingKey {
        case active, previous, candidate
        case bundledFallback = "bundled_fallback"
        case protocolVersion = "protocol_version"
        case activeArchiveSHA256 = "active_archive_sha256"
        case activeTeamIdentifier = "active_team_identifier"
        case activeCDHash = "active_cdhash"
        case activeStrictSignatureValid = "active_strict_signature_valid"
        case activeVerified = "active_verified"
        case candidateArchiveSHA256 = "candidate_archive_sha256"
        case activeRecord = "active_record"
        case previousRecord = "previous_record"
        case candidateRecord = "candidate_record"
        case bundledFallbackRecord = "bundled_fallback_record"
    }
    public init(active: LibTVRuntimeIdentity, previous: LibTVRuntimeIdentity?, candidate: LibTVRuntimeIdentity?, bundledFallback: LibTVRuntimeIdentity, protocolVersion: String = "1", activeArchiveSHA256: String? = nil, activeTeamIdentifier: String? = nil, activeCDHash: String? = nil, activeStrictSignatureValid: Bool = false, activeVerified: Bool = false, candidateArchiveSHA256: String? = nil, activeRecord: LibTVRuntimeRecord? = nil, previousRecord: LibTVRuntimeRecord? = nil, candidateRecord: LibTVRuntimeRecord? = nil, bundledFallbackRecord: LibTVRuntimeRecord? = nil) {
        self.active = active
        self.previous = previous
        self.candidate = candidate
        self.bundledFallback = bundledFallback
        self.protocolVersion = protocolVersion
        self.activeArchiveSHA256 = activeArchiveSHA256
        self.activeTeamIdentifier = activeTeamIdentifier
        self.activeCDHash = activeCDHash
        self.activeStrictSignatureValid = activeStrictSignatureValid
        self.activeVerified = activeVerified
        self.candidateArchiveSHA256 = candidateArchiveSHA256
        self.activeRecord = activeRecord
        self.previousRecord = previousRecord
        self.candidateRecord = candidateRecord
        self.bundledFallbackRecord = bundledFallbackRecord
    }
}

public enum LibTVRuntimeRegistryError: Error, Equatable, LocalizedError, Sendable {
    case open(String)
    case sqlite(Int32, String)
    case invalidRegistry(String)
    case unavailable(LibTVRuntimeRequirement)
    case persistedRuntimeUnavailable(LibTVRuntimeIdentity)
    case persistedRuntimeConflict(stored: LibTVRuntimeIdentity, requested: LibTVRuntimeRequirement)
    case candidateUnavailable
    case previousUnavailable
    case invalidExecutablePath(String)
    public var errorDescription: String? {
        switch self {
        case .open(let value): "Unable to open LibTV Runtime registry: \(value)"
        case .sqlite(let code, let value): "LibTV Runtime registry SQLite error \(code): \(value)"
        case .invalidRegistry(let value): "LibTV Runtime registry is invalid: \(value)"
        case .unavailable(let value): "No verified LibTV Runtime satisfies version=\(value.version ?? "any") sha256=\(value.sha256 ?? "any")."
        case .persistedRuntimeUnavailable(let value): "Pinned LibTV Runtime \(value.version) (\(value.sha256)) is unavailable; the remote task will not be queried with another version."
        case .persistedRuntimeConflict(let stored, let requested): "Persisted Runtime \(stored.version) (\(stored.sha256)) conflicts with requested version=\(requested.version ?? "any") sha256=\(requested.sha256 ?? "any")."
        case .candidateUnavailable: "No verified LibTV Runtime candidate is staged."
        case .previousUnavailable: "No previous LibTV Runtime is available for rollback."
        case .invalidExecutablePath(let value): "LibTV Runtime executable path is invalid: \(value)"
        }
    }
}

public protocol LibTVRuntimeProviding: Sendable {
    func resolveRuntime(requirement: LibTVRuntimeRequirement?, persisted: LibTVRuntimeIdentity?, remoteTaskExists: Bool) async throws -> LibTVRuntimeRecord
    func runtimeHeartbeat() async -> RunnerRuntimeHeartbeat?
    func pendingRuntimeValidationReports() async -> [RunnerRuntimeValidationReport]
    func acknowledgeRuntimeValidationReports(_ values: [RunnerRuntimeValidationAcknowledgement]) async
}

private final class RuntimeSQLiteHandle: @unchecked Sendable {
    let pointer: OpaquePointer
    init(_ pointer: OpaquePointer) { self.pointer = pointer }
    deinit { sqlite3_close(pointer) }
}

/// Runtime binaries are immutable. SQLite atomically stores the active/previous/candidate slots;
/// callers get an absolute executable path and never depend on PATH or a mutable symlink.
public actor LibTVRuntimeRegistry: LibTVRuntimeProviding {
    public nonisolated let rootURL: URL
    public nonisolated let versionsURL: URL
    public nonisolated let stagingURL: URL
    private nonisolated let databaseURL: URL
    private let bundledFallback: LibTVRuntimeRecord
    private var handle: RuntimeSQLiteHandle?
    private var database: OpaquePointer? { handle?.pointer }

    public init(rootURL: URL, bundledFallback: LibTVRuntimeRecord) {
        self.rootURL = rootURL.standardizedFileURL
        versionsURL = rootURL.standardizedFileURL
        stagingURL = rootURL.appending(path: ".staging", directoryHint: .isDirectory).standardizedFileURL
        databaseURL = rootURL.appending(path: "registry.sqlite3").standardizedFileURL
        self.bundledFallback = bundledFallback
    }

    public func bootstrap() throws {
        try secureDirectory(rootURL); try secureDirectory(versionsURL); try secureDirectory(stagingURL)
        if handle == nil {
            var pointer: OpaquePointer?
            let result = sqlite3_open_v2(databaseURL.path, &pointer, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
            guard result == SQLITE_OK, let pointer else {
                let message = pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
                if let pointer { sqlite3_close(pointer) }
                throw LibTVRuntimeRegistryError.open(message)
            }
            handle = RuntimeSQLiteHandle(pointer)
            try execute("PRAGMA journal_mode=WAL;")
            try execute("PRAGMA synchronous=FULL;")
            try execute("PRAGMA foreign_keys=ON;")
            try execute("""
                CREATE TABLE IF NOT EXISTS runtime_records (
                    version TEXT NOT NULL, sha256 TEXT NOT NULL, executable_path TEXT NOT NULL,
                    source TEXT NOT NULL, installed_at REAL NOT NULL, verified_at REAL NOT NULL,
                    archive_sha256 TEXT, team_identifier TEXT, cdhash TEXT,
                    strict_signature_valid INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (version, sha256));
                """)
            try execute("""
                CREATE TABLE IF NOT EXISTS runtime_slots (
                    slot TEXT PRIMARY KEY NOT NULL CHECK (slot IN ('active','previous','candidate')),
                    version TEXT NOT NULL, sha256 TEXT NOT NULL,
                    FOREIGN KEY (version, sha256) REFERENCES runtime_records(version, sha256));
                """)
            try execute("""
                CREATE TABLE IF NOT EXISTS runtime_validation_reports (
                    validation_id TEXT PRIMARY KEY NOT NULL,
                    report_json BLOB NOT NULL,
                    status TEXT NOT NULL,
                    updated_at REAL NOT NULL
                );
                """)
            try ensureColumn("runtime_records", "archive_sha256", "TEXT")
            try ensureColumn("runtime_records", "team_identifier", "TEXT")
            try ensureColumn("runtime_records", "cdhash", "TEXT")
            try ensureColumn("runtime_records", "strict_signature_valid", "INTEGER NOT NULL DEFAULT 0")
            _ = chmod(databaseURL.path, 0o600)
        }
        try transaction {
            try upsertRecord(bundledFallback)
            if try identity(in: "active") == nil { try setSlot("active", bundledFallback.identity) }
        }
        _ = try activeRuntime()
    }

    public func snapshot() throws -> RunnerRuntimeHeartbeat {
        let active = try activeRuntime()
        let candidateIdentity = try identity(in: "candidate")
        let candidate = try candidateIdentity.flatMap { try record($0) }
        let previousIdentity = try identity(in: "previous")
        let previous = try previousIdentity.flatMap { try record($0) }
        return RunnerRuntimeHeartbeat(active: active.identity, previous: previousIdentity, candidate: candidateIdentity, bundledFallback: bundledFallback.identity, activeArchiveSHA256: active.archiveSHA256, activeTeamIdentifier: active.teamIdentifier, activeCDHash: active.cdHash, activeStrictSignatureValid: active.strictSignatureValid, activeVerified: active.strictSignatureValid && active.teamIdentifier == LibTVRuntimeInstaller.officialTeamIdentifier, candidateArchiveSHA256: candidate?.archiveSHA256, activeRecord: active, previousRecord: previous, candidateRecord: candidate, bundledFallbackRecord: bundledFallback)
    }
    public func activeRuntime() throws -> LibTVRuntimeRecord { try requiredRecord(try requiredIdentity(in: "active")) }

    public func stageCandidate(_ record: LibTVRuntimeRecord) throws {
        guard record.source == .downloaded else { throw LibTVRuntimeRegistryError.invalidExecutablePath(record.executablePath) }
        try validateDownloadedPath(record.executableURL)
        guard FileManager.default.isExecutableFile(atPath: record.executablePath) else { throw LibTVRuntimeRegistryError.invalidExecutablePath(record.executablePath) }
        try transaction { try upsertRecord(record); try setSlot("candidate", record.identity) }
    }

    @discardableResult public func activateCandidate(expected: LibTVRuntimeIdentity? = nil) throws -> LibTVRuntimeRecord {
        let selected: LibTVRuntimeIdentity = try transaction {
            guard let candidate = try identity(in: "candidate") else { throw LibTVRuntimeRegistryError.candidateUnavailable }
            if let expected, candidate != expected {
                throw LibTVRuntimeRegistryError.invalidRegistry("candidate changed during compatibility verification")
            }
            _ = try requiredRecord(candidate)
            let active = try requiredIdentity(in: "active")
            if active != candidate { try setSlot("previous", active) }
            try setSlot("active", candidate); try clearSlot("candidate")
            return candidate
        }
        return try requiredRecord(selected)
    }

    @discardableResult public func rollback(expected: LibTVRuntimeIdentity? = nil) throws -> LibTVRuntimeRecord {
        let selected: LibTVRuntimeIdentity = try transaction {
            guard let previous = try identity(in: "previous") else { throw LibTVRuntimeRegistryError.previousUnavailable }
            if let expected, previous != expected {
                throw LibTVRuntimeRegistryError.invalidRegistry("previous Runtime changed during compatibility verification")
            }
            _ = try requiredRecord(previous)
            let active = try requiredIdentity(in: "active")
            try setSlot("active", previous); try setSlot("previous", active); try clearSlot("candidate")
            return previous
        }
        return try requiredRecord(selected)
    }

    @discardableResult public func recoverToBundledFallback() throws -> LibTVRuntimeRecord {
        try transaction {
            let active = try requiredIdentity(in: "active")
            if active != bundledFallback.identity { try setSlot("previous", active) }
            try setSlot("active", bundledFallback.identity)
            try clearSlot("candidate")
        }
        return bundledFallback
    }

    /// Removes only unreferenced downloaded versions. Callers pass Runtime identities retained by
    /// needs-review/recovery rows; active, previous, candidate and bundled 1.0.2 are always kept.
    @discardableResult public func prune(retaining externallyRetained: Set<LibTVRuntimeIdentity>) throws -> [LibTVRuntimeIdentity] {
        var retained = externallyRetained
        retained.insert(bundledFallback.identity)
        for slot in ["active", "previous", "candidate"] {
            if let value = try identity(in: slot) { retained.insert(value) }
        }
        let removable = try records().filter { $0.source == .downloaded && !retained.contains($0.identity) }
        try transaction {
            for value in removable {
                let statement = try prepare("DELETE FROM runtime_records WHERE version=? AND sha256=?;")
                bind(value.identity.version, 1, statement); bind(value.identity.sha256, 2, statement)
                do { try stepDone(statement); sqlite3_finalize(statement) }
                catch { sqlite3_finalize(statement); throw error }
            }
        }
        for value in removable { try? FileManager.default.removeItem(at: value.executableURL.deletingLastPathComponent()) }
        return removable.map(\.identity)
    }

    public func resolveRuntime(requirement: LibTVRuntimeRequirement?, persisted: LibTVRuntimeIdentity?, remoteTaskExists: Bool) throws -> LibTVRuntimeRecord {
        if let persisted {
            if let requirement, !requirement.isEmpty, !Self.matches(persisted, requirement) {
                throw LibTVRuntimeRegistryError.persistedRuntimeConflict(stored: persisted, requested: requirement)
            }
            guard let pinned = try record(persisted), FileManager.default.isExecutableFile(atPath: pinned.executablePath) else {
                throw LibTVRuntimeRegistryError.persistedRuntimeUnavailable(persisted)
            }
            return pinned
        }
        // Server-migrated historical jobs know only that they were created by
        // the original bundled 1.0.2. A known remote task must therefore use
        // that exact bundled binary instead of a later downloaded 1.0.2 build.
        if remoteTaskExists,
           requirement?.sha256 == nil,
           requirement?.version == nil || requirement?.version == bundledFallback.identity.version {
            return bundledFallback
        }
        if let requirement, !requirement.isEmpty {
            guard let matching = try records().filter({ Self.matches($0.identity, requirement) }).sorted(by: { $0.verifiedAt > $1.verifiedAt }).first,
                  FileManager.default.isExecutableFile(atPath: matching.executablePath) else { throw LibTVRuntimeRegistryError.unavailable(requirement) }
            return matching
        }
        // Pre-registry remote tasks were submitted by bundled 1.0.2 and must never follow active.
        if remoteTaskExists { return bundledFallback }
        return try activeRuntime()
    }
    public func runtimeHeartbeat() -> RunnerRuntimeHeartbeat? { try? snapshot() }

    public func upsertRuntimeValidationReport(_ report: RunnerRuntimeValidationReport) throws {
        let data = try JSONEncoder().encode(report)
        let statement = try prepare("""
            INSERT INTO runtime_validation_reports(validation_id,report_json,status,updated_at)
            VALUES(?,?,?,?) ON CONFLICT(validation_id) DO UPDATE SET
                report_json=excluded.report_json,status=excluded.status,updated_at=excluded.updated_at;
            """)
        defer { sqlite3_finalize(statement) }
        bind(report.validationID, 1, statement)
        _ = data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 2, bytes.baseAddress, Int32(bytes.count), Self.sqliteTransient)
        }
        bind(report.status, 3, statement)
        sqlite3_bind_double(statement, 4, Date.now.timeIntervalSince1970)
        try stepDone(statement)
    }

    public func pendingRuntimeValidationReports() -> [RunnerRuntimeValidationReport] {
        guard let statement = try? prepare("SELECT report_json FROM runtime_validation_reports ORDER BY updated_at;") else { return [] }
        defer { sqlite3_finalize(statement) }
        var values: [RunnerRuntimeValidationReport] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let count = Int(sqlite3_column_bytes(statement, 0))
            guard let pointer = sqlite3_column_blob(statement, 0), count > 0 else { continue }
            let data = Data(bytes: pointer, count: count)
            if let value = try? JSONDecoder().decode(RunnerRuntimeValidationReport.self, from: data) { values.append(value) }
        }
        return values
    }

    public func acknowledgeRuntimeValidationReports(_ values: [RunnerRuntimeValidationAcknowledgement]) {
        let reports = Dictionary(uniqueKeysWithValues: pendingRuntimeValidationReports().map { ($0.validationID, $0) })
        for value in values where ["passed", "failed"].contains(reports[value.id]?.status) {
            guard let statement = try? prepare("DELETE FROM runtime_validation_reports WHERE validation_id=?;") else { continue }
            bind(value.id, 1, statement); _ = try? stepDone(statement); sqlite3_finalize(statement)
        }
    }

    public func immutableDestination(for identity: LibTVRuntimeIdentity) throws -> URL {
        versionsURL.appending(path: try safeComponent(identity.version), directoryHint: .isDirectory)
            .appending(path: try safeComponent(identity.sha256), directoryHint: .isDirectory)
            .appending(path: "libtv", directoryHint: .notDirectory).standardizedFileURL
    }

    private func records() throws -> [LibTVRuntimeRecord] {
        let statement = try prepare("SELECT version,sha256,executable_path,source,installed_at,verified_at,archive_sha256,team_identifier,cdhash,strict_signature_valid FROM runtime_records ORDER BY verified_at DESC;")
        defer { sqlite3_finalize(statement) }
        var values: [LibTVRuntimeRecord] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return values }
            guard code == SQLITE_ROW else { throw sqliteError(code) }
            values.append(try decodeRecord(statement))
        }
    }
    private func record(_ identity: LibTVRuntimeIdentity) throws -> LibTVRuntimeRecord? {
        let statement = try prepare("SELECT version,sha256,executable_path,source,installed_at,verified_at,archive_sha256,team_identifier,cdhash,strict_signature_valid FROM runtime_records WHERE version=? AND sha256=? LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        bind(identity.version, 1, statement); bind(identity.sha256, 2, statement)
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { return nil }
        guard code == SQLITE_ROW else { throw sqliteError(code) }
        return try decodeRecord(statement)
    }
    private func requiredRecord(_ identity: LibTVRuntimeIdentity) throws -> LibTVRuntimeRecord {
        guard let value = try record(identity) else { throw LibTVRuntimeRegistryError.invalidRegistry("missing record for \(identity.version)/\(identity.sha256)") }
        guard FileManager.default.isExecutableFile(atPath: value.executablePath) else { throw LibTVRuntimeRegistryError.invalidExecutablePath(value.executablePath) }
        if value.source == .downloaded { try validateDownloadedPath(value.executableURL) }
        return value
    }
    private func upsertRecord(_ value: LibTVRuntimeRecord) throws {
        if let old = try record(value.identity), old.executablePath != value.executablePath { throw LibTVRuntimeRegistryError.invalidRegistry("immutable identity has conflicting paths") }
        let statement = try prepare("INSERT INTO runtime_records(version,sha256,executable_path,source,installed_at,verified_at,archive_sha256,team_identifier,cdhash,strict_signature_valid) VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(version,sha256) DO UPDATE SET verified_at=excluded.verified_at,archive_sha256=excluded.archive_sha256,team_identifier=excluded.team_identifier,cdhash=excluded.cdhash,strict_signature_valid=excluded.strict_signature_valid;")
        defer { sqlite3_finalize(statement) }
        bind(value.identity.version, 1, statement); bind(value.identity.sha256, 2, statement); bind(value.executablePath, 3, statement); bind(value.source.rawValue, 4, statement)
        sqlite3_bind_double(statement, 5, value.installedAt.timeIntervalSince1970); sqlite3_bind_double(statement, 6, value.verifiedAt.timeIntervalSince1970)
        bindOptional(value.archiveSHA256, 7, statement); bindOptional(value.teamIdentifier, 8, statement); bindOptional(value.cdHash, 9, statement); sqlite3_bind_int(statement, 10, value.strictSignatureValid ? 1 : 0)
        try stepDone(statement)
    }
    private func identity(in slot: String) throws -> LibTVRuntimeIdentity? {
        let statement = try prepare("SELECT version,sha256 FROM runtime_slots WHERE slot=? LIMIT 1;")
        defer { sqlite3_finalize(statement) }; bind(slot, 1, statement)
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { return nil }
        guard code == SQLITE_ROW else { throw sqliteError(code) }
        return .init(version: text(statement, 0) ?? "", sha256: text(statement, 1) ?? "")
    }
    private func requiredIdentity(in slot: String) throws -> LibTVRuntimeIdentity {
        guard let value = try identity(in: slot) else { throw LibTVRuntimeRegistryError.invalidRegistry("missing \(slot) slot") }
        return value
    }
    private func setSlot(_ slot: String, _ identity: LibTVRuntimeIdentity) throws {
        let statement = try prepare("INSERT INTO runtime_slots(slot,version,sha256) VALUES(?,?,?) ON CONFLICT(slot) DO UPDATE SET version=excluded.version,sha256=excluded.sha256;")
        defer { sqlite3_finalize(statement) }; bind(slot, 1, statement); bind(identity.version, 2, statement); bind(identity.sha256, 3, statement); try stepDone(statement)
    }
    private func clearSlot(_ slot: String) throws {
        let statement = try prepare("DELETE FROM runtime_slots WHERE slot=?;")
        defer { sqlite3_finalize(statement) }; bind(slot, 1, statement); try stepDone(statement)
    }
    private func decodeRecord(_ statement: OpaquePointer?) throws -> LibTVRuntimeRecord {
        guard let sourceValue = text(statement, 3), let source = LibTVRuntimeSource(rawValue: sourceValue) else { throw LibTVRuntimeRegistryError.invalidRegistry("unknown Runtime source") }
        return .init(identity: .init(version: text(statement, 0) ?? "", sha256: text(statement, 1) ?? ""), executableURL: URL(fileURLWithPath: text(statement, 2) ?? ""), source: source, installedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)), verifiedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)), archiveSHA256: text(statement, 6), teamIdentifier: text(statement, 7), cdHash: text(statement, 8), strictSignatureValid: sqlite3_column_int(statement, 9) == 1)
    }
    private func validateDownloadedPath(_ url: URL) throws {
        let root = versionsURL.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root) else { throw LibTVRuntimeRegistryError.invalidExecutablePath(url.path) }
    }
    private func safeComponent(_ value: String) throws -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !value.isEmpty, value != ".", value != "..", value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { throw LibTVRuntimeRegistryError.invalidRegistry("unsafe Runtime identity") }
        return value
    }
    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE;")
        do { let value = try body(); try execute("COMMIT;"); return value }
        catch { try? execute("ROLLBACK;"); throw error }
    }
    private func secureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); _ = chmod(url.path, 0o700)
    }
    private func prepare(_ sql: String) throws -> OpaquePointer? {
        guard let database else { throw LibTVRuntimeRegistryError.invalidRegistry("bootstrap has not completed") }
        var statement: OpaquePointer?; let code = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard code == SQLITE_OK else { throw sqliteError(code) }; return statement
    }
    private func stepDone(_ statement: OpaquePointer?) throws { let code = sqlite3_step(statement); guard code == SQLITE_DONE else { throw sqliteError(code) } }
    private func execute(_ sql: String) throws {
        guard let database else { throw LibTVRuntimeRegistryError.invalidRegistry("bootstrap has not completed") }
        var message: UnsafeMutablePointer<CChar>?; let code = sqlite3_exec(database, sql, nil, nil, &message)
        guard code == SQLITE_OK else { let value = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database)); sqlite3_free(message); throw LibTVRuntimeRegistryError.sqlite(code, value) }
    }
    private func ensureColumn(_ table: String, _ name: String, _ definition: String) throws {
        let statement = try prepare("PRAGMA table_info(\(table));")
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if text(statement, 1) == name { return }
        }
        try execute("ALTER TABLE \(table) ADD COLUMN \(name) \(definition);")
    }
    private func sqliteError(_ code: Int32) -> LibTVRuntimeRegistryError { .sqlite(code, database.map { String(cString: sqlite3_errmsg($0)) } ?? "database unavailable") }
    private func bind(_ value: String, _ index: Int32, _ statement: OpaquePointer?) { sqlite3_bind_text(statement, index, value, -1, Self.sqliteTransient) }
    private func bindOptional(_ value: String?, _ index: Int32, _ statement: OpaquePointer?) { if let value { bind(value, index, statement) } else { sqlite3_bind_null(statement, index) } }
    private func text(_ statement: OpaquePointer?, _ index: Int32) -> String? { guard let value = sqlite3_column_text(statement, index) else { return nil }; return String(cString: value) }
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static func matches(_ identity: LibTVRuntimeIdentity, _ requirement: LibTVRuntimeRequirement) -> Bool {
        (requirement.version == nil || requirement.version == identity.version) && (requirement.sha256 == nil || requirement.sha256?.caseInsensitiveCompare(identity.sha256) == .orderedSame)
    }
}
