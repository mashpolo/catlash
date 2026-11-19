import Foundation

struct StorageUsage: Sendable {
    var sizes = [Int64](repeating: 0, count: 5)
    var total: Int64 { sizes.reduce(0, +) }

    static func measure(profiles: URL, snapshots: URL) throws -> Self {
        let profiles = profiles.resolvingSymlinksInPath().standardizedFileURL
        let snapshots = snapshots.resolvingSymlinksInPath().standardizedFileURL
        var result = Self()
        try enumerate(profiles) { file, size in
            let path = file.standardizedFileURL.pathComponents.dropFirst(profiles.pathComponents.count).first
            switch path {
            case "yaml": result.sizes[0] += size
            case "ResourceLinks": result.sizes[1] += size
            case "SyncState": result.sizes[3] += size
            default: result.sizes[4] += size
            }
        }
        try enumerate(snapshots) { _, size in result.sizes[2] += size }
        return result
    }

    private static func enumerate(_ root: URL, collect: (URL, Int64) -> Void) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: root.path) else { return }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        var readError: Error?
        guard let files = manager.enumerator(at: root, includingPropertiesForKeys: Array(keys), errorHandler: { _, error in
            readError = error
            return false
        }) else { throw CocoaError(.fileReadUnknown) }
        for case let file as URL in files {
            let values = try file.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true { files.skipDescendants(); continue }
            if values.isRegularFile == true { collect(file, Int64(values.fileSize ?? 0)) }
        }
        if let readError { throw readError }
    }
}
