import Foundation
import Yams

public struct ProfileRule: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let raw: String
    public let type: String
    public let payload: String
    public let target: String
    public let options: [String]

    public init(raw: String, id: UUID = UUID()) throws {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, !value.contains(where: { $0.isNewline }), let first = value.firstIndex(of: ",") else {
            throw ProfileRuleError.invalidRule
        }
        let type = value[..<first].trimmingCharacters(in: .whitespaces).uppercased()
        let rest = value[value.index(after: first)...]
        let payload: String
        let target: String
        let options: [String]
        if type == "MATCH" {
            guard !rest.contains(",") else { throw ProfileRuleError.invalidRule }
            payload = ""
            target = rest.trimmingCharacters(in: .whitespaces)
            options = []
        } else if ["AND", "OR", "NOT", "SUB-RULE", "DOMAIN-REGEX", "PROCESS-NAME-REGEX", "PROCESS-PATH-REGEX"].contains(type) {
            // Mihomo treats the final comma as the target separator for these
            // types. All nested conditions and regex quantifiers stay intact.
            guard let last = rest.lastIndex(of: ",") else { throw ProfileRuleError.invalidRule }
            payload = rest[..<last].trimmingCharacters(in: .whitespaces)
            target = rest[rest.index(after: last)...].trimmingCharacters(in: .whitespaces)
            options = []
        } else {
            let fields = rest.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 2 else { throw ProfileRuleError.invalidRule }
            payload = fields[0]
            target = fields[1]
            options = Array(fields.dropFirst(2))
        }
        guard !type.isEmpty, !target.isEmpty, type == "MATCH" || !payload.isEmpty else { throw ProfileRuleError.invalidRule }
        self.id = id
        self.raw = value
        self.type = type
        self.payload = payload
        self.target = target
        self.options = options
    }
}

public struct ProfileRuleFields: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case domain = "DOMAIN", suffix = "DOMAIN-SUFFIX", keyword = "DOMAIN-KEYWORD"
        case cidr = "IP-CIDR", cidr6 = "IP-CIDR6", geoIP = "GEOIP", geoSite = "GEOSITE"
        case destinationPort = "DST-PORT", ruleSet = "RULE-SET", match = "MATCH"

        public var supportsNoResolve: Bool {
            switch self {
            case .cidr, .cidr6, .geoIP, .ruleSet: true
            default: false
            }
        }
    }

    public var type: Kind = .domain
    public var payload = ""
    public var target = "DIRECT"
    public var noResolve = false

    public init() {}

    public init?(_ rule: ProfileRule) {
        guard let kind = Kind(rawValue: rule.type),
              rule.options.isEmpty || (kind.supportsNoResolve && rule.options == ["no-resolve"]) else { return nil }
        type = kind
        payload = rule.payload
        target = rule.target
        noResolve = !rule.options.isEmpty
    }

    public var raw: String {
        var values = [type.rawValue]
        if type != .match { values.append(payload.trimmingCharacters(in: .whitespaces)) }
        values.append(target)
        if type.supportsNoResolve && noResolve { values.append("no-resolve") }
        return values.joined(separator: ",")
    }

    public func rule(replacing original: ProfileRule?) throws -> ProfileRule {
        if let original, ProfileRuleFields(original) == self { return original }
        guard !target.contains(","), type == .match || !payload.contains(",") else { throw ProfileRuleError.invalidRule }
        return try ProfileRule(raw: raw, id: original?.id ?? UUID())
    }
}

public struct ProfileRuleDocument: Sendable {
    public let rules: [ProfileRule]
    public let policyChoices: [String]
    public let readOnlyReason: String?
    private let source: Data
    private let replacement: Range<Int>
    private let newline: String

    public init(data: Data) throws {
        guard data.count <= YAMLDocument.maximumBytes else { throw ProfileStoreError.tooLarge }
        guard let text = String(data: data, encoding: .utf8) else { throw ProfileStoreError.invalidUTF8 }
        let document = try EffectiveYAML.compose(data: data)
        if let value = document["rules"], value.tag != Tag(.null) {
            guard let sequence = value.sequence else { throw ProfileRuleError.invalidList }
            rules = try sequence.map { node in
                guard node.tag == Tag(.str), let raw = node.string else { throw ProfileRuleError.invalidList }
                return try ProfileRule(raw: raw)
            }
        } else { rules = [] }
        let groups = document["proxy-groups"]?.array().compactMap { $0["name"]?.string } ?? []
        let nodes = document["proxies"]?.array().compactMap { $0["name"]?.string } ?? []
        let targets = rules.filter { $0.type != "SUB-RULE" }.map(\.target)
        var seen = Set<String>()
        policyChoices = (["DIRECT", "REJECT", "REJECT-DROP"] + groups + nodes + targets).filter { seen.insert($0).inserted }

        let parser: Parser
        let root: Node
        do {
            parser = try Parser(yaml: text, encoding: .utf8)
            guard let parsed = try parser.singleRoot() else { throw ProfileStoreError.invalidYAML }
            root = parsed
        } catch { throw ProfileStoreError.invalidYAML }
        let layout = withExtendedLifetime(parser) { Self.layout(root: root, text: text) }
        source = data
        replacement = layout.range
        readOnlyReason = layout.reason
        newline = text.contains("\r\n") ? "\r\n" : text.contains("\r") ? "\r" : "\n"
    }

