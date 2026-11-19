import Foundation
import XCTest
@testable import PacketBridge

final class TunnelNetworkPlanTests: XCTestCase {
    func testYAMLUsesDefaultRoutesAndCoreProvidedDNS() throws {
        let configuration = RuntimeConfiguration(mtu: 1500, outbound: .mihomo(yaml: "ipv6: true\n"))
        let plan = try TunnelNetworkPlan(configuration: configuration, yamlSettings: settings(ipv6: true, dns: ["198.18.0.1"]))
        XCTAssertTrue(plan.ipv4DefaultRoute)
        XCTAssertTrue(plan.ipv6DefaultRoute)
        XCTAssertEqual(plan.dnsServers, ["198.18.0.1"])
        XCTAssertEqual(plan.mtu, 1500)
    }

    func testRealCoreSuppliesInterfaceAddressesAndPrefixes() throws {
        let plan = try GoPacketSession.networkPlan(configuration: RuntimeConfiguration(outbound: .mihomo(yaml: "ipv6: true\n")))
        XCTAssertEqual(plan.ipv4Address, "198.18.0.1")
        XCTAssertEqual(plan.ipv4PrefixLength, 30)
        XCTAssertEqual(plan.ipv4SubnetMask, "255.255.255.252")
        XCTAssertEqual(plan.ipv6Address, "fd00:198:18::1")
        XCTAssertEqual(plan.ipv6PrefixLength, 126)
    }

    func testDisabledYAMLDNSDoesNotInventAServerOrIPv6Route() throws {
        let configuration = RuntimeConfiguration(outbound: .mihomo(yaml: "mode: direct\n"))
        let plan = try TunnelNetworkPlan(configuration: configuration, yamlSettings: settings(ipv6: false, dns: []))
        XCTAssertTrue(plan.ipv4DefaultRoute)
        XCTAssertFalse(plan.ipv6DefaultRoute)
        XCTAssertTrue(plan.dnsServers.isEmpty)
    }

    func testLegacyProbeConfigurationsRetainTheirNarrowRoute() throws {
        for outbound in [RuntimeConfiguration.Outbound.direct, .socks5(server: "127.0.0.1", port: 1080)] {
            let plan = try TunnelNetworkPlan(configuration: RuntimeConfiguration(outbound: outbound))
            XCTAssertFalse(plan.ipv4DefaultRoute)
            XCTAssertFalse(plan.ipv6DefaultRoute)
            XCTAssertTrue(plan.dnsServers.isEmpty)
        }
    }

    func testMissingOrInvalidCoreSettingsCannotSilentlyFallBackToProbeRouting() {
        let configuration = RuntimeConfiguration(outbound: .mihomo(yaml: "mode: rule\n"))
        XCTAssertThrowsError(try TunnelNetworkPlan(configuration: configuration))
        for invalid in ["{}", "{\"ipv6\":true,\"dnsServers\":null}", "not JSON"] {
            XCTAssertThrowsError(try TunnelNetworkPlan(configuration: configuration, yamlSettings: Data(invalid.utf8)))
        }
    }
    func testExcludedRoutesReachNetworkExtensionSettings() throws {
        let configuration = RuntimeConfiguration(outbound: .mihomo(yaml: "ipv6: true\n"))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: settings(ipv6: true, dns: [])) as? [String: Any])
        json["ipv4ExcludedRoutes"] = [
            ["address": "192.168.50.0", "prefixLength": 24],
            ["address": "10.1.2.3", "prefixLength": 32],
            ["address": "0.0.0.0", "prefixLength": 0],
        ]
        json["ipv6ExcludedRoutes"] = [["address": "2001:db8:1234::", "prefixLength": 48]]
        let plan = try TunnelNetworkPlan(configuration: configuration, yamlSettings: JSONSerialization.data(withJSONObject: json))
        let network = plan.networkSettings()
        XCTAssertEqual(network.ipv4Settings?.excludedRoutes?.map(\.destinationAddress), ["192.168.50.0", "10.1.2.3", "0.0.0.0"])
        XCTAssertEqual(network.ipv4Settings?.excludedRoutes?.map(\.destinationSubnetMask), ["255.255.255.0", "255.255.255.255", "0.0.0.0"])
        XCTAssertEqual(network.ipv6Settings?.excludedRoutes?.map(\.destinationAddress), ["2001:db8:1234::"])
        XCTAssertEqual(network.ipv6Settings?.excludedRoutes?.map(\.destinationNetworkPrefixLength), [48])
        XCTAssertEqual(network.ipv4Settings?.includedRoutes?.first?.destinationAddress, "0.0.0.0")
        XCTAssertEqual(network.ipv6Settings?.includedRoutes?.first?.destinationAddress, "::")
    }

    func testRealCoreExcludedRoutesReachNetworkExtension() throws {
        let configuration = RuntimeConfiguration(outbound: .mihomo(yaml: """
        ipv6: true
        tun:
          route-exclude-address: [192.168.50.69/24, '2001:db8:1234::1/48']
        """))
        let network = try GoPacketSession.networkPlan(configuration: configuration).networkSettings()
        XCTAssertEqual(network.ipv4Settings?.excludedRoutes?.first?.destinationAddress, "192.168.50.0")
        XCTAssertEqual(network.ipv4Settings?.excludedRoutes?.first?.destinationSubnetMask, "255.255.255.0")
        XCTAssertEqual(network.ipv6Settings?.excludedRoutes?.first?.destinationAddress, "2001:db8:1234::")
        XCTAssertEqual(network.ipv6Settings?.excludedRoutes?.first?.destinationNetworkPrefixLength, 48)
    }

    func testExcludedRoutePrefixLengthsAreValidatedAtCoreBoundary() throws {
        let configuration = RuntimeConfiguration(outbound: .mihomo(yaml: "ipv6: true\n"))
        for (key, address, prefix) in [("ipv4ExcludedRoutes", "192.0.2.0", 33), ("ipv6ExcludedRoutes", "2001:db8::", 129)] {
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: settings(ipv6: true, dns: [])) as? [String: Any])
            json[key] = [["address": address, "prefixLength": prefix]]
            XCTAssertThrowsError(try TunnelNetworkPlan(configuration: configuration, yamlSettings: JSONSerialization.data(withJSONObject: json)))
        }
    }

    private func settings(ipv6: Bool, dns: [String]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "ipv6": ipv6, "dnsServers": dns, "ipv4Address": "198.18.0.1", "ipv4PrefixLength": 30,
            "ipv6Address": "fd00:198:18::1", "ipv6PrefixLength": 126,
        ])
    }

}
