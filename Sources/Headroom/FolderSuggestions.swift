import Foundation

/// A folder worth watching, found on first launch so there is something to say yes to.
struct FolderSuggestion: Identifiable, Sendable {
    var id: String { path }
    let path: String
    /// The tool that creates worktrees here, when known.
    let tool: String?
    let repositories: Int
    let worktrees: Int

    var detail: String {
        var parts: [String] = []
        if worktrees > 0 { parts.append("\(worktrees) \(worktrees == 1 ? "worktree" : "worktrees")") }
        if repositories > 0 { parts.append("\(repositories) \(repositories == 1 ? "repo" : "repos")") }
        if let tool { parts.append(tool) }
        return parts.joined(separator: " · ")
    }
}

enum FolderSuggestions {
    /// Where agent tools keep worktrees, then common places people keep code.
    static let known: [(path: String, tool: String?)] = [
        (".t3/worktrees", "T3 Code"), ("conductor/workspaces", "Conductor"), (".codex/worktrees", "Codex"),
        (".cursor/worktrees", "Cursor"), (".claude/worktrees", "Claude Code"),
        ("Documents/GitHub", nil), ("GitHub", nil), ("Developer", nil), ("code", nil), ("Code", nil), ("src", nil),
        ("Projects", nil), ("projects", nil), ("dev", nil), ("repos", nil), ("workspace", nil), ("git", nil), ("work", nil),
    ]

    /// Counts Git repositories (`.git` folder) and linked worktrees (`.git` file) up to three levels down.
    /// Cheap: directory listings only, capped so a huge home folder cannot stall launch.
    static func find(home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [FolderSuggestion] {
        var seen: Set<String> = []
        return known.compactMap { entry -> FolderSuggestion? in
            let path = URL(fileURLWithPath: home + "/" + entry.path).resolvingSymlinksInPath().path
            guard !seen.contains(path.lowercased()), isDirectory(path) else { return nil }
            seen.insert(path.lowercased())
            var repositories = 0, worktrees = 0, visited = 0
            var queue = [(path, 0)]
            while !queue.isEmpty, visited < 5_000 {
                let (directory, depth) = queue.removeFirst()
                visited += 1
                var gitIsDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: directory + "/.git", isDirectory: &gitIsDirectory), directory != path {
                    if gitIsDirectory.boolValue { repositories += 1 } else { worktrees += 1 }
                    continue
                }
                guard depth < 3, let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { continue }
                for name in names where !name.hasPrefix(".") && name != "node_modules" && name != "Library" {
                    let child = directory + "/" + name
                    if isDirectory(child) { queue.append((child, depth + 1)) }
                }
            }
            guard repositories + worktrees > 0 else { return nil }
            return FolderSuggestion(path: path, tool: entry.tool, repositories: repositories, worktrees: worktrees)
        }
    }

    private static func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }
}
