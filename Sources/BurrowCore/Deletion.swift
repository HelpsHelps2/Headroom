import Foundation
import Darwin

// All deletion is relative to opened directory descriptors. Never follow links.
enum ContainedDeletion {
    static func remove(_ artifact: Artifact) throws {
        let parent = try openDirectory(artifact.project)
        guard parent >= 0 else { throw BurrowError.message("Project directory is no longer accessible.") }
        defer { close(parent) }
        let target = openat(parent, "target", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard target >= 0 else { throw BurrowError.message("Output directory changed.") }
        defer { close(target) }
        var metadata = stat()
        guard fstat(target, &metadata) == 0, FileInspection.identity(metadata) == artifact.identity else { throw BurrowError.message("Output identity changed after review.") }
        try contents(target, device: metadata.st_dev)
        var current = stat()
        guard fstatat(parent, "target", &current, AT_SYMLINK_NOFOLLOW) == 0,
              FileInspection.identity(current) == artifact.identity else { throw BurrowError.message("Output moved during cleanup; preserved replacement directory.") }
        guard unlinkat(parent, "target", AT_REMOVEDIR) == 0 else { throw failure() }
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
            guard next >= 0 else { throw BurrowError.message("Cannot open parent \(component) without following links: \(String(cString: strerror(errno)))") }
            fd = next
        }
        return fd
    }
    private static func contents(_ fd: Int32, device: dev_t) throws {
        guard let directory = fdopendir(dup(fd)) else { throw failure() }
        defer { closedir(directory) }
        errno = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            var metadata = stat()
            guard fstatat(fd, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0, metadata.st_dev == device else { throw failure() }
            if FileInspection.isDirectory(metadata) {
                let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard child >= 0 else { throw failure() }
                defer { close(child) }
                var opened = stat()
                guard fstat(child, &opened) == 0, FileInspection.identity(opened) == FileInspection.identity(metadata) else { throw BurrowError.message("Directory changed during cleanup.") }
                try contents(child, device: device)
                var current = stat()
                guard fstatat(fd, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                      FileInspection.identity(current) == FileInspection.identity(metadata) else { throw BurrowError.message("Directory was replaced during cleanup.") }
                guard unlinkat(fd, name, AT_REMOVEDIR) == 0 else { throw failure() }
            } else {
                guard metadata.st_mode & S_IFMT == S_IFREG else { throw BurrowError.message("A link or special file appeared during cleanup.") }
                guard unlinkat(fd, name, 0) == 0 else { throw failure() }
            }
            errno = 0
        }
        if errno != 0 { throw failure() }
    }
    private static func failure() -> BurrowError { .message("Filesystem changed or denied cleanup: \(String(cString: strerror(errno)))") }
}
