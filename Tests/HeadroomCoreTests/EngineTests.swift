import XCTest
import Darwin
@testable import HeadroomCore

final class Fixture {
    let base: URL, project: URL, target: URL, home: URL, state: URL
    init() throws {
        base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("headroom-tests-" + UUID().uuidString)
        project = base.appendingPathComponent("projects/example")
        target = project.appendingPathComponent("target")
        home = base.appendingPathComponent("home")
        state = base.appendingPathComponent("state")
        for dir in [project, home, target.appendingPathComponent("debug/.fingerprint"), target.appendingPathComponent("debug/deps")] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try Data("[package]\nname=\"example\"\nversion=\"0.1.0\"\n".utf8).write(to: project.appendingPathComponent("Cargo.toml"))
        try Data("{\"rustc_fingerprint\":1}".utf8).write(to: target.appendingPathComponent(".rustc_info.json"))
        try Data(repeating: 1, count: 8192).write(to: target.appendingPathComponent("debug/deps/libexample.rlib"))
        try Data().write(to: target.appendingPathComponent("debug/.cargo-lock"))
        let git = try Command.git(project.path, ["init", "-q"])
        guard git.status == 0 else { throw HeadroomError.message(git.error) }
        try age()
    }
    deinit { try? FileManager.default.removeItem(at: base) }
    func age() throws {
        let old = Date().addingTimeInterval(-86400 * 10)
        if let enumerator = FileManager.default.enumerator(at: target, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator { try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path) }
        }
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: target.path)
    }
    func engine(activity: ActivitySnapshot = .init(paths: []), clock: @escaping @Sendable () -> Date = { Date() }) throws -> Engine {
        try Engine(directory: state, home: home.path, activity: { activity }, clock: clock)
    }
    func preferences() -> Preferences {
        var p = Preferences(); p.roots = [.init(path: project.deletingLastPathComponent().path)]; return p
    }
}

final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date()
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ interval: TimeInterval) { lock.lock(); value = value.addingTimeInterval(interval); lock.unlock() }
}

