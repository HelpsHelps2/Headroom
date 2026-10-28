import Foundation
import Darwin

struct CommandResult { var status: Int32; var output: String; var error: String }

enum Command {
    static func run(_ executable: String, _ arguments: [String], at directory: String? = nil) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_COUNT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["LC_ALL"] = "C"
        for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES"] { environment.removeValue(forKey: key) }
        process.environment = environment
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temp) }
        let out = temp.appendingPathComponent("out"), err = temp.appendingPathComponent("err")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        FileManager.default.createFile(atPath: err.path, contents: nil)
        let outHandle = try FileHandle(forWritingTo: out), errHandle = try FileHandle(forWritingTo: err)
        defer { try? outHandle.close(); try? errHandle.close() }
        process.standardOutput = outHandle; process.standardError = errHandle
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        if exited.wait(timeout: .now() + 15) == .timedOut, process.isRunning { process.terminate(); usleep(50_000); if process.isRunning { kill(process.processIdentifier, SIGKILL) }; process.waitUntilExit(); throw HeadroomError.message("Inspection timed out: \(URL(fileURLWithPath: executable).lastPathComponent).") }
        process.waitUntilExit()
        return .init(status: process.terminationStatus, output: String(decoding: try Data(contentsOf: out), as: UTF8.self), error: String(decoding: try Data(contentsOf: err), as: UTF8.self))
    }
    static func git(_ project: String, _ args: [String]) throws -> CommandResult {
        try run("/usr/bin/git", ["--no-pager", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null"] + args, at: project)
    }
}

public struct ActivitySnapshot: Sendable {
    public struct Use: Sendable {
        public var path: String
        public var pid: Int32?
        public var command: String?
    }
    public var uses: [Use]
    public var failure: String?
    public var paths: [String] { uses.map(\.path) }
    public init(paths: [String], failure: String? = nil) {
        self.uses = paths.map { Use(path: $0, pid: nil, command: nil) }; self.failure = failure
    }
    public init(uses: [Use], failure: String? = nil) { self.uses = uses; self.failure = failure }
    public static func capture() -> ActivitySnapshot {
        do {
            let result = try Command.run("/usr/sbin/lsof", ["-nP", "-a", "-u", String(getuid()), "-Fpcn"])
            guard result.status == 0, result.error.isEmpty else {
                return .init(paths: [], failure: "Process inspection is incomplete. \(result.error.prefix(180))")
            }
            var uses: [Use] = [], pid: Int32?, command: String?
            for line in result.output.split(separator: "\n") {
                switch line.first {
                case "p": pid = Int32(line.dropFirst()); command = nil
                case "c": command = String(line.dropFirst())
                case "n" where line.dropFirst().hasPrefix("/"): uses.append(.init(path: String(line.dropFirst()), pid: pid, command: command))
                default: break
                }
            }
            var names: [Int32: String] = [:]
            for index in uses.indices {
                guard let pid = uses[index].pid else { continue }
                if names[pid] == nil { names[pid] = displayName(pid: pid, command: uses[index].command) }
                uses[index].command = names[pid]
            }
            return .init(uses: uses)
        } catch { return .init(paths: [], failure: error.localizedDescription) }
    }
    /// Some tools install versioned binaries (`…/claude/versions/2.1.312`); name them by their install folder instead.
    static func displayName(pid: Int32, command: String?) -> String? {
        if let command, command.contains(where: \.isLetter) { return command }
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return command }
        let parts = String(cString: buffer).split(separator: "/").reversed()
        return parts.first(where: { $0.contains(where: \.isLetter) && $0 != "versions" }).map(String.init) ?? command
    }
    func protection(for project: String, target: String) -> String? {
        if let failure { return failure }
        guard let use = uses.first(where: { Paths.contains(project, $0.path) || Paths.contains(target, $0.path) }) else { return nil }
        if let command = use.command, let pid = use.pid { return "In use by \(command) (pid \(pid))." }
        return "A process has a working directory or open file in this project."
    }
}

struct TreeMeasurement {
    var bytes: Int64 = 0
    var files: Int = 0
    var latestWrite: Date = .distantPast
    var identity: FileIdentity
}

