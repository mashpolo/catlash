import Foundation
import NetworkExtension

public struct OnDemandRule: Codable, Sendable, Equatable, Identifiable {
    public enum Network: String, Codable, Sendable, CaseIterable { case wifi, cellular, any }
    public enum Action: String, Codable, Sendable, CaseIterable { case connect, disconnect, ignore }
    public var id: UUID
    public var name: String
    public var network: Network
    public var ssid: String
    public var action: Action

    public init(id: UUID = UUID(), name: String, network: Network, ssid: String = "", action: Action) {
        self.id = id
        self.name = name
        self.network = network
        self.ssid = ssid
        self.action = action
    }
}

public struct OnDemandPolicy: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var rules: [OnDemandRule]

    public init(enabled: Bool = false, rules: [OnDemandRule] = []) {
        self.enabled = enabled
        self.rules = rules
    }

    public func validate() throws {
        guard !enabled || !rules.isEmpty else { throw OnDemandPolicyError.emptyRules }
        guard rules.count <= 64, Set(rules.map(\.id)).count == rules.count else { throw OnDemandPolicyError.invalidRules }
        for rule in rules {
            guard !rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, rule.name.count <= 64 else {
                throw OnDemandPolicyError.invalidName
            }
            guard rule.ssid.utf8.count <= 32, !rule.ssid.contains("\0"),
                  rule.network == .wifi || rule.ssid.isEmpty else { throw OnDemandPolicyError.invalidSSID }
        }
    }

    public func systemRules() throws -> [NEOnDemandRule] {
        try validate()
        var result: [NEOnDemandRule] = try rules.map { (value: OnDemandRule) throws -> NEOnDemandRule in
            let rule: NEOnDemandRule
            switch value.action {
            case .connect: rule = NEOnDemandRuleConnect()
            case .disconnect: rule = NEOnDemandRuleDisconnect()
            case .ignore: rule = NEOnDemandRuleIgnore()
            }
            switch value.network {
            case .any: rule.interfaceTypeMatch = .any
            case .wifi: rule.interfaceTypeMatch = .wiFi
            case .cellular:
                #if os(iOS)
                rule.interfaceTypeMatch = .cellular
                #else
                throw OnDemandPolicyError.cellularRequiresIOS
                #endif
            }
            rule.ssidMatch = value.ssid.isEmpty ? nil : [value.ssid]
            return rule
        }
        result.append(NEOnDemandRuleIgnore())
        return result
    }
}

public struct OnDemandPolicyStore: Sendable {
    private let root: URL
    public init(root: URL) { self.root = root }

    public func load() throws -> OnDemandPolicy {
        let file = root.appendingPathComponent("on-demand.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return OnDemandPolicy() }
        let policy = try JSONDecoder().decode(OnDemandPolicy.self, from: Data(contentsOf: file))
        try policy.validate()
        return policy
    }

    public func save(_ policy: OnDemandPolicy) throws {
        try policy.validate()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(policy).write(to: root.appendingPathComponent("on-demand.json"), options: .atomic)
    }
}

public enum OnDemandPolicyError: LocalizedError {
    case emptyRules, invalidRules, invalidName, invalidSSID, cellularRequiresIOS
    public var errorDescription: String? {
        switch self {
        case .emptyRules: return "启用按需连接前，请至少添加一条网络规则。"
        case .invalidRules: return "最多可保存 64 条规则，规则标识不能重复。"
        case .invalidName: return "规则名称不能为空，且最多为 64 个字符。"
        case .invalidSSID: return "SSID 仅适用于 Wi-Fi，长度不能超过 32 个 UTF-8 字节。"
        case .cellularRequiresIOS: return "蜂窝网络按需规则仅支持 iOS。"
        }
    }
}
