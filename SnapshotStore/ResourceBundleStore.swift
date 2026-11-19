import CryptoKit
import Darwin
import Foundation

public enum ResourceKind: String, Codable, Sendable {
    case proxyProvider = "proxy-provider"
    case ruleProvider = "rule-provider"
    case proxyFile = "proxy-file"
    case geoIPDat = "geoip-dat"
    case geoSiteDat = "geosite-dat"
    case geoIPMMDB = "geoip-mmdb"
    case asnMMDB = "asn-mmdb"

    var geodata: (fileName: String, urlKey: String)? {
        switch self {
        case .proxyProvider, .ruleProvider, .proxyFile: return nil
        case .geoIPDat: return ("GeoIP.dat", "geoip")
        case .geoSiteDat: return ("GeoSite.dat", "geosite")
        case .geoIPMMDB: return ("Country.mmdb", "mmdb")
        case .asnMMDB: return ("ASN.mmdb", "asn")
        }
    }

    func accepts(name: String) -> Bool { geodata == nil ? !name.isEmpty : name == "default" }
}

public struct ResourceEntryData: Sendable {
    public let kind: ResourceKind
    public let name: String
    public let data: Data

    public init(kind: ResourceKind, name: String, data: Data) {
        self.kind = kind
        self.name = name
        self.data = data
    }
}

public enum ResourceBundleError: Error, LocalizedError {
    case invalidID
    case invalidEntry
    case corruptBundle
    case resourceTooLarge
    case bundleTooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidID: return "The resource bundle identifier is invalid."
        case .invalidEntry: return "Provider names must be nonempty and unique. Geodata resources must use the name 'default'."
        case .corruptBundle: return "The resource snapshot is missing, damaged, or contains an unsafe file."
        case .resourceTooLarge: return "A provider resource exceeds the 16 MiB limit."
        case .bundleTooLarge: return "Provider resources exceed the 64 MiB bundle limit."
        }
    }
}

public struct ResourceBundleStore: Sendable {
    public static let maximumResourceBytes = 16 * 1024 * 1024
    public static let maximumBundleBytes = 64 * 1024 * 1024
    private let root: URL

    public init(root: URL) { self.root = root }

    public func stage(entries: [ResourceEntryData]) throws -> String {
        try stage(count: entries.count) { entries[$0] }
    }

