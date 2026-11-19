import Foundation
import Yams

public struct YAMLProxyGroup: Codable, Equatable, Sendable {
    public let name: String
    public let type: String?
    public let members: [String]
}

public struct YAMLDocument: Codable, Equatable, Sendable {
    public static let maximumBytes = 16 * 1024 * 1024
    public let proxyNames: [String]
    public let proxyGroups: [YAMLProxyGroup]
    public let storeSelected: Bool?
    public let proxyTypes: [String: String]?

    public static func validate(data: Data, providerData: [String: Data] = [:]) throws -> YAMLDocument {
        let document = try EffectiveYAML.compose(data: data)
        var storeSelected: Bool?
        if let selected = document["profile"]?["store-selected"] {
            guard selected.tag == Tag(.bool), let value = selected.bool else { throw ProfileStoreError.invalidYAML }
            storeSelected = value
        }
        let proxies = document["proxies"]?.array().compactMap { $0["name"]?.string } ?? []
        let providers = try providerNodes(document: document, data: providerData)
        let proxyTypes = Dictionary(document["proxies"]?.array().compactMap { node -> (String, String)? in
            guard let name = node["name"]?.string else { return nil }
            return (name, node["type"]?.string ?? "")
        } ?? [], uniquingKeysWith: { first, _ in first })
        let groups = try document["proxy-groups"]?.array().compactMap { node -> YAMLProxyGroup? in
            guard let name = node["name"]?.string else { return nil }
            let explicit = (node["proxies"]?.array(of: String.self) ?? []).map {
                PreviewProxy(name: $0, type: proxyTypes[$0] ?? $0)
            }
            let uses = node["use"]?.array(of: String.self) ?? []
            let downloaded = uses.flatMap { providers[$0] ?? [] }
            let included = try matching(downloaded, patterns: node["filter"]?.string)
            var combined = unique(explicit + included)
            if uses.count + (explicit.isEmpty ? 0 : 1) > 1, node["filter"]?.string?.contains("`") == true {
                combined = try unique(matching(combined, patterns: node["filter"]?.string) + combined)
            }
            let members = try excluding(combined, options: node, runtimeTypes: true)
            return YAMLProxyGroup(
                name: name,
                type: node["type"]?.string,
                members: members.map(\.name)
            )
        } ?? []
        var types = proxyTypes
        for provider in providers.keys.sorted() {
            for proxy in providers[provider] ?? [] where types[proxy.name] == nil && !proxy.type.isEmpty {
                types[proxy.name] = proxy.type
            }
        }
        for group in groups { types[group.name] = group.type }
        return YAMLDocument(proxyNames: proxies, proxyGroups: groups, storeSelected: storeSelected, proxyTypes: types)
    }

    public func selectionsForStorage(_ selections: [String: String]) -> [String: String] {
        storeSelected == false ? [:] : selections
    }

    private struct PreviewProxy {
        let name: String
        let type: String
    }

    private static func providerNodes(document: Node, data: [String: Data]) throws -> [String: [PreviewProxy]] {
        var result: [String: [PreviewProxy]] = [:]
        for (key, options) in document["proxy-providers"]?.mapping ?? [:] {
            guard let name = key.string else { continue }
            let source: [Node]
            if let bytes = data[name] {
                source = try EffectiveYAML.compose(data: bytes)["proxies"]?.array() ?? []
            } else if options["type"]?.string == "inline" {
                source = options["payload"]?.array() ?? []
            } else { continue }
            let proxies = source.compactMap { node -> PreviewProxy? in
                guard let name = node["name"]?.string else { return nil }
                return PreviewProxy(name: name, type: node["type"]?.string ?? "")
            }
            let filtered = try excluding(matching(proxies, patterns: options["filter"]?.string), options: options)
            let prefix = options["override"]?["additional-prefix"]?.string ?? ""
            let suffix = options["override"]?["additional-suffix"]?.string ?? ""
            result[name] = filtered.map { PreviewProxy(name: prefix + $0.name + suffix, type: $0.type) }
        }
        return result
    }

    private static func matching(_ proxies: [PreviewProxy], patterns: String?) throws -> [PreviewProxy] {
        let expressions = try expressions(patterns)
        guard !expressions.isEmpty else { return unique(proxies) }
        return unique(expressions.flatMap { expression in proxies.filter { matches(expression, $0.name) } })
    }

    private static func excluding(_ proxies: [PreviewProxy], options: Node, runtimeTypes: Bool = false) throws -> [PreviewProxy] {
        let excludedNames = try expressions(options["exclude-filter"]?.string)
        let excludedTypes = (options["exclude-type"]?.string ?? "").split(separator: "|").map { $0.lowercased() }
        return proxies.filter { proxy in
            let type = runtimeTypes ? runtimeType(proxy.type) : proxy.type.lowercased()
            return !excludedTypes.contains(type) && !excludedNames.contains { matches($0, proxy.name) }
        }
    }

    private static func runtimeType(_ type: String) -> String {
        switch type.lowercased() {
        case "ss": return "shadowsocks"
        case "ssr": return "shadowsocksr"
        case "select": return "selector"
        case "url-test": return "urltest"
        case "load-balance": return "loadbalance"
        default: return type.lowercased()
        }
    }

    private static func expressions(_ value: String?) throws -> [NSRegularExpression] {
        guard let value, !value.isEmpty else { return [] }
        do { return try value.components(separatedBy: "`").map { try NSRegularExpression(pattern: $0) } }
        catch { throw ProfileStoreError.invalidYAML }
    }

    private static func matches(_ expression: NSRegularExpression, _ value: String) -> Bool {
        expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }

    private static func unique(_ proxies: [PreviewProxy]) -> [PreviewProxy] {
        var names = Set<String>()
        return proxies.filter { names.insert($0.name).inserted }
    }
}

public enum ProfileValidationStatus: String, Codable, Sendable {
    case pendingCoreValidation
    case invalidYAML
}

public struct ProfileRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var displayName: String
    public let sourceURL: URL?
    public var revisionSHA: String
    public var updatedAt: Date
    public var validationStatus: ProfileValidationStatus
    public var overview: YAMLDocument?
    public var subscription: SubscriptionMetadata? = nil
}

public enum ProfileStoreError: Error, Equatable, LocalizedError {
    case tooLarge, invalidUTF8, invalidYAML, invalidProfileID, invalidName
    case unsafeFile, notFound, staleRevision, invalidSourceURL, noSubscription
    case invalidMetadata, storageFailure, downloadFailed, httpStatus(Int), invalidSubscriptionInterval

    public var errorDescription: String? {
        switch self {
        case .tooLarge: return "The YAML file exceeds the 16 MiB limit."
        case .invalidUTF8: return "The YAML file must use UTF-8 encoding."
        case .invalidYAML: return "The file must contain one valid YAML mapping document."
        case .invalidProfileID: return "The profile filename is invalid."
        case .invalidName: return "The profile name must not be empty."
        case .unsafeFile: return "The profile must be a regular YAML file."
        case .notFound: return "The profile was not found."
        case .staleRevision: return "The profile changed; reload it before saving."
        case .invalidSourceURL: return "The subscription URL must use HTTP or HTTPS."
        case .noSubscription: return "This profile has no subscription URL."
        case .invalidSubscriptionInterval: return "The subscription update interval must be a positive number of seconds."
        case .invalidMetadata: return "The local profile metadata is damaged."
        case .storageFailure: return "The local profile storage operation failed."
        case .downloadFailed: return "The subscription download failed."
        case let .httpStatus(status): return "The subscription server returned HTTP \(status)."
        }
    }
}