final class EngineTests: XCTestCase {
    func testReviewedCleanupPreservesSourceAndSharedCache() async throws {
        let f = try Fixture(), engine = try f.engine()
        let cache = f.home.appendingPathComponent("Library/Caches/Mozilla.sccache/cache-entry")
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: cache)
        try await engine.save(f.preferences())
        let inventory = try await engine.scan()
        XCTAssertEqual(inventory.artifacts.count, 1)
        XCTAssertTrue(inventory.artifacts[0].eligible, inventory.artifacts[0].reasons.joined())
        let plan = try await engine.plan(paths: [f.target.path])
        let result = try await engine.execute(plan)
        XCTAssertEqual(result.first?.outcome, "Cleaned", result.first?.detail ?? "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.target.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.project.appendingPathComponent("Cargo.toml").path))
        XCTAssertEqual(try String(contentsOf: cache, encoding: .utf8), "keep")
    }
    func testProcessUsingProjectProtectsIt() async throws {
        let f = try Fixture(), engine = try f.engine(activity: .init(paths: []))
        try await engine.save(f.preferences())
        let scanner = Scanner(home: f.home.path)
        let result = scanner.scan(preferences: f.preferences(), activity: .init(paths: [f.project.path]))
        XCTAssertFalse(try XCTUnwrap(result.artifacts.first).eligible)
    }
    func testIncompleteActivityNeverMeansInactive() throws {
        let f = try Fixture()
        let result = Scanner(home: f.home.path).scan(preferences: f.preferences(), activity: .init(paths: [], failure: "Permission denied"))
        XCTAssertTrue(try XCTUnwrap(result.artifacts.first).reasons.contains("Permission denied"))
    }
    func testPinnedProjectProtected() throws {
        let f = try Fixture(); var p = f.preferences(); p.pinned.insert(f.project.path)
        let result = Scanner(home: f.home.path).scan(preferences: p, activity: .init(paths: []))
        XCTAssertTrue(try XCTUnwrap(result.artifacts.first).reasons.contains("Pinned by you."))
    }
    func testHeldCargoLockProtectedButLeftoverFileIsNot() throws {
        let f = try Fixture()
        let fd = open(f.target.appendingPathComponent("debug/.cargo-lock").path, O_RDWR)
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        let held = Scanner(home: f.home.path).scan(preferences: f.preferences(), activity: .init(paths: []))
        XCTAssertTrue(try XCTUnwrap(held.artifacts.first).reasons.contains("Cargo holds a build lock."))
        flock(fd, LOCK_UN)
        let idle = Scanner(home: f.home.path).scan(preferences: f.preferences(), activity: .init(paths: []))
        XCTAssertTrue(try XCTUnwrap(idle.artifacts.first).eligible)
    }
    func testTrackedOutputProtected() throws {
        let f = try Fixture()
        _ = try Command.git(f.project.path, ["add", "target"])
        let result = Scanner(home: f.home.path).scan(preferences: f.preferences(), activity: .init(paths: []))
        XCTAssertTrue(try XCTUnwrap(result.artifacts.first).reasons.contains(where: { $0.contains("tracked files") }))
    }
    func testSymlinkInsideOutputPreservesDestination() throws {
        let f = try Fixture()
        let keep = f.base.appendingPathComponent("keep.txt")
        try Data("unique".utf8).write(to: keep)
        try FileManager.default.createSymbolicLink(atPath: f.target.appendingPathComponent("debug/deps/link").path, withDestinationPath: keep.path)
        let result = Scanner(home: f.home.path).scan(preferences: f.preferences(), activity: .init(paths: []))
        XCTAssertFalse(try XCTUnwrap(result.artifacts.first).eligible)
        XCTAssertEqual(try String(contentsOf: keep, encoding: .utf8), "unique")
    }
    func testConfigurationOverrideProtected() throws {
        let f = try Fixture()
        let config = f.project.appendingPathComponent(".cargo/config.toml")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("[build]\ntarget-dir=\"/shared/target\"".utf8).write(to: config)
        let result = Scanner(home: f.home.path).scan(preferences: f.preferences(), activity: .init(paths: []))
        XCTAssertTrue(try XCTUnwrap(result.artifacts.first).reasons.contains(where: { $0.contains("configuration needs review") }))
    }
    func testUnexpectedContentProtected() throws {
        let f = try Fixture()
        try Data("notes".utf8).write(to: f.target.appendingPathComponent("notes.md"))
        try f.age()
        let result = Scanner(home: f.home.path).scan(preferences: f.preferences(), activity: .init(paths: []))
        XCTAssertFalse(try XCTUnwrap(result.artifacts.first).eligible)
    }
    func testOutputChangedAfterReviewIsSkipped() async throws {
        let f = try Fixture(), engine = try f.engine()
        try await engine.save(f.preferences()); _ = try await engine.scan()
        let plan = try await engine.plan(paths: [f.target.path])
        try Data("new build".utf8).write(to: f.target.appendingPathComponent("debug/deps/new.rlib"))
        let result = try await engine.execute(plan)
        XCTAssertEqual(result.first?.outcome, "Skipped")
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.target.path))
    }
    func testRecentOutputNeedsAnExplicitSkip() async throws {
        let f = try Fixture(), engine = try f.engine()
        try Data("fresh".utf8).write(to: f.target.appendingPathComponent("debug/deps/fresh.rlib"))
        try await engine.save(f.preferences())
        let scanned = try await engine.scan().artifacts.first
        let artifact = try XCTUnwrap(scanned)
        XCTAssertFalse(artifact.eligible)
        XCTAssertTrue(artifact.waiting, artifact.reasons.joined())
        do { _ = try await engine.plan(paths: [f.target.path]); XCTFail("Recent output stays without a skip") } catch {}
        do { _ = try await engine.plan(paths: [f.target.path], skippingWait: [f.target.path], automatic: true); XCTFail("Automatic cleanup never skips the wait") } catch {}
        let plan = try await engine.plan(paths: [f.target.path], skippingWait: [f.target.path])
        let result = try await engine.execute(plan)
        XCTAssertEqual(result.first?.outcome, "Cleaned", result.first?.detail ?? "")
        XCTAssertTrue(result.first?.detail.contains("before the keep window") ?? false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.target.path))
    }
    func testSkippingTheWaitNeverOverridesActivity() async throws {
        let f = try Fixture(), engine = try f.engine(activity: .init(paths: [f.project.path]))
        try Data("fresh".utf8).write(to: f.target.appendingPathComponent("debug/deps/fresh.rlib"))
        try await engine.save(f.preferences())
        let scanned = try await engine.scan().artifacts.first
        let artifact = try XCTUnwrap(scanned)
        XCTAssertFalse(artifact.waiting, "In-use output is not merely waiting")
        do { _ = try await engine.plan(paths: [f.target.path], skippingWait: [f.target.path]); XCTFail("In-use output stays") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.target.path))
    }
    func testWritesAfterReviewStopASkippedWait() async throws {
        let f = try Fixture(), engine = try f.engine()
        try Data("fresh".utf8).write(to: f.target.appendingPathComponent("debug/deps/fresh.rlib"))
        try await engine.save(f.preferences()); _ = try await engine.scan()
        let plan = try await engine.plan(paths: [f.target.path], skippingWait: [f.target.path])
        try Data("still building".utf8).write(to: f.target.appendingPathComponent("debug/deps/next.rlib"))
        let result = try await engine.execute(plan)
        XCTAssertEqual(result.first?.outcome, "Skipped")
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.target.path))
    }
    func testPolicyChangesInvalidatePlan() async throws {
        let f = try Fixture(), engine = try f.engine()
        var p = f.preferences(); try await engine.save(p); _ = try await engine.scan()
        let plan = try await engine.plan(paths: [f.target.path])
        p.pinned.insert(f.project.path); try await engine.save(p)
        do { _ = try await engine.execute(plan); XCTFail("Changed protections must invalidate a plan") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.target.path))
    }
    func testNewObservationCannotBeAutomaticallyCleaned() async throws {
        let f = try Fixture(), engine = try f.engine()
        var p = f.preferences(); p.scheduled = true; p.roots[0].automatic = true
        try await engine.save(p); _ = try await engine.scan()
        do { _ = try await engine.plan(paths: [f.target.path], automatic: true); XCTFail("New observations need a keep window") } catch {}
    }
    func testObservationGapRestartsAutomaticKeepWindow() async throws {
        let f = try Fixture(), clock = Clock(), engine = try f.engine(clock: { clock.now() })
        var p = f.preferences(); p.keepHours = 1; p.scheduled = true; p.roots[0].automatic = true
        try await engine.save(p)
        for _ in 0..<14 { _ = try await engine.scan(); clock.advance(300) }
        _ = try await engine.scan()
        _ = try await engine.plan(paths: [f.target.path], automatic: true)
        clock.advance(601); _ = try await engine.scan()
        do { _ = try await engine.plan(paths: [f.target.path], automatic: true); XCTFail("A gap must reset observation") } catch {}
    }
    func testKeepWindowAndObservationRunTogether() async throws {
        let f = try Fixture(), clock = Clock(), engine = try f.engine(clock: { clock.now() })
        var p = f.preferences(); p.keepHours = 1; p.scheduled = true; p.roots[0].automatic = true
        try await engine.save(p)
        // Freshly built: protected by the keep window, but the observation clock starts now.
        if let enumerator = FileManager.default.enumerator(at: f.target, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator { try FileManager.default.setAttributes([.modificationDate: clock.now()], ofItemAtPath: url.path) }
        }
        try FileManager.default.setAttributes([.modificationDate: clock.now()], ofItemAtPath: f.target.path)
        let first = try await engine.scan()
        XCTAssertTrue(try XCTUnwrap(first.artifacts.first).waiting)
        for _ in 0..<12 { clock.advance(300); _ = try await engine.scan() }
        clock.advance(1); _ = try await engine.scan()
        _ = try await engine.plan(paths: [f.target.path], automatic: true)
    }
    func testRecordedSleepKeepsObservationContinuous() async throws {
        let f = try Fixture(), clock = Clock(), engine = try f.engine(clock: { clock.now() })
        var p = f.preferences(); p.keepHours = 1; p.scheduled = true; p.roots[0].automatic = true
        try await engine.save(p)
        _ = try await engine.scan()
        clock.advance(120)
        let asleep = clock.now(); clock.advance(8 * 3600)
        await engine.recordSleep(DateInterval(start: asleep, end: clock.now()))
        clock.advance(60); _ = try await engine.scan()
        _ = try await engine.plan(paths: [f.target.path], automatic: true)
    }
    func testContinuityAllowsOnlyShortAwakeGaps() {
        let t = Date()
        XCTAssertTrue(Engine.continuous(seen: t, now: t.addingTimeInterval(600), sleeps: []))
        XCTAssertFalse(Engine.continuous(seen: t, now: t.addingTimeInterval(601), sleeps: []))
        let night = DateInterval(start: t.addingTimeInterval(300), end: t.addingTimeInterval(30_000))
        XCTAssertTrue(Engine.continuous(seen: t, now: t.addingTimeInterval(30_300), sleeps: [night]))
        // Awake and unwatched too long before or after the sleep.
        XCTAssertFalse(Engine.continuous(seen: t.addingTimeInterval(-400), now: t.addingTimeInterval(30_300), sleeps: [night]))
        XCTAssertFalse(Engine.continuous(seen: t, now: t.addingTimeInterval(30_700), sleeps: [night]))
        XCTAssertFalse(Engine.continuous(seen: t, now: t.addingTimeInterval(-1), sleeps: []))
    }
    func testScheduledCheckWithNothingReadyKeepsTheIntervalOpen() async throws {
        let f = try Fixture(), clock = Clock(), engine = try f.engine(clock: { clock.now() })
        var p = f.preferences(); p.keepHours = 2; p.intervalHours = 1; p.scheduled = true; p.roots[0].automatic = true
        try await engine.save(p)
        _ = try await engine.scan()
        _ = try await engine.runScheduleIfDue()
        var cleaned: [HistoryEntry] = []
        // Due after 1 h, but the output qualifies only after 2 h; it is cleaned at the first check after that.
        for _ in 0..<25 {
            clock.advance(300)
            _ = try await engine.scan()
            cleaned += try await engine.runScheduleIfDue()
            if !cleaned.isEmpty { break }
        }
        XCTAssertEqual(cleaned.filter { $0.outcome == "Cleaned" }.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.target.path))
    }
    func testSymlinkReplacementAfterReviewIsSkipped() async throws {
        let f = try Fixture(), engine = try f.engine()
        try await engine.save(f.preferences()); _ = try await engine.scan()
        let plan = try await engine.plan(paths: [f.target.path])
        let moved = f.base.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: f.target, to: moved)
        try FileManager.default.createSymbolicLink(atPath: f.target.path, withDestinationPath: moved.path)
        let entries = try await engine.execute(plan)
        XCTAssertEqual(entries.first?.outcome, "Skipped")
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.appendingPathComponent("debug/deps/libexample.rlib").path))
    }
    func testOverlappingRootsDoNotDuplicateArtifacts() throws {
        let f = try Fixture(); var p = f.preferences(); p.roots.append(.init(path: f.project.path))
        let result = Scanner(home: f.home.path).scan(preferences: p, activity: .init(paths: []))
        XCTAssertEqual(result.artifacts.count, 1)
    }
    func testProcessLeaseExcludesSecondWorker() throws {
        let f = try Fixture()
        let path = f.base.appendingPathComponent("operation.lock").path
        let first = try ProcessLease(path: path)
        XCTAssertThrowsError(try ProcessLease(path: path))
        withExtendedLifetime(first) {}
    }
    func testScheduledCleanupUsesObservationAndNormalExecutor() async throws {
        let f = try Fixture(), clock = Clock(), engine = try f.engine(clock: { clock.now() })
        var p = f.preferences(); p.keepHours = 1; p.intervalHours = 1; p.scheduled = true; p.roots[0].automatic = true
        try await engine.save(p)
        _ = try await engine.scan()
        let first = try await engine.runScheduleIfDue()
        XCTAssertTrue(first.isEmpty)
        var cleaned: [HistoryEntry] = []
        for _ in 0..<13 {
            clock.advance(300)
            _ = try await engine.scan()
            cleaned += try await engine.runScheduleIfDue()
        }
        XCTAssertEqual(cleaned.filter { $0.outcome == "Cleaned" }.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.target.path))
    }
    func testLockedLinkedWorktreeProtected() throws {
        let f = try Fixture()
        let commit = try Command.git(f.project.path, ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-m", "fixture"])
        XCTAssertEqual(commit.status, 0, commit.error)
        let linked = f.base.appendingPathComponent("projects/linked")
        let added = try Command.git(f.project.path, ["worktree", "add", "--detach", linked.path])
        XCTAssertEqual(added.status, 0, added.error)
        try FileManager.default.copyItem(at: f.project.appendingPathComponent("Cargo.toml"), to: linked.appendingPathComponent("Cargo.toml"))
        try FileManager.default.copyItem(at: f.target, to: linked.appendingPathComponent("target"))
        _ = try Command.git(f.project.path, ["worktree", "lock", linked.path])
        let inventory = Scanner(home: f.home.path).scan(preferences: f.preferences(), activity: .init(paths: []))
        let item = try XCTUnwrap(inventory.artifacts.first { $0.project == linked.path })
        XCTAssertTrue(item.reasons.contains("Git worktree is locked."), item.reasons.joined())
    }
    func testLiveProcessWorkingDirectoryIsObserved() throws {
        let f = try Fixture()
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]; process.currentDirectoryURL = f.project
        try process.run()
        defer { process.terminate(); process.waitUntilExit() }
        let snapshot = ActivitySnapshot.capture()
        XCTAssertNil(snapshot.failure, snapshot.failure ?? "")
        XCTAssertNotNil(snapshot.protection(for: f.project.path, target: f.target.path))
    }
}

