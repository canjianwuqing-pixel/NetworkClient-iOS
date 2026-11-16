import Darwin
import Foundation

/// Deletes retired VPN-only files by name. Their contents are never opened.
enum VPNObsoleteDataRemoval {
    static func remove(in container: URL) throws -> Int {
        guard try isDirectory(container) else { return 0 }
        let library = container.appendingPathComponent("Library", isDirectory: true)
        let caches = library.appendingPathComponent("Caches", isDirectory: true)
        let hasCaches = try isDirectory(library) && isDirectory(caches)
        var removed = try removeFiles(in: container) { name in
            name == "tunnel-stage.json"
                || uuidFilename(name, prefix: "active-selection-")
                || uuidFilename(name, prefix: "latency-batch-")
        }
        if hasCaches {
            removed += try removeFiles(in: caches) { name in
                name == "tunnel-stage-evidence.json"
                    || name == "developer-tunnel-events.jsonl"
                    || (name.hasPrefix("route-client-") && name.hasSuffix(".json"))
            }
        }
        return removed
    }

    private static func uuidFilename(_ name: String, prefix: String) -> Bool {
        guard name.hasPrefix(prefix), name.hasSuffix(".json") else { return false }
        let value = String(name.dropFirst(prefix.count).dropLast(5))
        return UUID(uuidString: value) != nil
    }

    private static func isDirectory(_ url: URL) throws -> Bool {
        var metadata = stat()
        if lstat(url.path, &metadata) != 0 {
            if errno == ENOENT { return false }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        // Never traverse a link to an unrelated container or business directory.
        guard metadata.st_mode & S_IFMT == S_IFDIR else { throw POSIXError(.ENOTDIR) }
        return true
    }

    private static func removeFiles(in directory: URL, matching: (String) -> Bool) throws -> Int {
        let manager = FileManager.default
        var removed = 0
        for file in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where matching(file.lastPathComponent) {
            var metadata = stat()
            guard lstat(file.path, &metadata) == 0 else {
                if errno == ENOENT { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let kind = metadata.st_mode & S_IFMT
            guard kind == S_IFREG || kind == S_IFLNK else { continue }
            try manager.removeItem(at: file)
            removed += 1
        }
        return removed
    }
}
