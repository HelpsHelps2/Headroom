import XCTest
@testable import HeadroomCore

final class AgentContextTests: XCTestCase {
    func database(_ f: RepositoryFixture, _ name: String, _ sql: String) throws {
        let path = f.home.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let result = try Command.run("/usr/bin/sqlite3", [path.path, sql])
        XCTAssertEqual(result.status, 0, result.error)
    }
    func t3(_ f: RepositoryFixture, records: [[String: Any]], active: [String] = []) throws {
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "''") + "'" }
        var sql = "CREATE TABLE projection_projects(project_id TEXT, workspace_root TEXT); CREATE TABLE orchestration_v2_projection_threads(thread_id TEXT, project_id TEXT, payload_json TEXT, archived_at TEXT, deleted_at TEXT); CREATE TABLE orchestration_v2_projection_runs(thread_id TEXT, status TEXT);"
        for record in records {
            let json = String(decoding: try JSONSerialization.data(withJSONObject: record), as: UTF8.self)
            sql += "INSERT INTO orchestration_v2_projection_threads VALUES(\(quote(record["id"] as! String)),NULL,\(quote(json)),NULL,NULL);"
        }
        for id in active { sql += "INSERT INTO orchestration_v2_projection_runs VALUES(\(quote(id)),'running');" }
        try database(f, ".t3/userdata/statev2.sqlite", sql)
    }
    func testAbsentIntegrationsDoNotRequireAnyAgent() throws {
        let f = try RepositoryFixture(), context = AgentContextReader(home: f.home.path).capture()
        XCTAssertTrue(context.sessions.isEmpty); XCTAssertTrue(context.failures.isEmpty)
    }
    func testT3ActiveChildProtectsSettledParentAndSharedOwnersPreventCompletion() throws {
        let f = try RepositoryFixture(), tree = try f.worktree("done")
        try t3(f, records: [
            ["id": "parent", "worktreePath": tree.path, "settledOverride": "settled", "settledAt": "2026-11-16T12:00:00Z"],
            ["id": "child", "lineage": ["parentThreadId": "parent"]]
        ], active: ["child"])
        let context = AgentContextReader(home: f.home.path).capture()
        XCTAssertTrue(context.failures.isEmpty)
        XCTAssertEqual(context.protection(tree.path), "Active T3 session")
        XCTAssertFalse(context.completion(tree.path, since: .distantPast))
    }
    func testT3SettlementAndCodexArchiveMustAgreeForSharedWorktree() throws {
        let f = try RepositoryFixture(), tree = try f.worktree("done")
        try t3(f, records: [["id": "parent", "worktreePath": tree.path, "settledOverride": "settled", "settledAt": "2026-11-16T12:00:00Z"]])
        var context = AgentContextReader(home: f.home.path).capture()
        XCTAssertTrue(context.completion(tree.path, since: .distantPast))
        try database(f, ".codex/state_5.sqlite", "CREATE TABLE threads(cwd TEXT,archived INTEGER,archived_at INTEGER,id TEXT); INSERT INTO threads VALUES('\(tree.path)',0,NULL,'codex-thread');")
        context = AgentContextReader(home: f.home.path).capture()
        XCTAssertFalse(context.completion(tree.path, since: .distantPast))
        XCTAssertNil(context.protection(tree.path))
        try database(f, ".codex/state_5.sqlite", "UPDATE threads SET archived=1,archived_at=1794830400;")
        context = AgentContextReader(home: f.home.path).capture()
        XCTAssertTrue(context.completion(tree.path, since: .distantPast))
        XCTAssertFalse(context.completion(tree.path, since: .distantFuture))
    }
    func testUnsupportedInstalledSchemaIsNotInactivity() throws {
        let f = try RepositoryFixture()
        try database(f, ".codex/state_999.sqlite", "CREATE TABLE changed_schema(id TEXT);")
        let context = AgentContextReader(home: f.home.path).capture()
        XCTAssertFalse(context.failures.isEmpty)
        XCTAssertNotNil(context.protection(f.trees.path))
    }
    func testClaudeLiveSessionProtectsEvenWhenItsResponseEnded() throws {
        let f = try RepositoryFixture(), tree = try f.worktree("done")
        let directory = f.home.appendingPathComponent(".claude/sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let json: [String: Any] = ["cwd": tree.path, "pid": ProcessInfo.processInfo.processIdentifier, "status": "idle"]
        try JSONSerialization.data(withJSONObject: json).write(to: directory.appendingPathComponent("session.json"))
        let context = AgentContextReader(home: f.home.path).capture()
        XCTAssertTrue(context.failures.isEmpty)
        XCTAssertEqual(context.protection(tree.path), "Active Claude Code session")
        XCTAssertFalse(context.completion(tree.path, since: .distantPast))
    }
    func testRecentWorkRequiresSelectionAndCanActuallyBeRemoved() async throws {
        let f = try RepositoryFixture(), tree = try f.worktree("done"), engine = try f.engine(later: 0)
        let statuses = try await f.survey(engine)
        XCTAssertEqual(statuses[tree.path]?.verdict, .needsLook)
        do { _ = try await engine.planWorktreeRemoval(tops: [tree.path]); XCTFail("Must explicitly select recent work") } catch {}
        let plan = try await engine.planWorktreeRemoval(tops: [tree.path], approvingIgnored: [tree.path])
        let entries = try await engine.removeWorktrees(plan)
        XCTAssertEqual(entries.first?.outcome, "Cleaned", entries.first?.detail ?? "")
        XCTAssertFalse(f.exists(tree))
    }
    func testFinishedContextRecommendsRecentMergedWorkButNeverUnmergedWork() async throws {
        let f = try RepositoryFixture(), done = try f.worktree("done"), local = try f.worktree("local", commits: 1)
        let context = AgentContext(sessions: [done, local].map { .init(path: $0.path, provider: "Fixture", state: .finished, finishedAt: .distantFuture) })
        let engine = try Engine(directory: f.state, home: f.home.path, activity: { .init(paths: []) },
                                pullRequests: .init(provider: { _ in [] }), agents: { context })
        let statuses = try await f.survey(engine)
        XCTAssertEqual(statuses[done.path]?.verdict, .ready)
        XCTAssertEqual(statuses[local.path]?.rule, .onlyOnThisMac)
    }
    func testSessionResumingAfterReviewBlocksDeletion() async throws {
        let f = try RepositoryFixture(), tree = try f.worktree("done")
        let context = Locked(AgentContext())
        let engine = try Engine(directory: f.state, home: f.home.path, activity: { .init(paths: []) },
                                pullRequests: .init(provider: { _ in [] }), agents: { context.with { $0 } })
        _ = try await f.survey(engine)
        let plan = try await engine.planWorktreeRemoval(tops: [tree.path], approvingIgnored: [tree.path])
        context.with { $0 = .init(sessions: [.init(path: tree.path, provider: "T3", state: .active)]) }
        let entries = try await engine.removeWorktrees(plan)
        XCTAssertEqual(entries.first?.outcome, "Skipped")
        XCTAssertTrue(f.exists(tree))
    }
    func testRecentNestedRepositoryStillBlocksRemoval() async throws {
        let f = try RepositoryFixture(), tree = try f.worktree("done")
        let nested = tree.appendingPathComponent("build/nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try f.run(nested, "init", "-q")
        let statuses = try await f.survey(try f.engine(later: 0))
        XCTAssertEqual(statuses[tree.path]?.rule, .nestedWorktree)
    }
    func testAgentResumingAlsoProtectsBuildOutput() async throws {
        let f = try Fixture(), context = Locked(AgentContext())
        let engine = try Engine(directory: f.state, home: f.home.path, activity: { .init(paths: []) }, agents: { context.with { $0 } })
        try await engine.save(f.preferences())
        _ = try await engine.scan()
        let plan = try await engine.plan(paths: [f.target.path])
        context.with { $0 = .init(sessions: [.init(path: f.project.path, provider: "T3", state: .active)]) }
        let entries = try await engine.execute(plan)
        XCTAssertEqual(entries.first?.outcome, "Skipped")
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.target.path))
    }
    func testUnreadableAgentMetadataBlocksCleanupInsteadOfAssumingIdle() async throws {
        let f = try Fixture()
        let engine = try Engine(directory: f.state, home: f.home.path, activity: { .init(paths: []) },
                                agents: { .init(failures: ["Couldn't inspect session metadata"]) })
        try await engine.save(f.preferences())
        let inventory = try await engine.scan()
        XCTAssertFalse(try XCTUnwrap(inventory.artifacts.first).eligible)
    }
    func testSharedUnknownOwnerSuppressesRecommendationAndPathsDoNotPrefixMatch() {
        let context = AgentContext(sessions: [
            .init(path: "/trees/one", provider: "T3", state: .finished, finishedAt: .distantFuture),
            .init(path: "/trees/one/package", provider: "Codex", state: .unknown),
            .init(path: "/trees/one-more", provider: "Claude Code", state: .active)
        ])
        XCTAssertFalse(context.completion("/trees/one", since: .distantPast))
        XCTAssertNil(context.protection("/trees/one"))
        XCTAssertNotNil(context.protection("/trees/one-more"))
    }

    func testInaccessibleStoreIsNotMistakenForAnAbsentIntegration() throws {
        let f = try RepositoryFixture(), directory = f.home.appendingPathComponent(".t3")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        XCTAssertFalse(AgentContextReader(home: f.home.path).capture().failures.isEmpty)
    }

    func testNewUnknownOwnerWithSameSummaryInvalidatesReview() async throws {
        let f = try RepositoryFixture(), tree = try f.worktree("done")
        let original = AgentContext.Session(path: tree.path, provider: "Codex", state: .unknown, id: "first")
        let context = Locked(AgentContext(sessions: [original]))
        let engine = try Engine(directory: f.state, home: f.home.path, activity: { .init(paths: []) },
                                pullRequests: .init(provider: { _ in [] }), agents: { context.with { $0 } })
        _ = try await f.survey(engine)
        let plan = try await engine.planWorktreeRemoval(tops: [tree.path], approvingIgnored: [tree.path])
        context.with { $0.sessions.append(.init(path: tree.path, provider: "Codex", state: .unknown, id: "second")) }
        let entries = try await engine.removeWorktrees(plan)
        XCTAssertEqual(entries.first?.outcome, "Skipped")
        XCTAssertEqual(entries.first?.detail, "Its agent context changed since review.")
        XCTAssertTrue(f.exists(tree))
    }
    func testBrokenT3LineageDoesNotBecomeMissingEvidence() throws {
        let f = try RepositoryFixture()
        try t3(f, records: [["id": "child", "lineage": ["parentThreadId": "missing"]]], active: ["child"])
        XCTAssertFalse(AgentContextReader(home: f.home.path).capture().failures.isEmpty)
    }
    func testRevisionIgnoresRecordOrderingButNotOwnership() {
        let a = AgentContext.Session(path: "/tree", provider: "T3", state: .unknown, id: "a")
        let b = AgentContext.Session(path: "/tree", provider: "T3", state: .unknown, id: "b")
        XCTAssertEqual(AgentContext(sessions: [a,b]).revision("/tree"), AgentContext(sessions: [b,a]).revision("/tree"))
        XCTAssertNotEqual(AgentContext(sessions: [a]).revision("/tree"), AgentContext(sessions: [a,b]).revision("/tree"))
    }

    func testAncestorAgentProtectsOutputDuringScan() async throws {
        let f = try Fixture()
        let context = AgentContext(sessions: [.init(path: f.project.deletingLastPathComponent().path, provider: "T3", state: .active)])
        let engine = try Engine(directory: f.state, home: f.home.path, activity: { .init(paths: []) }, agents: { context })
        try await engine.save(f.preferences())
        let inventory = try await engine.scan()
        let artifact = try XCTUnwrap(inventory.artifacts.first)
        XCTAssertFalse(artifact.eligible)
        XCTAssertTrue(artifact.reasons.contains("Active T3 session"))
    }
    func testAncestorAgentStartingAfterReviewBlocksManualAndAutomaticOutputRemoval() async throws {
        for automatic in [false, true] {
            let f = try Fixture(), context = Locked(AgentContext()), clock = Clock()
            let engine = try Engine(directory: f.state, home: f.home.path, activity: { .init(paths: []) },
                                    clock: { clock.now() }, agents: { context.with { $0 } })
            var preferences = f.preferences()
            preferences.scheduled = true; preferences.roots[0].automatic = true; preferences.keepHours = 1
            try await engine.save(preferences)
            _ = try await engine.scan()
            for _ in 0..<7 { clock.advance(600); _ = try await engine.scan() }
            let plan = try await engine.plan(paths: [f.target.path], automatic: automatic)
            context.with { $0 = .init(sessions: [.init(path: f.project.deletingLastPathComponent().path, provider: "T3", state: .active)]) }
            let entries = try await engine.execute(plan)
            XCTAssertEqual(entries.first?.outcome, "Skipped", "automatic: \(automatic)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.target.path))
        }
    }

    func testAgentOverlapDoesNotBroadenOrdinaryProcessProtection() {
        var snapshot = ActivitySnapshot(paths: ["/projects"])
        XCTAssertNil(snapshot.protection(for: "/projects/repo", target: "/projects/repo/target"))
        snapshot.agents = .init(sessions: [.init(path: "/projects", provider: "T3", state: .active)])
        XCTAssertEqual(snapshot.protection(for: "/projects/repo", target: "/projects/repo/target"), "Active T3 session")
        XCTAssertNil(snapshot.protection(for: "/projects-other/repo", target: "/projects-other/repo/target"))
    }

}
