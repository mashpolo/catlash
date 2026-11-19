import Foundation
import XCTest
@testable import PacketBridge

final class RevisionApplicationTests: XCTestCase {
    func testPreparedRevisionIsUsedForApplyResultAndControlResponses() async {
        let application = RevisionApplication(
            load: { _ in Data() }, lastSuccessful: { nil },
            start: { _, _, completion in completion(nil) }, stop: { $0(nil) },
            startedRevision: { _, completion in completion("prepared") }
        )
        let connected = expectation(description: "connected")
        application.start(revision: "seed") { XCTAssertNil($0); connected.fulfill() }
        await fulfillment(of: [connected], timeout: 2)
        let active = expectation(description: "prepared revision")
        application.readActiveRevision { XCTAssertEqual($0, "prepared"); active.fulfill() }
        await fulfillment(of: [active], timeout: 2)
        let applied = expectation(description: "prepared apply")
        application.apply(revision: "new-seed") { result in
            XCTAssertEqual(result.activeRevision, "prepared")
            applied.fulfill()
        }
        await fulfillment(of: [applied], timeout: 2)
    }

    func testFailedApplyRestoresLastSuccessfulRevisionAndReportsFailure() async throws {
        let fixture = RevisionFixture()
        let application = fixture.application()
        try await connect(application, fixture: fixture)
        let applied = expectation(description: "apply completed")
        fixture.onStart = { revision in
            if revision == "new" { fixture.finishStart(RevisionTestError.failed) }
            if revision == "old" { fixture.finishStart(nil) }
        }
        application.apply(revision: "new") { result in
            XCTAssertEqual(result.activeRevision, "old")
            XCTAssertTrue(result.restoredPrevious)
            XCTAssertNotNil(result.error)
            applied.fulfill()
        }
        await fulfillment(of: [applied], timeout: 2)
        XCTAssertEqual(fixture.started, ["old", "new", "old"])
    }

    func testStopPreventsLateApplyFailureFromRestoringOldRevision() async throws {
        let fixture = RevisionFixture()
        let application = fixture.application()
        try await connect(application, fixture: fixture)
        let applying = expectation(description: "new starts")
        let cancelled = expectation(description: "apply superseded")
        cancelled.assertForOverFulfill = true
        fixture.onStart = { _ in applying.fulfill() }
        application.apply(revision: "new") { result in
            XCTAssertNotNil(result.error)
            XCTAssertFalse(result.restoredPrevious)
            cancelled.fulfill()
        }
        await fulfillment(of: [applying], timeout: 2)
        let stopped = expectation(description: "stop")
        application.stop { _ in stopped.fulfill() }
        fixture.finishStart(RevisionTestError.failed)
        await fulfillment(of: [stopped, cancelled], timeout: 2)
        let state = expectation(description: "state")
        application.readActiveRevision {
            XCTAssertNil($0)
            state.fulfill()
        }
        await fulfillment(of: [state], timeout: 2)
        XCTAssertEqual(fixture.started, ["old", "new"])
    }

    func testNewerApplySupersedesOldRecoveryIntent() async throws {
        let fixture = RevisionFixture()
        let application = fixture.application()
        try await connect(application, fixture: fixture)
        let firstStarted = expectation(description: "first starts")
        let firstCancelled = expectation(description: "first superseded")
        fixture.onStart = { _ in firstStarted.fulfill() }
        application.apply(revision: "first") { result in
            XCTAssertNotNil(result.error)
            firstCancelled.fulfill()
        }
        await fulfillment(of: [firstStarted], timeout: 2)
        let firstCallback = try XCTUnwrap(fixture.takeStart())
        let secondCompleted = expectation(description: "second applied")
        fixture.onStart = { _ in fixture.finishStart(nil) }
        application.apply(revision: "second") { result in
            XCTAssertEqual(result.activeRevision, "second")
            XCTAssertFalse(result.restoredPrevious)
            XCTAssertNil(result.error)
            secondCompleted.fulfill()
        }
        firstCallback(RevisionTestError.failed)
        await fulfillment(of: [firstCancelled, secondCompleted], timeout: 2)
        XCTAssertEqual(fixture.started, ["old", "first", "second"])
    }

