import Foundation
import XCTest
@testable import PacketBridge

final class TunnelLifecycleTests: XCTestCase {
    func testCancelledPreparationFinishesCleanupBeforeNextRevisionInstalls() {
        let fixture = LifecycleFixture()
        let preparing = expectation(description: "preparing")
        let cancelled = expectation(description: "preparation cancelled")
        let superseded = expectation(description: "old request answered")
        let installed = expectation(description: "latest install")
        let started = expectation(description: "latest started")
        let pending = PreparationFixture()
        let lifecycle = fixture.lifecycle(prepare: { activation, completion in
            if activation.revision == "old" {
                pending.set(completion)
                preparing.fulfill()
                return { cancelled.fulfill() }
            }
            completion(.success(.init(revision: "resolved", configuration: Data("ready".utf8))))
            return {}
        })
        lifecycle.start(revision: "old", configuration: Data()) { error in
            XCTAssertNotNil(error)
            superseded.fulfill()
        }
        wait(for: [preparing], timeout: 2)
        fixture.onInstall = { installed.fulfill() }
        lifecycle.start(revision: "latest", configuration: Data()) { error in
            XCTAssertNil(error)
            started.fulfill()
        }
        wait(for: [cancelled, superseded], timeout: 2)
        XCTAssertEqual(fixture.factoryCount, 0)
        XCTAssertNil(fixture.installedData)
        pending.finish(.success(.init(revision: "stale", configuration: Data())))
        wait(for: [installed], timeout: 2)
        XCTAssertEqual(fixture.installedData, Data("ready".utf8))
        fixture.finishInstall()
        wait(for: [started], timeout: 2)
        let active = expectation(description: "resolved revision")
        lifecycle.readActiveRevision { revision in XCTAssertEqual(revision, "resolved"); active.fulfill() }
        wait(for: [active], timeout: 2)
        stopRunning(lifecycle, fixture: fixture)
    }

    func testPreparationStartsAfterPreviousSessionAndSettingsAreFullyClosed() {
        let fixture = LifecycleFixture()
        let prepared = expectation(description: "prepared after cleanup")
        let lifecycle = fixture.lifecycle(prepare: { activation, completion in
            if activation.revision == "new" {
                XCTAssertEqual(fixture.session.closeCount, 1)
                XCTAssertEqual(fixture.completedClearCount, 1)
                prepared.fulfill()
            }
            completion(.success(activation))
            return {}
        })
        startRunning(lifecycle, fixture: fixture, revision: "old")
        let stopping = expectation(description: "old session stopping")
        let clearing = expectation(description: "old settings clearing")
        let installed = expectation(description: "new settings")
        let started = expectation(description: "new session")
        fixture.onStop = { stopping.fulfill() }
        fixture.onClear = { clearing.fulfill() }
        fixture.onInstall = { installed.fulfill() }
        lifecycle.start(revision: "new", configuration: Data()) { XCTAssertNil($0); started.fulfill() }
        wait(for: [stopping], timeout: 2)
        fixture.finishStop()
        wait(for: [clearing], timeout: 2)
        fixture.finishClear()
        wait(for: [prepared, installed], timeout: 2)
        fixture.finishInstall()
        wait(for: [started], timeout: 2)
        stopRunning(lifecycle, fixture: fixture)
    }

    func testStopCancelsPreparationWithoutInstallingSettings() {
        let fixture = LifecycleFixture()
        let preparing = expectation(description: "preparing")
        let cancelled = expectation(description: "cancelled")
        let stopped = expectation(description: "stopped after preparation cleanup")
        let pending = PreparationFixture()
        let lifecycle = fixture.lifecycle(prepare: { _, completion in
            pending.set(completion)
            preparing.fulfill()
            return { cancelled.fulfill() }
        })
        lifecycle.start(revision: "old", configuration: Data()) { XCTAssertNotNil($0) }
        wait(for: [preparing], timeout: 2)
        lifecycle.stop { XCTAssertNil($0); stopped.fulfill() }
        wait(for: [cancelled], timeout: 2)
        XCTAssertNil(fixture.installedData)
        pending.finish(.failure(CancellationError()))
        wait(for: [stopped], timeout: 2)
        XCTAssertNil(fixture.installedData)
        XCTAssertEqual(fixture.clearCount, 0)
    }

