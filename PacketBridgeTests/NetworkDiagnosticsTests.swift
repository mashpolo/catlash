import Darwin
import Foundation
import XCTest
@testable import PacketBridge

final class NetworkDiagnosticsTests: XCTestCase {
    func testDNSRequestAndCompressedAnswer() throws {
        let query = try DNSDiagnosticQuery(domain: "example.com", type: .a, id: 0x1234)
        var response = Array(query.packet)
        response[2] = 0x81; response[3] = 0x80; response[7] = 1
        response += [0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 1, 2, 3, 4]
        let result = try query.parse(Data(response))
        XCTAssertEqual(result.addresses, ["1.2.3.4"])
        XCTAssertEqual(result.responseCode, 0)
        response[0] = 0xff
        XCTAssertThrowsError(try query.parse(Data(response)))
    }

    func testDNSRejectsCompressionLoopTruncationAndInvalidDomain() throws {
        XCTAssertThrowsError(try DNSDiagnosticQuery(domain: "a..test", type: .aaaa))
        let query = try DNSDiagnosticQuery(domain: "example.com", type: .aaaa, id: 1)
        var response = Array(query.packet)
        response[2] = 0x81; response[3] = 0x80; response[7] = 1
        let start = response.count
        response += [0xc0, UInt8(start), 0, 28, 0, 1, 0, 0, 0, 1, 0, 16]
        response += [UInt8](repeating: 0, count: 16)
        XCTAssertThrowsError(try query.parse(Data(response)))
        XCTAssertThrowsError(try query.parse(Data(response.prefix(6))))
    }

    func testSTUNXORMappedAddressAndTransactionValidation() throws {
        let query = STUNDiagnosticQuery(transaction: Array(0..<12))
        var response: [UInt8] = [1, 1, 0, 12, 0x21, 0x12, 0xa4, 0x42] + query.transaction
        response += [0, 0x20, 0, 8, 0, 1, 0x32, 0x9a, 0xea, 0x12, 0xd5, 0x43]
        let result = try query.parse(Data(response))
        XCTAssertEqual(result.address, "203.0.113.1")
        XCTAssertEqual(result.port, 5000)
        response[8] ^= 1
        XCTAssertThrowsError(try query.parse(Data(response)))
        XCTAssertThrowsError(try query.parse(Data(response.prefix(19))))
    }

    func testSTUNIPv6MappingAndMalformedAttributeLength() throws {
        let query = STUNDiagnosticQuery(transaction: Array(0..<12))
        let address: [UInt8] = [0x20, 1, 0xd, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]
        let mask: [UInt8] = [0x21, 0x12, 0xa4, 0x42] + query.transaction
        var response: [UInt8] = [1, 1, 0, 24, 0x21, 0x12, 0xa4, 0x42] + query.transaction
        response += [0, 0x20, 0, 20, 0, 2, 0x32, 0x9a]
        response += zip(address, mask).map { $0 ^ $1 }
        let result = try query.parse(Data(response))
        XCTAssertEqual(result.address, "2001:db8::1")
        XCTAssertEqual(result.port, 5000)
        response[23] = 24
        XCTAssertThrowsError(try query.parse(Data(response)))
    }

    func testDNSAndSTUNUseActualUDPTransport() async throws {
        let dns = try DiagnosticUDPFixture { packet in
            var response = Array(packet)
            response[2] = 0x81; response[3] = 0x80; response[7] = 1
            response += [0xc0, 0x0c, 0, 28, 0, 1, 0, 0, 0, 60, 0, 16]
            response += [0x20, 1, 0xd, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]
            return Data(response)
        }
        let result = try await NetworkDiagnostics.dns(domain: "example.com", type: .aaaa, server: "127.0.0.1", port: dns.port)
        XCTAssertEqual(result.addresses, ["2001:db8::1"])
        let stun = try DiagnosticUDPFixture { packet in
            var response = Array(packet)
            response[0] = 1; response[1] = 1; response[3] = 12
            response += [0, 0x20, 0, 8, 0, 1, 0x32, 0x9a, 0xea, 0x12, 0xd5, 0x43]
            return Data(response)
        }
        let mapped = try await NetworkDiagnostics.stun(server: "127.0.0.1", port: stun.port)
        XCTAssertEqual(mapped.address, "203.0.113.1")
        XCTAssertEqual(mapped.port, 5000)
    }

    func testUDPTimeoutAndCancellationCompleteWithoutWaitingForServer() async throws {
        let server = try DiagnosticUDPFixture { _ in nil }
        let exchange = try DatagramDiagnosticExchange(host: "127.0.0.1", port: server.port, timeout: 0.05)
        do { _ = try await exchange.run(Data([1])); XCTFail("Expected timeout") }
        catch NetworkDiagnosticError.timeout {} catch { XCTFail("Unexpected error: \(error)") }
        let cancelled = Task { try await DatagramDiagnosticExchange(host: "127.0.0.1", port: server.port).run(Data([2])) }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Expected cancellation") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testHTTPTransferCapsResponseAndRejectsErrors() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DiagnosticHTTPFixture.self]
        let result = try await LimitedHTTPDiagnosticTransfer(configuration: configuration)
            .run(URLRequest(url: URL(string: "https://diagnostic.invalid/cap")!), maximumBytes: 1024)
        XCTAssertEqual(result.received, 1024)
        XCTAssertGreaterThan(result.seconds, 0)
        do {
            _ = try await LimitedHTTPDiagnosticTransfer(configuration: configuration)
                .run(URLRequest(url: URL(string: "https://diagnostic.invalid/error")!), maximumBytes: 1024)
            XCTFail("Expected HTTP rejection")
        } catch is NetworkDiagnosticError {}
    }

