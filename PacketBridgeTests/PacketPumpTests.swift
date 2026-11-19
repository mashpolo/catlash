import Darwin
import Foundation
import XCTest
@testable import PacketBridge

final class PacketPumpTests: XCTestCase {
    func testPacketsCrossBothDirectionsWithCorrectFamilies() throws {
        let flow = FakePacketFlow()
        let session = FakePacketSession()
        let inputRead = expectation(description: "flow read")
        let inputWritten = expectation(description: "core input")
        let outputWritten = expectation(description: "flow output")
        flow.onRead = { inputRead.fulfill() }
        session.onWrite = { inputWritten.fulfill() }
        flow.onWrite = { outputWritten.fulfill() }
        let pump = PacketPump(flow: flow)
        pump.start(session: session) { error in XCTFail("Unexpected error: \(error)") }
        wait(for: [inputRead], timeout: 2)
        flow.onRead = nil
        flow.deliver([ipv4Packet()], families: [NSNumber(value: AF_INET)])
        session.deliver(ipv6Packet())
        wait(for: [inputWritten, outputWritten], timeout: 2)
        XCTAssertEqual(session.writtenPackets, [ipv4Packet()])
        XCTAssertEqual(flow.writtenPackets, [ipv6Packet()])
        XCTAssertEqual(flow.writtenFamilies, [NSNumber(value: AF_INET6)])
        stop(pump)
    }

    func testStopUnblocksReaderAndClosesExactlyOnce() {
        let flow = FakePacketFlow()
        let session = FakePacketSession()
        let reading = expectation(description: "blocked core read")
        session.onRead = { reading.fulfill() }
        let pump = PacketPump(flow: flow)
        pump.start(session: session) { error in XCTFail("Unexpected error: \(error)") }
        wait(for: [reading], timeout: 2)
        stop(pump)
        stop(pump)
        XCTAssertEqual(session.closeCount, 1)
        XCTAssertEqual(session.activeReaders, 0)
    }

    func testStopDiscardsOutputThatWasAlreadyBeingRead() {
        let flow = FakePacketFlow()
        let session = FakePacketSession()
        let reading = expectation(description: "output reader entered")
        let closed = expectation(description: "session closed")
        let stopped = expectation(description: "pump stopped")
        let releaseRead = DispatchSemaphore(value: 0)
        session.returnQueuedPacketAfterClose = true
        session.onRead = {
            reading.fulfill()
            releaseRead.wait()
        }
        session.onClose = { closed.fulfill() }
        let pump = PacketPump(flow: flow)
        pump.start(session: session) { error in XCTFail("Unexpected error: \(error)") }
        wait(for: [reading], timeout: 2)
        session.deliver(ipv4Packet())
        pump.stop { stopped.fulfill() }
        wait(for: [closed], timeout: 2)
        releaseRead.signal()
        wait(for: [stopped], timeout: 2)
        XCTAssertTrue(flow.writtenPackets.isEmpty)
    }

    func testStopReleasesSessionWhileInputCallbackIsPending() {
        let flow = FakePacketFlow()
        let pump = PacketPump(flow: flow)
        let reading = expectation(description: "flow retains input callback")
        flow.onRead = { reading.fulfill() }
        weak var stoppedSession: FakePacketSession?
        do {
            let session = FakePacketSession()
            stoppedSession = session
            pump.start(session: session) { error in XCTFail("Unexpected error: \(error)") }
            wait(for: [reading], timeout: 2)
            stop(pump)
        }
        XCTAssertNil(stoppedSession)
        withExtendedLifetime(pump) {}
    }

    func testRestartDiscardsOldInputCallbackAndKeepsOnePendingRead() {
        let flow = FakePacketFlow()
        let first = FakePacketSession()
        let second = FakePacketSession()
        let firstRead = expectation(description: "old flow read")
        flow.onRead = { firstRead.fulfill() }
        let pump = PacketPump(flow: flow)
        pump.start(session: first) { error in XCTFail("Unexpected error: \(error)") }
        wait(for: [firstRead], timeout: 2)
        flow.onRead = nil
        stop(pump)
        let secondCoreRead = expectation(description: "new core reader")
        second.onRead = { secondCoreRead.fulfill() }
        pump.start(session: second) { error in XCTFail("Unexpected error: \(error)") }
        wait(for: [secondCoreRead], timeout: 2)
        let newFlowRead = expectation(description: "new flow read")
        flow.onRead = { newFlowRead.fulfill() }
        flow.deliver([ipv4Packet()], families: [NSNumber(value: AF_INET)])
        wait(for: [newFlowRead], timeout: 2)
        flow.onRead = nil
        XCTAssertTrue(first.writtenPackets.isEmpty)
        XCTAssertTrue(second.writtenPackets.isEmpty)
        let delivered = expectation(description: "new input delivered")
        second.onWrite = { delivered.fulfill() }
        flow.deliver([ipv4Packet()], families: [NSNumber(value: AF_INET)])
        wait(for: [delivered], timeout: 2)
        XCTAssertEqual(second.writtenPackets, [ipv4Packet()])
        XCTAssertEqual(flow.maximumPendingReads, 1)
        stop(pump)
    }

    func testBadInputDoesNotDiscardFollowingPacketOrStopSession() {
        let flow = FakePacketFlow()
        let session = FakePacketSession()
        let reading = expectation(description: "flow read")
        let written = expectation(description: "valid packet reached session")
        session.onWrite = { written.fulfill() }
        flow.onRead = { reading.fulfill() }
        let pump = PacketPump(flow: flow)
        pump.start(session: session) { error in XCTFail("Unexpected error: \(error)") }
        wait(for: [reading], timeout: 2)
        flow.onRead = nil
        flow.deliver([ipv4Packet(), ipv6Packet()], families: [NSNumber(value: AF_INET6), NSNumber(value: AF_INET6)])
        wait(for: [written], timeout: 2)
        XCTAssertEqual(session.writtenPackets, [ipv6Packet()])
        XCTAssertEqual(session.closeCount, 0)
        stop(pump)
    }

