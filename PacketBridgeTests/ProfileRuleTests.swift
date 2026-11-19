import XCTest
@testable import PacketBridge

final class ProfileRuleTests: XCTestCase {
    func testRuleFieldsPreserveUnchangedTextAndProduceValidEdits() throws {
        let original = try ProfileRule(raw: "IP-CIDR, 192.0.2.0/24 , Proxy ,no-resolve")
        var fields = try XCTUnwrap(ProfileRuleFields(original))
        XCTAssertEqual(try fields.rule(replacing: original), original)
        fields.target = "DIRECT"
        XCTAssertEqual(try fields.rule(replacing: original).raw, "IP-CIDR,192.0.2.0/24,DIRECT,no-resolve")
        XCTAssertEqual(try fields.rule(replacing: original).id, original.id)
        fields.type = .match
        XCTAssertEqual(try fields.rule(replacing: original).raw, "MATCH,DIRECT")
        fields.type = .domain
        fields.payload = "example.com,REJECT"
        XCTAssertThrowsError(try fields.rule(replacing: original))
        for raw in ["AND,((NETWORK,TCP),(DST-PORT,80)),Proxy", "DOMAIN-REGEX,^a{1,3}$,DIRECT",
                    "IP-CIDR,192.0.2.0/24,Proxy,src", "UNKNOWN,foo,Proxy"] {
            XCTAssertNil(ProfileRuleFields(try ProfileRule(raw: raw)))
        }
    }

    func testRuleTargetChoicesComeFromEditedProfile() throws {
        let profile = """
        group-default: &group {name: 工作组, type: select, proxies: [本地节点]}
        proxy-groups: [*group]
        proxies: [{name: 本地节点, type: direct}]
        rules: ['DOMAIN,example.org,已有来源节点', 'MATCH,工作组']
        """
        let document = try ProfileRuleDocument(data: Data(profile.utf8))
        XCTAssertEqual(document.policyChoices, ["DIRECT", "REJECT", "REJECT-DROP", "工作组", "本地节点", "已有来源节点"])
    }

    func testLogicalRegexAndOptionsKeepTheirPayloadAndTarget() throws {
        let logic = try ProfileRule(raw: "AND,((DOMAIN,example.com),(OR,((NETWORK,UDP),(DST-PORT,443)))),Proxy")
        XCTAssertEqual(logic.type, "AND")
        XCTAssertEqual(logic.target, "Proxy")
        XCTAssertEqual(logic.payload, "((DOMAIN,example.com),(OR,((NETWORK,UDP),(DST-PORT,443))))")
        let regex = try ProfileRule(raw: "DOMAIN-REGEX,^a{1,3}\\.example$,DIRECT")
        XCTAssertEqual(regex.payload, "^a{1,3}\\.example$")
        XCTAssertEqual(regex.target, "DIRECT")
        let network = try ProfileRule(raw: "IP-CIDR,192.0.2.0/24,Proxy,no-resolve")
        XCTAssertEqual(network.target, "Proxy")
        XCTAssertEqual(network.options, ["no-resolve"])
        XCTAssertEqual(try ProfileRule(raw: "MATCH,DIRECT").payload, "")
        for invalid in ["", "MATCH,", "DOMAIN,example.com", "MATCH,DIRECT\nmode: global"] {
            XCTAssertThrowsError(try ProfileRule(raw: invalid))
        }
    }

    func testEditDeleteInsertAndReorderPreserveAllOtherYAMLBytes() throws {
        let prefix = "# 配置\r\nproxy-groups:\r\n  - {name: 代理, type: select, proxies: [DIRECT]}\r\nsecret: 'a:#b' # keep\r\n"
        let suffix = "# DNS 的注释\r\ndns: {enable: true, nameserver: [system://]}\r\n...\r\n"
        let original = Data((prefix + "rules:\r\n  - DOMAIN,example.com,代理\r\n  - MATCH,DIRECT\r\n" + suffix).utf8)
        let document = try ProfileRuleDocument(data: original)
        XCTAssertNil(document.readOnlyReason)
        XCTAssertEqual(try document.replacingRules(document.rules), original)
        let edited = [try ProfileRule(raw: "DOMAIN-SUFFIX,测试.example,DIRECT"), document.rules[1], document.rules[0]]
        let saved = try document.replacingRules(edited)
        let text = String(decoding: saved, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix(prefix))
        XCTAssertTrue(text.hasSuffix(suffix))
        XCTAssertEqual(try ProfileRuleDocument(data: saved).rules.map(\.raw), edited.map(\.raw))
        let empty = try ProfileRuleDocument(data: saved).replacingRules([])
        XCTAssertEqual(try ProfileRuleDocument(data: empty).rules.count, 0)
        XCTAssertTrue(String(decoding: empty, as: UTF8.self).hasSuffix(suffix))
    }

