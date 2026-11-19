import Foundation
import XCTest
@testable import PacketBridge

final class YAMLProviderCatalogTests: XCTestCase {
    func testOfflineProtocolMetadataUsesProviderFinalNamesAndSurvivesStorage() throws {
        let yaml = Data("proxies: [{name: local, type: trojan}]\nproxy-providers: {remote: {type: http, override: {additional-prefix: 'P-', additional-suffix: '-X'}}}\nproxy-groups: [{name: Main, type: select, proxies: [local, DIRECT], use: [remote]}]".utf8)
        let provider = Data("proxies: [{name: JP, type: ss}, {name: US, type: anytls}]".utf8)
        let document = try YAMLDocument.validate(data: yaml, providerData: ["remote": provider])
        let bytes = try JSONEncoder().encode(document)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let protocols = encoded["proxyTypes"] as? [String: String]
        XCTAssertEqual(protocols?["local"], "trojan")
        XCTAssertEqual(protocols?["P-JP-X"], "ss")
        XCTAssertEqual(protocols?["P-US-X"], "anytls")
        XCTAssertEqual(protocols?["Main"], "select")
        XCTAssertNil(protocols?["JP"])
        XCTAssertEqual(try JSONDecoder().decode(YAMLDocument.self, from: bytes), document)
        let legacy = Data(#"{"proxyNames":["old"],"proxyGroups":[],"storeSelected":true}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(YAMLDocument.self, from: legacy).proxyNames, ["old"])
    }

    func testDownloadedProviderUsesOriginalNamesForFilteringThenOverridesAndGroupFilters() throws {
        let yaml = Data("""
        proxy-providers:
          remote:
            type: http
            url: https://example.invalid/nodes
            filter: 'JP`US'
            exclude-filter: 'expired'
            exclude-type: reject
            override: {additional-prefix: 'Paid-', additional-suffix: '-01'}
        proxy-groups:
          - name: Main
            type: select
            proxies: [DIRECT]
            use: [remote]
            filter: '^Paid-JP'
            exclude-filter: 'slow'
            exclude-type: AnyTLS
        """.utf8)
        let provider = Data("""
        proxies:
          - {name: US, type: ss}
          - {name: JP-ss, type: ss}
          - {name: JP-anytls, type: anytls}
          - {name: JP-slow, type: ss}
          - {name: JP-expired, type: ss}
          - {name: JP-reject, type: reject}
        """.utf8)
        let original = yaml
        let preview = try YAMLDocument.validate(data: yaml, providerData: ["remote": provider])
        XCTAssertEqual(preview.proxyGroups.first?.members, ["DIRECT", "Paid-JP-ss-01"])
        XCTAssertEqual(yaml, original)
        XCTAssertFalse(try YAMLDocument.validate(data: yaml).proxyGroups[0].members.contains("Paid-JP-ss-01"))
    }

    func testInlineProviderAndFilterOrderExpandUseWithoutDuplicates() throws {
        let yaml = Data("""
        proxy-providers:
          inline:
            type: inline
            filter: 'US`JP'
            payload: [{name: JP, type: ss}, {name: US, type: ss}]
            override: {additional-prefix: 'P-'}
        proxy-groups: [{name: Main, type: select, use: [inline, inline]}]
        """.utf8)
        XCTAssertEqual(try YAMLDocument.validate(data: yaml).proxyGroups[0].members, ["P-US", "P-JP"])
    }

    func testBundleProviderReadVerifiesAllResourcesAndReturnsOnlyProviders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ResourceBundleStore(root: root)
        let provider = Data("proxies: [{name: JP, type: ss}]".utf8)
        let id = try store.stage(entries: [
            .init(kind: .proxyProvider, name: "remote", data: provider),
            .init(kind: .ruleProvider, name: "rules", data: Data("payload: []".utf8)),
        ])
        let entries = try store.entries(id: id, kind: .proxyProvider)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.name, "remote")
        XCTAssertEqual(entries.first?.data, provider)
        let directory = try store.directory(id: id)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let blob = try XCTUnwrap(files.first { $0.lastPathComponent != "manifest.json" })
        try Data("corrupt".utf8).write(to: blob)
        XCTAssertThrowsError(try store.entries(id: id, kind: .proxyProvider))
    }

    func testGroupFilterOrderKeepsExplicitMembersAndUsesRuntimeProtocolNames() throws {
        let yaml = Data("""
        proxy-providers:
          nodes:
            type: inline
            payload: [{name: JP, type: ss}, {name: US, type: ss}, {name: US-TLS, type: anytls}]
        proxy-groups:
          - {name: Ordered, type: select, proxies: [DIRECT], use: [nodes], filter: 'US`JP', exclude-type: AnyTLS}
          - {name: NoSS, type: select, proxies: [DIRECT], use: [nodes], exclude-type: Shadowsocks}
        """.utf8)
        let preview = try YAMLDocument.validate(data: yaml)
        XCTAssertEqual(preview.proxyGroups[0].members, ["US", "JP", "DIRECT"])
        XCTAssertEqual(preview.proxyGroups[1].members, ["DIRECT", "US-TLS"])
    }
}
