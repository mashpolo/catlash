import Foundation
import XCTest
@testable import PacketBridge

final class RuntimeSnapshotTests: XCTestCase {
    func testRatesUseActualIntervalAndResetAcrossSessions() throws {
        var tracker = RuntimeTrafficTracker()
        XCTAssertNil(tracker.sample(try snapshot(time: 1_000, upload: 100, download: 200)))
        let rate = try XCTUnwrap(tracker.sample(try snapshot(time: 3_000, upload: 300, download: 800)))
        XCTAssertEqual(rate.uploadBytesPerSecond, 100)
        XCTAssertEqual(rate.downloadBytesPerSecond, 300)
        XCTAssertNil(tracker.sample(try snapshot(session: "second", time: 4_000, upload: 50, download: 100)))
        tracker.reset()
        XCTAssertNil(tracker.sample(try snapshot(session: "second", time: 5_000, upload: 100, download: 200)))
    }

    func testDuplicateTimeAndCounterRollbackDoNotProduceInvalidRates() throws {
        var tracker = RuntimeTrafficTracker()
        _ = tracker.sample(try snapshot(time: 1_000, upload: 100, download: 100))
        XCTAssertNil(tracker.sample(try snapshot(time: 1_000, upload: 200, download: 200)))
        XCTAssertNil(tracker.sample(try snapshot(time: 500, upload: 200, download: 200)))
        XCTAssertNil(tracker.sample(try snapshot(time: 2_000, upload: 10, download: 10)))
        let rate = try XCTUnwrap(tracker.sample(try snapshot(time: 3_000, upload: 20, download: 30)))
        XCTAssertEqual(rate.uploadBytesPerSecond, 10)
        XCTAssertEqual(rate.downloadBytesPerSecond, 20)
    }

    func testControlEnvelopePreservesRuntimeAndConnectionID() throws {
        let state = try snapshot(time: 1_000, upload: 123, download: 456)
        let request = TunnelControlRequest(action: .closeConnection, connectionID: "session:42")
        let decoded = try JSONDecoder().decode(TunnelControlRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(decoded.connectionID, "session:42")
        let response = TunnelControlResponse(id: request.id, runtime: state)
        let restored = try JSONDecoder().decode(TunnelControlResponse.self, from: JSONEncoder().encode(response))
        XCTAssertEqual(restored.runtime?.sessionID, "first")
        XCTAssertEqual(restored.runtime?.downloadTotal, 456)
    }

    private func snapshot(session: String = "first", time: Int64, upload: Int64, download: Int64) throws -> RuntimeSnapshot {
        let object: [String: Any] = [
            "sessionID": session, "sampledAt": time, "uploadTotal": upload, "downloadTotal": download,
            "activeCount": 0, "connections": [], "logs": [], "droppedConnections": 0, "droppedLogs": 0,
        ]
        return try JSONDecoder().decode(RuntimeSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
