import Foundation
import XCTest
@testable import PacketBridge

final class ResourceActivationConvergenceTests: XCTestCase {
    @MainActor
    func testSuccessfulPreparationConvergesPendingAndSurvivesAppRestart() throws {
        let fixture = try convergenceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.store.recordResourcePreparation(source: fixture.seed, prepared: fixture.final)
        XCTAssertNil(try fixture.store.prepareSuccessfulResourceAdoption())
        XCTAssertEqual(try fixture.store.pendingRevision(), fixture.seed)
        try fixture.store.markSuccessful(revision: fixture.final)
        let coordinator = SnapshotCommitCoordinator()
        let proposal = try XCTUnwrap(fixture.store.prepareSuccessfulResourceAdoption())
        XCTAssertTrue(try coordinator.adopt(proposal, to: fixture.store, observation: coordinator.observe()))
        XCTAssertEqual(try fixture.store.pendingRevision(), fixture.final)
        XCTAssertEqual(try fixture.store.pendingRevision(), try fixture.store.lastSuccessfulRevision())
        XCTAssertNil(try fixture.store.prepareSuccessfulResourceAdoption())
    }

    @MainActor
    func testNewPendingAndInFlightUserIntentPreventOldSuccessfulAdoption() throws {
        let fixture = try convergenceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.store.recordResourcePreparation(source: fixture.seed, prepared: fixture.final)
        try fixture.store.markSuccessful(revision: fixture.final)
        let coordinator = SnapshotCommitCoordinator()
        let oldObservation = coordinator.observe()
        let proposal = try XCTUnwrap(fixture.store.prepareSuccessfulResourceAdoption())
        let user = coordinator.begin()
        XCTAssertFalse(try coordinator.adopt(proposal, to: fixture.store, observation: oldObservation))
        XCTAssertFalse(try coordinator.adopt(proposal, to: fixture.store, observation: coordinator.observe()))
        XCTAssertEqual(try fixture.store.pendingRevision(), fixture.seed)
        let newer = try fixture.store.prepare(configuration: RuntimeConfiguration(mtu: 1500))
        try coordinator.commit(newer, to: fixture.store, intent: user)
        XCTAssertFalse(try coordinator.adopt(proposal, to: fixture.store, observation: coordinator.observe()))
        XCTAssertEqual(try fixture.store.pendingRevision(), newer.revision)
    }

    @MainActor
    func testCancelledUserPreparationAllowsLaterSuccessObservationWithoutSupersedingIntent() throws {
        let fixture = try convergenceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.store.recordResourcePreparation(source: fixture.seed, prepared: fixture.final)
        try fixture.store.markSuccessful(revision: fixture.final)
        let coordinator = SnapshotCommitCoordinator()
        let intent = coordinator.begin()
        coordinator.finish(intent)
        let proposal = try XCTUnwrap(fixture.store.prepareSuccessfulResourceAdoption())
        XCTAssertTrue(try coordinator.adopt(proposal, to: fixture.store, observation: coordinator.observe()))
        XCTAssertTrue(coordinator.isCurrent(intent))
    }

    func testPreparationReceiptRejectsChangedYAMLOrSelections() throws {
        let fixture = try convergenceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let changed = try fixture.store.prepare(configuration: RuntimeConfiguration(outbound: .mihomo(yaml: "mode: global")))
        XCTAssertThrowsError(try fixture.store.recordResourcePreparation(source: fixture.seed, prepared: changed.revision))
        try fixture.store.markSuccessful(revision: fixture.final)
        XCTAssertNil(try fixture.store.prepareSuccessfulResourceAdoption())
    }

    private func convergenceFixture() throws -> (root: URL, store: SnapshotStore, seed: String, final: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SnapshotStore(root: root)
        let bundle = try ResourceBundleStore(root: root.appendingPathComponent("Resources")).stage(entries: [.init(kind: .ruleProvider, name: "rules", data: Data("payload: []".utf8))])
        let seed = try store.stage(configuration: RuntimeConfiguration(outbound: .mihomo(yaml: "mode: rule")))
        let final = try store.prepare(configuration: RuntimeConfiguration(outbound: .mihomo(yaml: "mode: rule"), resources: bundle)).revision
        return (root, store, seed, final)
    }
}