    func testOutputContinuesAfterTransientRejection() {
        let flow = FakePacketFlow()
        let session = FakePacketSession()
        let first = expectation(description: "first write rejected")
        flow.onWrite = { first.fulfill() }
        flow.acceptsWrites = false
        let pump = PacketPump(flow: flow)
        pump.start(session: session) { error in XCTFail("Unexpected error: \(error)") }
        session.deliver(ipv4Packet())
        wait(for: [first], timeout: 2)
        let second = expectation(description: "next packet accepted")
        flow.onWrite = { second.fulfill() }
        flow.acceptsWrites = true
        session.deliver(ipv6Packet())
        wait(for: [second], timeout: 2)
        XCTAssertEqual(flow.writtenPackets, [ipv4Packet(), ipv6Packet()])
        XCTAssertEqual(session.closeCount, 0)
        stop(pump)
    }

    func testClosedCoreIsReportedAndStopsInput() {
        let flow = FakePacketFlow()
        let session = FakePacketSession()
        session.writeError = FakeError.closed
        let reading = expectation(description: "flow read")
        let failed = expectation(description: "closed core")
        flow.onRead = { reading.fulfill() }
        let pump = PacketPump(flow: flow)
        pump.start(session: session) { error in
            XCTAssertEqual(error as? FakeError, .closed)
            failed.fulfill()
        }
        wait(for: [reading], timeout: 2)
        flow.deliver([ipv4Packet()], families: [NSNumber(value: AF_INET)])
        wait(for: [failed], timeout: 2)
        stop(pump)
        XCTAssertEqual(flow.readCount, 1)
    }

    private func stop(_ pump: PacketPump) {
        let stopped = expectation(description: "stopped")
        pump.stop { stopped.fulfill() }
        wait(for: [stopped], timeout: 2)
    }
}

private func ipv4Packet() -> Data {
    Data([0x45] + Array(repeating: UInt8(0), count: 19))
}

private func ipv6Packet() -> Data {
    Data([0x60] + Array(repeating: UInt8(0), count: 39))
}

private enum FakeError: Error { case closed }

private final class FakePacketSession: PacketSession, @unchecked Sendable {
    private let condition = NSCondition()
    private var output: [Data] = []
    private var input: [Data] = []
    private var closed = false
    private var closes = 0
    private var readers = 0
    var onRead: (() -> Void)?
    var onWrite: (() -> Void)?
    var onClose: (() -> Void)?
    var writeError: Error?
    var returnQueuedPacketAfterClose = false

    var writtenPackets: [Data] { condition.withLock { input } }
    var closeCount: Int { condition.withLock { closes } }
    var activeReaders: Int { condition.withLock { readers } }

    func writePacket(_ packet: Data) throws {
        condition.lock()
        if let error = writeError {
            condition.unlock()
            throw error
        }
        input.append(packet)
        let callback = onWrite
        condition.unlock()
        callback?()
    }

    func readPacket() throws -> Data {
        condition.lock()
        readers += 1
        let callback = onRead
        condition.unlock()
        callback?()
        condition.lock()
        defer { readers -= 1; condition.unlock() }
        while output.isEmpty && !closed { condition.wait() }
        if closed && !(returnQueuedPacketAfterClose && !output.isEmpty) { throw FakeError.closed }
        return output.removeFirst()
    }

    func close() throws {
        condition.withLock {
            closes += 1
            closed = true
            condition.broadcast()
        }
        onClose?()
    }

    func deliver(_ packet: Data) {
        condition.withLock {
            output.append(packet)
            condition.signal()
        }
    }
}

private final class FakePacketFlow: PacketFlow, @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (@Sendable ([Data], [NSNumber]) -> Void)?
    private var output: [Data] = []
    private var families: [NSNumber] = []
    private var reads = 0
    private var maxPending = 0
    private var readCallback: (() -> Void)?
    private var writeCallback: (() -> Void)?
    var acceptsWrites = true

    var onRead: (() -> Void)? {
        get { lock.withLock { readCallback } }
        set { lock.withLock { readCallback = newValue } }
    }
    var onWrite: (() -> Void)? {
        get { lock.withLock { writeCallback } }
        set { lock.withLock { writeCallback = newValue } }
    }
    var writtenPackets: [Data] { lock.withLock { output } }
    var writtenFamilies: [NSNumber] { lock.withLock { families } }
    var maximumPendingReads: Int { lock.withLock { maxPending } }
    var readCount: Int { lock.withLock { reads } }

    func readPackets(completionHandler: @escaping @Sendable ([Data], [NSNumber]) -> Void) {
        lock.lock()
        maxPending = max(maxPending, completion == nil ? 1 : 2)
        completion = completionHandler
        reads += 1
        let callback = readCallback
        lock.unlock()
        callback?()
    }

    func writePackets(_ packets: [Data], withProtocols protocols: [NSNumber]) -> Bool {
        lock.lock()
        output.append(contentsOf: packets)
        families.append(contentsOf: protocols)
        let callback = writeCallback
        let accepted = acceptsWrites
        lock.unlock()
        callback?()
        return accepted
    }

    func deliver(_ packets: [Data], families: [NSNumber]) {
        lock.lock()
        let callback = completion
        completion = nil
        lock.unlock()
        callback?(packets, families)
    }
}
