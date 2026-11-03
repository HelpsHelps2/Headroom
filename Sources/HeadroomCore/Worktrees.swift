import Foundation

/// Why a worktree stays. Every worktree that is not offered for removal has exactly one of these, shown to the person.
public enum WorktreeRule: String, Codable, CaseIterable, Sendable {
    case inspectionFailed, mainCheckout, pinned, locked, inUse, nestedWorktree, uncommitted
    case onlyOnThisMac, openPullRequest, commitsAfterMerge, notMerged, mergeUnknown, recentlyUsed
}

public enum WorktreeVerdict: String, Codable, Sendable {
    /// Meets every rule. Offered for removal and checked by default.
    case ready
    /// Meets every rule but holds ignored files Headroom doesn't recognize. Offered, unchecked, so a person looks first.
    case needsLook
    case kept
}

public struct WorktreeStatus: Codable, Identifiable, Equatable, Sendable {
    public var id: String { top }
    public var top: String
    public var root: String
    public var repository: String
    public var common: String
    public var branch: String?
    public var head: String
    public var verdict: WorktreeVerdict
    public var rule: WorktreeRule?
    /// The kept reason, or nil when the worktree can go.
    public var reason: String?
    /// What shows the work is merged, such as "PR #812 merged".
    public var evidence: String?
    /// Ignored `.env` files that go with the worktree. They don't block removal, but the review names them.
    public var envFiles: [String]
    /// Ignored files that aren't build output or `.env` files.
    public var otherIgnored: [String]
    public var bytes: Int64
    public var lastUsed: Date?
    public var name: String { branch ?? URL(fileURLWithPath: top).lastPathComponent }
    public var removable: Bool { verdict != .kept }
    public init(top: String, root: String, repository: String, common: String, branch: String?, head: String, verdict: WorktreeVerdict,
                rule: WorktreeRule? = nil, reason: String? = nil, evidence: String? = nil, envFiles: [String] = [], otherIgnored: [String] = [],
                bytes: Int64 = 0, lastUsed: Date? = nil) {
        self.top = top; self.root = root; self.repository = repository; self.common = common; self.branch = branch; self.head = head
        self.verdict = verdict; self.rule = rule; self.reason = reason; self.evidence = evidence; self.envFiles = envFiles
        self.otherIgnored = otherIgnored; self.bytes = bytes; self.lastUsed = lastUsed
    }
}

/// Enough to recreate a removed worktree. The branch and commits stay in the repository; ignored files do not come back.
public struct WorktreeRestore: Codable, Equatable, Sendable {
    public var top: String
    public var common: String
    public var branch: String?
    public var head: String
    public init(top: String, common: String, branch: String?, head: String) {
        self.top = top; self.common = common; self.branch = branch; self.head = head
    }
}

public struct WorktreeRemovalPlan: Sendable {
    public let candidates: [WorktreeStatus]
    /// Worktrees whose unrecognized ignored files a person chose to remove.
    public let approvedIgnored: Set<String>
}

public struct PullRequest: Codable, Equatable, Sendable {
    public var number: Int
    public var state: String
    public var headRefName: String
    public var headRefOid: String
    public var baseRefName: String
    public init(number: Int, state: String, headRefName: String, headRefOid: String, baseRefName: String) {
        self.number = number; self.state = state; self.headRefName = headRefName; self.headRefOid = headRefOid; self.baseRefName = baseRefName
    }
}

public enum WorktreePolicy {
    public static let unusedDays = 7
    /// Branches that count as shared when they exist on origin, alongside origin's default branch.
    static let sharedBranches = ["main", "master", "staging"]
    /// Ignored folders and files that any build or test run recreates.
    static let rebuildable: Set<String> = [
        "node_modules", "target", "build", "dist", ".next", ".turbo", ".expo", ".svelte-kit", "coverage", ".vercel", "__pycache__",
        "Pods", ".venv", "venv", ".cache", ".output", ".gradle", ".build", "DerivedData", "test-results", "playwright-report", ".plugin-ui-build", ".DS_Store",
    ]

    enum IgnoredKind { case rebuildable, env, other }
    /// Sorts one `git status --ignored` path. A path inside a rebuildable folder counts as rebuildable.
    static func classify(_ path: String) -> IgnoredKind {
        let parts = path.split(separator: "/").map(String.init)
        if parts.contains(where: rebuildable.contains) { return .rebuildable }
        guard !path.hasSuffix("/"), let name = parts.last else { return .other }
        return name == ".env" || name.hasPrefix(".env.") ? .env : .other
    }

