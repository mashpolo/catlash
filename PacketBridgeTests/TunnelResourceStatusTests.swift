import Foundation
import XCTest
@testable import PacketBridge

final class TunnelResourceStatusTests: XCTestCase {
    func testResourceStatusAndRetryRequestRoundTrip() throws {
        for phase: TunnelResourceStatus.Phase in [.preparing, .applying, .failed, .ready] {
            let status = TunnelResourceStatus(phase: phase, message: "VPN 已连接，正在补全规则资源。")
            let response = TunnelControlResponse(id: UUID(), resourceStatus: status)
            let decoded = try JSONDecoder().decode(TunnelControlResponse.self, from: JSONEncoder().encode(response))
            XCTAssertEqual(decoded.resourceStatus, status)
            XCTAssertNil(decoded.error)
        }
        let request = TunnelControlRequest(action: .refreshResources)
        let decoded = try JSONDecoder().decode(TunnelControlRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(decoded.action, .refreshResources)
        XCTAssertEqual(decoded.id, request.id)
        let legacy = Data("{\"id\":\"\(UUID().uuidString)\"}".utf8)
        XCTAssertNil(try JSONDecoder().decode(TunnelControlResponse.self, from: legacy).resourceStatus)
    }

    func testAttachingStatusPreservesEveryExistingResponseField() throws {
        let response = TunnelControlResponse(
            id: UUID(), catalog: .init(mode: "rule", proxies: [.init(name: "Main", type: "Selector", all: ["DIRECT"], now: "DIRECT", delay: 3, testURL: nil)], warnings: ["warning"]),
            delayMilliseconds: 7, error: "operation failed", activeRevision: "revision", restoredPrevious: true,
            metrics: .init(physicalFootprintBytes: 100, residentBytes: 200, sampledAt: Date(timeIntervalSince1970: 123)),
            runtime: .init(sessionID: "session", sampledAt: 5, uploadTotal: 10, downloadTotal: 20, activeCount: 0, connections: [], logs: [], droppedConnections: 0, droppedLogs: 0),
            sharing: .init(enabled: true, listenAddress: "127.0.0.1", httpPort: 7890, socksPort: 7891),
            exitIP: try ExitIP.decodeIPQuery(Data(#"{"ip":"203.0.113.1"}"#.utf8)), delayFailure: .timeout
        )
        let status = TunnelResourceStatus(phase: .failed, message: "规则资源更新失败，VPN 保持连接。")
        let updated = response.withResourceStatus(status)
        XCTAssertEqual(updated.resourceStatus, status)
        let restored = try JSONSerialization.jsonObject(with: JSONEncoder().encode(updated.withResourceStatus(nil))) as? NSDictionary
        let original = try JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? NSDictionary
        XCTAssertEqual(restored, original)
    }
}
