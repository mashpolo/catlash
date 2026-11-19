import CryptoKit
import Foundation
import XCTest
@testable import PacketBridge

final class SnapshotResourceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }

    func testSuccessfulProfileResourcesSurviveAnotherProfileAndStoreReload() throws {
        let store = SnapshotStore(root: root)
        let resources = ResourceBundleStore(root: root.appendingPathComponent("Resources"))
        let bundle = try resources.stage(entries: [.init(kind: .ruleProvider, name: "rules", data: Data("payload: []".utf8))])
        let yaml = "mode: rule\n"
        let original = try store.stage(configuration: .init(outbound: .mihomo(yaml: yaml), resources: bundle, profileID: "original.yaml"))
        try store.markSuccessful(revision: original)
        let withoutResources = try store.stage(configuration: .init(outbound: .mihomo(yaml: yaml), profileID: "original.yaml"))
        try store.markSuccessful(revision: withoutResources)
        XCTAssertEqual(try store.lastSuccessfulRevision(profileID: "original.yaml", yaml: Data(yaml.utf8)), original)
        let direct = try store.stage(configuration: .init(outbound: .mihomo(yaml: "mode: direct\n"), profileID: "direct.yaml"))
        try store.markSuccessful(revision: direct)
        let reopened = SnapshotStore(root: root)
        XCTAssertEqual(try reopened.lastSuccessfulRevision(), direct)
        XCTAssertEqual(try reopened.lastSuccessfulRevision(profileID: "original.yaml", yaml: Data(yaml.utf8)), original)
        XCTAssertNil(try reopened.lastSuccessfulRevision(profileID: "other.yaml", yaml: Data(yaml.utf8)))
        XCTAssertNil(try reopened.lastSuccessfulRevision(profileID: "original.yaml", yaml: Data((yaml + "# edit").utf8)))
        let refreshedBundle = try resources.stage(entries: [.init(kind: .ruleProvider, name: "rules", data: Data("payload: [example.test]".utf8))])
        let pending = try store.stage(configuration: .init(outbound: .mihomo(yaml: yaml), resources: refreshedBundle, profileID: "original.yaml"))
        XCTAssertEqual(try reopened.lastSuccessfulRevision(profileID: "original.yaml", yaml: Data(yaml.utf8)), original)
        try store.markSuccessful(revision: pending)
        XCTAssertEqual(try reopened.lastSuccessfulRevision(profileID: "original.yaml", yaml: Data(yaml.utf8)), pending)
    }

    func testLegacySuccessfulReferenceRemainsUsableWithoutProfileIndex() throws {
        let store = SnapshotStore(root: root)
        let yaml = "mode: rule\n"
        let revision = try store.stage(configuration: .init(outbound: .mihomo(yaml: yaml), profileID: "legacy.yaml"))
        try Data(revision.utf8).write(to: root.appendingPathComponent("last-successful"))
        XCTAssertEqual(try store.lastSuccessfulRevision(profileID: "legacy.yaml", yaml: Data(yaml.utf8)), revision)
        XCTAssertNil(try store.lastSuccessfulRevision(profileID: "other.yaml", yaml: Data(yaml.utf8)))
    }

    func testResourceContentChangesSnapshotRevisionWithoutChangingYAML() throws {
        let resources = ResourceBundleStore(root: root.appendingPathComponent("Resources"))
        let store = SnapshotStore(root: root)
        let firstBundle = try resources.stage(entries: [.init(kind: .proxyProvider, name: "nodes", data: Data("first".utf8))])
        let secondBundle = try resources.stage(entries: [.init(kind: .proxyProvider, name: "nodes", data: Data("second".utf8))])
        let yaml = "# original\nmode: rule\n"
        let first = try store.stage(configuration: RuntimeConfiguration(outbound: .mihomo(yaml: yaml), resources: firstBundle))
        let second = try store.stage(configuration: RuntimeConfiguration(outbound: .mihomo(yaml: yaml), resources: secondBundle))
        XCTAssertNotEqual(first, second)
        let decoded = try RuntimeConfiguration.decode(store.loadForActivation(revision: first))
        XCTAssertEqual(decoded.resources, firstBundle)
        XCTAssertEqual(decoded.outbound, .mihomo(yaml: yaml))
        XCTAssertEqual(try RuntimeConfiguration.decode(store.loadForActivation(revision: second)).resources, secondBundle)
    }

    func testLegacyConfigurationOmitsResourcesAndInvalidIDsDoNotChangePending() throws {
        let store = SnapshotStore(root: root)
        let good = try store.stage(configuration: RuntimeConfiguration())
        let legacy = try store.load(revision: good)
        XCTAssertNil(try RuntimeConfiguration.decode(legacy).resources)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: legacy) as? [String: Any])
        XCTAssertNil(object["resources"])
        for id in ["", "../outside", String(repeating: "a", count: 63), String(repeating: "A", count: 64), String(repeating: "g", count: 64)] {
            let invalid = RuntimeConfiguration(outbound: .mihomo(yaml: "mode: direct\n"), resources: id)
            XCTAssertThrowsError(try store.stage(configuration: invalid))
            XCTAssertEqual(try store.pendingRevision(), good)
        }
    }

    func testCorruptResourceCannotBecomeSuccessfulOrReplacePriorRecoverySnapshot() throws {
        let store = SnapshotStore(root: root)
        let resources = ResourceBundleStore(root: root.appendingPathComponent("Resources"))
        let good = try store.stage(configuration: RuntimeConfiguration())
        try store.markSuccessful(revision: good)
        let payload = Data("provider bytes".utf8)
        let bundle = try resources.stage(entries: [.init(kind: .ruleProvider, name: "rules", data: payload)])
        let candidate = try store.stage(configuration: RuntimeConfiguration(outbound: .mihomo(yaml: "mode: rule\n"), resources: bundle))
        let blob = try resources.directory(id: bundle).appendingPathComponent(hash(payload))
        try Data("corruption".utf8).write(to: blob, options: .atomic)
        XCTAssertThrowsError(try store.loadForActivation(revision: candidate))
        XCTAssertThrowsError(try store.markSuccessful(revision: candidate))
        XCTAssertEqual(try store.lastSuccessfulRevision(), good)
        XCTAssertEqual(try store.restoreLastSuccessful(), good)
    }

    func testPreparingOldSnapshotDoesNotChangeNewerPendingReference() throws {
        let store = SnapshotStore(root: root)
        let old = try store.prepare(configuration: RuntimeConfiguration())
        XCTAssertNil(try store.pendingRevision())
        let latest = try store.stage(configuration: RuntimeConfiguration(mtu: 1500))
        XCTAssertEqual(try store.pendingRevision(), latest)
        XCTAssertNotEqual(old.revision, latest)
        XCTAssertEqual(try RuntimeConfiguration.decode(store.load(revision: old.revision)).mtu, 1280)
        let other = SnapshotStore(root: root.appendingPathComponent("other"))
        XCTAssertThrowsError(try other.commit(old))
        XCTAssertEqual(try store.pendingRevision(), latest)
    }

    func testMissingResourcesAreRejectedBeforeInterruptingAnActiveRevision() async throws {
        let store = SnapshotStore(root: root)
        let good = try store.stage(configuration: RuntimeConfiguration())
        try store.markSuccessful(revision: good)
        let missing = try store.stage(configuration: RuntimeConfiguration(
            outbound: .mihomo(yaml: "mode: rule\n"), resources: String(repeating: "a", count: 64)
        ))
        let starts = SnapshotStartCounter()
        let application = RevisionApplication(
            load: { try store.loadForActivation(revision: $0) },
            lastSuccessful: { try store.lastSuccessfulRevision() },
            start: { _, _, completion in starts.increment(); completion(nil) },
            stop: { completion in XCTFail("Loading an unavailable resource must not stop the active session"); completion(nil) }
        )
        let connected = expectation(description: "connected")
        application.start(revision: good) { error in XCTAssertNil(error); connected.fulfill() }
        await fulfillment(of: [connected], timeout: 2)
        let refused = expectation(description: "missing resource rejected")
        application.apply(revision: missing) { result in
            XCTAssertEqual(result.activeRevision, good)
            XCTAssertFalse(result.restoredPrevious)
            XCTAssertNotNil(result.error)
            refused.fulfill()
        }
        await fulfillment(of: [refused], timeout: 2)
        XCTAssertEqual(starts.value, 1)
        XCTAssertEqual(try store.lastSuccessfulRevision(), good)
    }

    @MainActor
    func testOlderResourceDownloadCannotReplaceANewerSaveOrRestore() async throws {
        let store = SnapshotStore(root: root)
        let good = try store.stage(configuration: RuntimeConfiguration())
        try store.markSuccessful(revision: good)
        let coordinator = SnapshotCommitCoordinator()
        let resources = ResourceBundleStore(root: root.appendingPathComponent("Resources"))
        let yaml = Data("proxy-providers:\n  nodes:\n    type: http\n    url: https://example.test/nodes\n".utf8)
        for restoring in [false, true] {
            let started = expectation(description: "resource download started")
            let gate = SnapshotDownloadGate { started.fulfill() }
            let preparer = ProfileResourcePreparer(bundleStore: resources, download: { _, _ in
                await gate.wait()
                return Data("proxies: []\n".utf8)
            })
            let oldIntent = coordinator.begin()
            let oldPreparation = Task {
                let bundle = try await preparer.prepare(yaml: yaml)
                return try store.prepare(configuration: RuntimeConfiguration(
                    outbound: .mihomo(yaml: String(decoding: yaml, as: UTF8.self)), resources: bundle
                ))
            }
            await fulfillment(of: [started], timeout: 2)
            let latestIntent = coordinator.begin()
            let latest = try restoring
                ? store.prepare(data: store.loadForActivation(revision: good))
                : store.prepare(configuration: RuntimeConfiguration(mtu: 1500))
            let expected = try coordinator.commit(latest, to: store, intent: latestIntent)
            await gate.resume()
            let old = try await oldPreparation.value
            XCTAssertThrowsError(try coordinator.commit(old, to: store, intent: oldIntent)) { error in
                XCTAssertTrue(error is CancellationError)
            }
            XCTAssertEqual(try store.pendingRevision(), expected)
        }
    }

    private func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private final class SnapshotStartCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private actor SnapshotDownloadGate {
    private let started: @Sendable () -> Void
    private var continuation: CheckedContinuation<Void, Never>?
    init(started: @escaping @Sendable () -> Void) { self.started = started }
    func wait() async {
        await withCheckedContinuation { continuation = $0; started() }
    }
    func resume() { continuation?.resume(); continuation = nil }
}