    enum MergeState: Equatable {
        case merged(String), onlyOnThisMac(Int), openPullRequest(Int), commitsAfterMerge(Int), notMerged, unknown
    }

    static func kept(_ rule: WorktreeRule, _ reason: String) -> (WorktreeVerdict, WorktreeRule?, String?) { (.kept, rule, reason) }

    static func describe(_ merge: MergeState) -> (WorktreeRule, String)? {
        switch merge {
        case .merged: return nil
        case .onlyOnThisMac(let count): return (.onlyOnThisMac, "\(count) \(count == 1 ? "commit" : "commits") only on this Mac")
        case .openPullRequest(let number): return (.openPullRequest, "PR #\(number) is still open")
        case .commitsAfterMerge(let number): return (.commitsAfterMerge, "Has commits after PR #\(number) merged")
        case .notMerged: return (.notMerged, "Pushed, not merged")
        case .unknown: return (.mergeUnknown, "Couldn't confirm it merged")
        }
    }
}

/// Merged pull requests per origin, reused between surveys because merges don't change often and listing them is slow.
public final class PullRequestCache: @unchecked Sendable {
    public typealias Provider = @Sendable (_ origin: String) -> [PullRequest]?
    private let provider: Provider
    private let entries = Locked<[String: (date: Date, pullRequests: [PullRequest]?)]>([:])
    private let lifetime: TimeInterval = 900
    public init(provider: @escaping Provider = { GitHub.pullRequests(origin: $0) }) { self.provider = provider }
    func pullRequests(origin: String, now: Date) -> [PullRequest]? {
        if let entry = entries.with({ $0[origin] }), now.timeIntervalSince(entry.date) < lifetime, now >= entry.date { return entry.pullRequests }
        let value = provider(origin)
        entries.with { $0[origin] = (now, value) }
        return value
    }
}

public enum GitHub {
    /// `owner/name` for a github.com remote. Other hosts return nil and are treated as unknown.
    public static func slug(origin: String) -> String? {
        var text = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["git@github.com:", "ssh://git@github.com/", "https://github.com/", "http://github.com/"] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
            if text.hasSuffix(".git") { text = String(text.dropLast(4)) }
            if text.hasSuffix("/") { text = String(text.dropLast()) }
            let parts = text.split(separator: "/", omittingEmptySubsequences: false)
            let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: "._-"))
            guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("-") && $0.unicodeScalars.allSatisfy(allowed.contains) }) else { return nil }
            return text
        }
        return nil
    }
    /// Reads pull requests with the person's own `gh`. Without it, or offline, the answer is unknown and worktrees stay.
    public static func pullRequests(origin: String) -> [PullRequest]? {
        guard let slug = slug(origin: origin),
              let gh = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"].first(where: FileManager.default.isExecutableFile(atPath:)),
              let result = try? Command.run(gh, ["pr", "list", "--repo", slug, "--state", "all", "--limit", "5000",
                                                 "--json", "number,state,headRefName,headRefOid,baseRefName"], timeout: 180),
              result.status == 0 else { return nil }
        return try? JSONDecoder().decode([PullRequest].self, from: Data(result.output.utf8))
    }
}

struct RepositoryFacts: Sendable {
    var common: String
    var name: String
    var sharedNames: Set<String>
    var pullRequests: [PullRequest]?
    var locked: Set<String>
    var registered: Set<String>
}

public struct WorktreeInspector: Sendable {
    let pullRequests: PullRequestCache
    public init(pullRequests: PullRequestCache = PullRequestCache()) { self.pullRequests = pullRequests }