final class LowSpaceTests: XCTestCase {
    /// A level above any real disk, so the fixture's volume always counts as low. The interval is long enough never to pass.
    private func lowPreferences(_ f: Fixture) -> Preferences {
        var p = f.preferences()
        p.keepHours = 1; p.intervalHours = 720; p.scheduled = true; p.roots[0].automatic = true
        p.lowSpaceGB = 100_000; p.cleansWhenLow = true
        return p
    }
    /// Scans and runs the schedule every five minutes, as the app does.
    private func run(_ engine: Engine, _ clock: Clock, minutes: Int) async throws -> [HistoryEntry] {
        var entries: [HistoryEntry] = []
        for _ in 0..<(minutes / 5) {
            clock.advance(300)
            _ = try await engine.scan()
            entries += try await engine.runScheduleIfDue()
        }
        return entries
    }
    func testLowSpaceCleansBeforeTheIntervalButAfterTheWait() async throws {
        let f = try Fixture(), clock = Clock(), engine = try f.engine(clock: { clock.now() })
        try await engine.save(lowPreferences(f))
        _ = try await engine.scan()
        _ = try await engine.runScheduleIfDue()
        let waiting = try await run(engine, clock, minutes: 55)
        XCTAssertTrue(waiting.isEmpty, "the wait still applies")
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.target.path))
        let cleaned = try await run(engine, clock, minutes: 10)
        XCTAssertEqual(cleaned.filter { $0.outcome == "Cleaned" }.count, 1)
        XCTAssertTrue(cleaned.allSatisfy(\.automatic))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.target.path))
    }
    func testFirstCheckAfterTurningOnDeletesNothingEvenWhenLow() async throws {
        let f = try Fixture(), clock = Clock(), engine = try f.engine(clock: { clock.now() })
        try await engine.save(lowPreferences(f))
        // The output has been watched for longer than the wait before the schedule's first check.
        for _ in 0..<14 { clock.advance(300); _ = try await engine.scan() }
        let first = try await engine.runScheduleIfDue()
        XCTAssertTrue(first.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.target.path))
        let later = try await run(engine, clock, minutes: 5)
        XCTAssertEqual(later.filter { $0.outcome == "Cleaned" }.count, 1)
    }
    func testLowSpaceNeedsTheOptIn() async throws {
        let f = try Fixture(), clock = Clock(), engine = try f.engine(clock: { clock.now() })
        var p = lowPreferences(f); p.cleansWhenLow = false
        try await engine.save(p)
        _ = try await engine.scan(); _ = try await engine.runScheduleIfDue()
        let entries = try await run(engine, clock, minutes: 90)
        XCTAssertTrue(entries.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.target.path))
    }
    func testLowSpaceKeepsFoldersNotSetToAutomatic() async throws {
        let f = try Fixture(), clock = Clock(), engine = try f.engine(clock: { clock.now() })
        var p = lowPreferences(f); p.roots[0].automatic = false
        try await engine.save(p)
        _ = try await engine.scan(); _ = try await engine.runScheduleIfDue()
        let entries = try await run(engine, clock, minutes: 90)
        XCTAssertTrue(entries.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.target.path))
    }
    func testLowSpaceRespectsPauseAndSchedule() async throws {
        for change in [{ (p: inout Preferences) in p.paused = true }, { (p: inout Preferences) in p.scheduled = false }] {
            let f = try Fixture(), clock = Clock(), engine = try f.engine(clock: { clock.now() })
            var p = lowPreferences(f); change(&p)
            try await engine.save(p)
            _ = try await engine.scan(); _ = try await engine.runScheduleIfDue()
            let entries = try await run(engine, clock, minutes: 90)
            XCTAssertTrue(entries.isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.target.path))
        }
    }
    func testLowSpaceNeverOverridesLiveActivity() async throws {
        let f = try Fixture(), clock = Clock()
        let engine = try f.engine(activity: .init(paths: [f.project.path]), clock: { clock.now() })
        try await engine.save(lowPreferences(f))
        _ = try await engine.scan(); _ = try await engine.runScheduleIfDue()
        let entries = try await run(engine, clock, minutes: 90)
        XCTAssertTrue(entries.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.target.path))
    }
    func testLowSpaceRunThatRemovesNothingWaitsBeforeRetrying() async throws {
        let f = try Fixture(), clock = Clock(), engine = try f.engine(clock: { clock.now() })
        try await engine.save(lowPreferences(f))
        _ = try await engine.scan(); _ = try await engine.runScheduleIfDue()
        _ = try await run(engine, clock, minutes: 55)
        clock.advance(300)
        _ = try await engine.scan()
        // Changes after the scan make the executor skip the folder, the same way it would for a build that just started.
        try Data(repeating: 2, count: 4096).write(to: f.target.appendingPathComponent("debug/deps/new.rlib"))
        let first = try await engine.runScheduleIfDue()
        XCTAssertEqual(first.map(\.outcome), ["Skipped"])
        let second = try await engine.runScheduleIfDue()
        XCTAssertTrue(second.isEmpty, "backs off instead of repeating the skip")
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.target.path))
    }
    func testSelectionTakesTheLargestUntilTheTarget() {
        var p = Preferences(); p.lowSpaceGB = 50
        func artifact(_ name: String, _ gb: Int64) -> Artifact {
            .init(project: "/p/" + name, path: "/p/\(name)/target", root: "/p", bytes: gb * 1_000_000_000, files: 1, latestWrite: .distantPast,
                  identity: .init(device: 1, inode: 1), reasons: [], firstObserved: .distantPast)
        }
        let eligible = [artifact("small", 5), artifact("large", 40), artifact("medium", 20)]
        let names = { (available: Int64) in
            LowSpace.selection(from: eligible, space: .init(capacity: 1_000_000_000_000, available: available * 1_000_000_000), preferences: p).map(\.name)
        }
        XCTAssertEqual(names(45), ["large", "medium"], "stops once 100 GB is reached")
        XCTAssertEqual(names(70), ["large"])
        XCTAssertEqual(names(0), ["large", "medium", "small"], "takes everything when even that falls short")
        XCTAssertEqual(names(100), [])
    }
    func testAFailedReadingIsNeverLow() {
        var p = Preferences(); p.lowSpaceGB = 50
        XCTAssertFalse(LowSpace.isLow(.init(capacity: 0, available: 0), p))
        XCTAssertTrue(LowSpace.isLow(.init(capacity: 1_000_000_000_000, available: 49_000_000_000), p))
        XCTAssertFalse(LowSpace.isLow(.init(capacity: 1_000_000_000_000, available: 50_000_000_000), p))
        p.lowSpaceGB = 0
        XCTAssertFalse(LowSpace.isLow(.init(capacity: 1_000_000_000_000, available: 0), p))
    }
    func testAlertsOnceThenOnlyWhenWorseOrADayLater() {
        var alerts = LowSpaceAlerts(), p = Preferences(); p.lowSpaceGB = 50
        let start = Date(), gb: Int64 = 1_000_000_000
        func notify(_ free: Int64, after hours: Double = 0) -> Bool {
            let space = DiskSpace(capacity: 1000 * gb, available: free * gb), now = start.addingTimeInterval(hours * 3600)
            guard alerts.shouldNotify(space, preferences: p, now: now) else { return false }
            alerts.notified(space, now: now)
            return true
        }
        XCTAssertFalse(notify(60), "above the line")
        XCTAssertTrue(notify(40), "first time under")
        XCTAssertFalse(notify(30, after: 1), "still low, not much worse")
        XCTAssertTrue(notify(15, after: 2), "free space halved")
        XCTAssertTrue(notify(15, after: 27), "a day later")
        XCTAssertFalse(notify(70, after: 28), "recovering")
        XCTAssertFalse(notify(40, after: 29), "not recovered past the target, so the same episode")
        XCTAssertFalse(notify(100, after: 30), "recovered")
        XCTAssertTrue(notify(40, after: 31), "a new episode")
        XCTAssertFalse(alerts.shouldNotify(.init(capacity: 0, available: 0), preferences: p, now: start.addingTimeInterval(32 * 3600)), "failed reading")
    }
    func testAnUndeliveredAlertIsTriedAgain() {
        var alerts = LowSpaceAlerts(), p = Preferences(); p.lowSpaceGB = 50
        let space = DiskSpace(capacity: 1_000_000_000_000, available: 40_000_000_000), now = Date()
        XCTAssertTrue(alerts.shouldNotify(space, preferences: p, now: now))
        XCTAssertTrue(alerts.shouldNotify(space, preferences: p, now: now.addingTimeInterval(60)), "not delivered yet")
        alerts.notified(space, now: now.addingTimeInterval(60))
        XCTAssertFalse(alerts.shouldNotify(space, preferences: p, now: now.addingTimeInterval(120)))
    }
    func testSettingsFromBeforeLowSpaceStillLoad() throws {
        let old = #"{"roots":[{"path":"/p","automatic":true}],"pinned":[],"keepHours":6,"scheduled":true,"intervalHours":6,"paused":false}"#
        let p = try JSONDecoder().decode(Preferences.self, from: Data(old.utf8))
        XCTAssertEqual(p.keepHours, 6)
        XCTAssertEqual(p.roots.first?.automatic, true)
        XCTAssertEqual(p.lowSpaceGB, 50)
        XCTAssertFalse(p.cleansWhenLow, "cleaning sooner is never turned on by an update")
        let again = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(again, p)
    }
    func testAutomaticWithNoFoldersIsDetected() {
        var p = Preferences()
        XCTAssertFalse(p.automaticHasNoFolders)
        p.scheduled = true
        XCTAssertFalse(p.automaticHasNoFolders, "no folders watched yet")
        p.roots = [.init(path: "/a"), .init(path: "/b")]
        XCTAssertTrue(p.automaticHasNoFolders)
        p.roots[1].automatic = true
        XCTAssertFalse(p.automaticHasNoFolders)
        p.scheduled = false; p.roots[1].automatic = false
        XCTAssertFalse(p.automaticHasNoFolders)
    }
}

