import Foundation
import XCTest
@testable import PacketBridge

final class ProxySharingBridgeTests: XCTestCase {
    func testSharingStartsDisabledAndRejectsMissingCredentialsAcrossBridge() throws {
        let session = try GoPacketSession(mtu: 1500)
        defer { try? session.close() }
        XCTAssertFalse(try session.sharingStatus().enabled)
        XCTAssertThrowsError(try session.configureSharing(ProxySharingConfiguration(enabled: true, listenAddress: "127.0.0.1")))
        XCTAssertFalse(try session.sharingStatus().enabled)
        XCTAssertFalse(try session.configureSharing(ProxySharingConfiguration(enabled: false)).enabled)
    }

    func testSharingResponseDoesNotReturnCredentials() throws {
        let status = try JSONDecoder().decode(ProxySharingStatus.self, from: Data(#"{"enabled":true,"listenAddress":"127.0.0.1","httpPort":7890,"socksPort":7891}"#.utf8))
        let response = TunnelControlResponse(id: UUID(), sharing: status)
        let data = try JSONEncoder().encode(response)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("password"))
        XCTAssertFalse(text.contains("username"))
        XCTAssertEqual(try JSONDecoder().decode(TunnelControlResponse.self, from: data).sharing?.httpPort, 7890)
    }
}
