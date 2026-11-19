import Foundation
import Yams

enum ProfileGeodataRequirements {
    static func required(document: Node, providerRules: [String]) -> Set<ResourceKind> {
        let country: ResourceKind = document["geodata-mode"]?.bool == true ? .geoIPDat : .geoIPMMDB
        var kinds = Set<ResourceKind>()
        let subRules = document["sub-rules"]?.mapping?.flatMap { strings($0.value) } ?? []
        for rule in strings(document["rules"]) + subRules + providerRules { collect(rule: rule, country: country, into: &kinds) }
        if let sniffer = document["sniffer"], sniffer["enable"]?.bool == true {
            for field in ["force-domain", "skip-domain"] {
                if strings(sniffer[field]).contains(where: isGeosite) { kinds.insert(.geoSiteDat) }
            }
            for field in ["skip-src-address", "skip-dst-address"] {
                for address in strings(sniffer[field]) where address.lowercased().hasPrefix("geoip:") {
                    for countryCode in address.dropFirst(6).split(separator: ",") {
                        collect(rule: "GEOIP,\(countryCode)", country: country, into: &kinds)
                    }
                }
            }
        }
        guard let dns = document["dns"], dns["enable"]?.bool == true else { return kinds }
        for field in ["nameserver-policy", "proxy-server-nameserver-policy"] {
            for (key, _) in dns[field]?.mapping ?? [:] {
                if let key = key.string, key.split(separator: ",").contains(where: { isGeosite(String($0)) }) {
                    kinds.insert(.geoSiteDat)
                }
            }
        }
        if dns["enhanced-mode"]?.string?.lowercased() == "fake-ip" {
            for value in strings(dns["fake-ip-filter"]) {
                if dns["fake-ip-filter-mode"]?.string?.lowercased() == "rule" {
                    collect(rule: value, country: country, into: &kinds)
                } else if isGeosite(value) { kinds.insert(.geoSiteDat) }
            }
        }
        if !strings(dns["fallback"]).isEmpty {
            let filter = dns["fallback-filter"]
            let code = filter?["geoip-code"]?.string ?? "CN"
            if filter?["geoip"]?.bool != false, code.lowercased() != "lan" { kinds.insert(country) }
            if !strings(filter?["geosite"]).isEmpty { kinds.insert(.geoSiteDat) }
        }
        return kinds
    }

    static func classicalRules(provider: Node, data: Data?) -> [String] {
        guard provider["behavior"]?.string == "classical" else { return [] }
        if provider["type"]?.string == "inline" { return strings(provider["payload"]) }
        guard let data, let text = String(data: data, encoding: .utf8) else { return [] }
        switch provider["format"]?.string ?? "yaml" {
        case "text":
            return text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        case "yaml":
            guard let document = try? EffectiveYAML.compose(data: data) else { return [] }
            return strings(document["payload"] ?? document["rules"])
        default:
            return []
        }
    }

    private static func collect(rule: String, country: ResourceKind, into kinds: inout Set<ResourceKind>) {
        var pending = [rule[...]]
        while let rule = pending.popLast() {
            let fields = rule.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2 else { continue }
            let type = fields[0].trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if ["AND", "OR", "NOT", "SUB-RULE"].contains(type) {
                guard let condition = groups(in: fields[1], firstOnly: true).first else { continue }
                if type == "SUB-RULE" { pending.append(condition) }
                else { pending.append(contentsOf: groups(in: condition)) }
                continue
            }
            let payload = fields[1].split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !payload.isEmpty else { continue }
            switch type {
            case "GEOIP", "SRC-GEOIP":
                if payload.lowercased() != "lan" { kinds.insert(country) }
            case "IP-ASN", "SRC-IP-ASN": kinds.insert(.asnMMDB)
            case "GEOSITE": kinds.insert(.geoSiteDat)
            default: break
            }
        }
    }

    private static func groups(in value: Substring, firstOnly: Bool = false) -> [Substring] {
        var depth = 0
        var count = 0
        var start = value.startIndex
        var result: [Substring] = []
        for index in value.indices {
            if value[index] == "(" {
                if depth == 0 { start = value.index(after: index) }
                depth += 1
                count += 1
                // The core rejects logical payloads beyond these bounds.
                guard depth <= 64, count <= 1024 else { return [] }
            } else if value[index] == ")" {
                depth -= 1
                guard depth >= 0 else { return [] }
                if depth == 0 {
                    result.append(value[start..<index])
                    if firstOnly { return result }
                }
            }
        }
        return depth == 0 ? result : []
    }

    private static func isGeosite(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("geosite:")
    }

    private static func strings(_ node: Node?) -> [String] { node?.array(of: String.self) ?? [] }
}
