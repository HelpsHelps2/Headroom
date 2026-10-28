import Foundation

public actor Engine {
    private let store: StateStore
    private let scanner: Scanner
    private let directory: URL
    private let activityProvider: @Sendable () -> ActivitySnapshot
    private let clock: @Sendable () -> Date
    private var inventory = Inventory.empty

    public init(directory: URL = Paths.defaultState,
                home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                activity: @escaping @Sendable () -> ActivitySnapshot = { ActivitySnapshot.capture() },
                clock: @escaping @Sendable () -> Date = { Date() }) throws {
        self.directory = directory; self.store = try StateStore(directory: directory)
        self.scanner = Scanner(home: home); self.activityProvider = activity; self.clock = clock
    }
    public func preferences() throws -> Preferences { try store.preferences() }
    public func save(_ preferences: Preferences) throws {
        let lease = try ProcessLease(path: directory.appendingPathComponent("operation.lock").path)
        defer { withExtendedLifetime(lease) {} }
        try store.save(preferences)
    }
    public func history() throws -> [HistoryEntry] { try store.history() }
    public func scan() throws -> Inventory {
        let lease = try ProcessLease(path: directory.appendingPathComponent("operation.lock").path)
        defer { withExtendedLifetime(lease) {} }
        try store.recoverInterrupted()
        let preferences = try store.preferences(), now = clock()
        try store.pruneObservations(now: now)
        var result = scanner.scan(preferences: preferences, activity: activityProvider(), now: now)
        for index in result.artifacts.indices {
            let since = try store.observed(result.artifacts[index], now: now, gapLimit: 600)
            result.artifacts[index].firstObserved = since
        }
        inventory = result
        return result
    }
    public func plan(paths: Set<String>, automatic: Bool = false) throws -> CleanupPlan {
        let preferences = try store.preferences(), now = clock()
        guard now.timeIntervalSince(inventory.scannedAt) < 300 else { throw BurrowError.message("Scan again before preparing cleanup.") }
        let candidates = inventory.artifacts.filter { artifact in
            guard paths.contains(artifact.path), artifact.eligible else { return false }
            if !automatic { return true }
            return preferences.scheduled && !preferences.paused &&
                preferences.roots.contains(where: { $0.path == artifact.root && $0.automatic }) &&
                now.timeIntervalSince(artifact.firstObserved) >= preferences.keepHours * 3600
        }
        guard !candidates.isEmpty else { throw BurrowError.message("No selected output is eligible. Protected items stay in place.") }
        return .init(id: UUID(), createdAt: now, candidates: candidates, preferences: preferences, automatic: automatic)
    }
    public func runScheduleIfDue() throws -> [HistoryEntry] {
        let preferences = try store.preferences()
        guard preferences.scheduled, !preferences.paused else { return [] }
        let due = try claimSchedule(interval: preferences.intervalHours * 3600)
        return try scheduledRun(due: due)
    }
    private func claimSchedule(interval: TimeInterval) throws -> Bool {
        let lease = try ProcessLease(path: directory.appendingPathComponent("operation.lock").path)
        defer { withExtendedLifetime(lease) {} }
        return try store.scheduleDue(now: clock(), interval: interval)
    }
    private func scheduledRun(due: Bool) throws -> [HistoryEntry] {
        guard due else { return [] }
        let paths = Set(inventory.artifacts.filter { $0.eligible }.map(\.path))
        guard !paths.isEmpty else { return [] }
        let preferences = try store.preferences(), now = clock()
        let eligible = inventory.artifacts.filter { artifact in
            paths.contains(artifact.path) && now.timeIntervalSince(artifact.firstObserved) >= preferences.keepHours * 3600 && preferences.roots.contains(where: { $0.path == artifact.root && $0.automatic })
        }
        guard !eligible.isEmpty else { return [] }
        return try execute(plan(paths: Set(eligible.map(\.path)), automatic: true))
    }
    public func execute(_ plan: CleanupPlan) throws -> [HistoryEntry] {
        let lease = try ProcessLease(path: directory.appendingPathComponent("operation.lock").path)
        defer { withExtendedLifetime(lease) {} }
        let preferences = try store.preferences()
        guard preferences == plan.preferences, clock().timeIntervalSince(plan.createdAt) >= 0,
              clock().timeIntervalSince(plan.createdAt) < 300 else { throw BurrowError.message("Settings or the review expired. Prepare a new cleanup plan.") }
        var entries: [HistoryEntry] = []
        for artifact in plan.candidates {
            if Task<Never, Never>.isCancelled { break }
            var entry = HistoryEntry(id: UUID().uuidString, date: clock(), path: artifact.path, outcome: "Skipped", detail: "", bytes: 0)
            do {
                guard preferences.roots.contains(where: { $0.path == artifact.root && Paths.contains($0.path, artifact.project) }),
                      URL(fileURLWithPath: artifact.project).resolvingSymlinksInPath().path == artifact.project else {
                    throw BurrowError.message("Project is outside its approved scan root.")
                }
                // Re-inspect the entire artifact and live activity immediately before deletion.
                let fresh = try scanner.inspect(project: artifact.project, root: artifact.root, preferences: preferences, activity: activityProvider(), now: clock())
                guard fresh.eligible else { throw BurrowError.message(fresh.reasons.joined(separator: " ")) }
                guard fresh.identity == artifact.identity, fresh.latestWrite == artifact.latestWrite,
                      fresh.files == artifact.files, fresh.bytes == artifact.bytes else { throw BurrowError.message("Output changed since review. Scan again.") }
                let locks = try CargoLocks(target: fresh.path)
                defer { withExtendedLifetime(locks) {} }
                entry.outcome = "Cleaning"; entry.detail = "Permanent removal of verified private Cargo output."
                try store.record(entry)
                try ContainedDeletion.remove(fresh)
                entry.outcome = "Cleaned"; entry.bytes = fresh.bytes
                entry.detail = "Build output removed. Shared compiler caches were preserved. Rebuilding may be required."
            } catch {
                entry.outcome = entry.outcome == "Cleaning" ? "Interrupted" : "Skipped"
                entry.detail = error.localizedDescription
            }
            try store.record(entry); entries.append(entry)
        }
        inventory = .empty
        return entries
    }
}
