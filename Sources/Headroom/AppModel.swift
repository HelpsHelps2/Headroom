import SwiftUI
import AppKit
import ServiceManagement
import HeadroomCore

enum AppTab: String, CaseIterable { case disk = "Disk", worktrees = "Worktrees", history = "History" }
enum Screen: Equatable { case main, review, sweep, settings, worktreeRules, worktreeReview, worktreeRemoval }
enum WorktreeFilter: String, CaseIterable { case all = "All", stale = "Stale", merged = "Merged", kept = "Kept" }
enum ReviewFilter: String, CaseIterable { case remove = "Remove", kept = "Kept", excluded = "Excluded" }

/// All build output found in one worktree.
struct WorktreeGroup: Identifiable {
    var id: String { top }
    let top: String
    let info: WorktreeInfo?
    let artifacts: [Artifact]
    var name: String { info?.branch ?? URL(fileURLWithPath: top).lastPathComponent }
    var repository: String { info?.repository ?? "Other" }
    var bytes: Int64 { artifacts.reduce(0) { $0 + $1.bytes } }
    var reclaimable: Int64 { artifacts.filter(\.eligible).reduce(0) { $0 + $1.bytes } }
    var stale: Bool { artifacts.contains(where: \.eligible) }
    /// Kept only by the keep-hours wait, which a person can skip.
    var waiting: Bool { !stale && artifacts.contains(where: \.waiting) }
    var selectable: Bool { stale || waiting }
    /// Output that goes when this worktree is selected: eligible folders, plus ones only waiting out the keep window.
    var removable: [Artifact] { artifacts.filter { $0.eligible || $0.waiting } }
    /// The process holding this worktree open, from "In use by name (pid N)."
    var process: (name: String, pid: pid_t)? {
        for reason in artifacts.flatMap(\.reasons) where reason.hasPrefix("In use by ") {
            guard let open = reason.range(of: " (pid "), let pid = pid_t(reason[open.upperBound...].prefix { $0.isNumber }) else { continue }
            return (String(reason[reason.index(reason.startIndex, offsetBy: 10)..<open.lowerBound]), pid)
        }
        return nil
    }
    var lastWrite: Date { artifacts.map(\.latestWrite).max() ?? .distantPast }
    var keptReason: String? { Reason.primary(artifacts.flatMap(\.reasons)) }
}

struct SweepRun: Identifiable {
    let id: String
    let entries: [HistoryEntry]
    var date: Date { entries.map(\.date).min() ?? .distantPast }
    var automatic: Bool { entries.first?.automatic ?? false }
    var cleaned: [HistoryEntry] { entries.filter { $0.outcome == "Cleaned" } }
    var skipped: [HistoryEntry] { entries.filter { $0.outcome != "Cleaned" } }
    var bytes: Int64 { cleaned.reduce(0) { $0 + $1.bytes } }
}

struct SweepState {
    var candidates: [Artifact]
    var entries: [String: HistoryEntry] = [:]
    /// Live work inside the current folder; cleared once that folder has an entry.
    var activity: CleanupActivity?
    var finished = false
    var stopping = false
    var failed = false
    var succeeded: Bool { finished && !stopping && !failed && freed > 0 && !entries.values.contains { $0.outcome == "Interrupted" } }
    var total: Int64 { candidates.reduce(0) { $0 + $1.bytes } }
    /// Bytes removed so far in the folder being swept, capped at what review measured.
    var removing: Int64 {
        guard case let .removing(path, bytes)? = activity, entries[path] == nil,
              let candidate = candidates.first(where: { $0.path == path }) else { return 0 }
        return min(bytes, candidate.bytes)
    }
    /// True once the current folder has moved past verification.
    var removingStarted: Bool {
        guard case let .removing(path, _)? = activity else { return false }
        return entries[path] == nil
    }
    var verifying: Bool {
        guard case let .verifying(path)? = activity else { return false }
        return entries[path] == nil
    }
    var freed: Int64 { entries.values.filter { $0.outcome == "Cleaned" }.reduce(0) { $0 + $1.bytes } + removing }
    var skippedBytes: Int64 {
        candidates.filter { entries[$0.path].map { $0.outcome != "Cleaned" } ?? false }.reduce(0) { $0 + $1.bytes }
    }
    var current: String? { finished ? nil : candidates.first { entries[$0.path] == nil }?.path }
    var done: Int { entries.count }
}

