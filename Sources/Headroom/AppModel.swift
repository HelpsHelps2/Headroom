import SwiftUI
import AppKit
import ServiceManagement
import HeadroomCore

enum AppTab: String, CaseIterable { case disk = "Disk", worktrees = "Worktrees", history = "History" }
enum Screen: Equatable { case main, review, sweep, settings }
enum WorktreeFilter: String, CaseIterable { case stale = "Stale", kept = "Kept", all = "All" }
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
    var finished = false
    var stopping = false
    var total: Int64 { candidates.reduce(0) { $0 + $1.bytes } }
    var freed: Int64 { entries.values.filter { $0.outcome == "Cleaned" }.reduce(0) { $0 + $1.bytes } }
    var skippedBytes: Int64 {
        candidates.filter { entries[$0.path].map { $0.outcome != "Cleaned" } ?? false }.reduce(0) { $0 + $1.bytes }
    }
    var current: String? { finished ? nil : candidates.first { entries[$0.path] == nil }?.path }
    var done: Int { entries.count }
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
    var reviewFilter: ReviewFilter = .remove
    var sweep: SweepState?
    var repository: String?
    var worktreeFilter: WorktreeFilter = .stale
    var confirmingSchedule = false
    var copied = false
    var suggestions: [FolderSuggestion] = []
    var chosenSuggestions: Set<String> = []
    var findingSuggestions = false
    let demo: Bool
    @ObservationIgnored private var engine: Engine?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored var sweepTask: Task<Void, Never>?

    init(demo: Bool = CommandLine.arguments.contains("--demo")) {
        self.demo = demo
        if demo { Demo.load(into: self); return }
        do { engine = try Engine() } catch { self.error = error.localizedDescription }
        Task {
            await reload()
            if preferences.roots.isEmpty { await suggestFolders() } else { await scan() }
            restartTimer()
        }
    }

    // MARK: Derived state

    /// Folders under 1 MB are not worth a line (for example a `node_modules` holding only a Vite cache).
    var visible: [Artifact] { inventory.artifacts.filter { $0.bytes >= 1_000_000 } }
    var eligible: [Artifact] { visible.filter(\.eligible) }
    var kept: [Artifact] { visible.filter { !$0.eligible } }
    var reclaimable: Int64 { eligible.reduce(0) { $0 + $1.bytes } }
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
    var selectedRepository: String? { repository.flatMap { name in repositories.contains { $0.name == name } ? name : nil } ?? repositories.first?.name }
    var repositoryGroups: [WorktreeGroup] {
        groups.filter { $0.repository == selectedRepository }.sorted { a, b in
            if (a.info?.isMain ?? false) != (b.info?.isMain ?? false) { return a.info?.isMain ?? false }
            if a.stale != b.stale { return a.stale }
            return a.bytes > b.bytes
        }
    }
    var runs: [SweepRun] {
        Dictionary(grouping: history, by: \.run).map { SweepRun(id: $0.key, entries: $0.value) }.sorted { $0.date > $1.date }
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
        guard let engine, !scanning, sweep == nil, !preferences.roots.isEmpty else { return }
        scanning = true
        defer { scanning = false }
        let progress: HeadroomCore.Scanner.Progress = { [weak self] done, total in
            Task { @MainActor in self?.scanProgress = (done, total) }
        }
        do {
            inventory = try await Task.detached(priority: .utility) { try await engine.scan(progress: progress) }.value
            hasScanned = true
            history = try await engine.history()
            space = try await engine.space(since: Date().addingTimeInterval(-14 * 86400))
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

    private func tick() async {
        guard sweep == nil, !scanning, !preferences.roots.isEmpty else { return }
        await scan()
        guard preferences.scheduled, !preferences.paused, let engine else { return }
        do {
            let entries = try await engine.runScheduleIfDue()
            if !entries.isEmpty { await reload(); await scan() }
        } catch { self.error = error.localizedDescription }
    }

    func windowOpened() {
        guard !demo, !scanning, Date().timeIntervalSince(inventory.scannedAt) > 120 else { return }
        Task { await scan() }
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

    func openReview(_ scope: [Artifact]) {
        review = scope.filter(\.eligible).sorted { ($0.worktree?.top ?? $0.project, -$0.bytes) < ($1.worktree?.top ?? $1.project, -$1.bytes) }
        let tops = Set(scope.map { $0.worktree?.top ?? $0.project })
        reviewKept = kept.filter { tops.contains($0.worktree?.top ?? $0.project) }
        excluded = []
        reviewFilter = .remove
        withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { screen = .review }
    }

    func toggleExcluded(_ artifact: Artifact) {
        if excluded.contains(artifact.path) { excluded.remove(artifact.path) } else { excluded.insert(artifact.path) }
    }

    func cliCommand() -> String {
        let binary = Bundle.main.bundlePath + "/Contents/MacOS/headroom-cli"
        let quoted = reviewIncluded.map { "  '" + $0.path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return (["'\(binary)' clean --yes"] + quoted).joined(separator: " \\\n")
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
        sweep = SweepState(candidates: included)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { screen = .sweep }
        if demo { Demo.simulateSweep(self); return }
        guard let engine else { return }
        let scannedAt = inventory.scannedAt
        sweepTask = Task { [weak self] in
            do {
                // Plans require a fresh inventory. Rescanning can only shrink what was reviewed, never add to it.
                if Date().timeIntervalSince(scannedAt) > 240 { _ = try await engine.scan() }
                let plan = try await engine.plan(paths: Set(included.map(\.path)))
                self?.sweep?.candidates = plan.candidates
                let results = try await engine.execute(plan) { entry in
                    Task { @MainActor in self?.record(entry) }
                }
                for entry in results { self?.record(entry) }
            } catch {
                self?.error = error.localizedDescription
            }
            self?.finishSweep()
        }
    }

    func record(_ entry: HistoryEntry) {
        withAnimation(.spring(response: 0.5, dampingFraction: 0.9)) { sweep?.entries[entry.path] = entry }
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
        sweep = nil
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
