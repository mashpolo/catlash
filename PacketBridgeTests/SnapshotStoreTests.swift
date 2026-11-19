import CryptoKit
import Foundation
import XCTest
@testable import PacketBridge

final class SnapshotStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    func testSnapshotAndReferencesSurviveReopening() throws {
        let configuration = RuntimeConfiguration(outbound: .socks5(
            server: "127.0.0.1", port: 1080, username: "test-user", password: "test-password", udp: true
        ))
        let store = SnapshotStore(root: root)
        let revision = try store.stage(configuration: configuration)
        try store.markSuccessful(revision: revision)

        let reopened = SnapshotStore(root: root)
        XCTAssertEqual(try reopened.pendingRevision(), revision)
        XCTAssertEqual(try reopened.lastSuccessfulRevision(), revision)
        XCTAssertEqual(try RuntimeConfiguration.decode(reopened.load(revision: revision)), configuration)
    }

    func testRawBytesArePreservedAndRepeatedStageIsIdempotent() throws {
        let data = Data("{ \"outbound\": {\"type\":\"direct\"}, \"version\":1, \"mtu\":1280 }\n".utf8)
        let store = SnapshotStore(root: root)
        let revision = try store.stage(data: data)
        XCTAssertEqual(revision, hash(data))
        XCTAssertEqual(try store.stage(data: data), revision)
        XCTAssertEqual(try store.load(revision: revision), data)
    }

    func testSuccessDoesNotOverwriteNewerPendingAndRollbackIsExplicit() throws {
        let app = SnapshotStore(root: root)
        let extensionStore = SnapshotStore(root: root)
        let first = try app.stage(configuration: RuntimeConfiguration())
        let second = try app.stage(configuration: RuntimeConfiguration(mtu: 1500))
        try extensionStore.markSuccessful(revision: first)
        XCTAssertEqual(try app.pendingRevision(), second)
        XCTAssertEqual(try app.lastSuccessfulRevision(), first)
        XCTAssertEqual(try app.restoreLastSuccessful(), first)
        XCTAssertEqual(try extensionStore.pendingRevision(), first)
    }

    func testCorruptCandidateCannotReplaceSuccessfulRevision() throws {
        let store = SnapshotStore(root: root)
        let good = try store.stage(configuration: RuntimeConfiguration())
        try store.markSuccessful(revision: good)
        let candidate = try store.stage(configuration: RuntimeConfiguration(mtu: 1500))
        try Data("tampered".utf8).write(to: snapshotURL(candidate))

        assertError(.corruptSnapshot) { _ = try store.load(revision: candidate) }
        assertError(.corruptSnapshot) { try store.markSuccessful(revision: candidate) }
        XCTAssertEqual(try store.lastSuccessfulRevision(), good)
        XCTAssertEqual(try store.restoreLastSuccessful(), good)
        XCTAssertEqual(try store.pendingRevision(), good)
    }

    func testInvalidConfigurationDoesNotChangeReferences() throws {
        let store = SnapshotStore(root: root)
        let good = try store.stage(configuration: RuntimeConfiguration())
        try store.markSuccessful(revision: good)
        let invalid: [(Data, SnapshotStoreError)] = [
            (Data("{\"version\":2,\"mtu\":1280,\"outbound\":{\"type\":\"direct\"}}".utf8), .unsupportedVersion),
            (Data("{\"version\":1,\"mtu\":9001,\"outbound\":{\"type\":\"direct\"}}".utf8), .invalidMTU),
            (Data("{\"version\":1,\"mtu\":1280,\"outbound\":{\"type\":\"unknown\"}}".utf8), .invalidOutbound),
            (Data("{\"version\":1,\"mtu\":1280,\"extra\":true,\"outbound\":{\"type\":\"direct\"}}".utf8), .invalidConfiguration),
            (Data("{\"version\":1,\"mtu\":1280,\"outbound\":{\"type\":\"direct\",\"udp\":true}}".utf8), .invalidConfiguration),
        ]
        for (data, error) in invalid {
            assertError(error) { _ = try store.stage(data: data) }
            XCTAssertEqual(try store.pendingRevision(), good)
            XCTAssertEqual(try store.lastSuccessfulRevision(), good)
        }
    }

    func testValidHashDoesNotBypassSchemaValidation() throws {
        let store = SnapshotStore(root: root)
        _ = try store.stage(configuration: RuntimeConfiguration())
        let invalid = Data("{\"version\":42,\"mtu\":1280,\"outbound\":{\"type\":\"direct\"}}".utf8)
        let revision = hash(invalid)
        try invalid.write(to: snapshotURL(revision))
        assertError(.unsupportedVersion) { _ = try store.load(revision: revision) }
    }

    func testInvalidRevisionCannotAccessPathsOrReplaceSuccess() throws {
        let store = SnapshotStore(root: root)
        let revision = try store.stage(configuration: RuntimeConfiguration())
        try store.markSuccessful(revision: revision)
        for invalid in ["../secret", "/tmp/secret", "", String(repeating: "a", count: 63), String(repeating: "G", count: 64)] {
            assertError(.invalidRevision) { _ = try store.load(revision: invalid) }
            assertError(.invalidRevision) { try store.markSuccessful(revision: invalid) }
        }
        XCTAssertEqual(try store.lastSuccessfulRevision(), revision)
    }

    func testMissingSuccessfulSnapshotDoesNotChangePending() throws {
        let store = SnapshotStore(root: root)
        XCTAssertNil(try store.pendingRevision())
        XCTAssertNil(try store.lastSuccessfulRevision())
        let pending = try store.stage(configuration: RuntimeConfiguration())
        assertError(.noSuccessfulSnapshot) { _ = try store.restoreLastSuccessful() }
        XCTAssertEqual(try store.pendingRevision(), pending)
    }

    func testSOCKS5DefaultsAndBoundaries() throws {
        let data = Data("{\"version\":1,\"mtu\":1280,\"outbound\":{\"type\":\"socks5\",\"server\":\"localhost\",\"port\":1080}}".utf8)
        XCTAssertEqual(try RuntimeConfiguration.decode(data).outbound, .socks5(
            server: "localhost", port: 1080, username: "", password: "", udp: true
        ))
        let store = SnapshotStore(root: root)
        for (server, port) in [("", 1080), (" \n", 1080), ("localhost", 0), ("localhost", 65_536)] {
            let config = RuntimeConfiguration(outbound: .socks5(server: server, port: port))
            assertError(.invalidOutbound) { _ = try store.stage(configuration: config) }
        }
    }

    func testNullAndUnknownSOCKS5FieldsAreRejected() {
        for suffix in [",\"udp\":null", ",\"username\":null", ",\"password\":null", ",\"unhandled\":true"] {
            let data = Data("{\"version\":1,\"mtu\":1280,\"outbound\":{\"type\":\"socks5\",\"server\":\"localhost\",\"port\":1080\(suffix)}}".utf8)
            assertError(.invalidConfiguration) { _ = try RuntimeConfiguration.decode(data) }
        }
    }

    func testOversizedInputAndCredentialsAreRejectedWithoutExposingValues() {
        let store = SnapshotStore(root: root)
        assertError(.invalidConfiguration) { _ = try store.stage(data: Data(repeating: 32, count: 16_385)) }
        let password = String(repeating: "密", count: 86)
        let config = RuntimeConfiguration(outbound: .socks5(server: "localhost", port: 1080, password: password))
        XCTAssertThrowsError(try store.stage(configuration: config)) { error in
            XCTAssertEqual(error as? SnapshotStoreError, .invalidOutbound)
            XCTAssertFalse(error.localizedDescription.contains(password))
        }
    }

    private func snapshotURL(_ revision: String) -> URL {
        root.appendingPathComponent("snapshots").appendingPathComponent(revision + ".json")
    }

    private func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func assertError(_ expected: SnapshotStoreError, operation: () throws -> Void) {
        XCTAssertThrowsError(try operation()) { error in
            XCTAssertEqual(error as? SnapshotStoreError, expected)
        }
    }
}