struct WorktreeRemovalState {
    var candidates: [WorktreeStatus]
    var entries: [String: HistoryEntry] = [:]
    var finished = false
    var stopping = false
    var failed = false
    var total: Int64 { candidates.reduce(0) { $0 + $1.bytes } }
    var freed: Int64 { entries.values.filter { $0.outcome == "Cleaned" }.reduce(0) { $0 + $1.bytes } }
    var current: String? { finished ? nil : candidates.first { entries[$0.top] == nil }?.top }
}

@MainActor @Observable
final class AppModel {
    var tab: AppTab = .disk
    var screen: Screen = .main
    var preferences = Preferences()
    var inventory = Inventory.empty
    var history: [HistoryEntry] = []
    var space: [SpaceSample] = []
    var scanning = false
    var scanProgress = (done: 0, total: 0)
    var hasScanned = false
    var error: String?
    var review: [Artifact] = []
    var reviewKept: [Artifact] = []
    var excluded: Set<String> = []
    /// Review lines a person chose to remove before the keep window ends.
    var reviewSkippingWait: Set<String> = []
    /// Worktree tops checked in the Worktrees tab.
    var selected: Set<String> = []
    @ObservationIgnored var selectionAnchor: String?
    var reviewFilter: ReviewFilter = .remove
    var sweep: SweepState?
    var lastReclaimed: Int64?
    @ObservationIgnored private var inventoryRevision = 0
    /// nil shows every repository.
    var repository: String?
    var worktreeFilter: WorktreeFilter = .all
    var confirmingSchedule = false
    var copied = false
    var suggestions: [FolderSuggestion] = []
    var chosenSuggestions: Set<String> = []
    var findingSuggestions = false
    /// Every worktree with its verdict under the removal rules.
    var worktrees: [WorktreeStatus] = []
    var surveying = false
    @ObservationIgnored var surveyedAt: Date?
    /// Ready worktrees unchecked by a person. Ready ones start checked.
    var worktreeUnchecked: Set<String> = []
    /// Worktrees with other ignored files checked by a person. Those start unchecked.
    var worktreeOptedIn: Set<String> = []
    var worktreeReview: [WorktreeStatus] = []
    var removal: WorktreeRemovalState?
    @ObservationIgnored var removalTask: Task<Void, Never>?
    let demo: Bool
    @ObservationIgnored private var engine: Engine?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var spaceTimer: Timer?
    @ObservationIgnored private var lowSpaceAlerts = LowSpaceAlerts()
    @ObservationIgnored private var wasLow = false
    @ObservationIgnored private var checkingSpace = false
    @ObservationIgnored private var ticking = 0
    /// Counts requests to open the window from outside a view, such as clicking a notification.
    var windowRequests = 0
    var notificationsDenied = false
    @ObservationIgnored var sweepTask: Task<Void, Never>?
    @ObservationIgnored private var sleptAt: Date?
    @ObservationIgnored private var powerObservers: [NSObjectProtocol] = []

    init(demo: Bool = CommandLine.arguments.contains("--demo")) {
        self.demo = demo
        if demo { Demo.load(into: self); return }
        do { engine = try Engine() } catch { self.error = error.localizedDescription }
        observeSleep()
        Task {
            await reload()
            if preferences.roots.isEmpty { await suggestFolders() } else { await scan() }
            restartTimer()
            startSpaceWatch()
        }
    }

