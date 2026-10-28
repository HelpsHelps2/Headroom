import Foundation

public struct Scanner: Sendable {
    public let home: String
    public init(home: String = FileManager.default.homeDirectoryForCurrentUser.path) { self.home = home }
    public var protectedCaches: [String] {
        var paths = [home + "/.cargo", home + "/Library/Caches/Mozilla.sccache", home + "/Library/Caches/sccache", home + "/.cache/sccache"]
        for key in ["SCCACHE_DIR", "CARGO_HOME"] {
            if let value = ProcessInfo.processInfo.environment[key], value.hasPrefix("/") { paths.append(value) }
        }
        return paths
    }
    public func scan(preferences: Preferences, activity: ActivitySnapshot, now: Date = Date()) -> Inventory {
        let fm = FileManager.default
        var artifacts: [Artifact] = [], issues: [String] = []
        var visited: Set<String> = []
        let skip: Set<String> = [".git", "node_modules", ".next", ".build", "DerivedData", "Pods", ".Trash", "registry", "Mozilla.sccache", "sccache"]
        for root in preferences.roots.sorted(by: { $0.path.count < $1.path.count }) {
            guard let value = try? FileInspection.metadata(root.path), FileInspection.isDirectory(value),
                  URL(fileURLWithPath: root.path).resolvingSymlinksInPath().path == root.path else {
                issues.append("Folder unavailable or linked: \(root.path)"); continue
            }
            var stack = [root.path]
            while let directory = stack.popLast() {
                if Task<Never, Never>.isCancelled { issues.append("Scan cancelled."); break }
                guard visited.insert(directory).inserted else { continue }
                if visited.count > 100_000 { issues.append("Scan reached the directory limit; select a narrower development folder."); stack.removeAll(); break }
                if protectedCaches.contains(where: { Paths.contains($0, directory) }) { continue }
                if directory != root.path, skip.contains(URL(fileURLWithPath: directory).lastPathComponent) { continue }
                do {
                    let names = try fm.contentsOfDirectory(atPath: directory)
                    if names.contains("Cargo.toml"), names.contains("target") {
                        let artifact = try inspect(project: directory, root: root.path, preferences: preferences, activity: activity, now: now)
                        artifacts.append(artifact)
                    }
                    for name in names where !skip.contains(name) && name != "target" {
                        let path = directory + "/" + name
                        if let metadata = try? FileInspection.metadata(path), FileInspection.isDirectory(metadata), metadata.st_dev == value.st_dev {
                            stack.append(path)
                        }
                    }
                } catch { issues.append("\(directory): \(error.localizedDescription)") }
            }
        }
        if let failure = activity.failure { issues.append(failure) }
        let diskPath = preferences.roots.first?.path ?? home
        let space = (try? fm.attributesOfFileSystem(forPath: diskPath)) ?? [:]
        return .init(artifacts: artifacts.sorted { $0.bytes > $1.bytes }, issues: Array(Set(issues)).sorted(), scannedAt: now,
                     capacity: (space[.systemSize] as? NSNumber)?.int64Value ?? 0,
                     available: (space[.systemFreeSize] as? NSNumber)?.int64Value ?? 0,
                     protectedCaches: protectedCaches)
    }
    func inspect(project: String, root: String, preferences: Preferences, activity: ActivitySnapshot, now: Date) throws -> Artifact {
        let target = project + "/target"
        var reasons: [String] = []
        var measurement = TreeMeasurement(identity: .init(device: 0, inode: 0))
        do { measurement = try FileInspection.measure(target) }
        catch { reasons.append(error.localizedDescription) }
        if preferences.pinned.contains(project) { reasons.append("Pinned by you.") }
        if let reason = activity.protection(for: project, target: target) { reasons.append(reason) }
        if measurement.latestWrite > now.addingTimeInterval(-preferences.keepHours * 3600) { reasons.append("Build output was written within the last \(Int(preferences.keepHours)) hours.") }
        if protectedCaches.contains(where: { Paths.contains($0, target) || Paths.contains(target, $0) }) { reasons.append("Shared compiler or Cargo cache is protected.") }
        if URL(fileURLWithPath: project).resolvingSymlinksInPath().path != project { reasons.append("Project path contains a symbolic link.") }
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
            let allowed: Set<String> = ["debug", "release", ".rustc_info.json", "CACHEDIR.TAG", ".DS_Store"]
            if !names.isSubset(of: allowed) { reasons.append("Output contains an unsupported layout or unexpected top-level files.") }
            let marker = try String(contentsOfFile: target + "/.rustc_info.json", encoding: .utf8)
            guard let data = marker.data(using: .utf8), (try JSONSerialization.jsonObject(with: data)) is [String: Any] else {
                throw BurrowError.message("Missing valid Cargo build evidence.")
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
        do {
            let git = try Command.git(project, ["rev-parse", "--show-toplevel"])
            let rawTop = git.output.trimmingCharacters(in: .whitespacesAndNewlines)
            let top = URL(fileURLWithPath: rawTop).resolvingSymlinksInPath().path
            guard git.status == 0, !rawTop.isEmpty, Paths.contains(top, project) else { throw BurrowError.message("Project is not in an inspectable Git worktree. \(git.error) [\(rawTop)]") }
            if let reason = activity.protection(for: top, target: target), !reasons.contains(reason) { reasons.append(reason) }
            let relative = String(target.dropFirst(top.count + 1))
            let tracked = try Command.git(top, ["ls-files", "-z", "--", relative])
            if tracked.status != 0 || !tracked.output.isEmpty { reasons.append("Output contains tracked files or tracked-file inspection failed.") }
            let list = try Command.git(top, ["worktree", "list", "--porcelain", "-z"])
            guard list.status == 0 else { throw BurrowError.message("Cannot inspect Git worktree locks.") }
            for block in list.output.components(separatedBy: "\0\0") {
                let fields = block.components(separatedBy: "\0")
                if fields.contains(where: { $0.hasPrefix("worktree ") && Paths.contains(String($0.dropFirst(9)), top) && Paths.contains(top, String($0.dropFirst(9))) }), fields.contains(where: { $0 == "locked" || $0.hasPrefix("locked ") }) {
                    reasons.append("Git worktree is locked.")
                }
            }
        } catch { reasons.append(error.localizedDescription) }
        do { let locks = try CargoLocks(target: target); withExtendedLifetime(locks) {} }
        catch { reasons.append(error.localizedDescription) }
        return .init(project: project, path: target, root: root, bytes: measurement.bytes, files: measurement.files,
                     latestWrite: measurement.latestWrite, identity: measurement.identity, reasons: Array(Set(reasons)).sorted(), firstObserved: now)
    }
}
