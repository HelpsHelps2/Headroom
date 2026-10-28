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
        try process.run()
        let deadline = Date().addingTimeInterval(15)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { process.terminate(); usleep(50_000); if process.isRunning { kill(process.processIdentifier, SIGKILL) }; process.waitUntilExit(); throw BurrowError.message("Inspection timed out: \(URL(fileURLWithPath: executable).lastPathComponent).") }
        process.waitUntilExit()
        return .init(status: process.terminationStatus, output: String(decoding: try Data(contentsOf: out), as: UTF8.self), error: String(decoding: try Data(contentsOf: err), as: UTF8.self))
    }
    static func git(_ project: String, _ args: [String]) throws -> CommandResult {
        try run("/usr/bin/git", ["--no-pager", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null"] + args, at: project)
    }
}

public struct ActivitySnapshot: Sendable {
    public var paths: [String]
    public var failure: String?
    public init(paths: [String], failure: String? = nil) { self.paths = paths; self.failure = failure }
    public static func capture() -> ActivitySnapshot {
        do {
            let result = try Command.run("/usr/sbin/lsof", ["-nP", "-a", "-u", String(getuid()), "-Fpn"])
            guard result.status == 0, result.error.isEmpty else {
                return .init(paths: [], failure: "Process inspection is incomplete. \(result.error.prefix(180))")
            }
            let paths = result.output.split(separator: "\n").compactMap { line -> String? in
                guard line.hasPrefix("n/") else { return nil }
                return String(line.dropFirst())
            }
            return .init(paths: paths)
        } catch { return .init(paths: [], failure: error.localizedDescription) }
    }
    func protection(for project: String, target: String) -> String? {
        if let failure { return failure }
        if paths.contains(where: { Paths.contains(project, $0) || Paths.contains(target, $0) }) {
            return "A process has a working directory or open file in this project."
        }
        return nil
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
        guard lstat(path, &value) == 0 else { throw BurrowError.message("Cannot inspect \(path): \(String(cString: strerror(errno)))") }
        return value
    }
    static func identity(_ value: stat) -> FileIdentity { .init(device: UInt64(value.st_dev), inode: UInt64(value.st_ino)) }
    static func isDirectory(_ value: stat) -> Bool { value.st_mode & S_IFMT == S_IFDIR }
    static func date(_ value: stat) -> Date { Date(timeIntervalSince1970: Double(value.st_mtimespec.tv_sec) + Double(value.st_mtimespec.tv_nsec) / 1e9) }
    static func measure(_ path: String) throws -> TreeMeasurement {
        let root = try metadata(path)
        guard isDirectory(root) else { throw BurrowError.message("Output is not a regular directory (links are protected).") }
        var result = TreeMeasurement(identity: identity(root))
        result.latestWrite = date(root)
        let fm = FileManager.default
        var stack = [path]
        while let directory = stack.popLast() {
            for name in try fm.contentsOfDirectory(atPath: directory) {
                let child = directory + "/" + name
                let value = try metadata(child)
                guard value.st_mode & S_IFMT != S_IFLNK else { throw BurrowError.message("Output contains a symbolic link; review it manually.") }
                guard value.st_mode & S_IFMT == S_IFREG || isDirectory(value) else { throw BurrowError.message("Output contains a special filesystem object.") }
                guard value.st_dev == root.st_dev else { throw BurrowError.message("Output crosses a filesystem boundary.") }
                result.latestWrite = max(result.latestWrite, date(value))
                result.files += 1
                guard result.files <= 1_000_000 else { throw BurrowError.message("Output exceeds this build's inspection limit.") }
                if isDirectory(value) { stack.append(child) }
                else { result.bytes += Int64(value.st_blocks) * 512 }
            }
        }
        return result
    }
}

final class ProcessLease {
    private var fd: Int32 = -1
    init(path: String) throws {
        fd = open(path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            if fd >= 0 { close(fd); fd = -1 }
            throw BurrowError.message("Another Burrow operation is running. Try again when it finishes.")
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
                    guard fd >= 0 else { throw BurrowError.message("Cannot inspect Cargo's build lock.") }
                    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw BurrowError.message("Cargo holds a build lock.") }
                    descriptors.append(fd)
                }
            }
        } catch { for fd in descriptors { close(fd) }; descriptors = []; throw error }
    }
    deinit { for fd in descriptors { flock(fd, LOCK_UN); close(fd) } }
}
