import Foundation

/// Size and free space of one volume. A failed reading has zero capacity and is never treated as low.
public struct DiskSpace: Equatable, Sendable {
    public var capacity: Int64
    public var available: Int64
    public init(capacity: Int64, available: Int64) { self.capacity = capacity; self.available = available }
    public static func read(path: String) -> DiskSpace {
        let values = (try? FileManager.default.attributesOfFileSystem(forPath: path)) ?? [:]
        return .init(capacity: (values[.systemSize] as? NSNumber)?.int64Value ?? 0,
                     available: (values[.systemFreeSize] as? NSNumber)?.int64Value ?? 0)
    }
}

/// When free space counts as low and how much to clean. Which folders may be removed stays with the normal
/// eligibility checks: low space changes when and how much is cleaned, never what is protected.
public enum LowSpace {
    /// Decimal, like the sizes shown in the interface. The upper limit only guards the conversion to bytes.
    static func threshold(_ preferences: Preferences) -> Int64 { Int64(min(max(preferences.lowSpaceGB, 0), 1_000_000) * 1e9) }
    /// Cleaning and alerts both stop at twice the threshold, so a run buys room instead of sitting at the line.
    static func target(_ preferences: Preferences) -> Int64 { threshold(preferences) * 2 }
    public static func isLow(_ space: DiskSpace, _ preferences: Preferences) -> Bool {
        let line = threshold(preferences)
        return line > 0 && space.capacity > 0 && space.available < line
    }
    /// The largest folders that bring free space to the target by their estimated sizes. An estimate that falls short
    /// is corrected by the next check, which measures free space again.
    static func selection(from eligible: [Artifact], space: DiskSpace, preferences: Preferences) -> [Artifact] {
        var needed = target(preferences) - space.available, chosen: [Artifact] = []
        for artifact in eligible.sorted(by: { $0.bytes > $1.bytes }) where needed > 0 {
            chosen.append(artifact); needed -= artifact.bytes
        }
        return chosen
    }
}

/// Decides when low space is worth interrupting someone: once when it starts, again if free space halves or a day
/// passes, and from scratch only after free space recovers past the target.
public struct LowSpaceAlerts: Sendable {
    public static let repeatAfter: TimeInterval = 86400
    private var last: (date: Date, available: Int64)?
    public init() {}
    public mutating func shouldNotify(_ space: DiskSpace, preferences: Preferences, now: Date) -> Bool {
        guard LowSpace.isLow(space, preferences) else {
            if LowSpace.threshold(preferences) == 0 || (space.capacity > 0 && space.available >= LowSpace.target(preferences)) { last = nil }
            return false
        }
        if let last, now.timeIntervalSince(last.date) < Self.repeatAfter, space.available >= last.available / 2 { return false }
        last = (now, space.available)
        return true
    }
}
