import Foundation
import XCTest
@testable import PacketBridge

@MainActor
final class RuntimeMonitorTests: XCTestCase {
    func testStopRejectsLateReplyAndRepeatedStartDoesNotOverlapRequests() async throws {
        let requested = expectation(description: "one runtime request")
        requested.assertForOverFulfill = true
        let completed = expectation(description: "late request returned")
        var pending: CheckedContinuation<TunnelControlResponse, Never>?
        let monitor = RuntimeMonitor(sleep: { completed.fulfill(); throw CancellationError() })
        let send: RuntimeMonitor.Send = { request in
            XCTAssertEqual(request.action, .runtimeSnapshot)
            return await withCheckedContinuation { continuation in
                pending = continuation
                requested.fulfill()
            }
        }
        monitor.start(using: send)
        monitor.start(using: send)
        await fulfillment(of: [requested], timeout: 2)
        monitor.stop(clear: true)
        pending?.resume(returning: TunnelControlResponse(id: UUID(), runtime: state("old")))
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertNil(monitor.snapshot)
        XCTAssertNil(monitor.rate)
        XCTAssertFalse(monitor.isFresh)
        XCTAssertFalse(monitor.isPolling)
    }

    func testForegroundResumeKeepsNewSessionWhenOldReplyArrives() async throws {
        let requested = expectation(description: "old request")
        let completed = expectation(description: "both requests finished")
        completed.expectedFulfillmentCount = 2
        var pending: CheckedContinuation<TunnelControlResponse, Never>?
        let monitor = RuntimeMonitor(sleep: { completed.fulfill(); throw CancellationError() })
        monitor.start { _ in
            await withCheckedContinuation { continuation in
                pending = continuation
                requested.fulfill()
            }
        }
        await fulfillment(of: [requested], timeout: 2)
        monitor.stop()
        let current = state("new")
        monitor.start { request in TunnelControlResponse(id: request.id, runtime: current) }
        pending?.resume(returning: TunnelControlResponse(id: UUID(), runtime: state("old")))
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(monitor.snapshot?.sessionID, "new")
        XCTAssertTrue(monitor.isFresh)
        XCTAssertNil(monitor.rate)
        monitor.stop()
    }

    func testMissingRuntimeReportsFailureWithoutFreshOrInventedData() async {
        let completed = expectation(description: "failed sample")
        let monitor = RuntimeMonitor(sleep: { completed.fulfill(); throw CancellationError() })
        monitor.start { request in TunnelControlResponse(id: request.id) }
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertFalse(monitor.isFresh)
        XCTAssertNil(monitor.snapshot)
        XCTAssertNil(monitor.rate)
        XCTAssertNotNil(monitor.error)
        monitor.stop()
    }

    func testLogExportPreservesCapturedLevelsMessagesAndTime() async {
        let sampled = expectation(description: "logs sampled")
        let monitor = RuntimeMonitor(sleep: { sampled.fulfill(); throw CancellationError() })
        let logs = [
            RuntimeLogEntry(id: 1, time: 1_000, level: "debug", message: "调试记录"),
            RuntimeLogEntry(id: 2, time: 2_000, level: "warning", message: "connection timed out"),
        ]
        let snapshot = RuntimeSnapshot(sessionID: "logs", sampledAt: 3_000, uploadTotal: 0, downloadTotal: 0,
                                       activeCount: 0, connections: [], logs: logs, droppedConnections: 0, droppedLogs: 5)
        monitor.start { request in TunnelControlResponse(id: request.id, runtime: snapshot) }
        await fulfillment(of: [sampled], timeout: 2)
        let lines = monitor.exportedLogs.components(separatedBy: "\n")
        XCTAssertEqual(lines, [
            "1970-01-01T00:00:01Z [DEBUG] 调试记录",
            "1970-01-01T00:00:02Z [WARNING] connection timed out",
        ])
        XCTAssertEqual(monitor.snapshot?.droppedLogs, 5)
        monitor.stop(clear: true)
        XCTAssertEqual(monitor.exportedLogs, "")
    }

    func testSessionActionsCarryExpectedSessionAndRejectLateCompletion() async {
        let sampled = expectation(description: "initial snapshot")
        let actionStarted = expectation(description: "cache clear started")
        var pending: CheckedContinuation<TunnelControlResponse, Never>?
        let monitor = RuntimeMonitor(sleep: { sampled.fulfill(); throw CancellationError() })
        monitor.start { request in
            if request.action == .runtimeSnapshot { return TunnelControlResponse(id: request.id, runtime: self.state("old")) }
            XCTAssertEqual(request.action, .clearDNSCache)
            XCTAssertEqual(request.expectedSessionID, "old")
            return await withCheckedContinuation { pending = $0; actionStarted.fulfill() }
        }
        await fulfillment(of: [sampled], timeout: 2)
        let task = Task { await monitor.clearDNSCache() }
        await fulfillment(of: [actionStarted], timeout: 2)
        XCTAssertTrue(monitor.isClearingDNSCache)
        monitor.stop(clear: true)
        pending?.resume(returning: TunnelControlResponse(id: UUID(), runtime: state("old")))
        await task.value
        XCTAssertNil(monitor.actionMessage)
        XCTAssertFalse(monitor.isClearingDNSCache)
        XCTAssertNil(monitor.snapshot)
    }

    func testCloseAllTargetsSessionWithoutReplacingSnapshotWithControlReply() async {
        let sampled = expectation(description: "initial snapshot")
        let monitor = RuntimeMonitor(sleep: { sampled.fulfill(); throw CancellationError() })
        var actions = 0
        monitor.start { request in
            if request.action == .runtimeSnapshot { return TunnelControlResponse(id: request.id, runtime: self.state("session")) }
            XCTAssertEqual(request.action, .closeAllConnections)
            XCTAssertEqual(request.expectedSessionID, "session")
            actions += 1
            return TunnelControlResponse(id: request.id, runtime: self.state("unexpected"))
        }
        await fulfillment(of: [sampled], timeout: 2)
        await monitor.closeAllConnections()
        XCTAssertEqual(actions, 1)
        XCTAssertEqual(monitor.snapshot?.sessionID, "session")
        XCTAssertNil(monitor.actionMessage)
        monitor.stop(clear: true)
    }

    private func state(_ session: String) -> RuntimeSnapshot {
        RuntimeSnapshot(sessionID: session, sampledAt: 1000, uploadTotal: 12, downloadTotal: 24,
                        activeCount: 0, connections: [], logs: [], droppedConnections: 0, droppedLogs: 0)
    }
}