/// An npm project with workspace and `.bin` links and a file hard-linked from a package store.
final class NodeFixture {
    let base: URL, project: URL, modules: URL, home: URL, state: URL, source: URL, store: URL
    init(ignored: Bool = true, lockfile: Bool = true) throws {
        let fm = FileManager.default
        base = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("headroom-node-" + UUID().uuidString)
        project = base.appendingPathComponent("projects/web")
        modules = project.appendingPathComponent("node_modules")
        home = base.appendingPathComponent("home"); state = base.appendingPathComponent("state")
        source = project.appendingPathComponent("packages/shared")
        store = base.appendingPathComponent("store/blob.js")
        for dir in [home, source, modules.appendingPathComponent("left-pad"), modules.appendingPathComponent(".bin"), store.deletingLastPathComponent()] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try Data("{\"name\":\"web\"}".utf8).write(to: project.appendingPathComponent("package.json"))
        if lockfile { try Data("{}".utf8).write(to: project.appendingPathComponent("package-lock.json")) }
        if ignored { try Data("node_modules/\n".utf8).write(to: project.appendingPathComponent(".gitignore")) }
        try Data("export const shared = 1".utf8).write(to: source.appendingPathComponent("index.js"))
        try Data("{}".utf8).write(to: modules.appendingPathComponent(".package-lock.json"))
        try Data("{\"name\":\"left-pad\"}".utf8).write(to: modules.appendingPathComponent("left-pad/package.json"))
        try Data(repeating: 1, count: 8192).write(to: modules.appendingPathComponent("left-pad/index.js"))
        try Data(repeating: 2, count: 1_048_576).write(to: store)
        XCTAssertEqual(link(store.path, modules.appendingPathComponent("left-pad/store.js").path), 0)
        try fm.createSymbolicLink(atPath: modules.appendingPathComponent(".bin/left-pad").path, withDestinationPath: "../left-pad/index.js")
        try fm.createSymbolicLink(atPath: modules.appendingPathComponent("shared").path, withDestinationPath: source.path)
        let git = try Command.git(project.path, ["init", "-q"])
        guard git.status == 0 else { throw HeadroomError.message(git.error) }
        try age(modules)
    }
    deinit { try? FileManager.default.removeItem(at: base) }
    /// Ages entries without following links, so link destinations keep their own times.
    func age(_ url: URL) throws {
        let old = Date().addingTimeInterval(-86400 * 10).timeIntervalSince1970
        var times = [timeval(tv_sec: Int(old), tv_usec: 0), timeval(tv_sec: Int(old), tv_usec: 0)]
        var paths = [url.path]
        if let enumerator = FileManager.default.enumerator(atPath: url.path) {
            for case let relative as String in enumerator { paths.append(url.path + "/" + relative) }
        }
        for path in paths { XCTAssertEqual(lutimes(path, &times), 0) }
    }
    func engine() throws -> Engine { try Engine(directory: state, home: home.path, activity: { .init(paths: []) }) }
    func preferences() -> Preferences { var p = Preferences(); p.roots = [.init(path: project.deletingLastPathComponent().path)]; return p }
    func scan(_ preferences: Preferences? = nil) throws -> Artifact {
        let inventory = Scanner(home: home.path).scan(preferences: preferences ?? self.preferences(), activity: .init(paths: []))
        return try XCTUnwrap(inventory.artifacts.first { $0.kind == .node })
    }
}

