import Foundation

public struct WatchedRoot: Codable, Identifiable, Equatable, Sendable {
    public var id: String { path }
    public var path: String
    public var automatic: Bool
    public init(path: String, automatic: Bool = false) {
        self.path = URL(fileURLWithPath: path).standardizedFileURL.path
        self.automatic = automatic
    }
}

public struct Preferences: Codable, Equatable, Sendable {
    public var roots: [WatchedRoot] = []
    /// Projects or whole worktrees the user asked to keep. Matches the path and everything below it.
    public var pinned: Set<String> = []
    public var keepHours: Double = 24
    public var scheduled: Bool = false
    public var intervalHours: Double = 24
    public var paused: Bool = false
    public init() {}
    public func isPinned(_ project: String) -> Bool { pinned.contains { Paths.contains($0, project) } }
}

public struct FileIdentity: Codable, Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public init(device: UInt64, inode: UInt64) { self.device = device; self.inode = inode }
}

/// Each kind is an adapter with its own positive evidence. The central policy and executor keep authority.
public enum ArtifactKind: String, Codable, CaseIterable, Sendable {
    case cargo, node
    public var directory: String { self == .cargo ? "target" : "node_modules" }
    public var manifest: String { self == .cargo ? "Cargo.toml" : "package.json" }
    /// Node installs legitimately contain symbolic links (`.bin`, workspace packages). They are removed, never followed.
    var removesLinks: Bool { self == .node }
}

public struct WorktreeInfo: Codable, Equatable, Sendable {
    public var top: String
    /// Display name of the repository shared by all of its worktrees.
    public var repository: String
    public var branch: String?
    public var isMain: Bool
    public var changedFiles: Int
    public var lastCommit: Date?
    public init(top: String, repository: String, branch: String?, isMain: Bool, changedFiles: Int, lastCommit: Date?) {
        self.top = top; self.repository = repository; self.branch = branch
        self.isMain = isMain; self.changedFiles = changedFiles; self.lastCommit = lastCommit
    }
}

public struct Artifact: Codable, Identifiable, Equatable, Sendable {
    public var id: String { path }
    public var kind: ArtifactKind
    public var project: String
    public var path: String
    public var root: String
    public var bytes: Int64
    public var files: Int
    public var latestWrite: Date
    public var identity: FileIdentity
    public var reasons: [String]
    public var firstObserved: Date
    public var worktree: WorktreeInfo?
    public var eligible: Bool { reasons.isEmpty }
    public var name: String { URL(fileURLWithPath: project).lastPathComponent }
    /// Output path relative to its worktree, e.g. `packages/web/node_modules`.
    public var relativePath: String {
        guard let top = worktree?.top, Paths.contains(top, path), path != top else { return kind.directory }
        return String(path.dropFirst(top.count + 1))
    }
    public init(kind: ArtifactKind = .cargo, project: String, path: String, root: String, bytes: Int64, files: Int, latestWrite: Date, identity: FileIdentity, reasons: [String], firstObserved: Date, worktree: WorktreeInfo? = nil) {
        self.kind = kind; self.project = project; self.path = path; self.root = root; self.bytes = bytes; self.files = files
        self.latestWrite = latestWrite; self.identity = identity; self.reasons = reasons; self.firstObserved = firstObserved
        self.worktree = worktree
    }
}

public struct Inventory: Codable, Sendable {
    public var artifacts: [Artifact]
    public var issues: [String]
    public var scannedAt: Date
    public var capacity: Int64
    public var available: Int64
    public var protectedCaches: [String]
    public var volume: String
    public init(artifacts: [Artifact], issues: [String], scannedAt: Date, capacity: Int64, available: Int64, protectedCaches: [String], volume: String = "") {
        self.artifacts = artifacts; self.issues = issues; self.scannedAt = scannedAt
        self.capacity = capacity; self.available = available; self.protectedCaches = protectedCaches; self.volume = volume
    }
    public static let empty = Inventory(artifacts: [], issues: [], scannedAt: .distantPast, capacity: 0, available: 0, protectedCaches: [])
}

public struct CleanupPlan: Codable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let candidates: [Artifact]
    public let preferences: Preferences
    public let automatic: Bool
    public var bytes: Int64 { candidates.reduce(0) { $0 + $1.bytes } }
}

public struct HistoryEntry: Codable, Identifiable, Sendable {
    public var id: String
    public var date: Date
    public var path: String
    public var outcome: String
    public var detail: String
    public var bytes: Int64
    /// Groups the entries of one cleanup plan.
    public var run: String
    public var automatic: Bool
    public init(id: String, date: Date, path: String, outcome: String, detail: String, bytes: Int64, run: String, automatic: Bool) {
        self.id = id; self.date = date; self.path = path; self.outcome = outcome
        self.detail = detail; self.bytes = bytes; self.run = run; self.automatic = automatic
    }
}

public struct SpaceSample: Codable, Sendable {
    public var date: Date
    public var capacity: Int64
    public var available: Int64
    public init(date: Date, capacity: Int64, available: Int64) { self.date = date; self.capacity = capacity; self.available = available }
}

public enum HeadroomError: LocalizedError {
    case message(String)
    public var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}

public enum Paths {
    public static func contains(_ parent: String, _ child: String) -> Bool {
        func physical(_ path: String) -> String { path.hasPrefix("/var/") || path.hasPrefix("/tmp/") ? "/private" + path : path }
        let parent = physical(parent), child = physical(child)
        return child == parent || child.hasPrefix(parent.hasSuffix("/") ? parent : parent + "/")
    }
    public static var defaultState: URL {
        if let override = ProcessInfo.processInfo.environment["HEADROOM_STATE_DIR"], override.hasPrefix("/") {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Headroom", isDirectory: true)
    }
    public static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
