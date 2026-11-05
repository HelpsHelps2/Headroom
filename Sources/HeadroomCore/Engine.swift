import Foundation

public actor Engine {
    private let store: StateStore
    private let scanner: Scanner
    private let directory: URL
    private let activityProvider: @Sendable () -> ActivitySnapshot
    private let clock: @Sendable () -> Date
    private var inventory = Inventory.empty
    private let discovery = DiscoveryCache()
    private let inspector: WorktreeInspector
    private var worktrees: [WorktreeStatus] = []
    /// Times the Mac slept while this process kept running. Nothing can use a folder then, so these do not break observation.
    private var sleeps: [DateInterval] = []
    /// A low-space run that removed nothing is not retried every check, which would only fill History with the same skips.
    private var lowSpaceRetry: Date = .distantPast
    static let lowSpaceBackoff: TimeInterval = 3600
    /// Longest unobserved awake stretch that keeps an observation continuous.
    static let gapLimit: TimeInterval = 600

    public init(directory: URL = Paths.defaultState,
                home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                activity: @escaping @Sendable () -> ActivitySnapshot = { ActivitySnapshot.capture() },
                clock: @escaping @Sendable () -> Date = { Date() },
                pullRequests: PullRequestCache = PullRequestCache()) throws {
        self.directory = directory; self.store = try StateStore(directory: directory)
        self.scanner = Scanner(home: home); self.activityProvider = activity; self.clock = clock
        self.inspector = WorktreeInspector(pullRequests: pullRequests)
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
    /// Records a sleep the calling process lived through. Only a process that stayed running can vouch that it watched.
    public func recordSleep(_ interval: DateInterval) {
        sleeps.append(interval)
        sleeps = Array(sleeps.suffix(64))
    }
    /// True when every awake stretch between `seen` and `now` is within `gapLimit`, counting recorded sleeps as watched.
    static func continuous(seen: Date, now: Date, sleeps: [DateInterval], gapLimit: TimeInterval = gapLimit) -> Bool {
        guard now >= seen else { return false }
        var cursor = seen
        for sleep in sleeps.sorted(by: { $0.start < $1.start }) where sleep.end > cursor && sleep.start < now {
            if sleep.start.timeIntervalSince(cursor) > gapLimit { return false }
            cursor = max(cursor, sleep.end)
        }
        return now.timeIntervalSince(cursor) <= gapLimit
    }
    public func scan(progress: Scanner.Progress? = nil) throws -> Inventory {
        let lease = try ProcessLease(path: directory.appendingPathComponent("operation.lock").path)
        defer { withExtendedLifetime(lease) {} }
        try store.recoverInterrupted()
        let preferences = try store.preferences(), now = clock()
        try store.pruneObservations(now: now)
        var result = scanner.scan(preferences: preferences, activity: activityProvider(), now: now, progress: progress, discovery: discovery)
        let sleeps = self.sleeps
        for index in result.artifacts.indices {
            let since = try store.observed(result.artifacts[index], now: now) { Self.continuous(seen: $0, now: now, sleeps: sleeps) }
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
    /// Cleans what automatic cleanup may remove, at most once per interval. A check with nothing ready does not use up
    /// the interval, so output that becomes idle later is cleaned at the next check instead of a full interval later.
    public func runScheduleIfDue() throws -> [HistoryEntry] {
        let preferences = try store.preferences(), now = clock()
        guard preferences.scheduled, !preferences.paused else { return [] }
        let eligible = inventory.artifacts.filter { artifact in
            artifact.eligible && Self.idle(since: artifact.firstObserved, now: now, hours: preferences.keepHours) &&
                preferences.roots.contains(where: { $0.path == artifact.root && $0.automatic })
        }
        guard try claimSchedule(interval: preferences.intervalHours * 3600, ready: !eligible.isEmpty) else {
            return try cleanForLowSpace(eligible: eligible, preferences: preferences, now: now)
        }
        return try execute(plan(paths: Set(eligible.map(\.path)), automatic: true))
    }
    /// Runs before the interval is up when the person opted in and free space is low. It only narrows what the schedule
    /// would remove anyway: the candidates have already passed every check, including the wait.
    private func cleanForLowSpace(eligible: [Artifact], preferences: Preferences, now: Date) throws -> [HistoryEntry] {
        let space = DiskSpace(capacity: inventory.capacity, available: inventory.available)
        guard preferences.cleansWhenLow, now >= lowSpaceRetry, LowSpace.isLow(space, preferences),
              let diskPath = preferences.roots.first?.path, let disk = try? FileInspection.metadata(diskPath) else { return [] }
        // Free space is measured on one volume. Output on another would not help it.
        let sameVolume = eligible.filter { $0.identity.device == UInt64(disk.st_dev) }
        let chosen = LowSpace.selection(from: sameVolume, space: space, preferences: preferences)
        guard !chosen.isEmpty else { return [] }
        let entries = try execute(plan(paths: Set(chosen.map(\.path)), automatic: true))
        if !entries.contains(where: { $0.outcome == "Cleaned" }) { lowSpaceRetry = now.addingTimeInterval(Self.lowSpaceBackoff) }
        return entries
    }
    private func claimSchedule(interval: TimeInterval, ready: Bool) throws -> Bool {
        let lease = try ProcessLease(path: directory.appendingPathComponent("operation.lock").path)
        defer { withExtendedLifetime(lease) {} }
        return try store.scheduleDue(now: clock(), interval: interval, ready: ready)
    }
    // MARK: Whole worktrees

    /// Applies the worktree rules to everything the last scan found. Read-only, and off the actor so scans can continue meanwhile.
    public func surveyWorktrees() async throws -> [WorktreeStatus] {
        let roots = inventory.worktrees
        guard !roots.isEmpty else { return worktrees }
        let preferences = try store.preferences(), artifacts = inventory.artifacts, now = clock()
        let activity = activityProvider(), inspector = self.inspector
        let result = await Task.detached(priority: .utility) {
            inspector.survey(roots: roots, preferences: preferences, activity: activity, artifacts: artifacts, now: now)
        }.value
        worktrees = result
        return result
    }
    /// There is deliberately no automatic path to this: removing a worktree always follows a person's review.
    public func planWorktreeRemoval(tops: Set<String>, approvingIgnored: Set<String> = []) throws -> WorktreeRemovalPlan {
        try planWorktreeRemoval(reviewed: worktrees.filter { tops.contains($0.top) }, approvingIgnored: approvingIgnored)
    }
    /// Plans from the statuses a person actually saw, not the latest survey, which may have refreshed during the review.
    public func planWorktreeRemoval(reviewed: [WorktreeStatus], approvingIgnored: Set<String> = []) throws -> WorktreeRemovalPlan {
        let candidates = reviewed.filter { $0.verdict == .ready || ($0.verdict == .needsLook && approvingIgnored.contains($0.top)) }
        guard !candidates.isEmpty else { throw HeadroomError.message("No selected worktree can be removed. Scan again and review the reasons.") }
        return .init(candidates: candidates, approvedIgnored: approvingIgnored.intersection(candidates.map(\.top)))
    }
    /// Removes reviewed worktrees one at a time, applying every rule again immediately before each one.
    public func removeWorktrees(_ plan: WorktreeRemovalPlan, progress: (@Sendable (HistoryEntry) -> Void)? = nil) throws -> [HistoryEntry] {
        let lease = try ProcessLease(path: directory.appendingPathComponent("operation.lock").path)
        defer { withExtendedLifetime(lease) {} }
        let preferences = try store.preferences(), run = UUID().uuidString, known = Array(inventory.worktrees.keys)
        var entries: [HistoryEntry] = []
        for reviewed in plan.candidates {
            if Task<Never, Never>.isCancelled { break }
            var entry = HistoryEntry(id: UUID().uuidString, date: clock(), path: reviewed.top, outcome: "Skipped", detail: "", bytes: 0, run: run, automatic: false)
            do {
                guard preferences.roots.contains(where: { $0.path == reviewed.root && Paths.contains($0.path, reviewed.top) }) else {
                    throw HeadroomError.message("Worktree is outside its approved scan root.")
                }
                let repository = inspector.repository(top: reviewed.top, now: clock())
                let fresh = inspector.inspect(top: reviewed.top, root: reviewed.root, repository: repository, preferences: preferences,
                                              activity: activityProvider(), artifacts: inventory.artifacts, known: known, now: clock(), remeasure: true)
                guard fresh.verdict != .kept else { throw HeadroomError.message(fresh.reason ?? "It no longer meets the rules.") }
                guard fresh.head == reviewed.head else { throw HeadroomError.message("Its commit changed since review.") }
                // Everything unrestorable that goes must have been on the review screen.
                guard Set(fresh.envFiles).isSubset(of: reviewed.envFiles), Set(fresh.otherIgnored).isSubset(of: reviewed.otherIgnored),
                      fresh.verdict == .ready || plan.approvedIgnored.contains(reviewed.top) else {
                    throw HeadroomError.message("It has new ignored files since review.")
                }
                if let repository { try inspector.preserveCommit(top: fresh.top, head: fresh.head, repository: repository) }
                let restore = WorktreeRestore(top: fresh.top, common: fresh.common, branch: fresh.branch, head: fresh.head)
                entry.restore = restore
                entry.outcome = "Cleaning"; entry.detail = "Removing the worktree."
                try store.record(entry)
                // Never --force: Git makes its own check and refuses changes, locks, and submodules.
                let result = try Command.git(fresh.common, WorktreeInspector.removeArguments(top: fresh.top), timeout: 900)
                guard result.status == 0 else {
                    let exists = FileManager.default.fileExists(atPath: fresh.top + "/.git")
                    entry.outcome = exists ? "Skipped" : "Interrupted"; entry.restore = nil
                    throw HeadroomError.message(result.error.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                entry.outcome = "Cleaned"; entry.bytes = fresh.bytes
                var detail = fresh.branch.map { "Worktree removed. Branch \($0) stays." } ?? "Worktree removed. Its commit stays in the repository."
                let gone = fresh.envFiles + fresh.otherIgnored
                if !gone.isEmpty { detail += " Also removed: \(gone.joined(separator: ", "))." }
                entry.detail = detail
            } catch {
                if entry.outcome == "Cleaning" { entry.outcome = "Interrupted" }
                entry.detail = error.localizedDescription
            }
            try store.record(entry); entries.append(entry)
            progress?(entry)
        }
        worktrees.removeAll { status in entries.contains { $0.path == status.top && $0.outcome == "Cleaned" } }
        inventory = .empty
        if let space = try? FileManager.default.attributesOfFileSystem(forPath: plan.candidates.first?.root ?? "/") {
            try? store.recordSpace(.init(date: clock(), capacity: (space[.systemSize] as? NSNumber)?.int64Value ?? 0,
                                         available: (space[.systemFreeSize] as? NSNumber)?.int64Value ?? 0))
        }
        return entries
    }
    /// Recreates a removed worktree from its branch, or at its commit if the branch is gone. Ignored files do not come back.
    public func restoreWorktree(_ restore: WorktreeRestore) throws {
        let lease = try ProcessLease(path: directory.appendingPathComponent("operation.lock").path)
        defer { withExtendedLifetime(lease) {} }
        guard !FileManager.default.fileExists(atPath: restore.top) else { throw HeadroomError.message("Something already exists at \(restore.top).") }
        var arguments = ["worktree", "add", "--detach", restore.top, restore.head]
        if let branch = restore.branch, try Command.git(restore.common, ["rev-parse", "-q", "--verify", "refs/heads/\(branch)"]).status == 0 {
            arguments = ["worktree", "add", restore.top, branch]
        }
        let result = try Command.git(restore.common, arguments, timeout: 600)
        guard result.status == 0 else { throw HeadroomError.message(result.error.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// Runs a reviewed plan one folder at a time. Cancelling the calling task stops before the next folder.
    /// `progress` fires once per finished folder; `activity` reports verification and removal inside the current folder.
    public func execute(_ plan: CleanupPlan, progress: (@Sendable (HistoryEntry) -> Void)? = nil,
                        activity: (@Sendable (CleanupActivity) -> Void)? = nil) throws -> [HistoryEntry] {
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
                activity?(.verifying(path: artifact.path))
                // Re-inspect the entire artifact and live activity immediately before deletion.
                let fresh = try scanner.inspect(kind: artifact.kind, project: artifact.project, root: artifact.root, preferences: preferences, activity: activityProvider(), now: clock())
                guard fresh.eligible(skippingWait: plan.skippingWait.contains(fresh.path)) else { throw HeadroomError.message(fresh.reasons.joined(separator: " ")) }
                guard fresh.identity == artifact.identity, fresh.latestWrite == artifact.latestWrite,
                      fresh.files == artifact.files, fresh.bytes == artifact.bytes else { throw HeadroomError.message("Output changed since review. Scan again.") }
                let locks = fresh.kind == .cargo ? try CargoLocks(target: fresh.path) : nil
                defer { withExtendedLifetime(locks) {} }
                entry.outcome = "Cleaning"; entry.detail = "Permanent removal of verified \(fresh.kind.directory) output."
                try store.record(entry)
                activity?(.removing(path: artifact.path, bytes: 0))
                try ContainedDeletion.remove(fresh) { bytes in activity?(.removing(path: artifact.path, bytes: bytes)) }
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
