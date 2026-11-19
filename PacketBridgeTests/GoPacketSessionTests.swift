import Foundation
import XCTest
@testable import PacketBridge

final class GoPacketSessionTests: XCTestCase {
    func testGeneratedFrameworkReturnsICMPReply() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SnapshotStore(root: root)
        let revision = try store.stage(configuration: RuntimeConfiguration())
        let data = try store.load(revision: revision)
        let session = try GoPacketSession(configuration: String(decoding: data, as: UTF8.self))
        defer { try? session.close() }
        let request = Data([
            0x45, 0x00, 0x00, 0x22, 0x00, 0x00, 0x00, 0x00, 0x40, 0x01,
            0xb2, 0xc5, 0xc6, 0x12, 0x00, 0x02, 0x01, 0x01, 0x01, 0x01,
            0x08, 0x00, 0xc0, 0xf1, 0x00, 0x01, 0x00, 0x01,
            0x70, 0x68, 0x61, 0x73, 0x65, 0x30,
        ])
        let replied = expectation(description: "Reply across Swift and Go")
        DispatchQueue.global().async {
            do {
                let reply = try session.readPacket()
                XCTAssertEqual(reply.count, request.count)
                guard reply.count == request.count else { replied.fulfill(); return }
                XCTAssertEqual(reply[20], 0)
                XCTAssertEqual(reply[12..<16], request[16..<20])
                XCTAssertEqual(reply[16..<20], request[12..<16])
                XCTAssertEqual(reply.suffix(6), Data("phase0".utf8))
            } catch { XCTFail("Read failed: \(error)") }
            replied.fulfill()
        }
        try session.writePacket(request)
        wait(for: [replied], timeout: 3)
    }

    func testConfiguredFrameworkValidatesSnapshotAndRestarts() throws {
        XCTAssertThrowsError(try GoPacketSession(configuration: #"{"version":2,"mtu":1280,"outbound":{"type":"direct"}}"#))
        let configuration = #"{"version":1,"mtu":1280,"outbound":{"type":"direct"}}"#
        let session = try GoPacketSession(configuration: configuration)
        XCTAssertThrowsError(try GoPacketSession(configuration: configuration))
        try session.close()
        let restarted = try GoPacketSession(configuration: configuration)
        try restarted.close()
    }

    func testFrameworkUsesTheConfigurationValidatedBySwift() throws {
        let raw = Data(#"{"version":1.0,"version":2,"mtu":1280e0,"outbound":{"type":"direct","type":"unsupported"}}"#.utf8)
        let expected = try RuntimeConfiguration.decode(raw)
        XCTAssertEqual(expected, RuntimeConfiguration())
        let session = try GoPacketSession(configuration: String(decoding: raw, as: UTF8.self))
        try session.close()
    }

    func testFrameworkCloseUnblocksReadAndAllowsRestart() throws {
        let session = try GoPacketSession(mtu: 1280)
        let closed = expectation(description: "Go blocking read released")
        DispatchQueue.global().async {
            do {
                _ = try session.readPacket()
                XCTFail("Read succeeded after close")
            } catch {
                XCTAssertFalse(error.localizedDescription.isEmpty)
            }
            closed.fulfill()
        }
        try session.close()
        wait(for: [closed], timeout: 3)
        try session.close()
        let next = try GoPacketSession(mtu: 1280)
        try next.close()
    }
}
