import Foundation
import XCTest
@testable import PacketBridge

final class TunnelControlTests: XCTestCase {
    func testYAMLNetworkSettingsCrossBridgeWithoutStartingSession() throws {
        let configuration = RuntimeConfiguration(outbound: .mihomo(yaml: """
        mode: direct
        ipv6: true
        dns:
          enable: true
          nameserver: [1.1.1.1]
        """))
        let plan = try GoPacketSession.networkPlan(configuration: configuration)
        XCTAssertTrue(plan.ipv4DefaultRoute)
        XCTAssertTrue(plan.ipv6DefaultRoute)
        XCTAssertEqual(plan.dnsServers, ["198.18.0.1"])
        XCTAssertThrowsError(try GoPacketSession.networkPlan(configuration: RuntimeConfiguration(outbound: .mihomo(yaml: "proxies: ["))))
    }

    func testRoutingModeSwitchCrossesBridgeWithoutReplacingSession() throws {
        let runtime = RuntimeConfiguration(outbound: .mihomo(yaml: "mode: rule\nrules: [\"MATCH,DIRECT\"]"))
        let data = try JSONEncoder().encode(runtime)
        let session = try GoPacketSession(configuration: String(decoding: data, as: UTF8.self))
        defer { try? session.close() }
        let sessionID = try session.runtimeSnapshot().sessionID
        for mode in ["global", "direct", "rule"] {
            try session.setMode(mode)
            XCTAssertEqual(try session.proxyCatalog().mode, mode)
            XCTAssertEqual(try session.runtimeSnapshot().sessionID, sessionID)
            let request = TunnelControlRequest(action: .setMode, mode: mode)
            let decoded = try JSONDecoder().decode(TunnelControlRequest.self, from: JSONEncoder().encode(request))
            XCTAssertEqual(decoded.mode, mode)
            XCTAssertEqual(decoded.action, .setMode)
        }
        XCTAssertThrowsError(try session.setMode("invalid"))
        XCTAssertEqual(try session.proxyCatalog().mode, "rule")
        try session.close()
        XCTAssertThrowsError(try session.setMode("direct"))
    }

    func testYAMLSessionCatalogAndSelectionStayWithinTheSameSession() throws {
        let yaml = """
        mode: rule
        proxies: []
        proxy-groups:
          - name: Selection
            type: select
            proxies: [DIRECT, REJECT]
        rules:
          - MATCH,Selection
        """
        let runtime = RuntimeConfiguration(outbound: .mihomo(yaml: yaml, selections: ["Selection": "REJECT"]))
        let data = try JSONEncoder().encode(runtime)
        let session = try GoPacketSession(configuration: String(decoding: data, as: UTF8.self))
        defer { try? session.close() }
        let initial = try session.proxyCatalog()
        XCTAssertEqual(initial.mode, "rule")
        XCTAssertEqual(initial.proxies.first { $0.name == "Selection" }?.now, "REJECT")
        try session.selectProxy(group: "Selection", name: "DIRECT")
        let selected = try session.proxyCatalog()
        XCTAssertEqual(selected.proxies.first { $0.name == "Selection" }?.now, "DIRECT")
        XCTAssertThrowsError(try session.selectProxy(group: "Selection", name: "unknown"))
        XCTAssertEqual(try session.proxyCatalog().proxies.first { $0.name == "Selection" }?.now, "DIRECT")
        session.cancelTests()
        try session.close()
        XCTAssertThrowsError(try session.proxyCatalog())
        XCTAssertThrowsError(try session.selectProxy(group: "Selection", name: "REJECT"))
    }
}
