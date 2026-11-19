import Foundation
import Yams

public struct DNSOverrides: Codable, Equatable, Sendable {
    public var appendSystemDNS: Bool
    public var dns: [String: String]
    public var tun: [String: String]

    public init(appendSystemDNS: Bool = false, dns: [String: String] = [:], tun: [String: String] = [:]) {
        self.appendSystemDNS = appendSystemDNS
        self.dns = dns
        self.tun = tun
    }

    public func validate() throws {
        let dnsValues = Dictionary(uniqueKeysWithValues: try parsed(dns, section: "dns"))
        _ = try parsed(tun, section: "tun")
        if appendSystemDNS, let value = dnsValues["nameserver"] {
            _ = try appendingSystemDNS(to: value)
        }
    }

    public func canReuseSourceResources(_ source: Data) throws -> Bool {
        guard !appendSystemDNS, dns.isEmpty else { return false }
        return try EffectiveYAML.compose(data: source)["dns"]?["enable"]?.bool == true
    }

    public func applying(to source: Data) throws -> Data {
        var document = try EffectiveYAML.compose(data: source)
        var effectiveDNS = try mapping(document["dns"], section: "dns")
        if effectiveDNS["enable"]?.bool != true {
            effectiveDNS["enable"] = Node("true", Tag(.bool))
            effectiveDNS["enhanced-mode"] = Node("fake-ip")
            effectiveDNS["nameserver"] = Node([Node("https://doh.pub/dns-query"), Node("https://dns.alidns.com/dns-query")])
        }
        for (key, value) in try parsed(dns, section: "dns") { effectiveDNS[key] = value }
        if appendSystemDNS {
            effectiveDNS["nameserver"] = try appendingSystemDNS(to: effectiveDNS["nameserver"])
        }
        document["dns"] = effectiveDNS
        var effectiveTUN = try mapping(document["tun"], section: "tun")
        effectiveTUN["dns-hijack"] = Node([Node("any:53")])
        for (key, value) in try parsed(tun, section: "tun") { effectiveTUN[key] = value }
        document["tun"] = effectiveTUN
        let bytes = Data(try Yams.serialize(node: document, allowUnicode: true).utf8)
        guard bytes.count <= YAMLDocument.maximumBytes else { throw ProfileStoreError.tooLarge }
        return bytes
    }

    private func parsed(_ values: [String: String], section: String) throws -> [(String, Node)] {
        try values.keys.sorted().map { key in
            guard !key.isEmpty, let text = values[key], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DNSOverrideError.invalidValue(section: section, key: key)
            }
            let indented = text.split(separator: "\n", omittingEmptySubsequences: false).map { "  " + $0 }.joined(separator: "\n")
            do {
                let wrapped = try EffectiveYAML.compose(data: Data(("value:\n" + indented + "\n").utf8))
                guard let value = wrapped["value"] else { throw ProfileStoreError.invalidYAML }
                return (key, value)
            } catch { throw DNSOverrideError.invalidValue(section: section, key: key) }
        }
    }

    private func mapping(_ node: Node?, section: String) throws -> Node {
        guard let node, node.null == nil else { return Node([(Node, Node)]()) }
        guard node.mapping != nil else { throw DNSOverrideError.invalidValue(section: section, key: "") }
        return node
    }

    private func appendingSystemDNS(to node: Node?) throws -> Node {
        var nameservers: [Node] = []
        var hasSystemDNS = false
        if let node {
            guard let sequence = node.sequence, sequence.allSatisfy({ $0.scalar != nil && $0.null == nil }) else {
                throw DNSOverrideError.invalidValue(section: "dns", key: "nameserver")
            }
            nameservers = sequence.filter {
                guard $0.string == "system://" else { return true }
                defer { hasSystemDNS = true }
                return !hasSystemDNS
            }
        }
        if !hasSystemDNS { nameservers.append(Node("system://")) }
        return Node(nameservers)
    }
}

public enum DNSOverrideError: Error, LocalizedError, Equatable {
    case invalidValue(section: String, key: String)

    public var errorDescription: String? {
        switch self {
        case let .invalidValue(section, key):
            return "\(section)\(key.isEmpty ? "" : "." + key) 的 YAML 值无效。"
        }
    }
}
