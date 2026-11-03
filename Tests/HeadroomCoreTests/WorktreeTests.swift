import XCTest
@testable import HeadroomCore

/// A real origin, a main checkout, and linked worktrees in temporary folders. Never touches live worktrees.
final class RepositoryFixture {
    let base: URL, origin: URL, main: URL, trees: URL, state: URL, home: URL
    init(defaultBranch: String = "main") throws {
        base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("headroom-worktrees-" + UUID().uuidString)
        origin = base.appendingPathComponent("origin.git")
        main = base.appendingPathComponent("projects/repo")
        trees = base.appendingPathComponent("projects/trees")
        state = base.appendingPathComponent("state")
        home = base.appendingPathComponent("home")
        for directory in [trees, home, main.deletingLastPathComponent()] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        try run(origin, "init", "-q", "--bare", "-b", defaultBranch)
        try run(base, "clone", "-q", origin.path, main.path)
        try run(main, "checkout", "-q", "-b", defaultBranch)
        try Data("build/\ntarget/\n.env\n.env.*\nnotes/\nscratch.png\nnested/\n".utf8).write(to: main.appendingPathComponent(".gitignore"))
        try Data("hello\n".utf8).write(to: main.appendingPathComponent("README.md"))
        try run(main, "add", "."); try commit(main, "first")
        try run(main, "push", "-q", "-u", "origin", defaultBranch)
        try run(main, "remote", "set-head", "origin", defaultBranch)
    }
    deinit { try? FileManager.default.removeItem(at: base) }
    @discardableResult func run(_ directory: URL, _ args: String...) throws -> String {
        let result = try Command.git(directory.path, Array(args))
        guard result.status == 0 else { throw HeadroomError.message("git \(args.joined(separator: " ")): \(result.error)") }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func commit(_ directory: URL, _ message: String) throws {
        _ = try Command.git(directory.path, ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-q", "--allow-empty", "-m", message])
    }
    /// A linked worktree on a new branch from the current default branch.
    func worktree(_ name: String, commits: Int = 0, push: Bool = false) throws -> URL {
        let url = trees.appendingPathComponent(name)
        try run(main, "worktree", "add", "-q", "-b", name, url.path)
        for index in 0..<commits { try commit(url, "\(name) \(index)") }
        if push { try run(url, "push", "-q", "-u", "origin", name) }
        return url
    }
    func head(_ url: URL) throws -> String { try run(url, "rev-parse", "HEAD") }
    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    /// An engine whose clock is past the unused window, so only the rule under test decides.
    func engine(pullRequests: [PullRequest]? = [], later days: Double = 8, activity: ActivitySnapshot = .init(paths: [])) throws -> Engine {
        let clock = Date().addingTimeInterval(days * 86400)
        return try Engine(directory: state, home: home.path, activity: { activity }, clock: { clock },
                          pullRequests: PullRequestCache(provider: { _ in pullRequests }))
    }
    func survey(_ engine: Engine, configure: (inout Preferences) -> Void = { _ in }) async throws -> [String: WorktreeStatus] {
        var preferences = Preferences(); preferences.roots = [.init(path: main.deletingLastPathComponent().path)]
        configure(&preferences)
        try await engine.save(preferences)
        _ = try await engine.scan()
        return Dictionary(uniqueKeysWithValues: try await engine.surveyWorktrees().map { ($0.top, $0) })
    }
}

final class WorktreeTests: XCTestCase {
    func testCommitsInDefaultBranchAreReady() async throws {
        let f = try RepositoryFixture(), tree = try f.worktree("done")
        let status = try await f.survey(try f.engine())
        XCTAssertEqual(status[tree.path]?.verdict, .ready, status[tree.path]?.reason ?? "")
        XCTAssertEqual(status[tree.path]?.evidence, "In main")
    }
    func testStagingDefaultBranchCounts() async throws {
        let f = try RepositoryFixture(defaultBranch: "staging"), tree = try f.worktree("done")
        let status = try await f.survey(try f.engine())
        XCTAssertEqual(status[tree.path]?.verdict, .ready, status[tree.path]?.reason ?? "")
        XCTAssertEqual(status[tree.path]?.evidence, "In staging")
    }
    func testStagingCountsWhenItIsNotTheDefault() async throws {
        let f = try RepositoryFixture()
        try f.run(f.main, "checkout", "-q", "-b", "staging"); try f.commit(f.main, "on staging")
        try f.run(f.main, "push", "-q", "-u", "origin", "staging")
        let tree = f.trees.appendingPathComponent("detached")
        try f.run(f.main, "worktree", "add", "-q", "--detach", tree.path, "origin/staging")
        let status = try await f.survey(try f.engine())
        XCTAssertEqual(status[tree.path]?.evidence, "In staging")
    }
    func testMainCheckoutIsAlwaysKept() async throws {
        let f = try RepositoryFixture()
        let status = try await f.survey(try f.engine())
        XCTAssertEqual(status[f.main.path]?.rule, .mainCheckout)
    }
    func testCommitsOnlyOnThisMacAreKept() async throws {
        let f = try RepositoryFixture(), tree = try f.worktree("local", commits: 2)
        let status = try await f.survey(try f.engine())
        XCTAssertEqual(status[tree.path]?.rule, .onlyOnThisMac)
        XCTAssertEqual(status[tree.path]?.reason, "2 commits only on this Mac")
    }
    func testSquashMergedPullRequestUsesExactHead() async throws {
        let f = try RepositoryFixture(), tree = try f.worktree("squashed", commits: 2, push: true)
        let pull = PullRequest(number: 812, state: "MERGED", headRefName: "squashed", headRefOid: try f.head(tree), baseRefName: "main")
        let status = try await f.survey(try f.engine(pullRequests: [pull]))
        XCTAssertEqual(status[tree.path]?.verdict, .ready, status[tree.path]?.reason ?? "")
        XCTAssertEqual(status[tree.path]?.evidence, "PR #812 merged")
    }
    func testEarlierCommitOfMergedBranchCounts() async throws {
        let f = try RepositoryFixture(), source = try f.worktree("feature", commits: 3, push: true)
        let review = f.trees.appendingPathComponent("review")
        try f.run(f.main, "worktree", "add", "-q", "--detach", review.path, try f.run(source, "rev-parse", "HEAD~1"))
        let pull = PullRequest(number: 9, state: "MERGED", headRefName: "feature", headRefOid: try f.head(source), baseRefName: "main")
        let status = try await f.survey(try f.engine(pullRequests: [pull]))
        XCTAssertEqual(status[review.path]?.verdict, .ready, status[review.path]?.reason ?? "")
        XCTAssertEqual(status[review.path]?.evidence, "Part of PR #9")
    }
    func testCommitsAfterTheMergeAreKept() async throws {
        let f = try RepositoryFixture(), tree = try f.worktree("reused", commits: 1, push: true)
        let pull = PullRequest(number: 5, state: "MERGED", headRefName: "reused", headRefOid: try f.head(tree), baseRefName: "main")
        try f.commit(tree, "more work"); try f.run(tree, "push", "-q")
        let status = try await f.survey(try f.engine(pullRequests: [pull]))
        XCTAssertEqual(status[tree.path]?.rule, .commitsAfterMerge)
    }
    func testBranchNameAloneNeverCounts() async throws {
        let f = try RepositoryFixture(), tree = try f.worktree("reused", commits: 1, push: true)
        let pull = PullRequest(number: 5, state: "MERGED", headRefName: "reused", headRefOid: String(repeating: "a", count: 40), baseRefName: "main")
        let status = try await f.survey(try f.engine(pullRequests: [pull]))
        XCTAssertEqual(status[tree.path]?.verdict, .kept)
    }
    func testPullRequestMergedIntoAnotherFeatureBranchDoesNotCount() async throws {
        let f = try RepositoryFixture(), tree = try f.worktree("stacked", commits: 1, push: true)
        let pull = PullRequest(number: 6, state: "MERGED", headRefName: "stacked", headRefOid: try f.head(tree), baseRefName: "some-feature")
        let status = try await f.survey(try f.engine(pullRequests: [pull]))
        XCTAssertEqual(status[tree.path]?.rule, .notMerged)
    }
    func testOpenPullRequestIsKept() async throws {
        let f = try RepositoryFixture(), tree = try f.worktree("open", commits: 1, push: true)
        let pull = PullRequest(number: 7, state: "OPEN", headRefName: "open", headRefOid: try f.head(tree), baseRefName: "main")
        let status = try await f.survey(try f.engine(pullRequests: [pull]))
        XCTAssertEqual(status[tree.path]?.rule, .openPullRequest)
    }
    func testGitHubUnavailableKeepsWhatOnlyGitHubCanConfirm() async throws {
        let f = try RepositoryFixture(), pushed = try f.worktree("pushed", commits: 1, push: true), merged = try f.worktree("merged")
        let status = try await f.survey(try f.engine(pullRequests: nil))
        XCTAssertEqual(status[pushed.path]?.rule, .mergeUnknown)
        XCTAssertEqual(status[merged.path]?.verdict, .ready, "Git alone proves this one")
    }
    func testUncommittedAndUntrackedChangesAreKept() async throws {
        let f = try RepositoryFixture(), modified = try f.worktree("modified"), untracked = try f.worktree("untracked")
        try Data("changed\n".utf8).write(to: modified.appendingPathComponent("README.md"))
        try Data("new\n".utf8).write(to: untracked.appendingPathComponent("new.txt"))
        let status = try await f.survey(try f.engine())
        XCTAssertEqual(status[modified.path]?.rule, .uncommitted)
        XCTAssertEqual(status[untracked.path]?.rule, .uncommitted)
    }
    func testEnvFilesDoNotBlockAndAreNamed() async throws {
        let f = try RepositoryFixture(), tree = try f.worktree("secrets")
        try Data("A=1\n".utf8).write(to: tree.appendingPathComponent(".env"))
        try Data("B=2\n".utf8).write(to: tree.appendingPathComponent(".env.local"))
        let status = try await f.survey(try f.engine())
        XCTAssertEqual(status[tree.path]?.verdict, .ready, status[tree.path]?.reason ?? "")
        XCTAssertEqual(status[tree.path]?.envFiles, [".env", ".env.local"])
    }
    func testBuildOutputDoesNotBlockButOtherIgnoredFilesNeedALook() async throws {
        let f = try RepositoryFixture(), builds = try f.worktree("builds"), notes = try f.worktree("notes")
        try FileManager.default.createDirectory(at: builds.appendingPathComponent("build"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: builds.appendingPathComponent("build/out.bin"))
        try Data("x".utf8).write(to: notes.appendingPathComponent("scratch.png"))
        let status = try await f.survey(try f.engine())
        XCTAssertEqual(status[builds.path]?.verdict, .ready, status[builds.path]?.reason ?? "")
        XCTAssertEqual(status[notes.path]?.verdict, .needsLook)
        XCTAssertEqual(status[notes.path]?.otherIgnored, ["scratch.png"])
    }
    func testNestedWorktreeAndNestedRepositoryKeepTheOuterWorktree() async throws {
        let f = try RepositoryFixture(), outer = try f.worktree("outer"), holder = try f.worktree("holder")
        let inner = outer.appendingPathComponent("nested/inner")
        try f.run(f.main, "worktree", "add", "-q", "-b", "inner", inner.path)
        let repository = holder.appendingPathComponent("notes/other")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try f.run(repository, "init", "-q")
        let status = try await f.survey(try f.engine())
        XCTAssertEqual(status[outer.path]?.rule, .nestedWorktree)
        XCTAssertEqual(status[holder.path]?.rule, .nestedWorktree)
    }
    func testRepositoryInsideBuildOutputKeepsTheWorktree() async throws {
        let f = try RepositoryFixture(), tree = try f.worktree("holder"), clean = try f.worktree("clean")
        let repository = tree.appendingPathComponent("build/other")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try f.run(repository, "init", "-q")
        try FileManager.default.createDirectory(at: clean.appendingPathComponent("build/out"), withIntermediateDirectories: true)
        let status = try await f.survey(try f.engine())
        XCTAssertEqual(status[tree.path]?.rule, .nestedWorktree, status[tree.path]?.reason ?? "")
        XCTAssertEqual(status[clean.path]?.verdict, .ready, status[clean.path]?.reason ?? "")
    }
    func testBareRepositoryInsideBuildOutputKeepsTheWorktree() async throws {
        let f = try RepositoryFixture(), direct = try f.worktree("direct"), deeper = try f.worktree("deeper")
        for bare in [direct.appendingPathComponent("build/local.git"), deeper.appendingPathComponent("build/a/b/local.git")] {
            try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
            try f.run(bare, "init", "-q", "--bare")
        }
        let status = try await f.survey(try f.engine())
        XCTAssertEqual(status[direct.path]?.rule, .nestedWorktree, status[direct.path]?.reason ?? "")
        XCTAssertEqual(status[deeper.path]?.rule, .nestedWorktree, status[deeper.path]?.reason ?? "")
    }
    func testIgnoredFoldersAreListedAsFolders() async throws {
        let f = try RepositoryFixture(), tree = try f.worktree("notes")
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("notes/deep"), withIntermediateDirectories: true)
        for name in ["a.md", "deep/b.md"] { try Data("x".utf8).write(to: tree.appendingPathComponent("notes/" + name)) }
        let status = try await f.survey(try f.engine())
        XCTAssertEqual(status[tree.path]?.otherIgnored, ["notes/"])
    }
    func testHiddenUntrackedFilesAreStillFound() async throws {
        let f = try RepositoryFixture(), tree = try f.worktree("hidden")
        try f.run(f.main, "config", "status.showUntrackedFiles", "no")
        try Data("work\n".utf8).write(to: tree.appendingPathComponent("new.txt"))
        let status = try await f.survey(try f.engine())
        XCTAssertEqual(status[tree.path]?.rule, .uncommitted, status[tree.path]?.reason ?? "")
    }
    func testGitRefusesHiddenUntrackedFilesDuringRemoval() throws {
        let f = try RepositoryFixture(), tree = try f.worktree("hidden")
        try f.run(f.main, "config", "status.showUntrackedFiles", "no")
        try Data("work\n".utf8).write(to: tree.appendingPathComponent("new.txt"))
        let result = try Command.git(f.main.path, WorktreeInspector.removeArguments(top: tree.path))
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(f.exists(tree.appendingPathComponent("new.txt")))
    }
    func testChangesHiddenFromStatusAreKept() async throws {
        let f = try RepositoryFixture(), tree = try f.worktree("assumed")
        try f.run(tree, "update-index", "--assume-unchanged", "README.md")
        try Data("changed\n".utf8).write(to: tree.appendingPathComponent("README.md"))
        let status = try await f.survey(try f.engine())
        XCTAssertEqual(status[tree.path]?.rule, .uncommitted, status[tree.path]?.reason ?? "")
    }
    func testPinnedLockedAndInUseAreKept() async throws {
        let f = try RepositoryFixture()
        let pinned = try f.worktree("pinned"), locked = try f.worktree("locked"), used = try f.worktree("used")
        try f.run(f.main, "worktree", "lock", locked.path)
        let engine = try f.engine(activity: .init(uses: [.init(path: used.path, pid: 42, command: "node")]))
        let status = try await f.survey(engine) { $0.pinned.insert(pinned.path) }
        XCTAssertEqual(status[pinned.path]?.rule, .pinned)
        XCTAssertEqual(status[locked.path]?.rule, .locked)
        XCTAssertEqual(status[used.path]?.rule, .inUse)
        XCTAssertEqual(status[used.path]?.reason, "In use by node (pid 42)")
    }
    func testIncompleteActivityKeepsEverything() async throws {
        let f = try RepositoryFixture(), tree = try f.worktree("done")
        let status = try await f.survey(try f.engine(activity: .init(paths: [], failure: "Permission denied")))
        XCTAssertEqual(status[tree.path]?.rule, .inUse)
    }
    func testRecentlyUsedWaitsSevenDaysFromLastFileChange() async throws {
        let f = try RepositoryFixture(), tree = try f.worktree("recent")
        let soon = try await f.survey(try f.engine(later: 2))
        XCTAssertEqual(soon[tree.path]?.rule, .recentlyUsed)
        XCTAssertEqual(soon[tree.path]?.reason, "Merged, can go in 5 days")
        let later = try await f.survey(try f.engine(later: 8))
        XCTAssertEqual(later[tree.path]?.verdict, .ready)
    }
    func testRemovingBuildOutputDoesNotRestartTheUnusedClock() throws {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("headroom-clock-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("target"), withIntermediateDirectories: true)
        let old = Date().addingTimeInterval(-30 * 86400), file = directory.appendingPathComponent("source.txt")
        try Data("x".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("target")) // Moves the directory's own time, not the file's.
        let measured = try FileInspection.measure(directory.path)
        XCTAssertEqual(measured.latestFileWrite.timeIntervalSince1970, old.timeIntervalSince1970, accuracy: 1)
    }
    func testIgnoredPathClassification() {
        XCTAssertEqual(WorktreePolicy.classify("apps/web/.env.local"), .env)
        XCTAssertEqual(WorktreePolicy.classify(".envrc"), .other)
        XCTAssertEqual(WorktreePolicy.classify(".env/"), .other, "A folder named .env is not a dotenv file")
        XCTAssertEqual(WorktreePolicy.classify("packages/a/node_modules/"), .rebuildable)
        XCTAssertEqual(WorktreePolicy.classify("target/.env"), .rebuildable)
        XCTAssertEqual(WorktreePolicy.classify("frontend/.plugin-ui-build/"), .rebuildable)
        XCTAssertEqual(WorktreePolicy.classify("screenshots/"), .other)
    }
    func testGitHubSlugAcceptsOnlyGitHubRemotes() {
        XCTAssertEqual(GitHub.slug(origin: "git@github.com:Org/Repo.git"), "Org/Repo")
        XCTAssertEqual(GitHub.slug(origin: "https://github.com/Org/Repo"), "Org/Repo")
        XCTAssertEqual(GitHub.slug(origin: "ssh://git@github.com/Org/Repo.git\n"), "Org/Repo")
        XCTAssertNil(GitHub.slug(origin: "https://gitlab.com/Org/Repo.git"))
        XCTAssertNil(GitHub.slug(origin: "https://github.com/Org/Repo/extra"))
        XCTAssertNil(GitHub.slug(origin: "https://github.com/--flag/Repo"))
    }

    // MARK: Removal

    func testRemovalKeepsBranchAndCommitsAndRecordsHistory() async throws {
        let f = try RepositoryFixture(), tree = try f.worktree("done")
        try Data("A=1\n".utf8).write(to: tree.appendingPathComponent(".env"))
        let engine = try f.engine()
        _ = try await f.survey(engine)
        let plan = try await engine.planWorktreeRemoval(tops: [tree.path])
        let entries = try await engine.removeWorktrees(plan)
        XCTAssertEqual(entries.first?.outcome, "Cleaned", entries.first?.detail ?? "")
        XCTAssertFalse(f.exists(tree))
        XCTAssertEqual(try f.run(f.main, "branch", "--list", "done"), "done")
        XCTAssertTrue(entries.first?.detail.contains(".env") ?? false, "The history names what can't come back")
        let history = try await engine.history()
        XCTAssertEqual(history.first?.restore?.branch, "done")
        XCTAssertFalse(history.first?.automatic ?? true)
    }
    func testRestoreRecreatesTheWorktreeWithoutIgnoredFiles() async throws {
        let f = try RepositoryFixture(), tree = try f.worktree("done")
        try Data("A=1\n".utf8).write(to: tree.appendingPathComponent(".env"))
        let engine = try f.engine()
        _ = try await f.survey(engine)
        _ = try await engine.removeWorktrees(try await engine.planWorktreeRemoval(tops: [tree.path]))
        let history = try await engine.history()
        let restore = try XCTUnwrap(history.first?.restore)
        try await engine.restoreWorktree(restore)
        XCTAssertTrue(f.exists(tree.appendingPathComponent("README.md")))
        XCTAssertFalse(f.exists(tree.appendingPathComponent(".env")))
        XCTAssertEqual(try f.run(tree, "branch", "--show-current"), "done")
        do { try await engine.restoreWorktree(restore); XCTFail("Restoring over an existing folder must fail") } catch {}
    }
    func testRestoreFallsBackToTheCommitWhenTheBranchIsGone() async throws {
        let f = try RepositoryFixture(), tree = try f.worktree("done")
        let engine = try f.engine()
        _ = try await f.survey(engine)
        _ = try await engine.removeWorktrees(try await engine.planWorktreeRemoval(tops: [tree.path]))
        try f.run(f.main, "branch", "-q", "-D", "done")
        let history = try await engine.history()
        try await engine.restoreWorktree(try XCTUnwrap(history.first?.restore))
        XCTAssertTrue(f.exists(tree.appendingPathComponent("README.md")))
    }
    func testUnreferencedCommitSurvivesGarbageCollectionForRestore() async throws {
        let f = try RepositoryFixture(), source = try f.worktree("feature", commits: 2, push: true)
        let head = try f.head(source)
        let tree = f.trees.appendingPathComponent("detached")
        try f.run(f.main, "worktree", "add", "-q", "--detach", tree.path, head)
        // The squash-merged source branch is deleted everywhere, leaving only this worktree's HEAD holding the commit.
        try f.run(f.main, "worktree", "remove", source.path)
        try f.run(f.main, "branch", "-q", "-D", "feature")
        try f.run(f.main, "push", "-q", "origin", "--delete", "feature")
        try f.run(f.main, "fetch", "-q", "--prune")
        let pull = PullRequest(number: 3, state: "MERGED", headRefName: "feature", headRefOid: head, baseRefName: "main")
        let engine = try f.engine(pullRequests: [pull])
        let status = try await f.survey(engine)
        XCTAssertEqual(status[tree.path]?.verdict, .ready, status[tree.path]?.reason ?? "")
        let entries = try await engine.removeWorktrees(try await engine.planWorktreeRemoval(tops: [tree.path]))
        XCTAssertEqual(entries.first?.outcome, "Cleaned", entries.first?.detail ?? "")
        try f.run(f.main, "reflog", "expire", "--expire=now", "--all")
        try f.run(f.main, "gc", "-q", "--prune=now")
        let history = try await engine.history()
        try await engine.restoreWorktree(try XCTUnwrap(history.first?.restore))
        XCTAssertEqual(try f.head(tree), head)
    }
    func testNoRecoveryReferenceWhenTheBranchHoldsTheCommit() async throws {
        let f = try RepositoryFixture(), tree = try f.worktree("done")
        let engine = try f.engine()
        _ = try await f.survey(engine)
        _ = try await engine.removeWorktrees(try await engine.planWorktreeRemoval(tops: [tree.path]))
        XCTAssertEqual(try f.run(f.main, "for-each-ref", "refs/headroom"), "")
    }
    func testRemovalChecksAgainAndKeepsChangesMadeAfterReview() async throws {
        let f = try RepositoryFixture(), dirty = try f.worktree("dirty"), moved = try f.worktree("moved"), locked = try f.worktree("locked")
        let engine = try f.engine()
        _ = try await f.survey(engine)
        let plan = try await engine.planWorktreeRemoval(tops: [dirty.path, moved.path, locked.path])
        try Data("work\n".utf8).write(to: dirty.appendingPathComponent("new.txt"))
        try f.commit(moved, "new local work")
        try f.run(f.main, "worktree", "lock", locked.path)
        let entries = try await engine.removeWorktrees(plan)
        XCTAssertEqual(entries.count, 3)
        XCTAssertTrue(entries.allSatisfy { $0.outcome == "Skipped" }, entries.map(\.detail).joined(separator: " | "))
        for tree in [dirty, moved, locked] { XCTAssertTrue(f.exists(tree), tree.path) }
    }
    func testWorktreeAddedInsideAfterReviewKeepsTheOuterOne() async throws {
        let f = try RepositoryFixture(), outer = try f.worktree("outer")
        let engine = try f.engine()
        _ = try await f.survey(engine)
        let plan = try await engine.planWorktreeRemoval(tops: [outer.path])
        let inner = outer.appendingPathComponent("nested/inner")
        try f.run(f.main, "worktree", "add", "-q", "-b", "inner", inner.path)
        let entries = try await engine.removeWorktrees(plan)
        XCTAssertEqual(entries.first?.outcome, "Skipped", entries.first?.detail ?? "")
        XCTAssertTrue(f.exists(inner.appendingPathComponent("README.md")))
    }
    func testPinningAfterReviewKeepsTheWorktree() async throws {
        let f = try RepositoryFixture(), tree = try f.worktree("done")
        let engine = try f.engine()
        _ = try await f.survey(engine)
        let plan = try await engine.planWorktreeRemoval(tops: [tree.path])
        var preferences = try await engine.preferences(); preferences.pinned.insert(tree.path); try await engine.save(preferences)
        let entries = try await engine.removeWorktrees(plan)
        XCTAssertEqual(entries.first?.outcome, "Skipped")
        XCTAssertTrue(f.exists(tree))
    }
    func testIgnoredFilesRequireApprovalAndNewOnesCancelIt() async throws {
        let f = try RepositoryFixture(), tree = try f.worktree("notes"), other = try f.worktree("more")
        try Data("x".utf8).write(to: tree.appendingPathComponent("scratch.png"))
        try Data("x".utf8).write(to: other.appendingPathComponent("scratch.png"))
        let engine = try f.engine()
        _ = try await f.survey(engine)
        do { _ = try await engine.planWorktreeRemoval(tops: [tree.path]); XCTFail("Needs approval") } catch {}
        let plan = try await engine.planWorktreeRemoval(tops: [tree.path, other.path], approvingIgnored: [tree.path, other.path])
        try FileManager.default.createDirectory(at: other.appendingPathComponent("notes"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: other.appendingPathComponent("notes/new.md"))
        let entries = try await engine.removeWorktrees(plan)
        XCTAssertEqual(entries.first { $0.path == tree.path }?.outcome, "Cleaned")
        XCTAssertEqual(entries.first { $0.path == other.path }?.outcome, "Skipped")
        XCTAssertTrue(f.exists(other.appendingPathComponent("notes/new.md")))
    }
    func testRefreshDuringReviewCannotAddFilesToWhatWasApproved() async throws {
        let f = try RepositoryFixture(), tree = try f.worktree("notes")
        try Data("x".utf8).write(to: tree.appendingPathComponent("scratch.png"))
        let engine = try f.engine()
        let shown = try await f.survey(engine)
        let reviewed = try XCTUnwrap(shown[tree.path])
        // An older file arrives with its old time, so the unused wait still passes, and a survey refreshes during the review.
        let late = tree.appendingPathComponent("notes/old.md")
        try FileManager.default.createDirectory(at: late.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: late)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-30 * 86400)], ofItemAtPath: late.path)
        _ = try await engine.surveyWorktrees()
        let plan = try await engine.planWorktreeRemoval(reviewed: [reviewed], approvingIgnored: [tree.path])
        let entries = try await engine.removeWorktrees(plan)
        XCTAssertEqual(entries.first?.outcome, "Skipped", entries.first?.detail ?? "")
        XCTAssertTrue(f.exists(late))
    }
    func testEnvFileAddedAfterReviewCancelsRemoval() async throws {
        let f = try RepositoryFixture(), tree = try f.worktree("done")
        let engine = try f.engine()
        let shown = try await f.survey(engine)
        let plan = try await engine.planWorktreeRemoval(reviewed: [try XCTUnwrap(shown[tree.path])])
        let env = tree.appendingPathComponent(".env")
        try Data("A=1\n".utf8).write(to: env)
        let entries = try await engine.removeWorktrees(plan)
        XCTAssertEqual(entries.first?.outcome, "Skipped", entries.first?.detail ?? "")
        XCTAssertTrue(f.exists(env))
    }
    func testKeptWorktreesCannotBePlanned() async throws {
        let f = try RepositoryFixture(), tree = try f.worktree("local", commits: 1)
        let engine = try f.engine()
        _ = try await f.survey(engine)
        do { _ = try await engine.planWorktreeRemoval(tops: [tree.path, f.main.path], approvingIgnored: [tree.path, f.main.path]); XCTFail("Kept stays kept") } catch {}
        XCTAssertTrue(f.exists(tree))
    }
    func testAutomaticCleanupNeverRemovesWorktrees() async throws {
        let f = try RepositoryFixture(), tree = try f.worktree("done")
        let engine = try f.engine()
        _ = try await f.survey(engine) { $0.scheduled = true; $0.intervalHours = 1; $0.roots[0].automatic = true }
        _ = try await engine.runScheduleIfDue()
        _ = try await engine.runScheduleIfDue()
        XCTAssertTrue(f.exists(tree))
    }
    func testGitRefusesSubmodulesWithoutForce() async throws {
        let f = try RepositoryFixture()
        let library = f.base.appendingPathComponent("library.git")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try f.run(library, "init", "-q", "--bare", "-b", "main")
        let seed = f.base.appendingPathComponent("seed")
        try f.run(f.base, "clone", "-q", library.path, seed.path)
        try f.commit(seed, "first"); try f.run(seed, "push", "-q", "origin", "HEAD:main")
        _ = try Command.git(f.main.path, ["-c", "protocol.file.allow=always", "submodule", "add", "-q", library.path, "lib"])
        try f.commit(f.main, "add submodule"); try f.run(f.main, "push", "-q")
        let tree = f.trees.appendingPathComponent("with-submodule")
        try f.run(f.main, "worktree", "add", "-q", "--detach", tree.path, "origin/main")
        _ = try Command.git(tree.path, ["-c", "protocol.file.allow=always", "submodule", "update", "--init", "-q"])
        let engine = try f.engine()
        _ = try await f.survey(engine)
        let entries = try await engine.removeWorktrees(try await engine.planWorktreeRemoval(tops: [tree.path]))
        XCTAssertEqual(entries.first?.outcome, "Skipped", entries.first?.detail ?? "")
        XCTAssertTrue(f.exists(tree.appendingPathComponent("README.md")))
    }
}

extension WorktreePolicy.IgnoredKind: Equatable {}