    // MARK: Derived state

    /// Folders under 1 MB are not worth a line (for example a `node_modules` holding only a Vite cache).
    var visible: [Artifact] { inventory.artifacts.filter { $0.bytes >= 1_000_000 } }
    var eligible: [Artifact] { visible.filter(\.eligible) }
    var kept: [Artifact] { visible.filter { !$0.eligible } }
    var reclaimable: Int64 { eligible.reduce(0) { $0 + $1.bytes } }
    /// Output kept only by the keep window, which Clean Now removes too.
    var recent: [Artifact] { visible.filter(\.waiting) }
    var recentBytes: Int64 { recent.reduce(0) { $0 + $1.bytes } }
    var pressure: Double { inventory.capacity > 0 ? 1 - Double(inventory.available) / Double(inventory.capacity) : 0 }
    var groups: [WorktreeGroup] {
        Dictionary(grouping: visible) { $0.worktree?.top ?? $0.project }
            .map { WorktreeGroup(top: $0.key, info: $0.value.first?.worktree, artifacts: $0.value.sorted { $0.bytes > $1.bytes }) }
    }
    var repositories: [(name: String, bytes: Int64, trees: Int)] {
        Dictionary(grouping: groups, by: \.repository)
            .map { (name: $0.key, bytes: $0.value.reduce(0) { $0 + $1.bytes }, trees: $0.value.count) }
            .sorted { $0.bytes > $1.bytes }
    }
    /// The chosen repository, or nil for all of them (also when the chosen one disappears).
    var selectedRepository: String? { repository.flatMap { name in repositories.contains { $0.name == name } ? name : nil } }
    /// Worktrees in the selected repository, or in every repository ordered by repository size.
    var repositoryGroups: [WorktreeGroup] {
        let order = Dictionary(uniqueKeysWithValues: repositories.enumerated().map { ($1.name, $0) })
        return groups.filter { selectedRepository == nil || $0.repository == selectedRepository }.sorted { a, b in
            if a.repository != b.repository { return order[a.repository, default: .max] < order[b.repository, default: .max] }
            if (a.info?.isMain ?? false) != (b.info?.isMain ?? false) { return a.info?.isMain ?? false }
            if a.stale != b.stale { return a.stale }
            if a.waiting != b.waiting { return a.waiting }
            return a.bytes > b.bytes
        }
    }
    var runs: [SweepRun] {
        Dictionary(grouping: history, by: \.run).map { SweepRun(id: $0.key, entries: $0.value) }.sorted { $0.date > $1.date }
    }
    /// A cleanup or worktree removal owns the screen until a person closes it.
    var busy: Bool { sweep != nil || removal != nil }
    var scopedWorktrees: [WorktreeStatus] { worktrees.filter { selectedRepository == nil || $0.repository == selectedRepository } }
    var readyWorktrees: [WorktreeStatus] { scopedWorktrees.filter { $0.verdict == .ready } }
    var lookWorktrees: [WorktreeStatus] { scopedWorktrees.filter { $0.verdict == .needsLook } }
    var keptWorktrees: [WorktreeStatus] { scopedWorktrees.filter { $0.verdict == .kept } }
    var chosenWorktrees: [WorktreeStatus] { scopedWorktrees.filter(isChosen) }
    func isChosen(_ status: WorktreeStatus) -> Bool {
        switch status.verdict {
        case .ready: !worktreeUnchecked.contains(status.top)
        case .needsLook: worktreeOptedIn.contains(status.top)
        case .kept: false
        }
    }
    var reviewIncluded: [Artifact] { review.filter { !excluded.contains($0.path) } }
    var reviewBytes: Int64 { reviewIncluded.reduce(0) { $0 + $1.bytes } }
    var statusText: String {
        if preferences.roots.isEmpty { return suggestions.isEmpty ? "Choose folders to watch" : "\(suggestions.count) folders found" }
        if scanning && !hasScanned { return "Scanning" }
        if pressure >= 0.9 { return "Disk pressure high" }
        if pressure >= 0.75 { return "Disk filling up" }
        return "Plenty of room"
    }
    var calm: Bool { !preferences.roots.isEmpty && hasScanned && pressure < 0.75 }