    public func replacingRules(_ updated: [ProfileRule]) throws -> Data {
        if updated.map(\.raw) == rules.map(\.raw) { return source }
        if let readOnlyReason { throw ProfileRuleError.readOnly(readOnlyReason) }
        let encoder = JSONEncoder()
        let rows = try updated.map { rule -> String in
            _ = try ProfileRule(raw: rule.raw)
            let quoted = String(decoding: try encoder.encode(rule.raw), as: UTF8.self)
            return "  - " + quoted + newline
        }.joined()
        var block = updated.isEmpty ? "rules: []" + newline : "rules:" + newline + rows
        if replacement.isEmpty, replacement.lowerBound > 0, !([10, 13] as [UInt8]).contains(source[replacement.lowerBound - 1]) {
            block = newline + block
        }
        var result = Data(source.prefix(replacement.lowerBound))
        result.append(Data(block.utf8))
        result.append(source.suffix(from: replacement.upperBound))
        _ = try YAMLDocument.validate(data: result)
        let saved = try ProfileRuleDocument(data: result)
        guard saved.rules.map(\.raw) == updated.map(\.raw) else { throw ProfileRuleError.unsafeLayout }
        return result
    }

    private static func layout(root: Node, text: String) -> (range: Range<Int>, reason: String?) {
        let unsupported = "此配置的顶层结构无法安全局部修改，请使用 YAML 编辑器修改规则。"
        guard !text.unicodeScalars.contains(where: { [0x85, 0x2028, 0x2029].contains($0.value) }),
              let mapping = root.mapping, !mapping.isEmpty else { return (0..<0, unsupported) }
        let pairs = Array(mapping)
        let marks = pairs.compactMap { $0.key.mark }
        guard marks.count == pairs.count, marks.allSatisfy({ $0.column == 1 }),
              pairs.allSatisfy({ $0.key.scalar != nil && $0.key.anchor == nil }),
              zip(marks, marks.dropFirst()).allSatisfy({ $0.line < $1.line }) else { return (0..<0, unsupported) }
        let (lines, offsets) = sourceLines(text)
        let byteCount = text.utf8.count
        let endMarker = lines.firstIndex { line in
            line == "..." || line == "...\r" || line.hasPrefix("... #")
        } ?? lines.count
        guard let index = pairs.firstIndex(where: { $0.key.string == "rules" }) else {
            let offset = min(offsets[endMarker], byteCount)
            return (offset..<offset, nil)
        }
        let pair = pairs[index]
        if hasAnchor(pair.value) {
            return (0..<0, "rules 使用了 YAML 锚点或别名。为保留其它引用，请在 YAML 编辑器中修改。")
        }
        let firstLine = marks[index].line - 1
        var endLine = index + 1 < marks.count ? marks[index + 1].line - 1 : endMarker
        // Keep comments and blank lines belonging to the following section.
        while endLine > firstLine + 1 {
            let line = lines[endLine - 1].trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { endLine -= 1 } else { break }
        }
        return (offsets[firstLine]..<min(offsets[endLine], byteCount), nil)
    }

    private static func sourceLines(_ text: String) -> ([String], [Int]) {
        let bytes = Array(text.utf8)
        var lines: [String] = []
        var offsets = [0]
        var start = 0
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 10 || bytes[index] == 13 else { index += 1; continue }
            lines.append(String(decoding: bytes[start..<index], as: UTF8.self))
            if bytes[index] == 13, index + 1 < bytes.count, bytes[index + 1] == 10 { index += 1 }
            index += 1
            start = index
            offsets.append(index)
        }
        lines.append(String(decoding: bytes[start...], as: UTF8.self))
        offsets.append(bytes.count)
        return (lines, offsets)
    }

    private static func hasAnchor(_ node: Node) -> Bool {
        if node.anchor != nil { return true }
        if let sequence = node.sequence { return sequence.contains(where: hasAnchor) }
        if let mapping = node.mapping { return mapping.contains { hasAnchor($0.key) || hasAnchor($0.value) } }
        return false
    }
}

public enum ProfileRuleError: LocalizedError {
    case invalidRule, invalidList, unsafeLayout, readOnly(String)
    public var errorDescription: String? {
        switch self {
        case .invalidRule: "规则格式不完整。请填写类型、条件和策略；MATCH 规则只填写类型与策略，每条规则占一行。"
        case .invalidList: "配置的 rules 必须是规则字符串列表。请先在 YAML 编辑器中修正。"
        case .unsafeLayout: "无法保留当前 YAML 结构，规则未保存。请使用 YAML 编辑器修改。"
        case .readOnly(let reason): reason
        }
    }
}