    /// Inspects every known worktree. Read-only: Git runs without optional locks and nothing is written.
    public func survey(roots: [String: String], preferences: Preferences, activity: ActivitySnapshot, artifacts: [Artifact], now: Date) -> [WorktreeStatus] {
        var byCommon: [String: [String]] = [:]
        for top in roots.keys { byCommon[Scanner.gitDirectories(top: top)?.common ?? top, default: []].append(top) }
        let commons = Array(byCommon)
        let facts = Locked<[String: RepositoryFacts]>([:])
        DispatchQueue.concurrentPerform(iterations: commons.count) { index in
            if let value = repository(top: commons[index].value[0], now: now) { facts.with { $0[commons[index].key] = value } }
        }
        let known = Array(roots.keys), repositories = facts.with { $0 }
        let tops = roots.keys.sorted(), next = Locked(0), results = Locked<[WorktreeStatus]>([])
        DispatchQueue.concurrentPerform(iterations: min(Scanner.workers, max(tops.count, 1))) { _ in
            while true {
                let index = next.with { value -> Int in defer { value += 1 }; return value }
                guard index < tops.count else { return }
                let top = tops[index], root = roots[top] ?? ""
                let repository = repositories[Scanner.gitDirectories(top: top)?.common ?? top]
                let status = inspect(top: top, root: root, repository: repository, preferences: preferences, activity: activity,
                                     artifacts: artifacts, known: known, now: now)
                results.with { $0.append(status) }
            }
        }
        return results.with { $0 }.sorted { $0.bytes > $1.bytes }
    }

    func repository(top: String, now: Date) -> RepositoryFacts? {
        guard let directories = Scanner.gitDirectories(top: top) else { return nil }
        let commonURL = URL(fileURLWithPath: directories.common)
        let name = commonURL.lastPathComponent == ".git" ? commonURL.deletingLastPathComponent().lastPathComponent : commonURL.deletingPathExtension().lastPathComponent
        var shared = WorktreePolicy.sharedBranches
        if let head = try? Command.git(top, ["symbolic-ref", "-q", "refs/remotes/origin/HEAD"]), head.status == 0 {
            let value = head.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("refs/remotes/origin/") { shared.append(String(value.dropFirst(20))) }
        }
        let existing = Set(shared).filter { (try? Command.git(top, ["rev-parse", "-q", "--verify", "refs/remotes/origin/\($0)^{commit}"]))?.status == 0 }
        var locked: Set<String> = [], registered: Set<String> = []
        if let list = try? Command.git(top, ["worktree", "list", "--porcelain", "-z"]), list.status == 0 {
            for block in list.output.components(separatedBy: "\0\0") {
                let fields = block.components(separatedBy: "\0")
                guard let field = fields.first(where: { $0.hasPrefix("worktree ") }) else { continue }
                let path = URL(fileURLWithPath: String(field.dropFirst(9))).resolvingSymlinksInPath().path
                registered.insert(path)
                if fields.contains(where: { $0 == "locked" || $0.hasPrefix("locked ") }) { locked.insert(path) }
            }
        }
        var requests: [PullRequest]?
        if let origin = try? Command.git(top, ["remote", "get-url", "origin"]), origin.status == 0 {
            requests = pullRequests.pullRequests(origin: origin.output.trimmingCharacters(in: .whitespacesAndNewlines), now: now)
        }
        return .init(common: directories.common, name: name, sharedNames: existing, pullRequests: requests, locked: locked, registered: registered)
    }

