import Foundation
import HeadroomCore

enum Format {
    /// Decimal units, like Finder. Returns the number and unit separately for large displays.
    static func parts(_ bytes: Int64) -> (number: String, unit: String) {
        let value = Double(max(bytes, 0))
        if value >= 1e12 { return (String(format: "%.2f", value / 1e12), "TB") }
        if value >= 1e9 || value == 0 { return (String(format: "%.1f", value / 1e9), "GB") }
        if value >= 1e6 { return (String(format: "%.0f", value / 1e6), "MB") }
        return (String(format: "%.0f", value / 1e3), "KB")
    }
    static func bytes(_ bytes: Int64) -> String { let p = parts(bytes); return p.number + " " + p.unit }
    /// Compact form for dense logs, e.g. `14.2G`.
    static func compact(_ bytes: Int64) -> String { let p = parts(bytes); return p.number + String(p.unit.prefix(1)) }
    static func age(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(now.timeIntervalSince(date), 0)
        if seconds < 3600 { return "\(max(Int(seconds / 60), 1))m" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86400))d"
    }
    static func home(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
    static func hours(_ hours: Double) -> String { "\(Int(hours)) h" }
}

enum Reason {
    /// The reason most worth showing first: live activity beats configuration findings.
    static func primary(_ reasons: [String]) -> String? {
        let order = ["In use by", "A process has", "Cargo holds", "Pinned", "Git worktree is locked", "Output was written", "Unexpected items"]
        return reasons.min { rank($0, order) < rank($1, order) }
    }
    private static func rank(_ reason: String, _ order: [String]) -> Int { order.firstIndex { reason.hasPrefix($0) } ?? order.count }

    static func short(_ reason: String) -> String {
        if reason.hasPrefix("In use by ") {
            return "in use by " + reason.dropFirst(10).replacingOccurrences(of: " (pid ", with: " · pid ").replacingOccurrences(of: ").", with: "")
        }
        let table: [(String, String)] = [
            ("A process has", "in use by a process"), ("Cargo holds", "cargo build running"), ("Pinned", "kept by you"),
            ("Git worktree is locked", "worktree locked"), ("node_modules is not ignored", "not ignored by Git"),
            ("No lockfile", "no lockfile"), ("No installed packages", "no installed packages"),
            ("Cargo output evidence", "not a standard Cargo build"), ("No Cargo fingerprints", "not a standard Cargo build"),
            ("Process inspection is incomplete", "process check incomplete"), ("Output contains a symbolic link", "contains links"),
            ("Project is not in an inspectable Git", "not in a Git worktree"), ("Output contains tracked", "tracked by Git"),
            ("Shared compiler", "shared cache"), ("Cargo output configuration", "custom Cargo target-dir"),
        ]
        if let match = table.first(where: { reason.hasPrefix($0.0) }) { return match.1 }
        if reason.hasPrefix("Output was written within the last ") {
            return "built in the last " + reason.dropFirst(35).replacingOccurrences(of: " hours.", with: " h")
        }
        if reason.hasPrefix("Unexpected items in target: ") { return "contains " + reason.dropFirst(28).dropLast() }
        let trimmed = reason.hasSuffix(".") ? String(reason.dropLast()) : reason
        return trimmed.prefix(1).lowercased() + trimmed.dropFirst()
    }
}

extension Artifact {
    /// A worktree-qualified label such as `ledger/visits-sync/target`.
    var label: String {
        let tree = worktree.map { $0.branch ?? URL(fileURLWithPath: $0.top).lastPathComponent } ?? name
        return tree + "/" + relativePath
    }
}
