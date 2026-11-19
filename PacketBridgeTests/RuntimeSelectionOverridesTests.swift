import Foundation
import XCTest
@testable import PacketBridge

final class RuntimeSelectionOverridesTests: XCTestCase {
    func testLatePreparationCannotReplaceChoicesAlreadySetOnItsDestination() throws {
        let saved = try JSONEncoder().encode(RuntimeConfiguration(outbound: .mihomo(yaml: "mode: rule")))
        let overrides = RuntimeSelectionOverrides()
        try overrides.set(["MAIN": "old"], revision: "source")
        let old = try overrides.configuration(saved, revision: "source")
        try overrides.set(["MAIN": "new"], revision: "ready")
        try overrides.rememberPrepared(source: "source", prepared: "ready", configuration: old)
        let current = try RuntimeConfiguration.decode(overrides.configuration(saved, revision: "ready"))
        XCTAssertEqual(current.outbound, .mihomo(yaml: "mode: rule", selections: ["MAIN": "new"]))
    }

    func testTemporaryChoicesFollowPreparedRevisionButNotANewExtension() throws {
        let saved = try JSONEncoder().encode(RuntimeConfiguration(outbound: .mihomo(yaml: "profile: {store-selected: false}")))
        let overrides = RuntimeSelectionOverrides()
        try overrides.set(["MAIN": "working"], revision: "source")
        let active = try overrides.configuration(saved, revision: "source")
        try overrides.rememberPrepared(source: "source", prepared: "ready", configuration: active)
        XCTAssertEqual(try RuntimeConfiguration.decode(overrides.configuration(saved, revision: "ready")),
                       try RuntimeConfiguration.decode(active))
        XCTAssertEqual(try RuntimeSelectionOverrides().configuration(saved, revision: "ready"), saved)
        overrides.reset()
        XCTAssertEqual(try overrides.configuration(saved, revision: "ready"), saved)
    }

    func testLatePreparationDoesNotReplaceANewerManualSelection() throws {
        let saved = try JSONEncoder().encode(RuntimeConfiguration(outbound: .mihomo(yaml: "mode: rule")))
        let overrides = RuntimeSelectionOverrides()
        try overrides.set(["MAIN": "old"], revision: "source")
        let old = try overrides.configuration(saved, revision: "source")
        overrides.select(group: "MAIN", node: "new", revision: "source")
        try overrides.rememberPrepared(source: "source", prepared: "ready", configuration: old)
        XCTAssertEqual(try overrides.configuration(saved, revision: "ready"), saved)
        let current = try RuntimeConfiguration.decode(overrides.configuration(saved, revision: "source"))
        XCTAssertEqual(current.outbound, .mihomo(yaml: "mode: rule", selections: ["MAIN": "new"]))
    }

    func testOnlineChoicePreservesOtherSavedGroupsAndControlRoundTrips() throws {
        let saved = try JSONEncoder().encode(RuntimeConfiguration(outbound: .mihomo(yaml: "mode: rule", selections: ["A": "first", "B": "second"])))
        let overrides = RuntimeSelectionOverrides()
        overrides.select(group: "A", node: "replacement", revision: "ready")
        let current = try RuntimeConfiguration.decode(overrides.configuration(saved, revision: "ready"))
        XCTAssertEqual(current.outbound, .mihomo(yaml: "mode: rule", selections: ["A": "replacement", "B": "second"]))
        let request = TunnelControlRequest(action: .applyRevision, revision: "ready", selections: ["A": "replacement"])
        let decoded = try JSONDecoder().decode(TunnelControlRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(decoded.selections, request.selections)
        XCTAssertThrowsError(try RuntimeSelectionOverrides.decode(Data(repeating: 65, count: 16_385)))
    }
}