    // MARK: Engine

    func reload() async {
        guard let engine else { return }
        do {
            preferences = try await engine.preferences()
            history = try await engine.history()
            space = try await engine.space(since: Date().addingTimeInterval(-14 * 86400))
        } catch { self.error = error.localizedDescription }
    }

    func scan() async {
        guard let engine, !scanning, !busy, !preferences.roots.isEmpty else { return }
        scanning = true
        let revision = inventoryRevision
        defer { scanning = false }
        let progress: HeadroomCore.Scanner.Progress = { [weak self] done, total in
            Task { @MainActor in self?.scanProgress = (done, total) }
        }
        do {
            let refreshed = try await Task.detached(priority: .utility) { try await engine.scan(progress: progress) }.value
            guard revision == inventoryRevision else { return }
            inventory = refreshed
            hasScanned = true
            history = try await engine.history()
            space = try await engine.space(since: Date().addingTimeInterval(-14 * 86400))
            let looking = tab == .worktrees && worktreeFilter == .merged
            Task { await refreshWorktrees(force: looking) }
        } catch { self.error = error.localizedDescription }
    }

    /// Worktree verdicts run less often than scans: every rule is applied again before anything is removed, so an older list can't remove the wrong thing.
    func refreshWorktrees(force: Bool = false) async {
        guard let engine, !surveying, !busy else { return }
        if !force, let surveyedAt, Date().timeIntervalSince(surveyedAt) < 1800 { return }
        surveying = true
        defer { surveying = false }
        do {
            worktrees = try await engine.surveyWorktrees()
            surveyedAt = Date()
        } catch { self.error = error.localizedDescription }
    }

    private func persist() async {
        guard let engine else { return }
        do { try await engine.save(preferences) } catch {
            self.error = error.localizedDescription
            await reload()
        }
    }

    private func restartTimer() {
        timer?.invalidate()
        guard !demo else { return }
        // Automatic cleanup needs continuous observations no more than ten minutes apart.
        let interval: TimeInterval = preferences.scheduled && !preferences.paused ? 300 : 1800
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        timer?.tolerance = 30
    }