final class NodeAdapterTests: XCTestCase {
    func testCleanupRemovesLinksWithoutTouchingDestinations() async throws {
        let f = try NodeFixture(), engine = try f.engine()
        try await engine.save(f.preferences())
        let inventory = try await engine.scan()
        let item = try XCTUnwrap(inventory.artifacts.first { $0.kind == .node })
        XCTAssertTrue(item.eligible, item.reasons.joined(separator: " "))
        XCTAssertEqual(item.relativePath, "node_modules")
        XCTAssertLessThan(item.bytes, 1_000_000, "Hard-linked store files must not count as reclaimable")
        let entries = try await engine.execute(try await engine.plan(paths: [item.path]))
        XCTAssertEqual(entries.first?.outcome, "Cleaned", entries.first?.detail ?? "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.modules.path))
        XCTAssertEqual(try String(contentsOf: f.source.appendingPathComponent("index.js"), encoding: .utf8), "export const shared = 1")
        XCTAssertEqual(try Data(contentsOf: f.store).count, 1_048_576)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.project.appendingPathComponent("package.json").path))
    }
    func testNotIgnoredByGitIsProtected() throws {
        let item = try NodeFixture(ignored: false).scan()
        XCTAssertTrue(item.reasons.contains("node_modules is not ignored by Git."), item.reasons.joined())
    }
    func testMissingLockfileIsProtected() throws {
        let item = try NodeFixture(lockfile: false).scan()
        XCTAssertTrue(item.reasons.contains(where: { $0.hasPrefix("No lockfile found") }), item.reasons.joined())
    }
    func testFolderWithoutPackagesIsProtected() throws {
        let f = try NodeFixture()
        for name in try FileManager.default.contentsOfDirectory(atPath: f.modules.path) { try FileManager.default.removeItem(at: f.modules.appendingPathComponent(name)) }
        try FileManager.default.createDirectory(at: f.modules.appendingPathComponent(".vite/deps"), withIntermediateDirectories: true)
        try f.age(f.modules)
        XCTAssertTrue(try f.scan().reasons.contains("No installed packages were found in node_modules."))
    }
    func testPinningAWorktreeProtectsNestedProjects() throws {
        let f = try NodeFixture(); var p = f.preferences(); p.pinned = [f.project.path]
        XCTAssertTrue(try f.scan(p).reasons.contains("Pinned by you."))
    }
    func testActivityNamesTheProcess() throws {
        let f = try NodeFixture()
        let snapshot = ActivitySnapshot(uses: [.init(path: f.source.path, pid: 51807, command: "bun")])
        XCTAssertEqual(snapshot.protection(for: f.project.path, target: f.modules.path), "In use by bun (pid 51807).")
    }
    func testRunsAreGroupedAndSpaceIsSampled() async throws {
        let f = try NodeFixture(), engine = try f.engine()
        try await engine.save(f.preferences())
        let scanned = try await engine.scan()
        let item = try XCTUnwrap(scanned.artifacts.first)
        let plan = try await engine.plan(paths: [item.path])
        let seen = Locked<[String]>([])
        _ = try await engine.execute(plan) { entry in seen.with { $0.append(entry.outcome) } }
        XCTAssertEqual(seen.with { $0 }, ["Cleaned"])
        let history = try await engine.history()
        XCTAssertEqual(history.first?.run, plan.id.uuidString)
        let samples = try await engine.space(since: .distantPast)
        XCTAssertFalse(samples.isEmpty)
    }
    func testActivityReportsVerificationThenRemovedBytes() async throws {
        let f = try NodeFixture(), engine = try f.engine()
        try await engine.save(f.preferences())
        let scanned = try await engine.scan()
        let item = try XCTUnwrap(scanned.artifacts.first)
        let plan = try await engine.plan(paths: [item.path])
        let seen = Locked<[CleanupActivity]>([])
        _ = try await engine.execute(plan, activity: { activity in seen.with { $0.append(activity) } })
        let activities = seen.with { $0 }
        XCTAssertEqual(activities.first, .verifying(path: item.path))
        XCTAssertEqual(activities.dropFirst().first, .removing(path: item.path, bytes: 0))
        XCTAssertEqual(activities.last, .removing(path: item.path, bytes: item.bytes))
    }
    func testWorktreeInfoNamesRepositoryAndBranch() throws {
        let f = try NodeFixture()
        _ = try Command.git(f.project.path, ["checkout", "-q", "-b", "feat/handoff"])
        let info = try XCTUnwrap(try f.scan().worktree)
        XCTAssertEqual(info.repository, "web")
        XCTAssertEqual(info.branch, "feat/handoff")
        XCTAssertTrue(info.isMain)
    }
}