    func testStopDuringSettingsInstallWaitsForRollbackAndNeverCreatesSession() {
        let fixture = LifecycleFixture()
        let installed = expectation(description: "install requested")
        let clearing = expectation(description: "rollback requested")
        let cancelled = expectation(description: "start cancelled")
        let stopped = expectation(description: "stop completed")
        fixture.onInstall = { installed.fulfill() }
        fixture.onClear = { clearing.fulfill() }
        let lifecycle = fixture.lifecycle()
        lifecycle.start(revision: "first", configuration: Data()) { error in
            XCTAssertNotNil(error)
            cancelled.fulfill()
        }
        wait(for: [installed], timeout: 2)
        lifecycle.stop { error in XCTAssertNil(error); stopped.fulfill() }
        wait(for: [cancelled], timeout: 2)
        XCTAssertEqual(fixture.factoryCount, 0)
        fixture.finishInstall()
        wait(for: [clearing], timeout: 2)
        XCTAssertEqual(fixture.factoryCount, 0)
        fixture.finishClear()
        wait(for: [stopped], timeout: 2)
    }

    func testFiftyRapidTogglesLeaveOnlyLatestRevisionRunning() {
        let fixture = LifecycleFixture()
        let initialInstall = expectation(description: "initial install")
        let latestInstall = expectation(description: "latest install")
        let clearing = expectation(description: "clear superseded settings")
        let starts = expectation(description: "each start answered once")
        starts.expectedFulfillmentCount = 52
        starts.assertForOverFulfill = true
        let stops = expectation(description: "each stop answered once")
        stops.expectedFulfillmentCount = 50
        stops.assertForOverFulfill = true
        fixture.onInstall = { initialInstall.fulfill() }
        fixture.onClear = { clearing.fulfill() }
        let lifecycle = fixture.lifecycle()
        lifecycle.start(revision: "initial", configuration: Data()) { error in
            XCTAssertNotNil(error)
            starts.fulfill()
        }
        wait(for: [initialInstall], timeout: 2)
        for index in 0..<50 {
            lifecycle.start(revision: "discarded-\(index)", configuration: Data()) { error in
                XCTAssertNotNil(error)
                starts.fulfill()
            }
            lifecycle.stop { error in XCTAssertNil(error); stops.fulfill() }
        }
        lifecycle.start(revision: "latest", configuration: Data()) { error in
            XCTAssertNil(error)
            starts.fulfill()
        }
        fixture.onInstall = { latestInstall.fulfill() }
        fixture.finishInstall()
        wait(for: [clearing], timeout: 2)
        fixture.finishClear()
        wait(for: [latestInstall, stops], timeout: 2)
        fixture.finishInstall()
        wait(for: [starts], timeout: 2)
        XCTAssertEqual(fixture.factoryCount, 1)
        let state = expectation(description: "latest revision")
        lifecycle.readActiveRevision { revision in
            XCTAssertEqual(revision, "latest")
            state.fulfill()
        }
        wait(for: [state], timeout: 2)
        stopRunning(lifecycle, fixture: fixture)
    }

    func testSessionFailureClearsSettingsBeforeAnsweringStart() {
        let fixture = LifecycleFixture()
        fixture.factoryError = LifecycleTestError.creation
        let installed = expectation(description: "install")
        let clearing = expectation(description: "clear")
        let failed = expectation(description: "failed after rollback")
        fixture.onInstall = { installed.fulfill() }
        fixture.onClear = { clearing.fulfill() }
        let lifecycle = fixture.lifecycle()
        lifecycle.start(revision: "bad", configuration: Data()) { error in
            XCTAssertEqual(error as? LifecycleTestError, .creation)
            failed.fulfill()
        }
        wait(for: [installed], timeout: 2)
        fixture.finishInstall()
        wait(for: [clearing], timeout: 2)
        XCTAssertEqual(fixture.startedCount, 0)
        fixture.finishClear()
        wait(for: [failed], timeout: 2)
    }

