import Foundation
import XCTest
@testable import PacketBridge

final class YAMLMergeTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }

    func testInheritedCertificateRetainsScalarPathAndExplicitOverrideDoesNotRequireBaseFile() async throws {
        let yaml = Data("""
        tls: &tls {type: trojan, certificate: 001}
        proxies:
          - {<<: *tls, name: inherited}
          - {<<: *tls, name: overridden, certificate: '-----BEGIN CERTIFICATE----- inline'}
        """.utf8)
        let original = yaml
        let bundle = try await preparer().prepare(yaml: yaml, localFiles: ["001": Data("fixture certificate".utf8)])
        let entries = try manifest(XCTUnwrap(bundle))
        XCTAssertEqual(entries.compactMap { $0["name"] as? String }, ["001"])
        XCTAssertEqual(yaml, original)
        let overridden = Data("tls: &tls {type: trojan, certificate: missing.pem}\nproxies: [{<<: *tls, name: inline, certificate: '-----BEGIN CERTIFICATE----- inline'}]\n".utf8)
        let none = try await preparer().prepare(yaml: overridden)
        XCTAssertNil(none)
    }

    func testWireGuardMergedPrivateKeyAndOverriddenGeoRulesDoNotRequestFiles() async throws {
        let yaml = Data("""
        base: &base {private-key: not-a-file}
        route: &route {rules: ['GEOSITE,unused,DIRECT']}
        <<: *route
        rules: ['MATCH,DIRECT']
        proxies: [{<<: *base, type: wireguard, name: wg}]
        """.utf8)
        let bundle = try await preparer().prepare(yaml: yaml)
        XCTAssertNil(bundle)
    }

    func testMergePriorityAndSequenceOrderArePreservedAcrossConsumers() async throws {
        let yaml = Data("""
        first: &first {certificate: 2024-01-02, name: one}
        second: &second {certificate: ignored.pem, name: ignored}
        group: &group {type: select, proxies: [one, two, DIRECT]}
        provider: &provider {type: http, interval: 99}
        proxies:
          - {<<: [*first, *second], type: trojan}
          - {name: two, type: direct}
        proxy-groups: [{<<: *group, name: choices}]
        rule-providers: {rules: {<<: *provider, interval: 7}}
        """.utf8)
        let overview = try YAMLDocument.validate(data: yaml)
        XCTAssertEqual(overview.proxyNames, ["one", "two"])
        XCTAssertEqual(overview.proxyGroups.first?.members, ["one", "two", "DIRECT"])
        XCTAssertEqual(try ResourceRefreshSchedule.interval(yaml: yaml), 7)
        let document = try EffectiveYAML.compose(data: yaml)
        XCTAssertEqual(document["proxies"]?.array().first?["certificate"]?.string, "2024-01-02")
        XCTAssertEqual(document["proxies"]?.array().first?["name"]?.string, "one")
    }

    func testInheritedGeoRuleRequiresItsResource() async throws {
        let yaml = Data("base: &base {rules: ['GEOSITE,TEST,DIRECT']}\n<<: *base\n".utf8)
        do {
            _ = try await preparer().prepare(yaml: yaml)
            XCTFail("An inherited Geo rule must not omit its database")
        } catch let error as ProfileResourceError {
            XCTAssertEqual(error, .missingLocalFile(kind: .geoSiteDat, name: "default", path: "GeoSite.dat"))
        }
    }

    func testMergedProviderPayloadAndInvalidMergeKeysAreHandledAtBoundary() throws {
        let payload = Data("base: &base {certificate: 001}\nproxies: [{<<: *base, name: node, type: trojan}]\n".utf8)
        let provider = try EffectiveYAML.compose(data: Data("type: file".utf8))
        let proxies = ProfileProxyFiles.proxies(provider: provider, data: payload)
        XCTAssertEqual(try ProfileProxyFiles.paths(in: proxies), ["001"])
        for invalid in ["root: &root {<<: *root}", "base: &base {a: b}\n<<: *base\n? [complex, key]\n: value"] {
            XCTAssertThrowsError(try EffectiveYAML.compose(data: Data(invalid.utf8)))
        }
    }

    private func preparer() -> ProfileResourcePreparer {
        ProfileResourcePreparer(bundleStore: ResourceBundleStore(root: root), download: { _, _ in
            XCTFail("Merge analysis must not invent a download")
            return Data()
        })
    }

    private func manifest(_ id: String) throws -> [[String: Any]] {
        let directory = try ResourceBundleStore(root: root).directory(id: id)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        return try XCTUnwrap((object as? [String: Any])?["entries"] as? [[String: Any]])
    }
}
