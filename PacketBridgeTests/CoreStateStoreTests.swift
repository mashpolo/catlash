import CryptoKit
import Foundation
import XCTest
@testable import PacketBridge

final class CoreStateStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testRenameRestartAndCloneKeepIndependentIdentityState() async throws {
        let profiles = ProfileRepository(root: root.appendingPathComponent("Profiles"))
        let profile = try await profiles.importData(data: Data("mode: direct\n".utf8), name: "Original")
        let stateRoot = root.appendingPathComponent("CoreState")
        let first = try CoreStateStore(root: stateRoot).directory(profileID: profile.id)
        let identity = Data("synthetic persistent identity".utf8)
        try identity.write(to: first.appendingPathComponent("identity"))
        let renamed = try await profiles.rename(id: profile.id, name: "Renamed")
        let reopened = try CoreStateStore(root: stateRoot).directory(profileID: renamed.id)
        XCTAssertEqual(first, reopened)
        XCTAssertEqual(try Data(contentsOf: reopened.appendingPathComponent("identity")), identity)
        let clone = try await profiles.duplicate(id: profile.id)
        let separate = try CoreStateStore(root: stateRoot).directory(profileID: clone.id)
        XCTAssertNotEqual(first, separate)
        XCTAssertFalse(FileManager.default.fileExists(atPath: separate.appendingPathComponent("identity").path))
        try await profiles.delete(id: profile.id)
        XCTAssertEqual(try Data(contentsOf: first.appendingPathComponent("identity")), identity)
    }

    func testFrameworkReopensIndependentLazyIdentityDirectoriesWithoutConnecting() throws {
        let yaml = """
        mode: direct
        proxies:
          - {name: tail, type: tailscale}
          - {name: zero, type: zerotier, network: '8056c2e21c000001'}
          - {name: easy, type: easytier, network-name: test, no-listener: true, peers: ['tcp://127.0.0.1:9']}
        """
        let state = CoreStateStore(root: root.appendingPathComponent("CoreState"))
        let directory = try state.directory(profileID: "identity.yaml")
        let data = try JSONEncoder().encode(RuntimeConfiguration(outbound: .mihomo(yaml: yaml), profileID: "identity.yaml"))
        let configuration = String(decoding: data, as: UTF8.self)
        let first = try GoPacketSession(configuration: configuration, stateRoot: directory)
        XCTAssertTrue(Set(try first.proxyCatalog().proxies.map(\.name)).isSuperset(of: ["tail", "zero", "easy"]))
        try first.close()
        let folders = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(folders.count, 3)
        for folder in folders { try Data("identity marker".utf8).write(to: folder.appendingPathComponent("marker")) }
        let restarted = try GoPacketSession(configuration: configuration, stateRoot: directory)
        try restarted.close()
        for folder in folders { XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("marker")), Data("identity marker".utf8)) }
        XCTAssertThrowsError(try GoPacketSession(configuration: configuration))
        XCTAssertThrowsError(try GoPacketSession(configuration: configuration, stateRoot: state.directory(profileID: "other.yaml")))
        let resourceConfiguration = RuntimeConfiguration(outbound: .mihomo(yaml: yaml), resources: String(repeating: "a", count: 64), profileID: "identity.yaml")
        XCTAssertThrowsError(try GoPacketSession(configuration: String(decoding: JSONEncoder().encode(resourceConfiguration), as: UTF8.self), resourceRoot: root.appendingPathComponent("../outside"), stateRoot: directory))
    }

    func testSnapshotRoundTripKeepsOriginalYAMLAndLegacyNil() throws {
        let store = SnapshotStore(root: root.appendingPathComponent("Snapshots"))
        let yaml = "# preserved\nmode: direct\n"
        let configuration = RuntimeConfiguration(outbound: .mihomo(yaml: yaml), profileID: "同步配置.YAML")
        let revision = try store.stage(configuration: configuration)
        XCTAssertEqual(try RuntimeConfiguration.decode(store.load(revision: revision)), configuration)
        let legacy = try JSONEncoder().encode(RuntimeConfiguration())
        XCTAssertNil(try RuntimeConfiguration.decode(legacy).profileID)
        XCTAssertNil((try JSONSerialization.jsonObject(with: legacy) as? [String: Any])?["profileID"])
        XCTAssertThrowsError(try RuntimeConfiguration(profileID: "valid.yaml").validate())
    }

    func testUntrustedProfilePathsCannotCreateStateOrReplacePendingSnapshot() throws {
        let state = CoreStateStore(root: root.appendingPathComponent("CoreState"))
        let snapshots = SnapshotStore(root: root.appendingPathComponent("Snapshots"))
        let good = try snapshots.stage(configuration: RuntimeConfiguration())
        for id in ["", "../escape.yaml", "/tmp/escape.yaml", "nested/name.yaml", "nested\\name.yaml", ".hidden.yaml", "a\0.yaml", "not-yaml", String(repeating: "a", count: 251) + ".yaml"] {
            XCTAssertThrowsError(try state.directory(profileID: id))
            XCTAssertThrowsError(try snapshots.stage(configuration: RuntimeConfiguration(outbound: .mihomo(yaml: "mode: direct\n"), profileID: id)))
            XCTAssertEqual(try snapshots.pendingRevision(), good)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("CoreState").path))
    }

    func testSymlinkRootAndProfileDirectoriesAreRejectedWithoutWritingTarget() throws {
        let target = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let linkedRoot = root.appendingPathComponent("linked-root")
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: target)
        XCTAssertThrowsError(try CoreStateStore(root: linkedRoot).directory(profileID: "valid.yaml"))
        let stateRoot = root.appendingPathComponent("CoreState")
        let store = CoreStateStore(root: stateRoot)
        let directory = try store.directory(profileID: "valid.yaml")
        XCTAssertEqual(directory.lastPathComponent, SHA256.hash(data: Data("valid.yaml".utf8)).map { String(format: "%02x", $0) }.joined())
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: target)
        XCTAssertThrowsError(try store.directory(profileID: "valid.yaml"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), [])
    }
}
