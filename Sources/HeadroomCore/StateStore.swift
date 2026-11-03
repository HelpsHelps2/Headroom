import Foundation
import CSQLite

// Owned exclusively by Engine's actor. WAL and the process lease coordinate CLI/app access.
final class StateStore {
    private var db: OpaquePointer?
    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard sqlite3_open_v2(directory.appendingPathComponent("state.sqlite").path, &db,
                             SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw HeadroomError.message("Could not open the local inventory database.")
        }
        sqlite3_busy_timeout(db, 5000)
        try execute("PRAGMA journal_mode=WAL")
        let version = Int(try scalar("PRAGMA user_version") ?? "0") ?? 0
        guard version <= 2 else { throw HeadroomError.message("Unsupported database version.") }
        try execute("CREATE TABLE IF NOT EXISTS settings (id TEXT PRIMARY KEY, value TEXT NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS observation (path TEXT PRIMARY KEY, identity TEXT NOT NULL, since REAL NOT NULL, seen REAL NOT NULL, changed REAL NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS history (id TEXT PRIMARY KEY, date REAL NOT NULL, path TEXT NOT NULL, outcome TEXT NOT NULL, detail TEXT NOT NULL, bytes INTEGER NOT NULL)")
        // A new table rather than a schema version, so a copy of the app that predates it can still open this database.
        try execute("CREATE TABLE IF NOT EXISTS worktree_restore (entry TEXT PRIMARY KEY, top TEXT NOT NULL, common TEXT NOT NULL, branch TEXT NOT NULL, head TEXT NOT NULL)")
        if version < 2 {
            try execute("BEGIN")
            try execute("ALTER TABLE history ADD COLUMN run TEXT NOT NULL DEFAULT ''")
            try execute("ALTER TABLE history ADD COLUMN automatic INTEGER NOT NULL DEFAULT 0")
            try execute("CREATE TABLE IF NOT EXISTS space (date REAL PRIMARY KEY, capacity INTEGER NOT NULL, available INTEGER NOT NULL)")
            try execute("PRAGMA user_version=2")
            try execute("COMMIT")
        }
    }
    deinit { sqlite3_close(db) }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }
    private func error() -> HeadroomError { .message("Local database: \(String(cString: sqlite3_errmsg(db)))") }
    private func statement(_ sql: String, _ values: [String]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw error() }
        for (index, value) in values.enumerated() {
            _ = value.withCString { sqlite3_bind_text(stmt, Int32(index + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        }
        return stmt
    }
    private func scalar(_ sql: String, _ values: [String] = []) throws -> String? {
        let stmt = try statement(sql, values); defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return String(cString: sqlite3_column_text(stmt, 0))
    }
    private func update(_ sql: String, _ values: [String]) throws {
        let stmt = try statement(sql, values); defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw error() }
    }
    func preferences() throws -> Preferences {
        guard let text = try scalar("SELECT value FROM settings WHERE id='preferences'") else { return Preferences() }
        return try JSONDecoder().decode(Preferences.self, from: Data(text.utf8))
    }
    func save(_ preferences: Preferences) throws {
        guard preferences.keepHours >= 1, preferences.keepHours <= 8760,
              preferences.intervalHours >= 1, preferences.intervalHours <= 720 else {
            throw HeadroomError.message("Choose inactivity of 1–8760 hours and a schedule of 1–720 hours.")
        }
        let data = try JSONEncoder().encode(preferences)
        try update("INSERT OR REPLACE INTO settings VALUES ('preferences',?)", [String(decoding: data, as: UTF8.self)])
    }
    /// Start of the current unbroken stretch in which this output was seen unchanged with nothing protecting it except
    /// the keep window. That window and this observation run together, so automatic cleanup waits about one window, not two.
    func observed(_ artifact: Artifact, now: Date, continuous: (Date) -> Bool) throws -> Date {
        let identity = "\(artifact.identity.device):\(artifact.identity.inode)"
        let stmt = try statement("SELECT identity,since,seen,changed FROM observation WHERE path=?", [artifact.path])
        defer { sqlite3_finalize(stmt) }
        var since = now
        if sqlite3_step(stmt) == SQLITE_ROW {
            let oldID = String(cString: sqlite3_column_text(stmt, 0))
            let oldSince = sqlite3_column_double(stmt, 1)
            let seen = sqlite3_column_double(stmt, 2)
            let changed = sqlite3_column_double(stmt, 3)
            if oldID == identity, continuous(Date(timeIntervalSince1970: seen)),
               changed == artifact.latestWrite.timeIntervalSince1970,
               artifact.eligible || artifact.waiting {
                since = Date(timeIntervalSince1970: oldSince)
            }
        }
        try update("INSERT OR REPLACE INTO observation VALUES (?,?,?,?,?)", [artifact.path, identity, "\(since.timeIntervalSince1970)", "\(now.timeIntervalSince1970)", "\(artifact.latestWrite.timeIntervalSince1970)"])
        return since
    }
    func record(_ entry: HistoryEntry) throws {
        try update("INSERT OR REPLACE INTO history (id,date,path,outcome,detail,bytes,run,automatic) VALUES (?,?,?,?,?,?,?,?)",
                   [entry.id, "\(entry.date.timeIntervalSince1970)", entry.path, entry.outcome, entry.detail, "\(entry.bytes)", entry.run, entry.automatic ? "1" : "0"])
        if let restore = entry.restore {
            try update("INSERT OR REPLACE INTO worktree_restore VALUES (?,?,?,?,?)", [entry.id, restore.top, restore.common, restore.branch ?? "", restore.head])
        }
        try execute("DELETE FROM history WHERE id IN (SELECT id FROM history ORDER BY date DESC LIMIT -1 OFFSET 1000)")
        try execute("DELETE FROM worktree_restore WHERE entry NOT IN (SELECT id FROM history)")
    }
    func history() throws -> [HistoryEntry] {
        let stmt = try statement("SELECT h.id,h.date,h.path,h.outcome,h.detail,h.bytes,h.run,h.automatic,r.top,r.common,r.branch,r.head FROM history h LEFT JOIN worktree_restore r ON r.entry=h.id ORDER BY h.date DESC LIMIT 1000", [])
        defer { sqlite3_finalize(stmt) }
        var result: [HistoryEntry] = []
        func str(_ index: Int32) -> String { String(cString: sqlite3_column_text(stmt, index)) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let run = str(6)
            var restore: WorktreeRestore?
            if sqlite3_column_type(stmt, 8) != SQLITE_NULL {
                restore = .init(top: str(8), common: str(9), branch: str(10).isEmpty ? nil : str(10), head: str(11))
            }
            result.append(.init(id: str(0), date: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)), path: str(2), outcome: str(3), detail: str(4),
                                bytes: sqlite3_column_int64(stmt, 5), run: run.isEmpty ? str(0) : run, automatic: sqlite3_column_int(stmt, 7) != 0, restore: restore))
        }
        return result
    }
    func recordSpace(_ sample: SpaceSample) throws {
        guard sample.capacity > 0 else { return }
        try update("INSERT OR REPLACE INTO space VALUES (?,?,?)", ["\(sample.date.timeIntervalSince1970)", "\(sample.capacity)", "\(sample.available)"])
        try update("DELETE FROM space WHERE date < ?", ["\(sample.date.addingTimeInterval(-120 * 86400).timeIntervalSince1970)"])
    }
    func space(since: Date) throws -> [SpaceSample] {
        let stmt = try statement("SELECT date,capacity,available FROM space WHERE date >= ? ORDER BY date", ["\(since.timeIntervalSince1970)"])
        defer { sqlite3_finalize(stmt) }
        var result: [SpaceSample] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(.init(date: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0)), capacity: sqlite3_column_int64(stmt, 1), available: sqlite3_column_int64(stmt, 2)))
        }
        return result
    }
    func recoverInterrupted() throws {
        try execute("UPDATE history SET outcome='Interrupted',detail='Cleanup stopped unexpectedly. Inspect this path before continuing; output may be partially removed.' WHERE outcome='Cleaning'")
    }
    func pruneObservations(now: Date) throws {
        try update("DELETE FROM observation WHERE seen < ?", ["\(now.addingTimeInterval(-90 * 86400).timeIntervalSince1970)"])
        try execute("DELETE FROM observation WHERE path IN (SELECT path FROM observation ORDER BY seen DESC LIMIT -1 OFFSET 100000)")
    }
    /// Claims a scheduled run when the interval has passed and something is `ready`. Without anything ready the claim waits.
    func scheduleDue(now: Date, interval: TimeInterval, ready: Bool) throws -> Bool {
        let old = try scalar("SELECT value FROM settings WHERE id='lastSchedule'").flatMap(Double.init)
        if let old, now.timeIntervalSince1970 >= old, now.timeIntervalSince1970 - old < interval { return false }
        // First enablement starts the interval; it does not immediately delete.
        guard old == nil || ready else { return false }
        try update("INSERT OR REPLACE INTO settings VALUES ('lastSchedule',?)", ["\(now.timeIntervalSince1970)"])
        return old != nil
    }
}