    func testCommitFailureWaitsForSessionCloseBeforeClearingSettings() {
        let fixture = LifecycleFixture()
        fixture.commitError = LifecycleTestError.commit
        let installed = expectation(description: "install")
        let stopping = expectation(description: "pump stop requested")
        let clearing = expectation(description: "clear")
        let failed = expectation(description: "failed")
        fixture.onInstall = { installed.fulfill() }
        fixture.onStop = { stopping.fulfill() }
        fixture.onClear = { clearing.fulfill() }
        let lifecycle = fixture.lifecycle()
        lifecycle.start(revision: "cannot-commit", configuration: Data()) { error in
            XCTAssertEqual(error as? LifecycleTestError, .commit)
            failed.fulfill()
        }
        wait(for: [installed], timeout: 2)
        fixture.finishInstall()
        wait(for: [stopping], timeout: 2)
        XCTAssertEqual(fixture.clearCount, 0)
        fixture.finishStop()
        wait(for: [clearing], timeout: 2)
        XCTAssertEqual(fixture.session.closeCount, 1)
        fixture.finishClear()
        wait(for: [failed], timeout: 2)
    }

    func testClearFailureIsReportedAndNextStartRetriesCleanup() {
        let fixture = LifecycleFixture()
        let lifecycle = fixture.lifecycle()
        startRunning(lifecycle, fixture: fixture, revision: "old")
        let stopping = expectation(description: "stop")
        let clearing = expectation(description: "clear")
        let stopped = expectation(description: "stop reports failure")
        fixture.onStop = { stopping.fulfill() }
        fixture.onClear = { clearing.fulfill() }
        lifecycle.stop { error in XCTAssertNotNil(error); stopped.fulfill() }
        wait(for: [stopping], timeout: 2)
        fixture.finishStop()
        wait(for: [clearing], timeout: 2)
        fixture.finishClear(error: LifecycleTestError.clear)
        wait(for: [stopped], timeout: 2)
        XCTAssertEqual(fixture.clearCount, 1)
        let retry = expectation(description: "retry clear")
        let installed = expectation(description: "new install")
        let started = expectation(description: "new start")
        fixture.onClear = { retry.fulfill() }
        fixture.onInstall = { installed.fulfill() }
        lifecycle.start(revision: "new", configuration: Data()) { error in XCTAssertNil(error); started.fulfill() }
        wait(for: [retry], timeout: 2)
        XCTAssertEqual(fixture.factoryCount, 1)
        fixture.finishClear()
        wait(for: [installed], timeout: 2)
        fixture.finishInstall()
        wait(for: [started], timeout: 2)
        stopRunning(lifecycle, fixture: fixture)
    }

    func testStoppedCoordinatorIsReleasedWhilePumpRetainsFailureCallback() {
        let fixture = LifecycleFixture()
        let released = expectation(description: "coordinator dependencies released")
        var lifecycle: TunnelLifecycle? = fixture.lifecycle(onRelease: { released.fulfill() })
        let assertReleased = { [weak lifecycle] in XCTAssertNil(lifecycle) }
        startRunning(lifecycle!, fixture: fixture, revision: "temporary")
        stopRunning(lifecycle!, fixture: fixture)
        XCTAssertTrue(fixture.hasRetainedFailureCallback)
        lifecycle = nil
        wait(for: [released], timeout: 2)
        assertReleased()
    }

    private func startRunning(_ lifecycle: TunnelLifecycle, fixture: LifecycleFixture, revision: String) {
        let installed = expectation(description: "install \(revision)")
        let started = expectation(description: "start \(revision)")
        fixture.onInstall = { installed.fulfill() }
        lifecycle.start(revision: revision, configuration: Data()) { error in XCTAssertNil(error); started.fulfill() }
        wait(for: [installed], timeout: 2)
        fixture.finishInstall()
        wait(for: [started], timeout: 2)
    }