    func testInvalidSnapshotDoesNotInterruptCurrentRevision() async throws {
        let fixture = RevisionFixture()
        let application = fixture.application()
        try await connect(application, fixture: fixture)
        let rejected = expectation(description: "invalid rejected")
        application.apply(revision: "missing") { result in
            XCTAssertEqual(result.activeRevision, "old")
            XCTAssertNotNil(result.error)
            XCTAssertFalse(result.restoredPrevious)
            rejected.fulfill()
        }
        await fulfillment(of: [rejected], timeout: 2)
        XCTAssertEqual(fixture.started, ["old"])
        XCTAssertEqual(fixture.stopCount, 0)
    }

    func testFailedRestorationDoesNotClaimAnActiveRevision() async throws {
        let fixture = RevisionFixture()
        let application = fixture.application()
        try await connect(application, fixture: fixture)
        fixture.onStart = { _ in fixture.finishStart(RevisionTestError.failed) }
        let failed = expectation(description: "restore failed")
        application.apply(revision: "new") { result in
            XCTAssertNil(result.activeRevision)
            XCTAssertFalse(result.restoredPrevious)
            XCTAssertNotNil(result.error)
            failed.fulfill()
        }
        await fulfillment(of: [failed], timeout: 2)
        let refused = expectation(description: "disconnected apply rejected")
        application.apply(revision: "later") { result in
            XCTAssertNil(result.activeRevision)
            XCTAssertNotNil(result.error)
            refused.fulfill()
        }
        await fulfillment(of: [refused], timeout: 2)
        XCTAssertEqual(fixture.started, ["old", "new", "old"])
    }

    func testDisconnectedApplyIsRejectedWithoutStarting() async {
        let fixture = RevisionFixture()
        let application = fixture.application()
        let rejected = expectation(description: "not connected")
        application.apply(revision: "new") { result in
            XCTAssertNil(result.activeRevision)
            XCTAssertNotNil(result.error)
            rejected.fulfill()
        }
        await fulfillment(of: [rejected], timeout: 2)
        XCTAssertTrue(fixture.started.isEmpty)
    }

    func testSettingsCleanupFailureDoesNotAttemptAutomaticRestoration() async throws {
        let fixture = RevisionFixture()
        let application = fixture.application()
        try await connect(application, fixture: fixture)
        fixture.onStart = { _ in
            fixture.finishStart(TunnelLifecycleError.cleanupFailed(operation: "new revision", cleanup: "settings failed"))
        }
        let failed = expectation(description: "cleanup failure")
        application.apply(revision: "new") { result in
            XCTAssertNil(result.activeRevision)
            XCTAssertFalse(result.restoredPrevious)
            XCTAssertNotNil(result.error)
            failed.fulfill()
        }
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertEqual(fixture.started, ["old", "new"])
    }

    func testProviderQueueStopInvalidatesBeforeAlreadyQueuedFailureCallback() async throws {
        let fixture = RevisionFixture()
        let queue = DispatchQueue(label: "RevisionApplicationTests.Provider")
        let application = fixture.application(queue: queue)
        try await connect(application, fixture: fixture)
        let applying = expectation(description: "applying")
        let cancelled = expectation(description: "cancelled")
        fixture.onStart = { _ in applying.fulfill() }
        application.apply(revision: "new") { _ in cancelled.fulfill() }
        await fulfillment(of: [applying], timeout: 2)
        let failure = try XCTUnwrap(fixture.takeStart())
        fixture.onStart = nil
        let stopped = expectation(description: "stopped")
        queue.suspend()
        queue.async { application.stop { _ in stopped.fulfill() } }
        failure(RevisionTestError.failed)
        queue.resume()
        await fulfillment(of: [stopped, cancelled], timeout: 2)
        XCTAssertEqual(fixture.started, ["old", "new"])
    }

    func testControlResponseNeverPairsOldCatalogWithNewRevision() async throws {
        let fixture = RevisionFixture()
        let application = fixture.application()
        try await connect(application, fixture: fixture)
        let ticket = fixture.started.count
        let catalog = ProxyCatalog(mode: "rule", proxies: [], warnings: nil)
        let response = TunnelControlResponse(id: UUID(), catalog: catalog)
        let original = expectation(description: "current response")
        application.controlResponse(response, isCurrentSession: { fixture.started.count == ticket }) { result in
            XCTAssertEqual(result.activeRevision, "old")
            XCTAssertNotNil(result.catalog)
            XCTAssertNil(result.error)
            original.fulfill()
        }
        await fulfillment(of: [original], timeout: 2)
        let replaced = expectation(description: "new revision active")
        application.apply(revision: "new") { result in
            XCTAssertEqual(result.activeRevision, "new")
            replaced.fulfill()
        }
        await fulfillment(of: [replaced], timeout: 2)
        let stale = expectation(description: "old response rejected")
        application.controlResponse(response, isCurrentSession: { fixture.started.count == ticket }) { result in
            XCTAssertNil(result.activeRevision)
            XCTAssertNil(result.catalog)
            XCTAssertNotNil(result.error)
            stale.fulfill()
        }
        await fulfillment(of: [stale], timeout: 2)
    }

