import Foundation

public struct Scanner: Sendable {
    public let home: String
    public init(home: String = FileManager.default.homeDirectoryForCurrentUser.path) { self.home = home }
    public var protectedCaches: [String] {
        var paths = [home + "/.cargo", home + "/Library/Caches/Mozilla.sccache", home + "/Library/Caches/sccache", home + "/.cache/sccache",
                     home + "/.npm", home + "/Library/pnpm", home + "/.local/share/pnpm", home + "/.bun", home + "/Library/Caches/Yarn", home + "/.yarn"]
        for key in ["SCCACHE_DIR", "CARGO_HOME", "npm_config_cache", "PNPM_HOME", "BUN_INSTALL", "YARN_CACHE_FOLDER"] {
            if let value = ProcessInfo.processInfo.environment[key], value.hasPrefix("/") { paths.append(value) }
        }
        return paths
    }
    public typealias Progress = @Sendable (_ inspected: Int, _ total: Int) -> Void

    /// Walks each root until it reaches a Git worktree, then asks Git for that worktree's manifests instead of
    /// walking its source tree. Candidates are inspected concurrently.
    public func scan(preferences: Preferences, activity: ActivitySnapshot, now: Date = Date(), progress: Progress? = nil,
                     discovery: DiscoveryCache = DiscoveryCache()) -> Inventory {
        let fm = FileManager.default
        var issues: [String] = []
        var candidates: [Candidate] = []
        var worktrees: [String: String] = [:] // worktree top → scan root
        var visited: Set<String> = []
        let skip: Set<String> = [".git", "node_modules", ".next", ".build", "DerivedData", "Pods", ".Trash", "registry", "Mozilla.sccache", "sccache", ".expo", ".turbo", "target"]
        let roots = preferences.roots.sorted(by: { $0.path.count < $1.path.count })
        for root in roots {
            guard let value = try? FileInspection.metadata(root.path), FileInspection.isDirectory(value),
                  URL(fileURLWithPath: root.path).resolvingSymlinksInPath().path == root.path else {
                issues.append("Folder unavailable or linked: \(root.path)"); continue
            }
            var stack = [root.path]
            while let directory = stack.popLast() {
                if Task<Never, Never>.isCancelled { issues.append("Scan cancelled."); break }
                guard visited.insert(directory).inserted else { continue }
                if visited.count > 200_000 { issues.append("Scan reached the directory limit; select a narrower development folder."); stack.removeAll(); break }
                if protectedCaches.contains(where: { Paths.contains($0, directory) }) { continue }
                if directory != root.path, skip.contains(URL(fileURLWithPath: directory).lastPathComponent) { continue }
                do {
                    let entries = try FileInspection.listing(directory)
                    if entries.contains(where: { $0.name == ".git" }) { worktrees[directory] = root.path; continue }
                    let names = Set(entries.map(\.name))
                    for kind in ArtifactKind.allCases where names.contains(kind.manifest) && names.contains(kind.directory) {
                        candidates.append(.init(kind: kind, project: directory, root: root.path))
                    }
                    for entry in entries where entry.directory && !skip.contains(entry.name) {
                        let path = directory + "/" + entry.name
                        if let metadata = try? FileInspection.metadata(path), FileInspection.isDirectory(metadata), metadata.st_dev == value.st_dev {
                            stack.append(path)
                        }
                    }
                } catch { issues.append("\(directory): \(error.localizedDescription)") }
            }
        }
        // Linked worktrees can live anywhere, including inside another worktree's ignored folders.
        var repositories: [String: String] = [:] // common Git directory → one of its worktrees
        for top in worktrees.keys { repositories[Self.gitDirectories(top: top)?.common ?? top] = top }
        let tops = Array(repositories.values)
        let linked = Locked<[String: String]>([:])
        DispatchQueue.concurrentPerform(iterations: tops.count) { index in
            guard let list = try? Command.git(tops[index], ["worktree", "list", "--porcelain", "-z"]), list.status == 0 else { return }
            for field in list.output.components(separatedBy: "\0") where field.hasPrefix("worktree ") {
                let path = URL(fileURLWithPath: String(field.dropFirst(9))).resolvingSymlinksInPath().path
                guard let metadata = try? FileInspection.metadata(path), FileInspection.isDirectory(metadata) else { continue }
                if let root = roots.last(where: { Paths.contains($0.path, path) }) { linked.with { $0[path] = root.path } }
            }
        }
        for (path, root) in linked.with({ $0 }) where worktrees[path] == nil && !protectedCaches.contains(where: { Paths.contains($0, path) }) {
            worktrees[path] = root
        }
        let found = Locked<[Candidate]>([]), problems = Locked<[String]>([])
        let ordered = worktrees.sorted { $0.key < $1.key }
        DispatchQueue.concurrentPerform(iterations: ordered.count) { index in
            let (top, root) = ordered[index]
            do {
                let stamp = Self.indexStamp(top: top)
                if let stamp, let cached = discovery.entries.with({ $0[top] }), cached.stamp == stamp {
                    found.with { $0 += cached.candidates.map { Candidate(kind: $0.kind, project: $0.project, root: root) } }
                    return
                }
                let manifests = try self.manifests(in: top, root: root)
                if let stamp { discovery.entries.with { $0[top] = (stamp, manifests) } }
                found.with { $0 += manifests }
            }
            catch { problems.with { $0.append("\(top): \(error.localizedDescription)") } }
        }
        issues += problems.with { $0 }
        var seen: Set<String> = []
        candidates = (candidates + found.with { $0 }).filter { seen.insert($0.project + "/" + $0.kind.directory).inserted }

        let cache = WorktreeCache(), done = Locked(0), next = Locked(0)
        let results = Locked<[Artifact]>([])
        progress?(0, candidates.count)
        // A few workers keep the disk busy; more mostly add kernel contention on large trees.
        DispatchQueue.concurrentPerform(iterations: min(Self.workers, max(candidates.count, 1))) { _ in
            while true {
                let index = next.with { value -> Int in defer { value += 1 }; return value }
                guard index < candidates.count else { return }
                let candidate = candidates[index]
                if let artifact = try? inspect(kind: candidate.kind, project: candidate.project, root: candidate.root, preferences: preferences, activity: activity, now: now, cache: cache) {
                    results.with { $0.append(artifact) }
                }
                let count = done.with { $0 += 1; return $0 }
                progress?(count, candidates.count)
            }
        }
        if let failure = activity.failure { issues.append(failure) }
        let diskPath = preferences.roots.first?.path ?? home
        let space = (try? fm.attributesOfFileSystem(forPath: diskPath)) ?? [:]
        let volume = (try? URL(fileURLWithPath: diskPath).resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName ?? ""
        return .init(artifacts: results.with { $0 }.sorted { $0.bytes > $1.bytes }, issues: Array(Set(issues)).sorted(), scannedAt: now,
                     capacity: (space[.systemSize] as? NSNumber)?.int64Value ?? 0,
                     available: (space[.systemFreeSize] as? NSNumber)?.int64Value ?? 0,
                     protectedCaches: protectedCaches, volume: volume)
    }

    static let workers = 4

    /// Reads a worktree's `.git` pointer without running Git. Linked worktrees point at `<common>/worktrees/<name>`.
    static func gitDirectories(top: String) -> (gitDir: String, common: String)? {
        let dotGit = top + "/.git"
        guard let metadata = try? FileInspection.metadata(dotGit) else { return nil }
        if FileInspection.isDirectory(metadata) { return (dotGit, dotGit) }
        guard let text = try? String(contentsOfFile: dotGit, encoding: .utf8), text.hasPrefix("gitdir: ") else { return nil }
        let gitDir = URL(fileURLWithPath: text.dropFirst(8).trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: URL(fileURLWithPath: top, isDirectory: true)).standardizedFileURL
        let parent = gitDir.deletingLastPathComponent()
        return (gitDir.path, parent.lastPathComponent == "worktrees" ? parent.deletingLastPathComponent().path : gitDir.path)
    }
    /// Changes whenever files are staged, committed, or checked out in this worktree.
    static func indexStamp(top: String) -> String? {
        guard let gitDir = gitDirectories(top: top)?.gitDir else { return nil }
        let stamps = ["index", "HEAD"].map { name -> String in
            guard let value = try? FileInspection.metadata(gitDir + "/" + name) else { return "-" }
            return "\(value.st_ino):\(value.st_mtimespec.tv_sec):\(value.st_mtimespec.tv_nsec)"
        }
        return stamps.joined(separator: "|")
    }
    struct Candidate: Sendable { var kind: ArtifactKind; var project: String; var root: String }

    /// Tracked and untracked-but-not-ignored manifests in a worktree, with an output folder beside them.
    private func manifests(in top: String, root: String) throws -> [Candidate] {
        let pathspecs = ArtifactKind.allCases.map { ":(glob)**/" + $0.manifest }
        let list = try Command.git(top, ["ls-files", "-z", "--cached", "--others", "--exclude-standard", "--"] + pathspecs)
        guard list.status == 0 else { throw HeadroomError.message("Cannot list worktree files. \(list.error.prefix(160))") }
        var result: [Candidate] = []
        for file in Set(list.output.split(separator: "\0").map(String.init)) where !file.contains("node_modules/") {
            let url = URL(fileURLWithPath: top + "/" + file)
            guard let kind = ArtifactKind.allCases.first(where: { $0.manifest == url.lastPathComponent }) else { continue }
            let project = url.deletingLastPathComponent().standardizedFileURL.path
            if let metadata = try? FileInspection.metadata(project + "/" + kind.directory), FileInspection.isDirectory(metadata) {
                result.append(.init(kind: kind, project: project, root: root))
            }
        }
        return result
    }

    func inspect(kind: ArtifactKind = .cargo, project: String, root: String, preferences: Preferences, activity: ActivitySnapshot, now: Date, cache: WorktreeCache = WorktreeCache()) throws -> Artifact {
        let target = project + "/" + kind.directory
        var reasons: [String] = []
        var measurement = TreeMeasurement(identity: .init(device: 0, inode: 0))
        do { measurement = try FileInspection.measure(target, allowLinks: kind.removesLinks) }
        catch { reasons.append(error.localizedDescription) }
        if preferences.isPinned(project) { reasons.append("Pinned by you.") }
        if let reason = activity.protection(for: project, target: target) { reasons.append(reason) }
        if measurement.latestWrite > now.addingTimeInterval(-preferences.keepHours * 3600) { reasons.append(Artifact.recentReason + "\(Int(preferences.keepHours)) hours.") }
        if protectedCaches.contains(where: { Paths.contains($0, target) || Paths.contains(target, $0) }) { reasons.append("Shared compiler or package cache is protected.") }
        if URL(fileURLWithPath: project).resolvingSymlinksInPath().path != project { reasons.append("Project path contains a symbolic link.") }
        switch kind {
        case .cargo: reasons += cargoEvidence(project: project, target: target)
        case .node: reasons += nodeEvidence(target: target)
        }
        var worktree: WorktreeInfo?
        do {
            let git = try Command.git(project, ["rev-parse", "--path-format=absolute", "--show-toplevel", "--git-common-dir", "--git-dir"])
            let lines = git.output.split(separator: "\n").map(String.init)
            let rawTop = lines.first ?? ""
            let top = URL(fileURLWithPath: rawTop).resolvingSymlinksInPath().path
            guard git.status == 0, lines.count == 3, !rawTop.isEmpty, Paths.contains(top, project) else { throw HeadroomError.message("Project is not in an inspectable Git worktree. \(git.error) [\(rawTop)]") }
            if let reason = activity.protection(for: top, target: target), !reasons.contains(reason) { reasons.append(reason) }
            let relative = String(target.dropFirst(top.count + 1))
            let tracked = try Command.git(top, ["ls-files", "-z", "--", relative])
            if tracked.status != 0 || !tracked.output.isEmpty { reasons.append("Output contains tracked files or tracked-file inspection failed.") }
            if kind == .node {
                if lockfile(from: project, upTo: top) == nil { reasons.append("No lockfile found; reinstalling may not reproduce these dependencies.") }
                let ignored = try Command.git(top, ["check-ignore", "-q", "--", relative])
                if ignored.status == 1 { reasons.append("node_modules is not ignored by Git.") }
                else if ignored.status != 0 { reasons.append("Git ignore rules cannot be inspected.") }
            }
            if try cache.locked(top: top, common: lines[1]) { reasons.append("Git worktree is locked.") }
            worktree = try cache.info(top: top, common: lines[1], gitDir: lines[2])
        } catch { reasons.append(error.localizedDescription) }
        if kind == .cargo {
            do { let locks = try CargoLocks(target: target); withExtendedLifetime(locks) {} }
            catch { reasons.append(error.localizedDescription) }
        }
        return .init(kind: kind, project: project, path: target, root: root, bytes: measurement.bytes, files: measurement.files,
                     latestWrite: measurement.latestWrite, identity: measurement.identity, reasons: Array(Set(reasons)).sorted(),
                     firstObserved: now, worktree: worktree)
    }

    private func cargoEvidence(project: String, target: String) -> [String] {
        var reasons: [String] = []
        let fm = FileManager.default
        // Resolve only the local standard target. Configuration overrides remain review-only.
        var ancestors: [String] = [], current = project
        while current != "/" {
            ancestors.append(current); current = URL(fileURLWithPath: current).deletingLastPathComponent().path
        }
        for base in Array(Set(ancestors + [home])) {
            for config in [base + "/.cargo/config", base + "/.cargo/config.toml"] where fm.fileExists(atPath: config) {
                do {
                    let content = try String(contentsOfFile: config, encoding: .utf8)
                    if content.contains("target-dir") || content.contains("build-dir") || content.contains("include") {
                        reasons.append("Cargo output configuration needs review: \(config)")
                    }
                } catch { reasons.append("Cargo configuration cannot be inspected.") }
            }
        }
        for key in ["CARGO_TARGET_DIR", "CARGO_BUILD_TARGET_DIR", "CARGO_BUILD_BUILD_DIR"] where ProcessInfo.processInfo.environment[key] != nil {
            reasons.append("\(key) redirects build output; shared ownership is unresolved.")
        }
        do {
            let names = Set(try fm.contentsOfDirectory(atPath: target))
            // `tmp` is CARGO_TARGET_TMPDIR; `rust-analyzer` is the editor's private check output.
            let allowed: Set<String> = ["debug", "release", "tmp", "rust-analyzer", ".rustc_info.json", ".future-incompat-report.json", "CACHEDIR.TAG", ".DS_Store"]
            let unexpected = names.subtracting(allowed).sorted()
            if !unexpected.isEmpty { reasons.append("Unexpected items in target: \(unexpected.prefix(4).joined(separator: ", ")).") }
            let marker = try String(contentsOfFile: target + "/.rustc_info.json", encoding: .utf8)
            guard let data = marker.data(using: .utf8), (try JSONSerialization.jsonObject(with: data)) is [String: Any] else {
                throw HeadroomError.message("Missing valid Cargo build evidence.")
            }
            var fingerprint = false
            for profile in ["debug", "release"] where names.contains(profile) {
                let profileNames = Set(try fm.contentsOfDirectory(atPath: target + "/" + profile))
                if profileNames.contains(".fingerprint"), profileNames.contains("deps") { fingerprint = true }
                let directories: Set<String> = [".fingerprint", "deps", "build", "incremental", "examples", ".cargo-lock", ".DS_Store"]
                for name in profileNames where !directories.contains(name) {
                    let path = target + "/" + profile + "/" + name
                    let metadata = try FileInspection.metadata(path)
                    let ext = URL(fileURLWithPath: name).pathExtension
                    if FileInspection.isDirectory(metadata) || ["rs", "toml", "md", "txt"].contains(ext) {
                        reasons.append("Unexpected content in \(profile): \(name)")
                    }
                }
            }
            if !fingerprint { reasons.append("No Cargo fingerprints and dependency output were found.") }
        } catch { reasons.append("Cargo output evidence is incomplete: \(error.localizedDescription)") }
        return reasons
    }

    /// Positive evidence that this is a package manager's install tree rather than a hand-made folder.
    private func nodeEvidence(target: String) -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: target) else { return [] } // measure() already reported it
        let markers: Set<String> = [".package-lock.json", ".modules.yaml", ".yarn-state.yml", ".yarn-integrity", ".pnpm"]
        if !markers.isDisjoint(with: names) { return [] }
        for name in names.prefix(200) where !name.hasPrefix(".") {
            if name.hasPrefix("@") {
                let scoped = (try? fm.contentsOfDirectory(atPath: target + "/" + name)) ?? []
                if scoped.contains(where: { fm.fileExists(atPath: target + "/" + name + "/" + $0 + "/package.json") }) { return [] }
            } else if fm.fileExists(atPath: target + "/" + name + "/package.json") { return [] }
        }
        return ["No installed packages were found in node_modules."]
    }

    private func lockfile(from project: String, upTo top: String) -> String? {
        let names = ["package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml", "bun.lock", "bun.lockb"]
        var current = project
        while Paths.contains(top, current) {
            if let name = names.first(where: { FileManager.default.fileExists(atPath: current + "/" + $0) }) { return current + "/" + name }
            if current == top { break }
            current = URL(fileURLWithPath: current).deletingLastPathComponent().path
        }
        return nil
    }
}

