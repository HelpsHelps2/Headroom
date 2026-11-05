import XCTest
import HeadroomCore
@testable import Headroom

final class ReclaimStateTests: XCTestCase {
    @MainActor
    func testCleanedOutputDisappearsBeforeRescanAndDuplicateCallbacksAreHarmless() {
        let model = AppModel(demo: true)
        let candidates = Array(model.eligible.prefix(2))
        let before = model.reclaimable
        let available = model.inventory.available
        model.sweep = SweepState(candidates: candidates)
        let cleaned = HistoryEntry(id: "cleaned", date: Date(), path: candidates[0].path,
                                   outcome: "Cleaned", detail: "", bytes: candidates[0].bytes, run: "test", automatic: false)
        let skipped = HistoryEntry(id: "skipped", date: Date(), path: candidates[1].path,
                                   outcome: "Skipped", detail: "In use", bytes: 0, run: "test", automatic: false)
        model.record(cleaned)
        model.record(cleaned)
        model.record(skipped)
        XCTAssertEqual(model.reclaimable, before - cleaned.bytes)
        XCTAssertTrue(model.eligible.contains { $0.path == skipped.path })
        XCTAssertEqual(model.sweep?.freed, cleaned.bytes)
        model.finishSweep()
        XCTAssertEqual(model.sweep?.succeeded, true)
        model.closeSweep()
        XCTAssertEqual(model.screen, .main)
        XCTAssertEqual(model.reclaimable, before - cleaned.bytes)
        XCTAssertEqual(model.inventory.available, available + cleaned.bytes)
        model.record(cleaned) // A queued callback after dismissal must not change anything.
        XCTAssertNil(model.sweep)
        XCTAssertEqual(model.inventory.available, available + cleaned.bytes)
    }

    func testStoppedFailedAndEmptyRunsAreNotSuccesses() {
        var sweep = SweepState(candidates: [])
        sweep.finished = true
        XCTAssertFalse(sweep.succeeded)
        sweep.entries["test"] = HistoryEntry(id: "test", date: Date(), path: "test", outcome: "Cleaned",
                                            detail: "", bytes: 100, run: "test", automatic: false)
        XCTAssertTrue(sweep.succeeded)
        sweep.stopping = true
        XCTAssertFalse(sweep.succeeded)
        sweep.stopping = false
        sweep.failed = true
        XCTAssertFalse(sweep.succeeded)
    }

    @MainActor
    func testReadyWorktreesStartCheckedAndOthersDoNot() {
        let model = AppModel(demo: true)
        XCTAssertFalse(model.readyWorktrees.isEmpty)
        XCTAssertTrue(model.readyWorktrees.allSatisfy(model.isChosen))
        XCTAssertFalse(model.lookWorktrees.contains(where: model.isChosen))
        XCTAssertFalse(model.keptWorktrees.contains(where: model.isChosen))
        let kept = model.keptWorktrees[0], look = model.lookWorktrees[0], ready = model.readyWorktrees[0]
        model.toggleChosen(kept)
        XCTAssertFalse(model.isChosen(kept), "Kept worktrees can't be chosen")
        model.toggleChosen(look)
        XCTAssertTrue(model.isChosen(look))
        model.toggleChosen(ready)
        XCTAssertFalse(model.isChosen(ready))
    }

    @MainActor
    func testCleanNowCannotReplaceTheRemovalScreen() {
        let model = AppModel(demo: true)
        model.removal = WorktreeRemovalState(candidates: [model.readyWorktrees[0]])
        model.screen = .worktreeRemoval
        XCTAssertTrue(model.busy)
        model.cleanNow()
        XCTAssertEqual(model.screen, .worktreeRemoval)
    }

    @MainActor
    func testWorktreeRemovalDropsOnlyWhatWasRemoved() {
        let model = AppModel(demo: true)
        let removed = model.readyWorktrees[0], skipped = model.readyWorktrees[1]
        model.removal = WorktreeRemovalState(candidates: [removed, skipped])
        model.recordRemoval(HistoryEntry(id: "a", date: Date(), path: removed.top, outcome: "Cleaned", detail: "", bytes: removed.bytes, run: "test", automatic: false))
        model.recordRemoval(HistoryEntry(id: "b", date: Date(), path: skipped.top, outcome: "Skipped", detail: "2 uncommitted changes", bytes: 0, run: "test", automatic: false))
        XCTAssertFalse(model.worktrees.contains { $0.top == removed.top })
        XCTAssertTrue(model.worktrees.contains { $0.top == skipped.top })
        XCTAssertEqual(model.removal?.freed, removed.bytes)
    }

    func testGlanceDropsDecimalsUntilEveryGigabyteCounts() {
        XCTAssertEqual(Format.glance(173_707_198_464), "174 GB")
        XCTAssertEqual(Format.glance(10_000_000_000), "10 GB")
        XCTAssertEqual(Format.glance(7_400_000_000), "7.4 GB")
        XCTAssertEqual(Format.glance(850_000_000), "850 MB")
        XCTAssertEqual(Format.glance(1_200_000_000_000), "1.20 TB")
    }

    @MainActor
    func testWindowAndMenuBarUseTheSameBands() {
        let model = AppModel(demo: true)
        model.inventory.capacity = 994_000_000_000
        model.inventory.available = 174_000_000_000
        model.preferences.lowSpaceGB = 50
        XCTAssertEqual(model.statusText, "Plenty of room", "83% full, but 174 GB is not pressure")
        XCTAssertTrue(model.calm)
        model.inventory.available = 60_000_000_000
        XCTAssertEqual(model.statusText, "Disk filling up")
        XCTAssertFalse(model.calm)
        model.inventory.available = 40_000_000_000
        XCTAssertEqual(model.statusText, "Disk pressure high")
    }

    func testLowSpaceMessageSaysWhetherAnythingCanBeCleaned() {
        XCTAssertEqual(AppModel.lowSpaceMessage(free: 38_000_000_000, cleanable: 64_000_000_000), "38.0 GB free. 64.0 GB of build output can be cleaned.")
        XCTAssertEqual(AppModel.lowSpaceMessage(free: 38_000_000_000, cleanable: 0), "38.0 GB free. Headroom has no build output ready to clean.")
    }
}
