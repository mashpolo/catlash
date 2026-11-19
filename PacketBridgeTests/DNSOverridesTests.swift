import Foundation
import XCTest
import Yams
@testable import PacketBridge

final class DNSOverridesTests: XCTestCase {
    func testOriginalResourceReuseRequiresAlreadyEnabledAndUnchangedDNS() throws {
        let source = Data("dns: {enable: true, nameserver: ['1.1.1.1']}\ntun: {dns-hijack: ['any:53', 'tcp://any:53']}".utf8)
        XCTAssertTrue(try DNSOverrides().canReuseSourceResources(source))
        XCTAssertTrue(try DNSOverrides(tun: ["mtu": "1400"]).canReuseSourceResources(source))
        XCTAssertFalse(try DNSOverrides(appendSystemDNS: true).canReuseSourceResources(source))
        XCTAssertFalse(try DNSOverrides(dns: ["nameserver": "['1.1.1.1']"]).canReuseSourceResources(source))
        XCTAssertFalse(try DNSOverrides().canReuseSourceResources(Data("dns: {enable: false}".utf8)))
        XCTAssertFalse(try DNSOverrides().canReuseSourceResources(Data("mode: rule".utf8)))
    }

    func testDisabledDNSGetsDefaultsWhileOtherConfigurationSurvives() throws {
        for enabled in ["", "dns: {enable: false, ipv6: true}\n"] {
            let source = Data((enabled + "tun: {stack: gvisor, dns-hijack: ['tcp://any:53']}\nproxies: [{name: node, password: '001'}]\nrules: ['MATCH,DIRECT']\n").utf8)
            let effective = try DNSOverrides().applying(to: source)
            let document = try EffectiveYAML.compose(data: effective)
            XCTAssertEqual(document["dns"]?["enable"]?.bool, true)
            XCTAssertEqual(document["dns"]?["enhanced-mode"]?.string, "fake-ip")
            XCTAssertEqual(document["dns"]?["nameserver"]?.array(of: String.self), ["https://doh.pub/dns-query", "https://dns.alidns.com/dns-query"])
            XCTAssertEqual(document["tun"]?["dns-hijack"]?.array(of: String.self), ["any:53"])
            XCTAssertEqual(document["tun"]?["stack"]?.string, "gvisor")
            XCTAssertEqual(document["proxies"]?.array().first?["password"]?.string, "001")
            XCTAssertEqual(document["rules"]?.array(of: String.self), ["MATCH,DIRECT"])
            XCTAssertEqual(try DNSOverrides().applying(to: effective), effective)
        }
    }

    func testEnabledDNSIsPreservedAndOnlySelectedKeysReplaceValues() throws {
        let source = Data("dns: {enable: true, enhanced-mode: redir-host, nameserver: ['1.1.1.1'], fallback: ['8.8.8.8'], nameserver-policy: {'+.old.test': ['9.9.9.9']}}\ntun: {mtu: 1400}\n".utf8)
        let unchanged = try EffectiveYAML.compose(data: DNSOverrides().applying(to: source))
        XCTAssertEqual(unchanged["dns"]?["enhanced-mode"]?.string, "redir-host")
        XCTAssertEqual(unchanged["dns"]?["nameserver"]?.array(of: String.self), ["1.1.1.1"])
        let overrides = DNSOverrides(appendSystemDNS: true, dns: ["nameserver": "['8.8.4.4', 'system://', 'system://']", "nameserver-policy": "{'+.new.test': ['https://doh.pub/dns-query']}"], tun: ["dns-hijack": "['tcp://any:53']"])
        let document = try EffectiveYAML.compose(data: overrides.applying(to: source))
        XCTAssertEqual(document["dns"]?["nameserver"]?.array(of: String.self), ["8.8.4.4", "system://"])
        XCTAssertEqual(document["dns"]?["fallback"]?.array(of: String.self), ["8.8.8.8"])
        XCTAssertNil(document["dns"]?["nameserver-policy"]?["+.old.test"])
        XCTAssertNotNil(document["dns"]?["nameserver-policy"]?["+.new.test"])
        XCTAssertEqual(document["tun"]?["dns-hijack"]?.array(of: String.self), ["tcp://any:53"])
        XCTAssertEqual(document["tun"]?["mtu"]?.int, 1400)
    }

    func testSystemDNSAppendDoesNotReplaceProfileNameservers() throws {
        let source = Data("dns: {enable: true, nameserver: ['1.1.1.1', '1.1.1.1']}".utf8)
        let value = try EffectiveYAML.compose(data: DNSOverrides(appendSystemDNS: true).applying(to: source))
        XCTAssertEqual(value["dns"]?["nameserver"]?.array(of: String.self), ["1.1.1.1", "1.1.1.1", "system://"])
    }

    func testOverridesPreserveMergedNodesAndDiscoverNewDNSResources() async throws {
        let source = Data("geox-url: {geosite: 'https://example.invalid/geosite.dat'}\nbase: &defaults {enable: true, nameserver: ['system://', '1.1.1.1']}\ndns: {<<: *defaults}\nproxies: [{name: node, password: 'true'}]\n".utf8)
        let overrides = DNSOverrides(appendSystemDNS: true, dns: ["enhanced-mode": "fake-ip", "fake-ip-filter": "['geosite:TEST']"])
        let effective = try overrides.applying(to: source)
        let document = try EffectiveYAML.compose(data: effective)
        XCTAssertEqual(document["dns"]?["nameserver"]?.array(of: String.self), ["system://", "1.1.1.1"])
        XCTAssertEqual(document["proxies"]?.array().first?["password"]?.string, "true")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ResourceBundleStore(root: root)
        let preparer = ProfileResourcePreparer(bundleStore: store, download: { _, _ in Data("geosite fixture".utf8) })
        let originalBundle = try await preparer.prepare(yaml: source)
        XCTAssertNil(originalBundle)
        let prepared = try await preparer.prepare(yaml: effective)
        let bundle = try XCTUnwrap(prepared)
        XCTAssertEqual(try store.entries(id: bundle, kind: .geoSiteDat).count, 1)
    }

    func testOverrideValidationRejectsBrokenFragmentsWithoutEchoingValues() throws {
        for overrides in [DNSOverrides(dns: ["nameserver": "[private-token"]), DNSOverrides(tun: ["dns-hijack": "[private-token"])] {
            XCTAssertThrowsError(try overrides.validate()) { error in
                XCTAssertFalse(error.localizedDescription.contains("private-token"))
            }
        }
        let source = Data("dns: {enable: true, nameserver: invalid}".utf8)
        XCTAssertThrowsError(try DNSOverrides(appendSystemDNS: true).applying(to: source))
    }
}