    /// Sleep does not restart the idle clock: Headroom stays running through it and nothing can use a folder meanwhile.
    /// A quit or crash still restarts it, because then nothing was watching.
    private func observeSleep() {
        let center = NSWorkspace.shared.notificationCenter
        powerObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sleptAt = Date() }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.woke() }
            },
        ]
    }

    private func woke() {
        guard let start = sleptAt, let engine else { return }
        sleptAt = nil
        let interval = DateInterval(start: start, end: max(start, Date()))
        Task {
            await engine.recordSleep(interval)
            await tick()
        }
    }

    /// Scans are too heavy to run every minute, and free space can fall tens of gigabytes between them. Reading it is cheap.
    private func startSpaceWatch() {
        guard !CommandLine.arguments.contains("--snapshot") else { return }
        spaceTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkSpace() }
        }
        spaceTimer?.tolerance = 15
    }

    private func readSpace() async -> DiskSpace? {
        guard let path = preferences.roots.first?.path else { return nil }
        let space = await Task.detached(priority: .utility) { DiskSpace.read(path: path) }.value
        return space.capacity > 0 ? space : nil
    }

    /// Unlike `busy`, false once a cleanup is done, even if its results are still on screen.
    private var cleanupRunning: Bool { sweep?.finished == false || removal?.finished == false }

    /// Cleans first when free space falls under the level, then alerts only if that did not resolve it.
    private func checkSpace() async {
        guard !checkingSpace, ticking == 0, !cleanupRunning, !scanning, hasScanned else { return }
        checkingSpace = true
        defer { checkingSpace = false }
        guard var space = await readSpace() else { return }
        if LowSpace.isLow(space, preferences), !wasLow {
            wasLow = true
            await tick()
            guard let fresh = await readSpace() else { return }
            space = fresh
        }
        wasLow = LowSpace.isLow(space, preferences)
        // Something may have started during the reads. Wait for it, since it may resolve the problem.
        guard ticking == 0, !cleanupRunning, !scanning, lowSpaceAlerts.shouldNotify(space, preferences: preferences, now: Date()) else { return }
        let body = Self.lowSpaceMessage(free: space.available, cleanable: reclaimable + recentBytes)
        if await LowSpaceNotifier.shared.post(title: "Disk space is low", body: body) { lowSpaceAlerts.notified(space, now: Date()) }
        notificationsDenied = await LowSpaceNotifier.shared.denied
    }

    nonisolated static func lowSpaceMessage(free: Int64, cleanable: Int64) -> String {
        let start = "\(Format.bytes(free)) free."
        return cleanable > 0 ? "\(start) \(Format.bytes(cleanable)) of build output can be cleaned." : "\(start) Headroom has no build output ready to clean."
    }

    private func tick() async {
        ticking += 1
        defer { ticking -= 1 }
        Updates.shared.installIfIdle()
        guard !busy, !scanning, !preferences.roots.isEmpty else { return }
        await scan()
        guard preferences.scheduled, !preferences.paused, let engine else { return }
        do {
            let entries = try await engine.runScheduleIfDue()
            if !entries.isEmpty { await reload(); await scan() }
        } catch { self.error = error.localizedDescription }
    }

    func windowOpened() {
        if !demo { Task { notificationsDenied = await LowSpaceNotifier.shared.denied } }
        guard !demo, !scanning, Date().timeIntervalSince(inventory.scannedAt) > 120 else { return }
        Task { await scan() }
    }

    // MARK: Whole worktrees

    func openMerged() {
        guard !demo, surveyedAt.map({ Date().timeIntervalSince($0) > 300 }) ?? true else { return }
        Task { await refreshWorktrees(force: true) }
    }

    func toggleChosen(_ status: WorktreeStatus) {
        switch status.verdict {
        case .ready:
            if worktreeUnchecked.contains(status.top) { worktreeUnchecked.remove(status.top) } else { worktreeUnchecked.insert(status.top) }
        case .needsLook:
            if worktreeOptedIn.contains(status.top) { worktreeOptedIn.remove(status.top) } else { worktreeOptedIn.insert(status.top) }
        case .kept: break
        }
    }

    func toggleKeep(_ top: String) {
        if preferences.pinned.contains(top) { preferences.pinned.remove(top) } else { preferences.pinned.insert(top) }
        Task { await persist(); await refreshWorktrees(force: true) }
    }

    func openWorktreeReview() {
        worktreeReview = chosenWorktrees.sorted { $0.bytes > $1.bytes }
        guard !worktreeReview.isEmpty else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { screen = .worktreeReview }
    }

    func startWorktreeRemoval() {
        let list = worktreeReview
        guard !list.isEmpty, !busy else { return }
        removal = WorktreeRemovalState(candidates: list)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { screen = .worktreeRemoval }
        if demo { Demo.simulateRemoval(self); return }
        guard let engine else { return }
        let approved = Set(list.filter { $0.verdict == .needsLook }.map(\.top))
        removalTask = Task { [weak self] in
            do {
                let plan = try await engine.planWorktreeRemoval(reviewed: list, approvingIgnored: approved)
                self?.removal?.candidates = plan.candidates
                let results = try await engine.removeWorktrees(plan, progress: { entry in
                    Task { @MainActor in self?.recordRemoval(entry) }
                })
                for entry in results { self?.recordRemoval(entry) }
            } catch {
                self?.error = error.localizedDescription
                self?.removal?.failed = true
            }
            self?.removal?.finished = true
            self?.removalTask = nil
            await self?.reload()
        }
    }

    func recordRemoval(_ entry: HistoryEntry) {
        guard removal?.finished == false else { return }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.9)) {
            removal?.entries[entry.path] = entry
            if entry.outcome == "Cleaned" {
                worktrees.removeAll { $0.top == entry.path }
                inventory.artifacts.removeAll { Paths.contains(entry.path, $0.path) }
            }
        }
    }

    func stopWorktreeRemoval() {
        removal?.stopping = true
        removalTask?.cancel()
        if demo { removal?.finished = true }
    }

    func closeWorktreeRemoval() {
        guard let completed = removal, completed.finished else { return }
        lastReclaimed = completed.freed
        if demo {
            inventory.available = min(inventory.capacity, inventory.available + completed.freed)
        } else if let attributes = try? FileManager.default.attributesOfFileSystem(forPath: preferences.roots.first?.path ?? "/"),
                  let free = attributes[.systemFreeSize] as? NSNumber {
            inventory.available = free.int64Value
        }
        removal = nil
        worktreeUnchecked = []; worktreeOptedIn = []
        withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { screen = .main }
        Task { await scan() }
    }

    func restoreWorktree(_ restore: WorktreeRestore) {
        guard let engine, !demo else { return }
        Task {
            do {
                try await engine.restoreWorktree(restore)
                await scan()
            } catch { self.error = error.localizedDescription }
        }
    }

    // MARK: First launch

    /// Finds likely development folders and shows disk usage before anything is watched.
    func suggestFolders() async {
        findingSuggestions = true
        let watched = Set(preferences.roots.map(\.path))
        let found = await Task.detached(priority: .userInitiated) { FolderSuggestions.find() }.value
        suggestions = found.filter { !watched.contains($0.path) }
        chosenSuggestions = Set(suggestions.map(\.path))
        findingSuggestions = false
        if inventory.capacity == 0 {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let space = (try? FileManager.default.attributesOfFileSystem(forPath: home.path)) ?? [:]
            inventory.capacity = (space[.systemSize] as? NSNumber)?.int64Value ?? 0
            inventory.available = (space[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
            inventory.volume = (try? home.resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName ?? ""
        }
    }

    func toggleSuggestion(_ suggestion: FolderSuggestion) {
        if chosenSuggestions.contains(suggestion.path) { chosenSuggestions.remove(suggestion.path) } else { chosenSuggestions.insert(suggestion.path) }
    }

    func watchChosenSuggestions() {
        let chosen = suggestions.filter { chosenSuggestions.contains($0.path) }
        guard !chosen.isEmpty, !demo else { return }
        for suggestion in chosen where !preferences.roots.contains(where: { $0.path == suggestion.path }) {
            preferences.roots.append(WatchedRoot(path: suggestion.path))
        }
        suggestions = []
        Task { await persist(); await scan() }
    }

    // MARK: Review and sweep

    /// Opens the review for `scope`. With `skippingWait`, output only waiting out the keep window joins the plan.
    func openReview(_ scope: [Artifact], skippingWait: Bool = false) {
        guard !busy else { return }
        review = scope.filter { $0.eligible(skippingWait: skippingWait) }.sorted { ($0.worktree?.top ?? $0.project, -$0.bytes) < ($1.worktree?.top ?? $1.project, -$1.bytes) }
        let tops = Set(scope.map { $0.worktree?.top ?? $0.project })
        reviewKept = kept.filter { tops.contains($0.worktree?.top ?? $0.project) && !review.contains($0) }
        reviewSkippingWait = Set(review.filter { !$0.eligible }.map(\.path))
        excluded = []
        reviewFilter = .remove
        withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { screen = .review }
    }

    // MARK: Worktree selection

    var selectedGroups: [WorktreeGroup] { groups.filter { selected.contains($0.top) && $0.selectable } }

    /// Toggles one worktree, or with `range` everything between the last toggled row and this one.
    func toggleSelected(_ group: WorktreeGroup, range: Bool = false, in rows: [WorktreeGroup]) {
        guard group.selectable else { return }
        if range, let anchor = selectionAnchor, let from = rows.firstIndex(where: { $0.top == anchor }),
           let to = rows.firstIndex(where: { $0.top == group.top }) {
            let span = rows[min(from, to)...max(from, to)].filter(\.selectable).map(\.top)
            if selected.contains(anchor) { selected.formUnion(span) } else { selected.subtract(span) }
        } else if selected.contains(group.top) {
            selected.remove(group.top)
        } else {
            selected.insert(group.top)
        }
        selectionAnchor = group.top
    }

    /// Reviews everything that can go now: stale output plus output only waiting out the keep window.
    func cleanNow() {
        openReview(visible, skippingWait: true)
    }

    func reviewSelection() {
        openReview(selectedGroups.flatMap(\.removable), skippingWait: true)
    }

    /// Asks the process holding a worktree to quit, after confirmation, then scans again.
    func quit(_ process: (name: String, pid: pid_t)) {
        guard !demo else { return }
        let alert = NSAlert()
        alert.messageText = "Quit \(process.name)?"
        alert.informativeText = "Headroom asks \(process.name) (pid \(process.pid)) to quit, the same way the system does at logout. Anything it is doing stops. If it has unsaved work, it may ask you first."
        alert.addButton(withTitle: "Quit \(process.name)")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let app = NSRunningApplication(processIdentifier: process.pid) { app.terminate() } else { kill(process.pid, SIGTERM) }
        Task { try? await Task.sleep(for: .seconds(2)); await scan() }
    }

    func toggleExcluded(_ artifact: Artifact) {
        if excluded.contains(artifact.path) { excluded.remove(artifact.path) } else { excluded.insert(artifact.path) }
    }

    func cliCommand() -> String {
        let binary = Bundle.main.bundlePath + "/Contents/MacOS/headroom-cli"
        let quoted = reviewIncluded.map { "  '" + $0.path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let now = reviewIncluded.contains { reviewSkippingWait.contains($0.path) } ? " --now" : ""
        return (["'\(binary)' clean --yes" + now] + quoted).joined(separator: " \\\n")
    }

    func copyCLI() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cliCommand(), forType: .string)
        copied = true
        Task { try? await Task.sleep(for: .seconds(1.6)); copied = false }
    }

    func startSweep() {
        let included = reviewIncluded
        guard !included.isEmpty, sweep == nil else { return }
        inventoryRevision += 1
        lastReclaimed = nil
        sweep = SweepState(candidates: included)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { screen = .sweep }
        if demo { Demo.simulateSweep(self); return }
        guard let engine else { return }
        let scannedAt = inventory.scannedAt
        sweepTask = Task { [weak self] in
            do {
                // Plans require a fresh inventory. Rescanning can only shrink what was reviewed, never add to it.
                if Date().timeIntervalSince(scannedAt) > 240 { _ = try await engine.scan() }
                let paths = Set(included.map(\.path))
                let plan = try await engine.plan(paths: paths, skippingWait: self?.reviewSkippingWait.intersection(paths) ?? [])
                self?.sweep?.candidates = plan.candidates
                let results = try await engine.execute(plan, progress: { entry in
                    Task { @MainActor in self?.record(entry) }
                }, activity: { activity in
                    Task { @MainActor in self?.track(activity) }
                })
                for entry in results { self?.record(entry) }
            } catch {
                self?.error = error.localizedDescription
                self?.sweep?.failed = true
            }
            self?.finishSweep()
        }
    }

    func record(_ entry: HistoryEntry) {
        guard let sweep, !sweep.finished, sweep.candidates.contains(where: { $0.path == entry.path }) else { return }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.9)) {
            self.sweep?.entries[entry.path] = entry
            if entry.outcome == "Cleaned" { inventory.artifacts.removeAll { $0.path == entry.path } }
        }
    }

    func track(_ activity: CleanupActivity) {
        guard sweep?.finished == false else { return }
        withAnimation(.easeOut(duration: 0.25)) { sweep?.activity = activity }
    }

    func finishSweep() {
        sweep?.finished = true
        sweepTask = nil
        Task { await reload() }
    }

    func stopSweep() {
        sweep?.stopping = true
        sweepTask?.cancel()
        if demo { sweep?.finished = true }
    }

    func closeSweep() {
        guard let completed = sweep, completed.finished else { return }
        lastReclaimed = completed.freed
        // Refresh real free space without waiting for the full worktree scan.
        if demo {
            inventory.available = min(inventory.capacity, inventory.available + completed.freed)
        } else if let attributes = try? FileManager.default.attributesOfFileSystem(forPath: preferences.roots.first?.path ?? "/"),
                  let free = attributes[.systemFreeSize] as? NSNumber {
            inventory.available = free.int64Value
        }
        sweep = nil
        selected = []
        withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { screen = .main }
        Task { await scan() }
    }

    // MARK: Settings

    func addFolder() {
        guard !demo else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
        panel.message = "Choose folders that contain your repositories or worktrees."
        panel.prompt = "Watch"
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let path = url.resolvingSymlinksInPath().path
            if !preferences.roots.contains(where: { $0.path == path }) {
                preferences.roots.append(WatchedRoot(path: path))
            }
        }
        Task { await persist(); await scan() }
    }

    func removeRoot(_ root: WatchedRoot) {
        preferences.roots.removeAll { $0.path == root.path }
        if preferences.roots.isEmpty { inventory = .empty; hasScanned = false }
        Task {
            await persist()
            if preferences.roots.isEmpty { await suggestFolders() } else { await scan() }
        }
    }

    func toggleAutomatic(_ root: WatchedRoot) {
        guard let index = preferences.roots.firstIndex(where: { $0.path == root.path }) else { return }
        preferences.roots[index].automatic.toggle()
        Task { await persist() }
    }

    /// Turning automatic cleanup on asks for confirmation first, because it deletes without a review.
    func requestSchedule(_ on: Bool) {
        if on { confirmingSchedule = true } else { setSchedule(false) }
    }

    func setSchedule(_ on: Bool) {
        preferences.scheduled = on
        if on {
            preferences.paused = false
            if !preferences.roots.contains(where: \.automatic) {
                for index in preferences.roots.indices { preferences.roots[index].automatic = true }
            }
        }
        Task { await persist(); restartTimer() }
    }

    func setKeepHours(_ hours: Double) { preferences.keepHours = hours; Task { await persist(); await scan() } }
    func setInterval(_ hours: Double) { preferences.intervalHours = hours; Task { await persist() } }
    func togglePaused() { preferences.paused.toggle(); Task { await persist(); restartTimer() } }
    func setLowSpace(_ gigabytes: Double) { preferences.lowSpaceGB = gigabytes; Task { await persist() } }
    func toggleCleansWhenLow() { preferences.cleansWhenLow.toggle(); Task { await persist() } }

    func togglePin(_ group: WorktreeGroup) {
        if preferences.pinned.contains(group.top) { preferences.pinned.remove(group.top) } else { preferences.pinned.insert(group.top) }
        Task { await persist(); await scan() }
    }

    var opensAtLogin = SMAppService.mainApp.status == .enabled
    func toggleLogin() {
        guard !demo else { return }
        do {
            if opensAtLogin { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch { self.error = "Open at login needs the app installed in Applications. \(error.localizedDescription)" }
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }

    func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
}
