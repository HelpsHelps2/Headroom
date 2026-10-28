import Foundation
import HeadroomCore

/// Example data for `--demo`: screenshots and design review without touching a real inventory. Cleanup is simulated.
@MainActor
enum Demo {
    static func load(into model: AppModel) {
        let now = Date(), home = FileManager.default.homeDirectoryForCurrentUser.path
        let code = home + "/code", trees = home + "/.t3/worktrees"
        var preferences = Preferences()
        preferences.roots = [.init(path: code, automatic: true), .init(path: trees, automatic: true)]
        preferences.scheduled = true
        model.preferences = preferences

        var inode: UInt64 = 0
        func tree(_ repo: String, _ folder: String, branch: String?, main: Bool = false, changed: Int = 0) -> WorktreeInfo {
            .init(top: (main ? code : trees + "/" + repo) + "/" + folder, repository: repo, branch: branch, isMain: main, changedFiles: changed, lastCommit: nil)
        }
        func item(_ info: WorktreeInfo, _ kind: ArtifactKind, _ relative: String, _ gb: Double, idle days: Double, _ reasons: [String] = []) -> Artifact {
            inode += 1
            let path = info.top + "/" + relative
            return Artifact(kind: kind, project: URL(fileURLWithPath: path).deletingLastPathComponent().path, path: path,
                            root: info.isMain ? code : trees, bytes: Int64(gb * 1e9), files: Int(gb * 9000),
                            latestWrite: now.addingTimeInterval(-days * 86400), identity: .init(device: 1, inode: inode),
                            reasons: reasons, firstObserved: now.addingTimeInterval(-days * 86400), worktree: info)
        }
        let recent = "Output was written within the last 24 hours."
        let t3main = tree("t3code", "t3code", branch: "main", main: true)
        let handoff = tree("t3code", "feat-thread-handoff", branch: "feat/thread-handoff")
        let wal = tree("t3code", "spike-sqlite-wal", branch: "spike/sqlite-wal")
        let sse = tree("t3code", "fix-sse-reconnect", branch: "fix/sse-reconnect", changed: 2)
        let claude = tree("t3code", "t3-7f3a91c2", branch: "wt/claude-7f3a")
        let codex = tree("t3code", "t3-19c2b0d4", branch: "wt/codex-19c2", changed: 4)
        let active = tree("t3code", "t3-a04e55f1", branch: "wt/claude-a04e", changed: 7)
        let release = tree("t3code", "release-0.31", branch: "release/0.31")
        let visits = tree("ledger", "visits-sync", branch: "visits-sync")
        let ledgerMain = tree("ledger", "ledger", branch: "main", main: true, changed: 1)
        let export = tree("ledger", "export-csv", branch: "export-csv")
        let ui = tree("headroom", "ui-pass", branch: "ui-pass")
        let fitment = tree("atlas", "fitment-cache", branch: "fitment-cache")
        let pricing = tree("atlas", "fix-pricing", branch: "fix/pricing")
        let orbit = tree("orbit", "t3-20dd7483", branch: "schedule-settled", changed: 12)
        model.inventory = Inventory(artifacts: [
            item(visits, .cargo, "target", 14.2, idle: 3),
            item(visits, .node, "node_modules", 1.9, idle: 3),
            item(ui, .cargo, "target", 9.4, idle: 5),
            item(ui, .node, "node_modules", 3.8, idle: 5),
            item(wal, .node, "node_modules", 7.9, idle: 21),
            item(wal, .node, "packages/web/node_modules", 2.3, idle: 21),
            item(handoff, .node, "node_modules", 6.1, idle: 4),
            item(sse, .node, "node_modules", 5.4, idle: 9),
            item(claude, .node, "node_modules", 4.8, idle: 2),
            item(fitment, .cargo, "target", 46.1, idle: 2),
            item(pricing, .cargo, "target", 38.6, idle: 6),
            item(export, .node, "node_modules", 2.4, idle: 1.2),
            item(orbit, .cargo, "backend/api/target", 41.4, idle: 2.5),
            item(orbit, .node, "node_modules", 0.9, idle: 2.5),
            item(t3main, .node, "node_modules", 4.1, idle: 0.1, ["In use by Cursor (pid 2214).", recent]),
            item(codex, .node, "node_modules", 3.2, idle: 0.02, ["In use by bun (pid 51807).", recent]),
            item(active, .node, "node_modules", 2.2, idle: 0.01, [recent]),
            item(release, .node, "node_modules", 1.6, idle: 16, ["Git worktree is locked."]),
            item(ledgerMain, .cargo, "target", 8.8, idle: 0.01, ["Cargo holds a build lock.", "In use by cargo (pid 48213).", recent]),
            item(orbit, .cargo, "backend/db/target", 20.1, idle: 2.5, ["Unexpected items in target: pg.log, pgdata."]),
        ], issues: [], scannedAt: now, capacity: 494_400_000_000, available: 44_600_000_000,
           protectedCaches: [home + "/.cargo", home + "/.npm", home + "/.bun", home + "/Library/pnpm", home + "/Library/Caches/Mozilla.sccache"],
           volume: "Macintosh HD")
        model.hasScanned = true

        // Fourteen days of free space: steep daily drops until nightly sweeps start on day nine.
        var samples: [SpaceSample] = [], history: [HistoryEntry] = []
        let start = Calendar.current.startOfDay(for: now).addingTimeInterval(-13 * 86400)
        for hour in stride(from: 0, through: 13 * 24 + Calendar.current.component(.hour, from: now), by: 2) {
            let day = hour / 24, inDay = Double(hour % 24) / 24
            let nightly = day >= 8
            let free = nightly ? 230 - 34 * inDay : 236 - 200 * inDay
            samples.append(.init(date: start.addingTimeInterval(Double(hour) * 3600), capacity: 494_400_000_000, available: Int64(free * 1e9)))
        }
        if let last = samples.indices.last { samples[last].available = 44_600_000_000 }
        model.space = samples
        let runs: [(Double, Bool, Double, Int, Int)] = [(0.4, false, 191.2, 34, 0), (1.92, true, 176.8, 31, 2), (2.92, true, 168.4, 29, 0),
                                                         (3.92, true, 181.0, 30, 1), (4.92, true, 172.6, 28, 0), (6.3, false, 198.1, 36, 3)]
        for (ago, automatic, gb, count, skipped) in runs {
            let run = UUID().uuidString, date = now.addingTimeInterval(-ago * 86400)
            for index in 0..<count {
                let skip = index < skipped
                history.append(HistoryEntry(id: UUID().uuidString, date: date.addingTimeInterval(Double(index)), path: trees + "/t3code/t3-\(1000 + index)/node_modules",
                                            outcome: skip ? "Skipped" : "Cleaned", detail: skip ? "In use by node (pid \(40_000 + index))." : "Dependencies removed.",
                                            bytes: skip ? 0 : Int64(gb * 1e9) / Int64(count - skipped), run: run, automatic: automatic))
            }
        }
        model.history = history
    }

    /// Plays a cleanup without deleting anything. One folder becomes active mid-run and is skipped.
    static func simulateSweep(_ model: AppModel) {
        model.sweepTask = Task { @MainActor in
            guard let candidates = model.sweep?.candidates else { return }
            for (index, candidate) in candidates.enumerated() {
                try? await Task.sleep(for: .milliseconds(650))
                if Task.isCancelled { break }
                let skip = index == 3
                model.record(HistoryEntry(id: UUID().uuidString, date: Date(), path: candidate.path, outcome: skip ? "Skipped" : "Cleaned",
                                          detail: skip ? "In use by Cursor (pid 2214)." : "Demo: nothing was deleted.",
                                          bytes: skip ? 0 : candidate.bytes, run: "demo", automatic: false))
            }
            model.finishSweep()
        }
    }
}
