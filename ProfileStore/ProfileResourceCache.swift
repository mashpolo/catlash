import CryptoKit
import Darwin
import Foundation

struct ProfileResourceCache: Sendable {
    let root: URL

    func load(request: URLRequest, maximumBytes: Int) throws -> Data? {
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }
        try checkRoot()
        let url = root.appendingPathComponent(try identity(request))
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw ProfileResourceCacheError.storageFailure
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size <= ResourceBundleStore.maximumResourceBytes + 4096 else { return nil }
        let bytes = try handle.read(upToCount: ResourceBundleStore.maximumResourceBytes + 4097) ?? Data()
        guard let entry = try? PropertyListDecoder().decode(Entry.self, from: bytes), entry.version == 1,
              entry.data.count <= maximumBytes, Self.digest(entry.data) == entry.sha256 else { return nil }
        return entry.data
    }

    func save(_ data: Data, request: URLRequest) throws {
        try Task.checkCancellation()
        let entry = Entry(version: 1, sha256: Self.digest(data), data: data)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let bytes = try encoder.encode(entry)
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try checkRoot()
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try bytes.write(to: root.appendingPathComponent(try identity(request)), options: options)
    }

    private func identity(_ request: URLRequest) throws -> String {
        guard let url = request.url else { throw ProfileStoreError.invalidSourceURL }
        var headers: [String: String] = [:]
        for (name, value) in request.allHTTPHeaderFields ?? [:] { headers[name.lowercased()] = value }
        let value = Identity(version: 1, url: url.absoluteString, method: request.httpMethod ?? "GET", headers: headers)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return Self.digest(try encoder.encode(value))
    }

    private func checkRoot() throws {
        var info = stat()
        guard lstat(root.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw ProfileResourceCacheError.storageFailure
        }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct Identity: Encodable {
        let version: Int
        let url: String
        let method: String
        let headers: [String: String]
    }

    private struct Entry: Codable {
        let version: Int
        let sha256: String
        let data: Data
    }
}

enum ProfileResourceCacheError: Error { case storageFailure }