    func testHTTPTransferCancellationReleasesRequest() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DiagnosticHTTPFixture.self]
        let started = expectation(forNotification: Notification.Name("DiagnosticHTTPStarted"), object: nil)
        let stopped = expectation(forNotification: Notification.Name("DiagnosticHTTPStopped"), object: nil)
        let request = Task {
            try await LimitedHTTPDiagnosticTransfer(configuration: configuration)
                .run(URLRequest(url: URL(string: "https://diagnostic.invalid/slow")!), maximumBytes: 1024)
        }
        await fulfillment(of: [started], timeout: 2)
        request.cancel()
        do { _ = try await request.value; XCTFail("Expected cancellation") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        await fulfillment(of: [stopped], timeout: 2)
    }

    func testHTTPQualityReportsErrorCodesWithoutLeakingRequestDetails() async throws {
        let underlying = NSError(domain: NSOSStatusErrorDomain, code: -9824, userInfo: [
            NSLocalizedDescriptionKey: "failed https://sensitive.example/?token=secret",
            "Authorization": "Bearer credential",
        ])
        let error = NSError(domain: NSURLErrorDomain, code: URLError.secureConnectionFailed.rawValue, userInfo: [
            NSLocalizedDescriptionKey: "A TLS error at https://sensitive.example/?token=secret",
            NSUnderlyingErrorKey: underlying,
            NSURLErrorFailingURLErrorKey: URL(string: "https://sensitive.example/?token=secret")!,
            "_kCFStreamErrorDomainKey": 3, "_kCFStreamErrorCodeKey": -9824,
        ])
        let result = try await NetworkDiagnostics.quality(download: "https://diagnostic.invalid/down", upload: "https://diagnostic.invalid/up") { _, _ in
            throw error
        }
        XCTAssertEqual(result.failurePercent, 100)
        XCTAssertEqual(result.errors.count, 7)
        XCTAssertNil(result.downloadBytesPerSecond)
        XCTAssertNil(result.uploadBytesPerSecond)
        for message in result.errors {
            XCTAssertTrue(message.contains("TLS"))
            XCTAssertTrue(message.contains("NSURLErrorDomain -1200"))
            XCTAssertTrue(message.contains("NSOSStatusErrorDomain -9824"))
            XCTAssertTrue(message.contains("CFStream 3/-9824"))
            for secret in ["sensitive.example", "token=", "secret", "Authorization", "Bearer", "credential", "https://"] {
                XCTAssertFalse(message.contains(secret))
            }
        }
    }

    func testHTTPQualityCancellationDoesNotBecomeAFailedMeasurement() async throws {
        let started = expectation(description: "quality request started")
        let quality = Task {
            try await NetworkDiagnostics.quality(download: "https://diagnostic.invalid/down", upload: "https://diagnostic.invalid/up") { _, _ in
                started.fulfill()
                try await Task.sleep(nanoseconds: 30_000_000_000)
                return HTTPTransferResult(received: 0, sent: 0, seconds: 1)
            }
        }
        await fulfillment(of: [started], timeout: 2)
        quality.cancel()
        do { _ = try await quality.value; XCTFail("Cancellation must propagate") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testHTTPQualityUsesMeasuredSamplesAndFailureRate() {
        let result = HTTPQualityResult(latencies: [10, 30, 20], attempted: 5, downloadBytesPerSecond: 100, uploadBytesPerSecond: 50)
        XCTAssertEqual(result.averageLatency, 20)
        XCTAssertEqual(result.jitter, 15)
        XCTAssertEqual(result.failurePercent, 40)
    }
}

private final class DiagnosticUDPFixture {
    let port: UInt16
    private let socketFD: Int32
    private let done = DispatchSemaphore(value: 0)

    init(reply: @escaping @Sendable (Data) -> Data?) throws {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw POSIXError(.ENETDOWN) }
        socketFD = fd
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { Darwin.close(fd); throw POSIXError(.EADDRINUSE) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        guard named == 0 else { Darwin.close(fd); throw POSIXError(.ENETDOWN) }
        port = UInt16(bigEndian: address.sin_port)
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let done = done
        DispatchQueue.global().async {
            defer { done.signal() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            var source = sockaddr_storage(), sourceLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let count = withUnsafeMutablePointer(to: &source) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &sourceLength) } }
            guard count > 0, let response = reply(Data(buffer.prefix(count))) else { return }
            _ = response.withUnsafeBytes { bytes in
                withUnsafePointer(to: &source) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, bytes.baseAddress, response.count, 0, $0, sourceLength) } }
            }
        }
    }

    deinit {
        _ = shutdown(socketFD, SHUT_RDWR)
        _ = done.wait(timeout: .now() + 3)
        Darwin.close(socketFD)
    }
}

private final class DiagnosticHTTPFixture: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: request.url?.path == "/error" ? 503 : 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if request.url?.path == "/slow" {
            NotificationCenter.default.post(name: Notification.Name("DiagnosticHTTPStarted"), object: nil)
            return
        }
        client?.urlProtocol(self, didLoad: Data(repeating: 1, count: 4096))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
        if request.url?.path == "/slow" { NotificationCenter.default.post(name: Notification.Name("DiagnosticHTTPStopped"), object: nil) }
    }
}