/// Manifest locations per worktree, reused across scans until the worktree's index or HEAD changes.
/// New untracked manifests are found once something is staged or committed, or on the next uncached scan.
public final class DiscoveryCache: @unchecked Sendable {
    let entries = Locked<[String: (stamp: String, candidates: [Scanner.Candidate])]>([:])
    public init() {}
}

/// Git facts shared by every artifact in a worktree. Lives for one scan or one inspection only.
final class WorktreeCache: @unchecked Sendable {
    private let infos = Locked<[String: WorktreeInfo]>([:])
    private let lists = Locked<[String: [[String]]]>([:])

    func locked(top: String, common: String) throws -> Bool {
        var blocks = lists.with { $0[common] }
        if blocks == nil {
            let list = try Command.git(top, ["worktree", "list", "--porcelain", "-z"])
            guard list.status == 0 else { throw HeadroomError.message("Cannot inspect Git worktree locks.") }
            let parsed = list.output.components(separatedBy: "\0\0").map { $0.components(separatedBy: "\0") }
            lists.with { $0[common] = parsed }
            blocks = parsed
        }
        return (blocks ?? []).contains { fields in
            fields.contains(where: { $0.hasPrefix("worktree ") && Paths.contains(String($0.dropFirst(9)), top) && Paths.contains(top, String($0.dropFirst(9))) }) &&
                fields.contains(where: { $0 == "locked" || $0.hasPrefix("locked ") })
        }
    }

    func info(top: String, common: String, gitDir: String) throws -> WorktreeInfo {
        if let cached = infos.with({ $0[top] }) { return cached }
        let commonURL = URL(fileURLWithPath: common)
        let repository = commonURL.lastPathComponent == ".git" ? commonURL.deletingLastPathComponent().lastPathComponent : commonURL.deletingPathExtension().lastPathComponent
        let branch = try Command.git(top, ["symbolic-ref", "--short", "-q", "HEAD"])
        let status = try Command.git(top, ["status", "--porcelain", "--untracked-files=no", "--ignore-submodules"])
        let log = try Command.git(top, ["log", "-1", "--format=%ct"])
        let info = WorktreeInfo(
            top: top, repository: repository,
            branch: branch.status == 0 ? branch.output.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
            isMain: URL(fileURLWithPath: gitDir).standardizedFileURL.path == commonURL.standardizedFileURL.path,
            changedFiles: status.status == 0 ? status.output.split(separator: "\n").count : 0,
            lastCommit: log.status == 0 ? Double(log.output.trimmingCharacters(in: .whitespacesAndNewlines)).map(Date.init(timeIntervalSince1970:)) : nil)
        infos.with { $0[top] = info }
        return info
    }
}