    func testRuntimeSnapshotSurvivesRevisionEnvelopeAndRejectsStaleSession() async throws {
        let fixture = RevisionFixture()
        let application = fixture.application()
        try await connect(application, fixture: fixture)
        let state = RuntimeSnapshot(sessionID: "session-1", sampledAt: 1000, uploadTotal: 4, downloadTotal: 8,
                                    activeCount: 0, connections: [], logs: [], droppedConnections: 0, droppedLogs: 0)
        let exitIP = try ExitIP.decodeIPQuery(Data(#"{"ip":"203.0.113.1","risk":{"is_datacenter":true}}"#.utf8))
        let resourceStatus = TunnelResourceStatus(phase: .failed, message: "资源准备失败，VPN 保持连接。")
        let response = TunnelControlResponse(id: UUID(), runtime: state, exitIP: exitIP, delayFailure: .timeout, resourceStatus: resourceStatus)
        let delivered = expectation(description: "runtime delivered")
        application.controlResponse(response, isCurrentSession: { true }) { result in
            XCTAssertEqual(result.activeRevision, "old")
            XCTAssertEqual(result.runtime?.sessionID, "session-1")
            XCTAssertEqual(result.runtime?.downloadTotal, 8)
            XCTAssertEqual(result.exitIP, exitIP)
            XCTAssertEqual(result.delayFailure, .timeout)
            XCTAssertEqual(result.resourceStatus, resourceStatus)
            delivered.fulfill()
        }
        await fulfillment(of: [delivered], timeout: 2)
        let rejected = expectation(description: "stale runtime rejected")
        application.controlResponse(response, isCurrentSession: { false }) { result in
            XCTAssertNil(result.runtime)
            XCTAssertNil(result.exitIP)
            XCTAssertNil(result.delayFailure)
            XCTAssertNil(result.resourceStatus)
            XCTAssertNotNil(result.error)
            rejected.fulfill()
        }
        await fulfillment(of: [rejected], timeout: 2)
    }

    private func connect(_ application: RevisionApplication, fixture: RevisionFixture) async throws {
        let connected = expectation(description: "connected")
        fixture.onStart = { _ in fixture.finishStart(nil) }
        application.start(revision: "old") { error in
            XCTAssertNil(error)
            connected.fulfill()
        }
        await fulfillment(of: [connected], timeout: 2)
    }
}

private enum RevisionTestError: Error { case failed }

private final class RevisionFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var revisions: [String] = []
    private var starts: [@Sendable (Error?) -> Void] = []
    private var stops = 0
    private var startHook: (@Sendable (String) -> Void)?
    var started: [String] { lock.withLock { revisions } }
    var stopCount: Int { lock.withLock { stops } }
    var onStart: (@Sendable (String) -> Void)? {
        get { lock.withLock { startHook } }
        set { lock.withLock { startHook = newValue } }
    }

    func application(queue: DispatchQueue = DispatchQueue(label: "RevisionApplicationTests.State")) -> RevisionApplication {
        RevisionApplication(
            queue: queue,
            load: { revision in
                if revision == "missing" { throw RevisionTestError.failed }
                return Data(revision.utf8)
            },
            lastSuccessful: { "old" },
            start: { revision, _, completion in
                let hook = self.lock.withLock {
                    self.revisions.append(revision)
                    self.starts.append(completion)
                    return self.startHook
                }
                hook?(revision)
            },
            stop: { completion in
                self.lock.withLock { self.stops += 1 }
                completion(nil)
            }
        )
    }

    func takeStart() -> (@Sendable (Error?) -> Void)? {
        lock.withLock { starts.isEmpty ? nil : starts.removeFirst() }
    }

    func finishStart(_ error: Error?) { takeStart()?(error) }
}