enum FileInspection {
    static func metadata(_ path: String) throws -> stat {
        var value = stat()
        guard lstat(path, &value) == 0 else { throw HeadroomError.message("Cannot inspect \(path): \(String(cString: strerror(errno)))") }
        return value
    }
    static func identity(_ value: stat) -> FileIdentity { .init(device: UInt64(value.st_dev), inode: UInt64(value.st_ino)) }
    static func isDirectory(_ value: stat) -> Bool { value.st_mode & S_IFMT == S_IFDIR }
    static func date(_ value: stat) -> Date { Date(timeIntervalSince1970: Double(value.st_mtimespec.tv_sec) + Double(value.st_mtimespec.tv_nsec) / 1e9) }
    /// Allocated bytes of files that only this tree references. Hard-linked files (package stores) are not counted:
    /// deleting this copy does not free them. Links are counted as entries but never followed.
    static func measure(_ path: String, allowLinks: Bool = false) throws -> TreeMeasurement {
        let root = try metadata(path)
        guard isDirectory(root) else { throw HeadroomError.message("Output is not a regular directory (links are protected).") }
        var result = TreeMeasurement(identity: identity(root))
        result.latestWrite = date(root)
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw HeadroomError.message("Cannot open \(path): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, identity(opened) == result.identity else { throw HeadroomError.message("Output changed during inspection.") }
        try walk(fd, device: root.st_dev, allowLinks: allowLinks, into: &result)
        return result
    }
    private static func walk(_ fd: Int32, device: dev_t, allowLinks: Bool, into result: inout TreeMeasurement) throws {
        for name in try entries(fd) {
            var value = stat()
            guard fstatat(fd, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else { throw HeadroomError.message("Cannot inspect \(name): \(String(cString: strerror(errno)))") }
            let link = value.st_mode & S_IFMT == S_IFLNK
            guard !link || allowLinks else { throw HeadroomError.message("Output contains a symbolic link; review it manually.") }
            guard link || value.st_mode & S_IFMT == S_IFREG || isDirectory(value) else { throw HeadroomError.message("Output contains a special filesystem object.") }
            guard value.st_dev == device else { throw HeadroomError.message("Output crosses a filesystem boundary.") }
            result.latestWrite = max(result.latestWrite, date(value))
            result.files += 1
            guard result.files <= 2_000_000 else { throw HeadroomError.message("Output exceeds this build's inspection limit.") }
            if isDirectory(value) {
                let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard child >= 0 else { throw HeadroomError.message("Cannot open \(name): \(String(cString: strerror(errno)))") }
                defer { close(child) }
                try walk(child, device: device, allowLinks: allowLinks, into: &result)
            } else if !link, value.st_nlink <= 1 { result.bytes += Int64(value.st_blocks) * 512 }
        }
    }
    /// Names in an opened directory. The directory stream is closed before returning so deep trees hold one descriptor per level.
    static func entries(_ fd: Int32) throws -> [String] {
        guard let directory = fdopendir(dup(fd)) else { throw HeadroomError.message("Cannot read directory: \(String(cString: strerror(errno)))") }
        defer { closedir(directory) }
        var names: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != ".", name != ".." { names.append(name) }
        }
        return names
    }
    /// Directory listing with entry types from readdir, avoiding a stat call per file during discovery.
    static func listing(_ path: String) throws -> [(name: String, directory: Bool)] {
        guard let directory = opendir(path) else { throw HeadroomError.message("Cannot read \(path): \(String(cString: strerror(errno)))") }
        defer { closedir(directory) }
        var result: [(String, Bool)] = []
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            let type = entry.pointee.d_type
            let isDirectory = type == DT_DIR || (type == DT_UNKNOWN && (try? metadata(path + "/" + name)).map(FileInspection.isDirectory) == true)
            result.append((name, isDirectory))
        }
        return result
    }
}

/// A value shared by concurrent inspection workers.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func with<T>(_ body: (inout Value) throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body(&value) }
}

final class ProcessLease {
    private var fd: Int32 = -1
    init(path: String) throws {
        fd = open(path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            if fd >= 0 { close(fd); fd = -1 }
            throw HeadroomError.message("Another Headroom operation is running. Try again when it finishes.")
        }
    }
    deinit { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
}

final class CargoLocks {
    private var descriptors: [Int32] = []
    init(target: String) throws {
        do {
            for profile in ["debug", "release"] {
                let path = target + "/" + profile + "/.cargo-lock"
                if FileManager.default.fileExists(atPath: path) {
                    let fd = open(path, O_RDWR | O_NOFOLLOW)
                    guard fd >= 0 else { throw HeadroomError.message("Cannot inspect Cargo's build lock.") }
                    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw HeadroomError.message("Cargo holds a build lock.") }
                    descriptors.append(fd)
                }
            }
        } catch { for fd in descriptors { close(fd) }; descriptors = []; throw error }
    }
    deinit { for fd in descriptors { flock(fd, LOCK_UN); close(fd) } }
}
