import Foundation
import Yams

enum ProfileProxyFiles {
    static func proxies(provider: Node, data: Data?) -> [Node] {
        if provider["type"]?.string == "inline" { return provider["payload"]?.sequence?.map { $0 } ?? [] }
        guard let data, let document = try? EffectiveYAML.compose(data: data) else { return [] }
        return document["proxies"]?.sequence?.map { $0 } ?? []
    }

    static func paths(in proxies: [Node]) throws -> Set<String> {
        var paths = Set<String>()
        var visited = 0
        func collect(_ node: Node, depth: Int) throws {
            visited += 1
            guard depth <= 64, visited <= 262_144 else {
                throw ProfileResourceError.invalidProvider(kind: .proxyFile, name: "proxy resource references")
            }
            if let mapping = node.mapping {
                let kind = node["type"]?.string
                for (key, value) in mapping {
                    if let field = key.string, let text = value.string, !text.isEmpty {
                        if field == "certificate", !text.contains("-----BEGIN ") { paths.insert(text) }
                        if field == "private-key", kind != "wireguard", kind != "masque", !text.contains("PRIVATE KEY") {
                            paths.insert(text)
                        }
                    }
                    try collect(value, depth: depth + 1)
                }
            } else if let sequence = node.sequence {
                for value in sequence { try collect(value, depth: depth + 1) }
            }
        }
        for proxy in proxies { try collect(proxy, depth: 0) }
        return paths
    }
}
