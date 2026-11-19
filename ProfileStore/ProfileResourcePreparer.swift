import Foundation
import Yams

public enum ProfileResourceError: Error, Equatable, LocalizedError {
    case invalidProvider(kind: ResourceKind, name: String)
    case unsupportedSource(kind: ResourceKind, name: String)
    case missingLocalFile(kind: ResourceKind, name: String, path: String)
    case requiresConnectedProxy(kind: ResourceKind, name: String, proxy: String)
    case invalidHeader(kind: ResourceKind, name: String)
    case httpStatus(kind: ResourceKind, name: String, status: Int)
    case downloadFailed(kind: ResourceKind, name: String, error: ProfileDownloadError)
    case failed(kind: ResourceKind, name: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case let .invalidProvider(kind, name): return "The \(kind.rawValue) '\(name)' has invalid resource settings."
        case let .unsupportedSource(kind, name): return "The \(kind.rawValue) '\(name)' must use an HTTP, file, or inline source."
        case let .missingLocalFile(kind, name, path): return "Choose the local resource for \(kind.rawValue) '\(name)': \(path)"
        case let .requiresConnectedProxy(kind, name, proxy):
            return "The \(kind.rawValue) '\(name)' requests download through '\(proxy)'. Downloading through a connected proxy is not available yet."
        case let .invalidHeader(kind, name): return "The \(kind.rawValue) '\(name)' contains an invalid HTTP header."
        case let .httpStatus(kind, name, status): return "The \(kind.rawValue) '\(name)' server returned HTTP \(status)."
        case let .downloadFailed(kind, name, error): return "\(kind.rawValue) '\(name)'：\(error.localizedDescription)"
        case let .failed(kind, name, reason): return "\(kind.rawValue) '\(name)'：\(reason)"
        }
    }
}

public struct ProfileResourceProgress: Sendable, Equatable {
    public enum Phase: Sendable { case downloading, cached, local, deferred }
    public let kind: ResourceKind
    public let name: String
    public let phase: Phase
}

public enum ProfileResourcePreparationScope: Sendable {
    case connection
    case complete
}

