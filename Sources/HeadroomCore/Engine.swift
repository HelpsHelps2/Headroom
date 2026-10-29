import Foundation

public actor Engine {
    private let store: StateStore
    private let scanner: Scanner
    private let directory: URL
    private let activityProvider: @Sendable () -> ActivitySnapshot
    private let clock: @Sendable () -> Date
    private var inventory = Inventory.empty
    private let discovery = DiscoveryCache()

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
    /// Observation times round-trip through SQLite and Date's 2001 epoch, which can shift them by a fraction of a microsecond.
    static func idle(since: Date, now: Date, hours: Double) -> Bool { now.timeIntervalSince(since) >= hours * 3600 - 0.001 }
    public func space(since: Date) throws -> [SpaceSample] { try store.space(since: since) }
    public func scan(progress: Scanner.Progress? = nil) throws -> Inventory {
        let lease = try ProcessLease(path: directory.appendingPathComponent("operation.lock").path)
        defer { withExtendedLifetime(lease) {} }
        try store.recoverInterrupted()
        let preferences = try store.preferences(), now = clock()
        try store.pruneObservations(now: now)
        var result = scanner.scan(preferences: preferences, activity: activityProvider(), now: now, progress: progress, discovery: discovery)
        for index in result.artifacts.indices {
            let since = try store.observed(result.artifacts[index], now: now, gapLimit: 600)
            result.artifacts[index].firstObserved = since
        }
        inventory = result
        try store.recordSpace(.init(date: now, capacity: result.capacity, available: result.available))
        return result
    }
    /// `skippingWait` lets a person remove chosen output before the keep window ends. Automatic cleanup never skips it.
    public func plan(paths: Set<String>, skippingWait: Set<String> = [], automatic: Bool = false) throws -> CleanupPlan {
        let preferences = try store.preferences(), now = clock()
        guard now.timeIntervalSince(inventory.scannedAt) < 300 else { throw HeadroomError.message("Scan again before preparing cleanup.") }
        let skipping = automatic ? [] : skippingWait.intersection(paths)
        let candidates = inventory.artifacts.filter { artifact in
            guard paths.contains(artifact.path), artifact.eligible(skippingWait: skipping.contains(artifact.path)) else { return false }
            if !automatic { return true }
            return preferences.scheduled && !preferences.paused &&
                preferences.roots.contains(where: { $0.path == artifact.root && $0.automatic }) &&
                Self.idle(since: artifact.firstObserved, now: now, hours: preferences.keepHours)
        }
        guard !candidates.isEmpty else { throw HeadroomError.message("No selected output is eligible. Protected items stay in place.") }
        return .init(id: UUID(), createdAt: now, candidates: candidates, preferences: preferences, automatic: automatic,
                     skippingWait: skipping.intersection(candidates.map(\.path)))
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
            paths.contains(artifact.path) && Self.idle(since: artifact.firstObserved, now: now, hours: preferences.keepHours) && preferences.roots.contains(where: { $0.path == artifact.root && $0.automatic })
        }
        guard !eligible.isEmpty else { return [] }
        return try execute(plan(paths: Set(eligible.map(\.path)), automatic: true))
    }
    /// Runs a reviewed plan one folder at a time. Cancelling the calling task stops before the next folder.
    public func execute(_ plan: CleanupPlan, progress: (@Sendable (HistoryEntry) -> Void)? = nil) throws -> [HistoryEntry] {
        let lease = try ProcessLease(path: directory.appendingPathComponent("operation.lock").path)
        defer { withExtendedLifetime(lease) {} }
        let preferences = try store.preferences()
        guard preferences == plan.preferences, clock().timeIntervalSince(plan.createdAt) >= 0,
              clock().timeIntervalSince(plan.createdAt) < 300 else { throw HeadroomError.message("Settings or the review expired. Prepare a new cleanup plan.") }
        var entries: [HistoryEntry] = []
        for artifact in plan.candidates {
            if Task<Never, Never>.isCancelled { break }
            var entry = HistoryEntry(id: UUID().uuidString, date: clock(), path: artifact.path, outcome: "Skipped", detail: "", bytes: 0,
                                     run: plan.id.uuidString, automatic: plan.automatic)
            do {
                guard preferences.roots.contains(where: { $0.path == artifact.root && Paths.contains($0.path, artifact.project) }),
                      URL(fileURLWithPath: artifact.project).resolvingSymlinksInPath().path == artifact.project else {
                    throw HeadroomError.message("Project is outside its approved scan root.")
                }
                // Re-inspect the entire artifact and live activity immediately before deletion.
                let fresh = try scanner.inspect(kind: artifact.kind, project: artifact.project, root: artifact.root, preferences: preferences, activity: activityProvider(), now: clock())
                guard fresh.eligible(skippingWait: plan.skippingWait.contains(fresh.path)) else { throw HeadroomError.message(fresh.reasons.joined(separator: " ")) }
                guard fresh.identity == artifact.identity, fresh.latestWrite == artifact.latestWrite,
                      fresh.files == artifact.files, fresh.bytes == artifact.bytes else { throw HeadroomError.message("Output changed since review. Scan again.") }
                let locks = fresh.kind == .cargo ? try CargoLocks(target: fresh.path) : nil
                defer { withExtendedLifetime(locks) {} }
                entry.outcome = "Cleaning"; entry.detail = "Permanent removal of verified \(fresh.kind.directory) output."
                try store.record(entry)
                try ContainedDeletion.remove(fresh)
                entry.outcome = "Cleaned"; entry.bytes = fresh.bytes
                entry.detail = fresh.kind == .node
                    ? "Dependencies removed. Package caches were preserved. Reinstall before the next build."
                    : "Build output removed. Shared compiler caches were preserved. Rebuilding may be required."
                if !fresh.eligible { entry.detail += " Removed before the keep window ended, as you chose." }
            } catch {
                entry.outcome = entry.outcome == "Cleaning" ? "Interrupted" : "Skipped"
                entry.detail = error.localizedDescription
            }
            try store.record(entry); entries.append(entry)
            progress?(entry)
        }
        inventory = .empty
        if let space = try? FileManager.default.attributesOfFileSystem(forPath: plan.candidates.first?.project ?? "/") {
            try? store.recordSpace(.init(date: clock(), capacity: (space[.systemSize] as? NSNumber)?.int64Value ?? 0,
                                         available: (space[.systemFreeSize] as? NSNumber)?.int64Value ?? 0))
        }
        return entries
    }
}
