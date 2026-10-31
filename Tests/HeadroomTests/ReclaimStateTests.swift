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
}