    func stage(count: Int, preserving previousID: String? = nil, entryAt: (Int) throws -> ResourceEntryData) throws -> String {
        let bundles = root.appendingPathComponent("bundles", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.checkDirectory(root)
        let temporary = root.appendingPathComponent(".preparing-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        var written = Set<String>()
        var keys = Set<EntryKey>()
        var manifestEntries = [Entry]()
        var total = 0
        for index in 0..<count {
            try autoreleasepool {
                let item = try entryAt(index)
                guard item.kind.accepts(name: item.name), keys.insert(.init(kind: item.kind, name: item.name)).inserted else {
                    throw ResourceBundleError.invalidEntry
                }
                guard item.data.count <= Self.maximumResourceBytes else { throw ResourceBundleError.resourceTooLarge }
                total += item.data.count
                guard total <= Self.maximumBundleBytes else { throw ResourceBundleError.bundleTooLarge }
                let hash = Self.digest(item.data)
                manifestEntries.append(Entry(kind: item.kind, name: item.name, sha256: hash, size: item.data.count))
                if written.insert(hash).inserted { try Self.write(item.data, to: temporary.appendingPathComponent(hash)) }
            }
        }
        if let previousID {
            _ = try verifiedBundle(id: previousID, collecting: { _ in false }) { entry, data in
                guard keys.insert(EntryKey(kind: entry.kind, name: entry.name)).inserted else { return }
                total += entry.size
                guard total <= Self.maximumBundleBytes else { throw ResourceBundleError.bundleTooLarge }
                manifestEntries.append(entry)
                if written.insert(entry.sha256).inserted {
                    try Self.write(data, to: temporary.appendingPathComponent(entry.sha256))
                }
            }
        }
        let bytes = try Self.encode(Manifest(version: 1, entries: manifestEntries.sorted(by: Self.ordered)))
        guard bytes.count <= Self.maximumResourceBytes else { throw ResourceBundleError.bundleTooLarge }
        let id = Self.digest(bytes)
        try FileManager.default.createDirectory(at: bundles, withIntermediateDirectories: true)
        try Self.checkDirectory(bundles)
        let destination = bundles.appendingPathComponent(id, isDirectory: true)
        if Self.exists(destination) { return try verifiedID(id) }
        try Self.write(bytes, to: temporary.appendingPathComponent("manifest.json"))
        do { try FileManager.default.moveItem(at: temporary, to: destination) }
        catch {
            guard Self.exists(destination) else { throw error }
            return try verifiedID(id)
        }
        return id
    }

    public func directory(id: String) throws -> URL {
        try verifiedBundle(id: id, collecting: { _ in false }).directory
    }

    public func entries(id: String, kind: ResourceKind) throws -> [ResourceEntryData] {
        try verifiedBundle(id: id, collecting: { $0 == kind }).entries
    }

    public func cachedResourcesUsingBundledGeodata(id: String) throws -> String? {
        var hasBundledDatabase = false
        let result = try verifiedBundle(id: id, collecting: { kind in
            if kind == .geoIPMMDB || kind == .geoIPDat || kind == .asnMMDB {
                hasBundledDatabase = true
                return false
            }
            return true
        })
        guard hasBundledDatabase else { return id }
        return result.entries.isEmpty ? nil : try stage(entries: result.entries)
    }

    private func verifiedBundle(id: String, collecting: (ResourceKind) -> Bool, visit: ((Entry, Data) throws -> Void)? = nil) throws -> (directory: URL, entries: [ResourceEntryData]) {
        guard Self.validHash(id) else { throw ResourceBundleError.invalidID }
        let bundles = root.appendingPathComponent("bundles", isDirectory: true)
        let directory = bundles.appendingPathComponent(id, isDirectory: true)
        try Self.checkDirectory(root)
        try Self.checkDirectory(bundles)
        try Self.checkDirectory(directory)
        let bytes = try Self.read(directory.appendingPathComponent("manifest.json"), maximum: Self.maximumResourceBytes)
        guard Self.digest(bytes) == id,
              let manifest = try? JSONDecoder().decode(Manifest.self, from: bytes),
              manifest.version == 1, manifest.entries == manifest.entries.sorted(by: Self.ordered),
              try Self.encode(manifest) == bytes else { throw ResourceBundleError.corruptBundle }
        var total = 0
        var keys = Set<EntryKey>()
        var entries: [ResourceEntryData] = []
        for entry in manifest.entries {
            guard entry.kind.accepts(name: entry.name), keys.insert(EntryKey(kind: entry.kind, name: entry.name)).inserted,
                  Self.validHash(entry.sha256), (0...Self.maximumResourceBytes).contains(entry.size) else {
                throw ResourceBundleError.corruptBundle
            }
            total += entry.size
            guard total <= Self.maximumBundleBytes else { throw ResourceBundleError.bundleTooLarge }
            let data = try Self.read(directory.appendingPathComponent(entry.sha256), maximum: entry.size)
            guard data.count == entry.size, Self.digest(data) == entry.sha256 else { throw ResourceBundleError.corruptBundle }
            try visit?(entry, data)
            if collecting(entry.kind) { entries.append(.init(kind: entry.kind, name: entry.name, data: data)) }
        }
        return (directory, entries)
    }

    private func verifiedID(_ id: String) throws -> String {
        _ = try directory(id: id)
        return id
    }

    private struct EntryKey: Hashable { let kind: ResourceKind; let name: String }
    private struct Manifest: Codable {
        let version: Int
        let entries: [Entry]
        private enum CodingKeys: String, CodingKey { case version, entries }
        init(version: Int, entries: [Entry]) { self.version = version; self.entries = entries }
        init(from decoder: Decoder) throws {
            try rejectExtraKeys(decoder, allowed: ["version", "entries"])
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decode(Int.self, forKey: .version)
            entries = try values.decode([Entry].self, forKey: .entries)
        }
    }
    private struct Entry: Codable, Equatable {
        let kind: ResourceKind
        let name: String
        let sha256: String
        let size: Int
        private enum CodingKeys: String, CodingKey { case kind, name, sha256, size }
        init(kind: ResourceKind, name: String, sha256: String, size: Int) {
            self.kind = kind; self.name = name; self.sha256 = sha256; self.size = size
        }
        init(from decoder: Decoder) throws {
            try rejectExtraKeys(decoder, allowed: ["kind", "name", "sha256", "size"])
            let values = try decoder.container(keyedBy: CodingKeys.self)
            kind = try values.decode(ResourceKind.self, forKey: .kind)
            name = try values.decode(String.self, forKey: .name)
            sha256 = try values.decode(String.self, forKey: .sha256)
            size = try values.decode(Int.self, forKey: .size)
        }
    }

    private static func ordered(_ lhs: Entry, _ rhs: Entry) -> Bool {
        if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
        return lhs.name.utf8.lexicographicallyPrecedes(rhs.name.utf8)
    }

    private static func encode(_ manifest: Manifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(manifest)
    }

    private static func validHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    private static func checkDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { throw ResourceBundleError.corruptBundle }
    }

    private static func read(_ url: URL, maximum: Int) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw ResourceBundleError.corruptBundle }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size <= maximum else { throw ResourceBundleError.corruptBundle }
        var data = Data(capacity: Int(info.st_size))
        while let chunk = try handle.read(upToCount: min(65_536, maximum + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= maximum else { throw ResourceBundleError.corruptBundle }
        }
        return data
    }

    private static func write(_ data: Data, to url: URL) throws {
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try data.write(to: url, options: options)
    }
}

private struct ResourceManifestKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func rejectExtraKeys(_ decoder: Decoder, allowed: Set<String>) throws {
    let values = try decoder.container(keyedBy: ResourceManifestKey.self)
    guard values.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else { throw ResourceBundleError.corruptBundle }
}