    private func stopRunning(_ lifecycle: TunnelLifecycle, fixture: LifecycleFixture) {
        let stopping = expectation(description: "stop pump")
        let clearing = expectation(description: "clear settings")
        let stopped = expectation(description: "stopped")
        fixture.onStop = { stopping.fulfill() }
        fixture.onClear = { clearing.fulfill() }
        lifecycle.stop { error in XCTAssertNil(error); stopped.fulfill() }
        wait(for: [stopping], timeout: 2)
        fixture.finishStop()
        wait(for: [clearing], timeout: 2)
        fixture.finishClear()
        wait(for: [stopped], timeout: 2)
    }
}

private enum LifecycleTestError: Error { case creation, commit, clear }

private final class LifecycleReleaseToken: @unchecked Sendable {
    private let onRelease: (() -> Void)?
    init(_ onRelease: (() -> Void)?) { self.onRelease = onRelease }
    deinit { onRelease?() }
}

private final class LifecycleSession: PacketSession, @unchecked Sendable {
    private let lock = NSLock()
    private var closes = 0
    var closeCount: Int { lock.withLock { closes } }
    func writePacket(_ packet: Data) throws {}
    func readPacket() throws -> Data { throw LifecycleTestError.creation }
    func close() throws { lock.withLock { closes += 1 } }
}

private final class LifecycleFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var install: (@Sendable (Error?) -> Void)?
    private var clear: (@Sendable (Error?) -> Void)?
    private var stop: (@Sendable () -> Void)?
    private var packetFailure: TunnelLifecycle.Completion?
    private var installed: Data?
    var installedData: Data? { lock.withLock { installed } }
    private var factories = 0
    private var starts = 0
    private var clears = 0
    private var completedClears = 0
    var completedClearCount: Int { lock.withLock { completedClears } }
    let session = LifecycleSession()
    var onInstall: (() -> Void)?
    var onClear: (() -> Void)?
    var onStop: (() -> Void)?
    var factoryError: Error?
    var commitError: Error?
    var factoryCount: Int { lock.withLock { factories } }
    var startedCount: Int { lock.withLock { starts } }
    var clearCount: Int { lock.withLock { clears } }
    var hasRetainedFailureCallback: Bool { lock.withLock { packetFailure != nil } }

    func lifecycle(onRelease: (() -> Void)? = nil, prepare: @escaping TunnelLifecycle.Prepare = { activation, completion in completion(.success(activation)); return {} }) -> TunnelLifecycle {
        let releaseToken = LifecycleReleaseToken(onRelease)
        return TunnelLifecycle(
            prepare: prepare,
            installSettings: { data, completion in
                self.lock.withLock { self.installed = data }
                self.lock.withLock { self.install = completion }
                self.onInstall?()
            },
            clearSettings: { completion in
                self.lock.withLock { self.clear = completion; self.clears += 1 }
                self.onClear?()
            },
            makeSession: { _ in
                try withExtendedLifetime(releaseToken) {
                    self.lock.withLock { self.factories += 1 }
                    if let error = self.factoryError { throw error }
                    return self.session
                }
            },
            startPackets: { _, failure in self.lock.withLock { self.starts += 1; self.packetFailure = failure } },
            stopPackets: { completion in
                self.lock.withLock { self.stop = completion }
                self.onStop?()
            },
            didStart: { _ in if let error = self.commitError { throw error } },
            onFailure: { _ in }
        )
    }

    func finishInstall(error: Error? = nil) { lock.withLock { let result = install; install = nil; return result }?(error) }
    func finishClear(error: Error? = nil) { lock.withLock { let result = clear; clear = nil; completedClears += 1; return result }?(error) }
    func finishStop() {
        try? session.close()
        lock.withLock { let result = stop; stop = nil; return result }?()
    }
}

private final class PreparationFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: TunnelLifecycle.PreparationCompletion?
    func set(_ completion: @escaping TunnelLifecycle.PreparationCompletion) {
        lock.withLock { self.completion = completion }
    }
    func finish(_ result: Result<TunnelLifecycle.Activation, Error>) {
        lock.withLock { let callback = completion; completion = nil; return callback }?(result)
    }
}