    func testFlowRulesAndMissingRulesCanBeEditedWithoutRewritingOtherFields() throws {
        for source in ["mode: rule\nrules: ['MATCH,DIRECT'] # old\nkeep: 'unchanged'\n",
                       "mode: rule\nkeep: 'unchanged'\n...\n", "mode: rule", "mode: rule\nrules: null\n"] {
            let document = try ProfileRuleDocument(data: Data(source.utf8))
            XCTAssertNil(document.readOnlyReason)
            let raw = "DOMAIN-REGEX,^a{1,3}\\.example$,DIRECT"
            let saved = try document.replacingRules([ProfileRule(raw: raw)])
            XCTAssertEqual(try ProfileRuleDocument(data: saved).rules.map(\.raw), [raw])
            if source.contains("keep:") { XCTAssertTrue(String(decoding: saved, as: UTF8.self).contains("keep: 'unchanged'\n")) }
        }
    }

    func testMergedRulesBecomeExplicitAndAnchoredRulesRemainReadOnly() throws {
        let inherited = "defaults: &defaults\n  rules: ['MATCH,DIRECT']\n<<: *defaults\nmode: rule\n"
        let document = try ProfileRuleDocument(data: Data(inherited.utf8))
        XCTAssertEqual(document.rules.map(\.raw), ["MATCH,DIRECT"])
        let saved = try document.replacingRules([ProfileRule(raw: "MATCH,REJECT")])
        XCTAssertTrue(String(decoding: saved, as: UTF8.self).hasPrefix(inherited))
        XCTAssertEqual(try ProfileRuleDocument(data: saved).rules.map(\.raw), ["MATCH,REJECT"])
        for source in ["defaults: &rules ['MATCH,DIRECT']\nrules: *rules\n",
                       "rules: &rules ['MATCH,DIRECT']\nother: *rules\n",
                       "rules:\n  - &match MATCH,DIRECT\nother: *match\n",
                       "{mode: rule, rules: ['MATCH,DIRECT']}\n"] {
            let guarded = try ProfileRuleDocument(data: Data(source.utf8))
            XCTAssertEqual(guarded.rules.map(\.raw), ["MATCH,DIRECT"])
            XCTAssertNotNil(guarded.readOnlyReason)
            XCTAssertThrowsError(try guarded.replacingRules([ProfileRule(raw: "MATCH,REJECT")]))
            XCTAssertEqual(try guarded.replacingRules(guarded.rules), Data(source.utf8))
        }
    }

    func testCarriageReturnAndMixedLineEndingsPreserveUntouchedBytes() throws {
        for newline in ["\r", "\r\n"] {
            let prefix = "# header" + newline + "mode: rule" + newline
            let suffix = "dns: {enable: true}\n# retain LF here\r"
            let source = Data((prefix + "rules: ['MATCH,DIRECT']" + newline + suffix).utf8)
            let document = try ProfileRuleDocument(data: source)
            XCTAssertNil(document.readOnlyReason)
            let saved = try document.replacingRules([ProfileRule(raw: "MATCH,REJECT")])
            XCTAssertEqual(try ProfileRuleDocument(data: saved).rules.map(\.raw), ["MATCH,REJECT"])
            let text = String(decoding: saved, as: UTF8.self)
            XCTAssertTrue(text.hasPrefix(prefix))
            XCTAssertTrue(text.hasSuffix(suffix))
        }
    }

    func testCarriageReturnRulesAtStartDoNotRemoveFollowingMode() throws {
        let source = Data("rules: ['MATCH,DIRECT']\rmode: global\r".utf8)
        let document = try ProfileRuleDocument(data: source)
        let saved = try document.replacingRules([ProfileRule(raw: "MATCH,REJECT")])
        XCTAssertTrue(String(decoding: saved, as: UTF8.self).hasSuffix("mode: global\r"))
        XCTAssertEqual(try ProfileRuleDocument(data: saved).rules.map(\.raw), ["MATCH,REJECT"])
    }

    func testRejectsNonStringRulesAndMultipleDocuments() throws {
        for source in ["rules: [123]\n", "rules: {a: b}\n", "rules: [true]\n", "rules: []\n---\nmode: rule\n"] {
            XCTAssertThrowsError(try ProfileRuleDocument(data: Data(source.utf8)))
        }
    }
}
