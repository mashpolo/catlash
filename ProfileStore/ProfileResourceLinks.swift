import CryptoKit
import Foundation

public struct ProfileLinkedResource: Codable, Equatable, Identifiable, Sendable {
    public let path: String
    public let displayName: String
    public let sha256: String
    public let size: Int
    public var id: String { path }
}

public actor ProfileResourceLinks {
    private let root: URL
    public init(root: URL) { self.root = root }

    public func associate(profileID: String, path: String, displayName: String, data: Data) throws -> ProfileLinkedResource {
        guard !path.isEmpty, !displayName.isEmpty else { throw ProfileResourceLinkError.invalidAssociation }
        guard data.count <= ResourceBundleStore.maximumResourceBytes else { throw ResourceBundleError.resourceTooLarge }
        let link = ProfileLinkedResource(path: path, displayName: displayName, sha256: digest(data), size: data.count)
        return try withManifest(profileID: profileID) { manifest in
            manifest.links[path] = link
            try validate(manifest)
            let directory = root.appendingPathComponent("data", isDirectory: true)
            try coordinate(directory, writing: true) { try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true) }
            try coordinate(directory.appendingPathComponent(link.sha256), writing: true) { try write(data, to: $0) }
            return link
        }
    }

    public func list(profileID: String) throws -> [ProfileLinkedResource] {
        try withManifest(profileID: profileID) { $0.links.values.sorted { $0.path < $1.path } }
    }

    public func hasLocalResourceHistory(profileID: String) throws -> Bool {
        try withManifest(profileID: profileID) { _ in
            // Empty manifests are retained after the last association is removed.
            FileManager.default.fileExists(atPath: manifestURL(profileID: profileID).path)
        }
    }

    public func localFiles(profileID: String) throws -> [String: Data] {
        let links = try list(profileID: profileID)
        var files: [String: Data] = [:]
        for link in links {
            files[link.path] = try coordinate(root.appendingPathComponent("data").appendingPathComponent(link.sha256), writing: false) { url in
                let data = try read(url, maximum: link.size)
                guard data.count == link.size, digest(data) == link.sha256 else { throw ProfileResourceLinkError.corruptStorage }
                return data
            }
        }
        return files
    }

    public func remove(profileID: String, path: String) throws {
        try withManifest(profileID: profileID) { _ = $0.links.removeValue(forKey: path) }
    }

    public func copy(from source: String, to destination: String) throws {
        let links = try withManifest(profileID: source) { $0.links }
        try withManifest(profileID: destination) { $0.links = links }
    }

    public func delete(profileID: String) throws {
        try withManifest(profileID: profileID) { $0.links = [:] }
    }

    private struct Manifest: Codable, Equatable {
        var version = 1
        let profileID: String
        var links: [String: ProfileLinkedResource] = [:]
    }

    private func withManifest<T>(profileID: String, operation: (inout Manifest) throws -> T) throws -> T {
        guard !profileID.isEmpty else { throw ProfileResourceLinkError.invalidAssociation }
        try coordinate(root, writing: true) { try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true) }
        let url = manifestURL(profileID: profileID)
        return try coordinate(url, writing: true) { location in
            var manifest: Manifest
            if FileManager.default.fileExists(atPath: location.path) {
                let data = try read(location, maximum: ResourceBundleStore.maximumResourceBytes)
                guard let decoded = try? JSONDecoder().decode(Manifest.self, from: data), decoded.profileID == profileID else {
                    throw ProfileResourceLinkError.corruptStorage
                }
                manifest = decoded
                try validate(manifest)
            } else { manifest = Manifest(profileID: profileID) }
            let before = manifest
            let result = try operation(&manifest)
            if before != manifest {
                let data = try JSONEncoder().encode(manifest)
                guard data.count <= ResourceBundleStore.maximumResourceBytes else { throw ResourceBundleError.bundleTooLarge }
                try write(data, to: location)
            }
            return result
        }
    }

    private func manifestURL(profileID: String) -> URL {
        root.appendingPathComponent(digest(Data(profileID.utf8)) + ".json")
    }

    private func validate(_ manifest: Manifest) throws {
        guard manifest.version == 1 else { throw ProfileResourceLinkError.corruptStorage }
        var total = 0
        for (path, link) in manifest.links {
            guard !path.isEmpty, link.path == path, !link.displayName.isEmpty,
                  link.sha256.count == 64, link.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  (0...ResourceBundleStore.maximumResourceBytes).contains(link.size) else {
                throw ProfileResourceLinkError.corruptStorage
            }
            total += link.size
            guard total <= ResourceBundleStore.maximumBundleBytes else { throw ResourceBundleError.bundleTooLarge }
        }
    }

    private func read(_ url: URL, maximum: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= maximum else { throw ProfileResourceLinkError.corruptStorage }
        let data = try Data(contentsOf: url)
        guard data.count <= maximum else { throw ProfileResourceLinkError.corruptStorage }
        return data
    }

    private func write(_ data: Data, to url: URL) throws {
        var options: Data.WritingOptions = .atomic
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try data.write(to: url, options: options)
    }

    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func coordinate<T>(_ url: URL, writing: Bool, operation: (URL) throws -> T) throws -> T {
        var result: Result<T, Error>?
        var error: NSError?
        let accessor: (URL) -> Void = { location in result = Result { try operation(location) } }
        if writing { NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &error, byAccessor: accessor) }
        else { NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error, byAccessor: accessor) }
        do {
            if let error { throw error }
            guard let result else { throw ProfileResourceLinkError.storageFailure }
            return try result.get()
        } catch let error as ProfileResourceLinkError { throw error }
        catch let error as ResourceBundleError { throw error }
        catch { throw ProfileResourceLinkError.storageFailure }
    }
}

public enum ProfileResourceLinkError: Error, Equatable, LocalizedError {
    case invalidAssociation, corruptStorage, storageFailure
    public var errorDescription: String? {
        switch self {
        case .invalidAssociation: "资源关联信息无效。"
        case .corruptStorage: "本地资源副本缺失或已损坏，请重新选择文件。"
        case .storageFailure: "本地资源无法保存或读取。"
        }
    }
}
