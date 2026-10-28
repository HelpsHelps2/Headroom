import Foundation
import Darwin

// All deletion is relative to opened directory descriptors. Never follow links.
enum ContainedDeletion {
    static func remove(_ artifact: Artifact) throws {
        let parent = try openDirectory(artifact.project)
        guard parent >= 0 else { throw HeadroomError.message("Project directory is no longer accessible.") }
        defer { close(parent) }
        let name = artifact.kind.directory
        let target = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard target >= 0 else { throw HeadroomError.message("Output directory changed.") }
        defer { close(target) }
        var metadata = stat()
        guard fstat(target, &metadata) == 0, FileInspection.identity(metadata) == artifact.identity else { throw HeadroomError.message("Output identity changed after review.") }
        try contents(target, device: metadata.st_dev, removesLinks: artifact.kind.removesLinks)
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
    private static func contents(_ fd: Int32, device: dev_t, removesLinks: Bool) throws {
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
                try contents(child, device: device, removesLinks: removesLinks)
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
            }
        }
    }
    private static func failure() -> HeadroomError { .message("Filesystem changed or denied cleanup: \(String(cString: strerror(errno)))") }
}
