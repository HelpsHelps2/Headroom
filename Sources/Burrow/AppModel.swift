import SwiftUI
import AppKit
import ServiceManagement
import BurrowCore

@MainActor
final class AppModel: ObservableObject {
    @Published var preferences = Preferences()
    @Published var inventory = Inventory.empty
    @Published var history: [HistoryEntry] = []
    @Published var busy = false
    @Published var selection: String?
    @Published var query = ""
    @Published var filter = "All projects"
    @Published var error: String?
    @Published var plan: CleanupPlan?
    @Published var showSettings = false
    @Published var page = "Projects"
    let demo: Bool
    private var engine: Engine?
    private var observationTimer: Timer?

    init() {
        demo = CommandLine.arguments.contains("--demo")
        do { if !demo { engine = try Engine() } } catch { self.error = error.localizedDescription }
        if demo { loadDemo() }
        else {
            Task {
                await reload()
                if !preferences.roots.isEmpty { await scan() }
            }
            observationTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.tick() }
            }
        }
    }
    var artifacts: [Artifact] {
        inventory.artifacts.filter { artifact in
            (query.isEmpty || artifact.project.localizedCaseInsensitiveContains(query) || artifact.reasons.joined().localizedCaseInsensitiveContains(query)) &&
            (filter == "All projects" || (filter == "Ready to clean" ? artifact.eligible : !artifact.eligible))
        }
    }
    var selected: Artifact? { artifacts.first { $0.path == selection } ?? artifacts.first }
    var reclaimable: Int64 { inventory.artifacts.filter(\.eligible).reduce(0) { $0 + $1.bytes } }
    var total: Int64 { inventory.artifacts.reduce(0) { $0 + $1.bytes } }
    var pressure: Double { inventory.capacity > 0 ? 1 - Double(inventory.available) / Double(inventory.capacity) : 0 }
    var mood: String { pressure > 0.9 ? "A little crowded in here." : pressure > 0.75 ? "Let's make a little room." : "Room to make good things." }
    var automaticCount: Int {
        inventory.artifacts.filter { $0.eligible && Date().timeIntervalSince($0.firstObserved) >= preferences.keepHours * 3600 }.count
    }
    func reload() async {
        guard let engine else { return }
        do { preferences = try await engine.preferences(); history = try await engine.history() }
        catch { self.error = error.localizedDescription }
    }
    func persist() async {
        guard let engine else { return }
        do { try await engine.save(preferences) } catch { self.error = error.localizedDescription }
    }
    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
        panel.message = "Choose development folders. Shared compiler caches stay protected."
        if panel.runModal() == .OK {
            for url in panel.urls where !preferences.roots.contains(where: { $0.path == url.path }) {
                preferences.roots.append(WatchedRoot(path: url.resolvingSymlinksInPath().path))
            }
            Task { await persist(); await scan() }
        }
    }
    func scan() async {
        guard !busy, let engine else { return }
        busy = true
        defer { busy = false }
        do {
            inventory = try await engine.scan()
            if !inventory.artifacts.contains(where: { $0.path == selection }) { selection = inventory.artifacts.first?.path }
            history = try await engine.history()
        } catch { self.error = error.localizedDescription }
    }
    func pin(_ artifact: Artifact) {
        if preferences.pinned.contains(artifact.project) { preferences.pinned.remove(artifact.project) }
        else { preferences.pinned.insert(artifact.project) }
        Task { await persist(); await scan() }
    }
    func review(_ paths: Set<String>) async {
        guard let engine, !busy else { return }
        do { plan = try await engine.plan(paths: paths) }
        catch { self.error = error.localizedDescription }
    }
    func clean() async {
        guard let plan, let engine, !busy else { return }
        self.plan = nil; busy = true
        do { _ = try await engine.execute(plan) }
        catch { self.error = error.localizedDescription }
        busy = false
        await scan()
    }
    func tick() async {
        guard !busy, !preferences.paused, !preferences.roots.isEmpty else { return }
        await scan()
        guard !busy, let engine else { return }
        do {
            busy = true
            _ = try await engine.runScheduleIfDue()
            busy = false
            history = try await engine.history()
        } catch { busy = false; self.error = error.localizedDescription }
    }
    func togglePaused() {
        preferences.paused.toggle()
        Task { await persist() }
    }
    func enableLogin(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch { self.error = error.localizedDescription }
    }
    private func loadDemo() {
        let now = Date(), root = "/Users/developer/Projects"
        preferences.roots = [.init(path: root)]
        inventory = .init(artifacts: [
            .init(project: root + "/atlas-search", path: root + "/atlas-search/target", root: root, bytes: 18_400_000_000, files: 8231, latestWrite: now.addingTimeInterval(-86400 * 8), identity: .init(device: 1, inode: 1), reasons: [], firstObserved: now.addingTimeInterval(-86400 * 3)),
            .init(project: root + "/worktrees/fix-command-palette", path: root + "/worktrees/fix-command-palette/target", root: root, bytes: 12_800_000_000, files: 4189, latestWrite: now.addingTimeInterval(-86400 * 4), identity: .init(device: 1, inode: 2), reasons: [], firstObserved: now.addingTimeInterval(-86400 * 2)),
            .init(project: root + "/burrow", path: root + "/burrow/target", root: root, bytes: 7_200_000_000, files: 2351, latestWrite: now, identity: .init(device: 1, inode: 3), reasons: ["A terminal and language server are using this project."], firstObserved: now),
            .init(project: root + "/worktrees/new-parser", path: root + "/worktrees/new-parser/target", root: root, bytes: 4_600_000_000, files: 3121, latestWrite: now.addingTimeInterval(-86400 * 12), identity: .init(device: 1, inode: 4), reasons: ["Pinned by you."], firstObserved: now)
        ], issues: [], scannedAt: now, capacity: 1_000_000_000_000, available: 176_000_000_000, protectedCaches: ["~/.cargo/registry", "~/Library/Caches/Mozilla.sccache"])
        selection = inventory.artifacts.first?.path
    }
}