public actor ProfileResourcePreparer {
    public typealias Download = @Sendable (URLRequest, Int) async throws -> Data
    private let bundleStore: ResourceBundleStore
    private let download: Download
    private let cache: ProfileResourceCache?
    public typealias Progress = @Sendable (ProfileResourceProgress) async -> Void

    public init(downloader: (any ProfileDownloader)? = nil, bundleStore: ResourceBundleStore, cacheDirectory: URL? = nil) {
        let client = downloader ?? URLSessionProfileDownloader()
        self.bundleStore = bundleStore
        cache = cacheDirectory.map(ProfileResourceCache.init)
        download = { try await client.download(request: $0, maximumBytes: $1) }
    }

    public init(bundleStore: ResourceBundleStore, cacheDirectory: URL? = nil, download: @escaping Download) {
        self.bundleStore = bundleStore
        cache = cacheDirectory.map(ProfileResourceCache.init)
        self.download = download
    }

    public func prepare(yaml: Data, localFiles: [String: Data] = [:], deferProxyDownloads: Bool = false,
                        scope: ProfileResourcePreparationScope = .complete, forceRefresh: Bool = false, progress: Progress? = nil) async throws -> String? {
        let document = try Self.parse(yaml)
        let globalUserAgent = document["global-ua"]?.string
        var entries: [ResourceEntryData] = []
        var total = 0
        var providerRules: [String] = []
        var hasDeferredClassicalProvider = false
        var linkedPaths = Set<String>()
        var hasRemoteNodes = false
        var proxies = document["proxies"]?.sequence?.map { $0 } ?? []
        for (key, kind) in [("proxy-providers", ResourceKind.proxyProvider), ("rule-providers", .ruleProvider)] {

            guard let node = document[key] else { continue }
            guard let providers = node.mapping else { throw ProfileResourceError.invalidProvider(kind: kind, name: key) }
            for (nameNode, provider) in providers {
                try Task.checkCancellation()
                guard let name = nameNode.string, !name.isEmpty, provider.mapping != nil else {
                    throw ProfileResourceError.invalidProvider(kind: kind, name: key)
                }
                if scope == .connection, provider["type"]?.string == "http" {
                    if kind == .proxyProvider { hasRemoteNodes = true }
                    continue
                }
                if let path = provider["path"]?.string, provider["type"]?.string == "file" {
                    linkedPaths.insert(path)
                    if scope == .connection, kind == .ruleProvider, localFiles[path] == nil { continue }
                }
                if deferProxyDownloads, provider["type"]?.string == "http",
                   let proxy = provider["proxy"]?.string, !proxy.isEmpty, proxy != "DIRECT" {
                    _ = try Self.maximumBytes(provider, kind: kind, name: name)
                    _ = try Self.request(provider, kind: kind, name: name, globalUserAgent: globalUserAgent)
                    if kind == .ruleProvider, provider["behavior"]?.string == "classical" {
                        hasDeferredClassicalProvider = true
                    }
                    await progress?(.init(kind: kind, name: name, phase: .deferred))
                    continue
                }
                let data = try await resource(provider, kind: kind, name: name, globalUserAgent: globalUserAgent, localFiles: localFiles, forceRefresh: forceRefresh, progress: progress)
                if kind == .ruleProvider {
                    providerRules += ProfileGeodataRequirements.classicalRules(provider: provider, data: data)
                } else {
                    proxies += ProfileProxyFiles.proxies(provider: provider, data: data)
                }
                guard let data else { continue }
                total += data.count
                try Self.checkTotal(total, kind: kind, name: name)
                entries.append(ResourceEntryData(kind: kind, name: name, data: data))
            }
        }
        let geoKinds: [ResourceKind] = [.geoIPDat, .geoSiteDat, .geoIPMMDB, .asnMMDB]
        var nodeFiles = try ProfileProxyFiles.paths(in: proxies)
        if hasRemoteNodes {
            let reserved = linkedPaths.union(geoKinds.compactMap { $0.geodata?.fileName })
            nodeFiles.formUnion(localFiles.keys.filter { !reserved.contains($0) })
        }
        for path in nodeFiles.sorted() {
            try Task.checkCancellation()
            guard let data = localFiles[path] else {
                throw ProfileResourceError.missingLocalFile(kind: .proxyFile, name: path, path: path)
            }
            await progress?(.init(kind: .proxyFile, name: path, phase: .local))
            try Self.checkSize(data, maximum: ResourceBundleStore.maximumResourceBytes, kind: .proxyFile, name: path)
            total += data.count
            try Self.checkTotal(total, kind: .proxyFile, name: path)
            entries.append(ResourceEntryData(kind: .proxyFile, name: path, data: data))
        }
        var geodataKinds: Set<ResourceKind> = scope == .complete
            ? ProfileGeodataRequirements.required(document: document, providerRules: providerRules) : []
        if hasDeferredClassicalProvider || scope == .connection {
            for kind in [ResourceKind.geoIPDat, .geoSiteDat, .geoIPMMDB, .asnMMDB] {
                if let fileName = kind.geodata?.fileName, localFiles[fileName] != nil { geodataKinds.insert(kind) }
            }
        }
        for kind in geodataKinds.sorted(by: { $0.rawValue < $1.rawValue }) {
            try Task.checkCancellation()
            let data = try await geodata(kind, document: document, localFiles: localFiles, forceRefresh: forceRefresh, progress: progress)
            total += data.count
            try Self.checkTotal(total, kind: kind, name: kind.geodata?.fileName ?? "default")
            entries.append(ResourceEntryData(kind: kind, name: "default", data: data))
        }
        try Task.checkCancellation()
        guard !entries.isEmpty else { return nil }
        return try bundleStore.stage(entries: entries)
    }

    private func geodata(_ kind: ResourceKind, document: Node, localFiles: [String: Data], forceRefresh: Bool, progress: Progress?) async throws -> Data {
        guard let resource = kind.geodata else { throw ResourceBundleError.invalidEntry }
        let data: Data
        if let local = localFiles[resource.fileName] {
            await progress?(.init(kind: kind, name: resource.fileName, phase: .local))
            data = local
        } else if let value = document["geox-url"]?[resource.urlKey]?.string, !value.isEmpty {
            let url = try Self.resourceURL(value, kind: kind, name: resource.fileName)
            let request = try Self.applyingGlobalUserAgent(document["global-ua"]?.string, to: URLRequest(url: url), kind: kind, name: resource.fileName)
            data = try await downloadResource(request, maximum: ResourceBundleStore.maximumResourceBytes, kind: kind, name: resource.fileName, forceRefresh: forceRefresh, progress: progress)
        } else {
            throw ProfileResourceError.missingLocalFile(kind: kind, name: "default", path: resource.fileName)
        }
        try Task.checkCancellation()
        try Self.checkSize(data, maximum: ResourceBundleStore.maximumResourceBytes, kind: kind, name: resource.fileName)
        return data
    }

    private func resource(_ provider: Node, kind: ResourceKind, name: String, globalUserAgent: String?, localFiles: [String: Data], forceRefresh: Bool, progress: Progress?) async throws -> Data? {
        guard let type = provider["type"]?.string else { throw ProfileResourceError.invalidProvider(kind: kind, name: name) }
        if type == "inline" { return nil }
        let maximum = try Self.maximumBytes(provider, kind: kind, name: name)
        let data: Data
        switch type {
        case "http":
            if let proxyNode = provider["proxy"] {
                guard let proxy = proxyNode.string else { throw ProfileResourceError.invalidProvider(kind: kind, name: name) }
                guard proxy.isEmpty || proxy == "DIRECT" else {
                    throw ProfileResourceError.requiresConnectedProxy(kind: kind, name: name, proxy: proxy)
                }
            }
            let request = try Self.request(provider, kind: kind, name: name, globalUserAgent: globalUserAgent)
            data = try await downloadResource(request, maximum: maximum, kind: kind, name: name, forceRefresh: forceRefresh, progress: progress)
        case "file":
            guard let path = provider["path"]?.string, !path.isEmpty else {
                throw ProfileResourceError.invalidProvider(kind: kind, name: name)
            }
            guard let authorized = localFiles[path] else { throw ProfileResourceError.missingLocalFile(kind: kind, name: name, path: path) }
            await progress?(.init(kind: kind, name: name, phase: .local))
            data = authorized
        default:
            throw ProfileResourceError.unsupportedSource(kind: kind, name: name)
        }
        try Task.checkCancellation()
        try Self.checkSize(data, maximum: maximum, kind: kind, name: name)
        return data
    }

    private func downloadResource(_ request: URLRequest, maximum: Int, kind: ResourceKind, name: String, forceRefresh: Bool, progress: Progress?) async throws -> Data {
        do {
            try Task.checkCancellation()
            if !forceRefresh, let data = try cache?.load(request: request, maximumBytes: maximum) {
                await progress?(.init(kind: kind, name: name, phase: .cached))
                try Task.checkCancellation()
                return data
            }
            await progress?(.init(kind: kind, name: name, phase: .downloading))
            try Task.checkCancellation()
            var downloadRequest = request
            if forceRefresh { downloadRequest.cachePolicy = .reloadIgnoringLocalCacheData }
            let data = try await download(downloadRequest, maximum)
            try Task.checkCancellation()
            try Self.checkSize(data, maximum: maximum, kind: kind, name: name)
            try cache?.save(data, request: request)
            return data
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as ProfileResourceError {
            throw error
        } catch let error as ProfileDownloadError {
            throw ProfileResourceError.downloadFailed(kind: kind, name: name, error: error)
        } catch let error as URLError {
            throw ProfileResourceError.downloadFailed(kind: kind, name: name, error: .transport(error.code))
        } catch ProfileStoreError.httpStatus(let status) {
            throw ProfileResourceError.httpStatus(kind: kind, name: name, status: status)
        } catch ProfileStoreError.tooLarge {
            throw Self.sizeError(maximum: maximum, kind: kind, name: name)
        } catch is ProfileResourceCacheError {
            throw ProfileResourceError.failed(kind: kind, name: name, reason: "资源缓存读取或保存失败。")
        } catch {
            throw ProfileResourceError.failed(kind: kind, name: name, reason: "资源下载或保存失败，请重试。")
        }
    }

    private static func resourceURL(_ value: String, kind: ResourceKind, name: String) throws -> URL {
        guard let url = URL(string: value), (try? validateSubscriptionURL(url)) != nil else {
            throw ProfileResourceError.failed(kind: kind, name: name, reason: "资源地址必须使用 HTTP 或 HTTPS。")
        }
        return url
    }

    private static func sizeError(maximum: Int, kind: ResourceKind, name: String) -> ProfileResourceError {
        .failed(kind: kind, name: name, reason: "资源超过当前 \(maximum) 字节限制。")
    }

    private static func checkSize(_ data: Data, maximum: Int, kind: ResourceKind, name: String) throws {
        guard data.count <= maximum else { throw sizeError(maximum: maximum, kind: kind, name: name) }
    }

    private static func checkTotal(_ total: Int, kind: ResourceKind, name: String) throws {
        guard total <= ResourceBundleStore.maximumBundleBytes else {
            throw ProfileResourceError.failed(kind: kind, name: name, reason: "加入此资源后，资源总量超过 64 MiB 限制。")
        }
    }

    private static func maximumBytes(_ provider: Node, kind: ResourceKind, name: String) throws -> Int {
        guard let limit = provider["size-limit"] else { return ResourceBundleStore.maximumResourceBytes }
        guard let value = limit.int, value >= 0 else { throw ProfileResourceError.invalidProvider(kind: kind, name: name) }
        return value == 0 ? ResourceBundleStore.maximumResourceBytes : min(value, ResourceBundleStore.maximumResourceBytes)
    }

    private static func request(_ provider: Node, kind: ResourceKind, name: String, globalUserAgent: String?) throws -> URLRequest {
        guard let rawURL = provider["url"]?.string else {
            throw ProfileResourceError.invalidProvider(kind: kind, name: name)
        }
        let url = try resourceURL(rawURL, kind: kind, name: name)
        var request = URLRequest(url: url)
        guard let headerNode = provider["header"] else {
            return try applyingGlobalUserAgent(globalUserAgent, to: request, kind: kind, name: name)
        }
        guard let headers = headerNode.mapping else { throw ProfileResourceError.invalidHeader(kind: kind, name: name) }
        for (keyNode, valueNode) in headers {
            guard let key = keyNode.string, validHeaderName(key) else { throw ProfileResourceError.invalidHeader(kind: kind, name: name) }
            let values: [String]
            if let single = valueNode.string { values = [single] }
            else if let sequence = valueNode.sequence {
                values = try sequence.map { value in
                    guard let string = value.string else { throw ProfileResourceError.invalidHeader(kind: kind, name: name) }
                    return string
                }
            } else { throw ProfileResourceError.invalidHeader(kind: kind, name: name) }
            for value in values {
                guard validHeaderValue(value) else {
                    throw ProfileResourceError.invalidHeader(kind: kind, name: name)
                }
                request.addValue(value, forHTTPHeaderField: key)
            }
        }
        return try applyingGlobalUserAgent(globalUserAgent, to: request, kind: kind, name: name)
    }

    private static func applyingGlobalUserAgent(_ value: String?, to original: URLRequest, kind: ResourceKind, name: String) throws -> URLRequest {
        guard original.value(forHTTPHeaderField: "User-Agent") == nil, let value, !value.isEmpty else { return original }
        guard validHeaderValue(value) else { throw ProfileResourceError.invalidHeader(kind: kind, name: name) }
        var request = original
        request.setValue(value, forHTTPHeaderField: "User-Agent")
        return request
    }

    private static func validHeaderValue(_ value: String) -> Bool {
        !value.utf8.contains { $0 == 0 || $0 == 10 || $0 == 13 }
    }

    private static func validHeaderName(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                || "!#$%&'*+-.^_`|~".utf8.contains($0)
        }
    }

    private static func parse(_ data: Data) throws -> Node {
        try EffectiveYAML.compose(data: data)
    }
}
