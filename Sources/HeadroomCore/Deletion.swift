import Foundation
import Darwin

// All deletion is relative to opened directory descriptors. Never follow links.
enum ContainedDeletion {
    /// `removed` receives the running total of allocated bytes removed, at most every 64 MB or quarter second.
    static func remove(_ artifact: Artifact, removed: ((Int64) -> Void)? = nil) throws {
        let counter = Counter(report: removed)
        let parent = try openDirectory(artifact.project)
        guard parent >= 0 else { throw HeadroomError.message("Project directory is no longer accessible.") }
        defer { close(parent) }
        let name = artifact.kind.directory
        let target = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard target >= 0 else { throw HeadroomError.message("Output directory changed.") }
        defer { close(target) }
        var metadata = stat()
        guard fstat(target, &metadata) == 0, FileInspection.identity(metadata) == artifact.identity else { throw HeadroomError.message("Output identity changed after review.") }
        try contents(target, device: metadata.st_dev, removesLinks: artifact.kind.removesLinks, counter: counter)
        counter.flush()
        var current = stat()
        guard fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              FileInspection.identity(current) == artifact.identity else { throw HeadroomError.message("Output moved during cleanup; preserved replacement directory.") }
        guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw failure() }
    }
    private static func openDirectory(_ path: String) throws -> Int32 {
        // Foundation can report temporary URLs using macOS's /var alias. Resolve
        // only these fixed system aliases; never resolve user-controlled links.
        let physical = path.hasPrefix("/var/") || path.hasPrefix("/tmp/") ? "/private" + path : path
        var fd = open("/", O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { throw failure() }
        for component in physical.split(separator: "/") {
            let next = openat(fd, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            close(fd)
            guard next >= 0 else { throw HeadroomError.message("Cannot open parent \(component) without following links: \(String(cString: strerror(errno)))") }
            fd = next
        }
        return fd
    }
    /// Counts bytes the same way inspection measures them: allocated blocks of files only this tree references.
    final class Counter {
        let report: ((Int64) -> Void)?
        var bytes: Int64 = 0
        var reported: Int64 = 0
        var last = Date()
        init(report: ((Int64) -> Void)?) { self.report = report }
        func add(_ metadata: stat) {
            guard let report, metadata.st_nlink <= 1 else { return }
            bytes += Int64(metadata.st_blocks) * 512
            if bytes - reported >= 64 << 20 || Date().timeIntervalSince(last) >= 0.25 {
                reported = bytes; last = Date(); report(bytes)
            }
        }
        func flush() { if bytes != reported { reported = bytes; report?(bytes) } }
    }
    private static func contents(_ fd: Int32, device: dev_t, removesLinks: Bool, counter: Counter) throws {
        // Read the whole listing before unlinking: removing entries mid-iteration can make readdir skip some.
        for name in try FileInspection.entries(fd) {
            var metadata = stat()
            guard fstatat(fd, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0, metadata.st_dev == device else { throw failure() }
            if FileInspection.isDirectory(metadata) {
                let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard child >= 0 else { throw failure() }
                defer { close(child) }
                var opened = stat()
                guard fstat(child, &opened) == 0, FileInspection.identity(opened) == FileInspection.identity(metadata) else { throw HeadroomError.message("Directory changed during cleanup.") }
                try contents(child, device: device, removesLinks: removesLinks, counter: counter)
                var current = stat()
                guard fstatat(fd, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                      FileInspection.identity(current) == FileInspection.identity(metadata) else { throw HeadroomError.message("Directory was replaced during cleanup.") }
                guard unlinkat(fd, name, AT_REMOVEDIR) == 0 else { throw failure() }
            } else if metadata.st_mode & S_IFMT == S_IFLNK, removesLinks {
                // unlinkat on a link removes the link itself; its destination is never touched.
                guard unlinkat(fd, name, 0) == 0 else { throw failure() }
            } else {
                guard metadata.st_mode & S_IFMT == S_IFREG else { throw HeadroomError.message("A link or special file appeared during cleanup.") }
                guard unlinkat(fd, name, 0) == 0 else { throw failure() }
                counter.add(metadata)
            }
        }
    }
    private static func failure() -> HeadroomError { .message("Filesystem changed or denied cleanup: \(String(cString: strerror(errno)))") }
}
