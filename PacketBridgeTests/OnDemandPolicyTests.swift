import Foundation
import NetworkExtension
import XCTest
@testable import PacketBridge

final class OnDemandPolicyTests: XCTestCase {
    func testDefaultPolicyIsDisabledAndUnmatchedNetworksAreIgnored() throws {
        let policy = OnDemandPolicy()
        XCTAssertFalse(policy.enabled)
        let rules = try policy.systemRules()
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0].action, .ignore)
        XCTAssertEqual(rules[0].interfaceTypeMatch, .any)
    }

    func testRulesPreserveOrderAndExactSSID() throws {
        let policy = OnDemandPolicy(enabled: true, rules: [
            OnDemandRule(name: "Home", network: .wifi, ssid: " Home WiFi ", action: .disconnect),
            OnDemandRule(name: "WiFi", network: .wifi, action: .connect),
            OnDemandRule(name: "Default", network: .any, action: .ignore),
        ])
        let rules = try policy.systemRules()
        XCTAssertEqual(rules.map(\.action), [.disconnect, .connect, .ignore, .ignore])
        XCTAssertEqual(rules[0].ssidMatch, [" Home WiFi "])
        XCTAssertEqual(rules[0].interfaceTypeMatch, .wiFi)
        XCTAssertNil(rules[1].ssidMatch)
        XCTAssertEqual(rules[2].interfaceTypeMatch, .any)
    }

    func testRejectsInvalidRulesAtPersistenceAndMappingBoundaries() throws {
        let invalid: [OnDemandPolicy] = [
            OnDemandPolicy(enabled: true),
            OnDemandPolicy(rules: [OnDemandRule(name: "", network: .wifi, action: .connect)]),
            OnDemandPolicy(rules: [OnDemandRule(name: "bad", network: .cellular, ssid: "Home", action: .connect)]),
            OnDemandPolicy(rules: [OnDemandRule(name: "bad", network: .wifi, ssid: String(repeating: "a", count: 33), action: .connect)]),
        ]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OnDemandPolicyStore(root: root)
        for policy in invalid {
            XCTAssertThrowsError(try policy.validate())
            XCTAssertThrowsError(try policy.systemRules())
            XCTAssertThrowsError(try store.save(policy))
        }
    }

    func testDraftRoundTripPreservesDisabledRuleOrderAndIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OnDemandPolicyStore(root: root)
        XCTAssertEqual(try store.load(), OnDemandPolicy())
        let policy = OnDemandPolicy(rules: [
            OnDemandRule(name: "Cellular", network: .cellular, action: .connect),
            OnDemandRule(name: "Home", network: .wifi, ssid: "Home", action: .disconnect),
        ])
        try store.save(policy)
        XCTAssertEqual(try store.load(), policy)
        let changed = OnDemandPolicy(enabled: true, rules: policy.rules.reversed())
        try store.save(changed)
        XCTAssertEqual(try OnDemandPolicyStore(root: root).load(), changed)
    }

    func testCellularMappingIsExplicitlyPlatformSpecific() throws {
        let policy = OnDemandPolicy(rules: [OnDemandRule(name: "Cellular", network: .cellular, action: .connect)])
        #if os(iOS)
        XCTAssertEqual(try policy.systemRules()[0].interfaceTypeMatch, .cellular)
        #else
        XCTAssertThrowsError(try policy.systemRules())
        #endif
    }
}