    /// Applies the rules to one worktree. Unknown or failed checks always keep it.
    func inspect(top: String, root: String, repository: RepositoryFacts?, preferences: Preferences, activity: ActivitySnapshot,
                 artifacts: [Artifact], known: [String], now: Date) -> WorktreeStatus {
        let own = artifacts.filter { $0.worktree?.top == top || ($0.worktree == nil && Paths.contains(top, $0.path)) }
        let builds = own.reduce(0) { $0 + $1.bytes }
        var status = WorktreeStatus(top: top, root: root, repository: repository?.name ?? URL(fileURLWithPath: top).lastPathComponent,
                                    common: repository?.common ?? "", branch: nil, head: "", verdict: .kept, bytes: builds)
        func keep(_ rule: WorktreeRule, _ reason: String) -> WorktreeStatus {
            status.verdict = .kept; status.rule = rule; status.reason = reason; return status
        }
        guard let repository, let directories = Scanner.gitDirectories(top: top) else { return keep(.inspectionFailed, "Couldn't read this repository") }
        guard let head = try? Command.git(top, ["rev-parse", "HEAD"]), head.status == 0 else { return keep(.inspectionFailed, "Couldn't read its current commit") }
        status.head = head.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if let branch = try? Command.git(top, ["symbolic-ref", "--short", "-q", "HEAD"]), branch.status == 0 {
            status.branch = branch.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if URL(fileURLWithPath: directories.gitDir).standardizedFileURL.path == URL(fileURLWithPath: directories.common).standardizedFileURL.path {
            return keep(.mainCheckout, "Main checkout")
        }
        guard repository.registered.contains(top) else { return keep(.inspectionFailed, "Git doesn't list this worktree") }
        if URL(fileURLWithPath: top).resolvingSymlinksInPath().path != top { return keep(.inspectionFailed, "Its path contains a symbolic link") }
        if preferences.isPinned(top) { return keep(.pinned, "Kept by you") }
        if repository.locked.contains(top) { return keep(.locked, "Locked in Git") }
        if let reason = activity.protection(for: top, target: top) {
            return keep(.inUse, reason.hasSuffix(".") ? String(reason.dropLast()) : reason)
        }
        // The scan's list can be older than this check, so Git's current list counts too.
        if (known + repository.registered).contains(where: { $0 != top && Paths.contains(top, $0) }) { return keep(.nestedWorktree, "Contains another worktree") }

        // Explicit modes: a repository's own settings can hide untracked files and submodule changes from plain `git status`.
        // `normal`, not `all`: `all` lists ignored folders file by file, and the review should name them as folders.
        guard let git = try? Command.git(top, ["status", "--porcelain", "--ignored", "--untracked-files=normal", "--ignore-submodules=none", "-z"], timeout: 60), git.status == 0 else {
            return keep(.inspectionFailed, "Couldn't read its Git status")
        }
        var changed = 0, env: [String] = [], other: [String] = []
        for entry in git.output.components(separatedBy: "\0") where !entry.isEmpty {
            guard entry.hasPrefix("!! ") else { changed += 1; continue }
            let path = String(entry.dropFirst(3))
            switch WorktreePolicy.classify(path) {
            case .rebuildable: break
            case .env: env.append(path)
            case .other: other.append(path)
            }
        }
        // `--assume-unchanged` and `--skip-worktree` hide edits from status. Sparse checkouts mark absent files the same way, so those don't count.
        guard let index = try? Command.git(top, ["ls-files", "-v", "-z"], timeout: 60), index.status == 0 else {
            return keep(.inspectionFailed, "Couldn't read its Git index")
        }
        for entry in index.output.components(separatedBy: "\0") {
            guard let tag = entry.first, tag.isLowercase || tag == "S" else { continue }
            if FileManager.default.fileExists(atPath: top + "/" + entry.dropFirst(2)) { changed += 1 }
        }
        if changed > 0 { return keep(.uncommitted, "\(changed) uncommitted \(changed == 1 ? "change" : "changes")") }
        let merge = mergeState(top: top, head: status.head, branch: status.branch, repository: repository)
        if let (rule, reason) = WorktreePolicy.describe(merge) { return keep(rule, reason) }
        if case .merged(let evidence) = merge { status.evidence = evidence }
        status.envFiles = env.sorted(); status.otherIgnored = other.sorted()

        var measurement: TreeMeasurement
        do { measurement = try FileInspection.measure(top, allowLinks: true, skipping: ["node_modules", "target"]) }
        catch { return keep(.inspectionFailed, "Couldn't inspect its files") }
        status.bytes = builds + measurement.bytes
        var used = [measurement.latestFileWrite] + own.map(\.latestWrite)
        for name in ["index", "HEAD"] {
            if let value = try? FileInspection.metadata(directories.gitDir + "/" + name) { used.append(FileInspection.date(value)) }
        }
        if let log = try? Command.git(top, ["log", "-1", "--format=%ct"]), log.status == 0,
           let seconds = Double(log.output.trimmingCharacters(in: .whitespacesAndNewlines)) {
            used.append(Date(timeIntervalSince1970: seconds))
        }
        let lastUsed = used.max() ?? .distantPast
        status.lastUsed = lastUsed
        let wait = Double(WorktreePolicy.unusedDays) * 86400 - now.timeIntervalSince(lastUsed)
        if wait > 0 {
            let days = max(Int(ceil(wait / 86400)), 1)
            return keep(.recentlyUsed, "Merged, can go in \(days) \(days == 1 ? "day" : "days")")
        }
        // A repository anywhere inside is real work that `git worktree remove` would delete without complaint, and Git's
        // status can't be relied on to show it. This walks everything, so it runs only for worktrees that passed the rest.
        switch Self.containsRepository(top) {
        case true?: return keep(.nestedWorktree, "Contains another repository")
        case false?: break
        case nil: return keep(.inspectionFailed, "Couldn't check its folders")
        }
        status.verdict = other.isEmpty ? .ready : .needsLook
        return status
    }

    /// `git worktree remove` honors the repository's status settings too, so they are overridden. Never `--force`.
    static func removeArguments(top: String) -> [String] {
        ["-c", "status.showUntrackedFiles=normal", "worktree", "remove", top]
    }

    /// Removing a worktree drops its HEAD, which may be all that holds a squash-merged commit once its branch is gone.
    /// A private ref keeps that commit from garbage collection so Restore keeps working. Remote branches can be pruned, so only
    /// local branches, tags, and shared branches count as already holding it.
    func preserveCommit(top: String, head: String, repository: RepositoryFacts) throws {
        let holders = ["refs/heads", "refs/tags"] + repository.sharedNames.map { "refs/remotes/origin/\($0)" }
        let held = try Command.git(top, ["for-each-ref", "--count=1", "--contains", head, "--format=%(refname)"] + holders)
        guard held.status == 0 else { throw HeadroomError.message("Couldn't check what holds its commit.") }
        guard held.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let saved = try Command.git(top, ["update-ref", "refs/headroom/restore/\(head)", head])
        guard saved.status == 0 else { throw HeadroomError.message("Couldn't keep its commit for Restore.") }
    }

    /// Bounded walk of a worktree for a nested `.git` or bare repository, past its own `.git` file. Links aren't followed.
    /// Returns nil when the walk can't finish, which keeps the worktree.
    static func containsRepository(_ top: String) -> Bool? {
        var stack = [top], visited = 0
        while let directory = stack.popLast() {
            guard let entries = try? FileInspection.listing(directory) else { return nil }
            if directory != top {
                if entries.contains(where: { $0.name == ".git" }) { return true }
                // A bare repository has no `.git`. These three are what Git itself looks for.
                if entries.contains(where: { $0.name == "HEAD" && !$0.directory }),
                   entries.contains(where: { $0.name == "objects" && $0.directory }),
                   entries.contains(where: { $0.name == "refs" && $0.directory }) { return true }
            }
            for entry in entries {
                visited += 1
                if visited > 2_000_000 { return nil }
                guard entry.directory, !(directory == top && entry.name == ".git") else { continue }
                let child = directory + "/" + entry.name
                if let value = try? FileInspection.metadata(child), FileInspection.isDirectory(value) { stack.append(child) }
            }
        }
        return false
    }

    /// Merged means every commit here is in a shared branch or was part of a pull request merged into one.
    /// Git's graph and the exact pull request commit decide this. A matching branch name alone never does.
    func mergeState(top: String, head: String, branch: String?, repository: RepositoryFacts) -> WorktreePolicy.MergeState {
        func ancestor(_ ref: String) -> Bool { (try? Command.git(top, ["merge-base", "--is-ancestor", head, ref]))?.status == 0 }
        for name in repository.sharedNames.sorted() where ancestor("refs/remotes/origin/\(name)") { return .merged("In \(name)") }
        let unpushed = (try? Command.git(top, ["rev-list", "--count", head, "--not", "--remotes"])).flatMap { $0.status == 0 ? Int($0.output.trimmingCharacters(in: .whitespacesAndNewlines)) : nil }
        guard let requests = repository.pullRequests else {
            if let unpushed, unpushed > 0 { return .onlyOnThisMac(unpushed) }
            return .unknown
        }
        let merged = requests.filter { $0.state == "MERGED" && repository.sharedNames.contains($0.baseRefName) }
        if let exact = merged.first(where: { $0.headRefOid == head }) { return .merged("PR #\(exact.number) merged") }
        var containing: Set<String> = []
        if let refs = try? Command.git(top, ["for-each-ref", "--contains", head, "--format=%(refname)", "refs/remotes/origin"]), refs.status == 0 {
            containing = Set(refs.output.split(separator: "\n").map { String($0.dropFirst("refs/remotes/origin/".count)) })
        }
        if let branch { containing.insert(branch) }
        for request in merged where containing.contains(request.headRefName) && ancestor(request.headRefOid) {
            return .merged("Part of PR #\(request.number)")
        }
        guard let unpushed else { return .unknown }
        if unpushed > 0 { return .onlyOnThisMac(unpushed) }
        if let open = requests.first(where: { $0.state == "OPEN" && containing.contains($0.headRefName) }) { return .openPullRequest(open.number) }
        if let branch, let earlier = merged.first(where: { $0.headRefName == branch }) { return .commitsAfterMerge(earlier.number) }
        return .notMerged
    }
}
