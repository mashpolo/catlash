import Darwin
import Foundation
import XCTest
@testable import PacketBridge

final class RuntimeBridgeTests: XCTestCase {
    func testDNSHistoryAndSessionScopedControlsCrossGeneratedFramework() throws {
        let runtime = RuntimeConfiguration(outbound: .mihomo(yaml: """
        dns:
          enable: true
          enhanced-mode: fake-ip
          nameserver: [127.0.0.1:9]
        """))
        let data = try JSONEncoder().encode(runtime)
        let session = try GoPacketSession(configuration: String(decoding: data, as: UTF8.self))
        defer { try? session.close() }
        var query: [UInt8] = [0, 1, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0]
        for label in ["history", "invalid"] { query.append(UInt8(label.utf8.count)); query.append(contentsOf: label.utf8) }
        query.append(contentsOf: [0, 0, 1, 0, 1])
        let requestSize = query.count
        let received = expectation(description: "DNS response returned through packet bridge")
        DispatchQueue.global().async {
            do {
                let response = try session.readPacket()
                XCTAssertEqual(response[9], 17)
                XCTAssertGreaterThan(response.count, 28 + requestSize)
            } catch { XCTFail("DNS response failed: \(error)") }
            received.fulfill()
        }
        try session.writePacket(udpPacket(host: "198.18.0.1", port: 53, payload: Data(query)))
        wait(for: [received], timeout: 3)
        let state = try session.runtimeSnapshot()
        let record = try XCTUnwrap(state.dnsQueries?.first)
        XCTAssertEqual(record.domain, "history.invalid")
        XCTAssertEqual(record.mode, "fakeip")
        XCTAssertEqual(record.status, "success")
        XCTAssertEqual(record.answers.count, 1)
        XCTAssertThrowsError(try session.clearDNSCache(expectedSessionID: "foreign"))
        XCTAssertThrowsError(try session.closeAllConnections(expectedSessionID: "foreign"))
        try session.clearDNSCache(expectedSessionID: state.sessionID)
        try session.closeAllConnections(expectedSessionID: state.sessionID)
        XCTAssertEqual(try session.runtimeSnapshot().dnsQueries?.count, 1)
        try session.close()
        XCTAssertThrowsError(try session.clearDNSCache(expectedSessionID: state.sessionID))
        let restarted = try GoPacketSession(mtu: 1500)
        defer { try? restarted.close() }
        XCTAssertEqual(try restarted.runtimeSnapshot().dnsQueries?.count, 0)
        XCTAssertThrowsError(try restarted.closeAllConnections(expectedSessionID: state.sessionID))
    }

    func testUDPFlowAndLogsCrossGeneratedFramework() throws {
        let host = try localIPv4()
        let socketFD = socket(AF_INET, SOCK_DGRAM, 0)
        XCTAssertGreaterThanOrEqual(socketFD, 0)
        guard socketFD >= 0 else { return }
        defer { Darwin.close(socketFD) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr(host)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(bound, 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &length) }
        }
        XCTAssertEqual(named, 0)
        let port = UInt16(bigEndian: address.sin_port)
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let echoed = expectation(description: "local server echoed actual payload")
        let payload = Data("swift-runtime-evidence".utf8)
        DispatchQueue.global().async {
            var source = sockaddr_storage()
            var sourceLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
            var buffer = [UInt8](repeating: 0, count: 512)
            let count = withUnsafeMutablePointer(to: &source) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(socketFD, &buffer, buffer.count, 0, $0, &sourceLength)
                }
            }
            XCTAssertEqual(count, payload.count)
            if count > 0 {
                XCTAssertEqual(Data(buffer.prefix(count)), payload)
                let sent = withUnsafePointer(to: &source) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(socketFD, buffer, count, 0, $0, sourceLength)
                    }
                }
                XCTAssertEqual(sent, count)
            }
            echoed.fulfill()
        }
        let session = try GoPacketSession(mtu: 1500)
        defer { try? session.close() }
        let received = expectation(description: "echo traversed Go packet session")
        DispatchQueue.global().async {
            do {
                let response = try session.readPacket()
                XCTAssertEqual(response[9], 17)
                XCTAssertEqual(response.suffix(payload.count), payload)
            } catch { XCTFail("Packet read failed: \(error)") }
            received.fulfill()
        }
        try session.writePacket(udpPacket(host: host, port: port, payload: payload))
        wait(for: [echoed, received], timeout: 3)
        let sampled = expectation(description: "runtime reports forwarded bytes")
        DispatchQueue.global().async {
            do {
                let deadline = Date().addingTimeInterval(2)
                var snapshot = try session.runtimeSnapshot()
                while snapshot.downloadTotal != payload.count && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.005)
                    snapshot = try session.runtimeSnapshot()
                }
                XCTAssertEqual(snapshot.uploadTotal, Int64(payload.count))
                XCTAssertEqual(snapshot.downloadTotal, Int64(payload.count))
                XCTAssertEqual(snapshot.activeCount, 1)
                let connection = try XCTUnwrap(snapshot.connections.first)
                XCTAssertEqual(connection.network, "udp")
                XCTAssertEqual(connection.proxy, "DIRECT")
                XCTAssertEqual(connection.destination, "\(host):\(port)")
                XCTAssertFalse(snapshot.logs.isEmpty)
                try session.closeConnection(id: connection.id)
            } catch { XCTFail("Runtime bridge failed: \(error)") }
            sampled.fulfill()
        }
        wait(for: [sampled], timeout: 3)
        let firstID = try session.runtimeSnapshot().sessionID
        try session.close()
        let restarted = try GoPacketSession(mtu: 1500)
        defer { try? restarted.close() }
        let fresh = try restarted.runtimeSnapshot()
        XCTAssertNotEqual(fresh.sessionID, firstID)
        XCTAssertEqual(fresh.uploadTotal, 0)
        XCTAssertTrue(fresh.connections.isEmpty)
    }

    private func localIPv4() throws -> String {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { throw POSIXError(.ENETDOWN) }
        defer { freeifaddrs(first) }
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == AF_INET,
                  entry.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  entry.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: name)
            }
        }
        throw XCTSkip("The MIP packet bridge requires a non-loopback local IPv4 test endpoint.")
    }

    private func udpPacket(host: String, port: UInt16, payload: Data) -> Data {
        let destination = host.split(separator: ".").compactMap { UInt8($0) }
        let size = UInt16(28 + payload.count)
        let udpSize = UInt16(8 + payload.count)
        var bytes: [UInt8] = [
            0x45, 0, UInt8(size >> 8), UInt8(size & 255), 0, 1, 0, 0, 64, 17, 0, 0,
            198, 18, 0, 2, destination[0], destination[1], destination[2], destination[3],
            0x9c, 0x40, UInt8(port >> 8), UInt8(port & 255), UInt8(udpSize >> 8), UInt8(udpSize & 255), 0, 0,
        ]
        var sum: UInt32 = 0
        for index in stride(from: 0, to: 20, by: 2) { sum += UInt32(bytes[index]) << 8 | UInt32(bytes[index + 1]) }
        while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        let checksum = ~UInt16(sum)
        bytes[10] = UInt8(checksum >> 8)
        bytes[11] = UInt8(checksum & 255)
        return Data(bytes) + payload
    }
}
