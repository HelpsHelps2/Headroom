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
    public var pinned: Set<String> = []
    public var keepHours: Double = 24
    public var scheduled: Bool = false
    public var intervalHours: Double = 24
    public var paused: Bool = false
    public init() {}
}

public struct FileIdentity: Codable, Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public init(device: UInt64, inode: UInt64) { self.device = device; self.inode = inode }
}

public struct Artifact: Codable, Identifiable, Equatable, Sendable {
    public var id: String { path }
    public var project: String
    public var path: String
    public var root: String
    public var bytes: Int64
    public var files: Int
    public var latestWrite: Date
    public var identity: FileIdentity
    public var reasons: [String]
    public var firstObserved: Date
    public var eligible: Bool { reasons.isEmpty }
    public var name: String { URL(fileURLWithPath: project).lastPathComponent }
    public init(project: String, path: String, root: String, bytes: Int64, files: Int, latestWrite: Date, identity: FileIdentity, reasons: [String], firstObserved: Date) {
        self.project = project; self.path = path; self.root = root; self.bytes = bytes; self.files = files
        self.latestWrite = latestWrite; self.identity = identity; self.reasons = reasons; self.firstObserved = firstObserved
    }
}

public struct Inventory: Codable, Sendable {
    public var artifacts: [Artifact]
    public var issues: [String]
    public var scannedAt: Date
    public var capacity: Int64
    public var available: Int64
    public var protectedCaches: [String]
    public init(artifacts: [Artifact], issues: [String], scannedAt: Date, capacity: Int64, available: Int64, protectedCaches: [String]) {
        self.artifacts = artifacts; self.issues = issues; self.scannedAt = scannedAt
        self.capacity = capacity; self.available = available; self.protectedCaches = protectedCaches
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
}

public enum BurrowError: LocalizedError {
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
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Burrow", isDirectory: true)
    }
    public static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
