import Foundation
import CSQLite
import CryptoKit
import Darwin

/// Optional evidence, never permission to delete. No prompts, messages, credentials, or transcripts are read.
public struct AgentContext: Sendable {
    public enum State: Sendable { case finished, unknown, active }
    public struct Session: Sendable {
        public var id: String?
        public var path: String
        public var provider: String
        public var state: State
        public var finishedAt: Date?
        public init(path: String, provider: String, state: State, finishedAt: Date? = nil, id: String? = nil) {
            self.id = id; self.path = path; self.provider = provider; self.state = state; self.finishedAt = finishedAt
        }
    }
    public var sessions: [Session]
    public var failures: [String]
    public init(sessions: [Session] = [], failures: [String] = []) { self.sessions = sessions; self.failures = failures }
    func matching(_ top: String) -> [Session] {
        sessions.filter { Paths.contains(top, $0.path) || Paths.contains($0.path, top) }
    }
    /// Compare ownership evidence, not UI text: adding another unknown owner must invalidate a review too.
    func revision(_ top: String) -> String {
        let records = matching(top).map { session in
            [session.id ?? "", session.path, session.provider, String(describing: session.state),
             session.finishedAt.map { String($0.timeIntervalSince1970) } ?? ""]
        }.sorted { $0.lexicographicallyPrecedes($1) }
        let data = (try? JSONEncoder().encode(records)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    func protection(_ top: String) -> String? {
        if let failure = failures.first { return failure }
        return matching(top).first(where: { $0.state == .active }).map { "Active \($0.provider) session" }
    }
    func completion(_ top: String, since: Date) -> Bool {
        let owners = matching(top)
        return !owners.isEmpty && owners.allSatisfy { $0.state == .finished && ($0.finishedAt ?? .distantPast) >= since }
    }
    func summary(_ top: String) -> String? {
        let owners = matching(top)
        guard !owners.isEmpty else { return nil }
        return Set(owners.map(\.provider)).sorted().map { provider in
            let group = owners.filter { $0.provider == provider }
            return provider + (group.allSatisfy { $0.state == .finished } ? " finished" : " completion unconfirmed")
        }.joined(separator: " · ")
    }
}

/// Version-tolerant, read-only adapters. Unsupported installed schemas fail closed; absent tools are optional.
public struct AgentContextReader: Sendable {
    public let home: String
    public init(home: String = FileManager.default.homeDirectoryForCurrentUser.path) { self.home = home }
    public func capture() -> AgentContext {
        var result = AgentContext()
        for (name, read) in [("T3", t3), ("Codex", codex), ("Claude Code", claude)] {
            do { result.sessions += try read() }
            catch { result.failures.append("Couldn't inspect \(name) session metadata") }
        }
        return result
    }
    private func exists(_ path: String) throws -> Bool {
        var value = stat()
        if lstat(path, &value) == 0 { return true }
        if errno == ENOENT { return false }
        throw MetadataError.invalid
    }
    private func canonical(_ path: String) throws -> String {
        guard path.hasPrefix("/") else { throw MetadataError.invalid }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
    private func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
    private func t3() throws -> [AgentContext.Session] {
        let base = home + "/.t3/userdata/"
        let modern = try exists(base + "statev2.sqlite")
        let path = base + (modern ? "statev2.sqlite" : "state.sqlite")
        guard try exists(path) else { return [] }
        let db = try MetadataDatabase(path)
        if !modern {
            // Older installations still expose explicit settlement, but cannot attest to all delegated runs.
            return try db.rows("SELECT worktree_path FROM projection_threads WHERE worktree_path IS NOT NULL AND deleted_at IS NULL").map {
                .init(path: try canonical($0[0] ?? ""), provider: "T3", state: .unknown)
            }
        }
        let rows = try db.rows("""
            SELECT t.thread_id, json_extract(t.payload_json,'$.worktreePath'),
              json_extract(t.payload_json,'$.settledOverride'), json_extract(t.payload_json,'$.settledAt'),
              t.archived_at, t.deleted_at, json_extract(t.payload_json,'$.lineage.parentThreadId'),
              EXISTS(SELECT 1 FROM orchestration_v2_projection_runs r WHERE r.thread_id=t.thread_id
                AND r.status NOT IN ('completed','cancelled','failed','interrupted')), p.workspace_root
            FROM orchestration_v2_projection_threads t LEFT JOIN projection_projects p ON p.project_id=t.project_id
            """)
        let byID = Dictionary(uniqueKeysWithValues: rows.compactMap { row in row[0].map { ($0, row) } })
        func resolve(_ row: [String?]) throws -> String? {
            var current = row, visited = Set<String>()
            for _ in 0..<64 {
                if let path = current[1] { return path }
                guard let parent = current[6] else { return current[8] }
                guard visited.insert(parent).inserted, let next = byID[parent] else { throw MetadataError.invalid }
                current = next
            }
            throw MetadataError.invalid
        }
        return try rows.compactMap { row in
            let active = row[7] == "1"
            if row[5] != nil && !active { return nil }
            guard let path = try resolve(row) else {
                if active { throw MetadataError.invalid }
                return nil
            }
            let finished = row[2] == "settled" || row[4] != nil
            return .init(path: try canonical(path), provider: "T3", state: active ? .active : finished ? .finished : .unknown,
                         finishedAt: date(row[4] ?? row[3]), id: row[0])
        }
    }
    private func codex() throws -> [AgentContext.Session] {
        let directory = (home == FileManager.default.homeDirectoryForCurrentUser.path ? ProcessInfo.processInfo.environment["CODEX_HOME"] : nil) ?? home + "/.codex"
        guard try exists(directory) else { return [] }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory).filter { $0.hasPrefix("state_") && $0.hasSuffix(".sqlite") }
        guard let name = names.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }).first else { return [] }
        return try MetadataDatabase(directory + "/" + name).rows("SELECT cwd, archived, archived_at, id FROM threads").map { row in
            .init(path: try canonical(row[0] ?? ""), provider: "Codex", state: row[1] == "1" ? .finished : .unknown,
                  finishedAt: row[2].flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }, id: row[3])
        }
    }
    private func claude() throws -> [AgentContext.Session] {
        let directory = ((home == FileManager.default.homeDirectoryForCurrentUser.path ? ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] : nil) ?? home + "/.claude") + "/sessions"
        guard try exists(directory) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(atPath: directory).filter { $0.hasSuffix(".json") }
        guard files.count <= 10_000 else { throw MetadataError.invalid }
        return try files.map { file in
            let url = URL(fileURLWithPath: directory + "/" + file)
            guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_000_000 else { throw MetadataError.invalid }
            guard let record = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
                  let cwd = record["cwd"] as? String, let pid = record["pid"] as? Int32, pid > 0 else { throw MetadataError.invalid }
            // EPERM or PID reuse is conservatively active; stale files never imply task completion.
            let alive = kill(pid, 0) == 0 || errno != ESRCH
            return .init(path: try canonical(cwd), provider: "Claude Code", state: alive ? .active : .unknown, id: file)
        }
    }
}

private enum MetadataError: Error { case invalid }
/// Separate connection for every capture; never opens or creates a writable agent database.
private final class MetadataDatabase {
    private var db: OpaquePointer?
    init(_ path: String) throws {
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db); db = nil; throw MetadataError.invalid
        }
        sqlite3_busy_timeout(db, 1000)
    }
    deinit { sqlite3_close(db) }
    func rows(_ sql: String) throws -> [[String?]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw MetadataError.invalid }
        defer { sqlite3_finalize(statement) }
        var rows: [[String?]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return rows }
            guard status == SQLITE_ROW, rows.count < 100_000 else { throw MetadataError.invalid }
            rows.append((0..<sqlite3_column_count(statement)).map { index in
                sqlite3_column_text(statement, index).map { String(cString: $0) }
            })
        }
    }
}
