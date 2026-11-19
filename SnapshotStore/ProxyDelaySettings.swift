import Foundation

public struct ProxyDelaySettings: Codable, Hashable, Sendable {
    public var url: String
    public var timeoutMilliseconds: Int

    public init(url: String = "https://www.gstatic.com/generate_204", timeoutMilliseconds: Int = 10_000) {
        self.url = url
        self.timeoutMilliseconds = timeoutMilliseconds
    }

    public func validate() throws {
        guard url.utf8.count <= 4096, !url.contains(where: { $0.isWhitespace || $0.isNewline }),
              let components = URLComponents(string: url),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.fragment == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true,
              components.url != nil else { throw ProxyDelaySettingsError.invalidURL }
        guard (1...60_000).contains(timeoutMilliseconds) else { throw ProxyDelaySettingsError.invalidTimeout }
    }

    public var extensionTimeout: TimeInterval { Double(timeoutMilliseconds) / 1000 + 2 }
    public var clientTimeout: TimeInterval { extensionTimeout + 3 }
}

public struct ProxyDelayKey: Hashable, Sendable {
    public let node: String
    public let settings: ProxyDelaySettings
    public init(node: String, settings: ProxyDelaySettings) {
        self.node = node
        self.settings = settings
    }
}

public enum ProxyDelaySettingsError: Error, LocalizedError {
    case invalidURL, invalidTimeout
    public var errorDescription: String? {
        switch self {
        case .invalidURL: "请输入有效的 HTTP 或 HTTPS 测速地址，不含用户名、密码或片段。"
        case .invalidTimeout: "测速超时必须是 1 到 60000 毫秒的整数。"
        }
    }
}

public enum ProxyDelayResult: Equatable, Sendable {
    case measured(Int64), timedOut, failed

    public var milliseconds: Int64? {
        if case .measured(let value) = self { return value }
        return nil
    }

    public var text: String {
        switch self {
        case .measured(let value): "\(value) ms"
        case .timedOut: "超时"
        case .failed: "失败"
        }
    }
}

public enum ProxyNodeSort: String, Codable, CaseIterable, Sendable {
    case original, name, delay
}

public struct ProxyDelayPreferences: Codable, Equatable, Sendable {
    public var settings = ProxyDelaySettings()
    public var sort = ProxyNodeSort.original
    public var hideFailures = false
    private static let key = "NativeProfiles.proxyDelayPreferences"

    public init() {}

    private enum CodingKeys: String, CodingKey { case settings, sort, sortByDelay, hideFailures }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        settings = try values.decode(ProxyDelaySettings.self, forKey: .settings)
        sort = try values.decodeIfPresent(ProxyNodeSort.self, forKey: .sort)
            ?? (values.decodeIfPresent(Bool.self, forKey: .sortByDelay) == true ? .delay : .original)
        hideFailures = try values.decodeIfPresent(Bool.self, forKey: .hideFailures) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(settings, forKey: .settings)
        try values.encode(sort, forKey: .sort)
        try values.encode(hideFailures, forKey: .hideFailures)
    }

    public static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: key), let value = try? JSONDecoder().decode(Self.self, from: data),
              (try? value.settings.validate()) != nil else { return Self() }
        return value
    }

    public func save(to defaults: UserDefaults = .standard) throws {
        try settings.validate()
        defaults.set(try JSONEncoder().encode(self), forKey: Self.key)
    }

    public static func matching(_ nodes: [String], search: String) -> [String] {
        nodes.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }
    }

    public static func ordered(_ nodes: [String], results: [String: ProxyDelayResult], sort: ProxyNodeSort, hideFailures: Bool) -> [String] {
        let visible = nodes.enumerated().filter { !hideFailures || (results[$0.element] != .failed && results[$0.element] != .timedOut) }
        guard sort != .original else { return visible.map(\.element) }
        return visible.sorted {
            if sort == .name {
                let comparison = $0.element.localizedStandardCompare($1.element)
                return comparison == .orderedSame ? $0.offset < $1.offset : comparison == .orderedAscending
            }
            let left = results[$0.element]?.milliseconds ?? Int64.max
            let right = results[$1.element]?.milliseconds ?? Int64.max
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
    }
}

public enum ProxyDelayFailure: String, Codable, Error, Sendable {
    case timeout, failed, cancelled
}
