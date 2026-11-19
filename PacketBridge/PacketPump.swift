import Darwin
import Foundation
import NetworkExtension

public protocol PacketFlow: AnyObject, Sendable {
    func readPackets(completionHandler: @escaping @Sendable ([Data], [NSNumber]) -> Void)
    func writePackets(_ packets: [Data], withProtocols protocols: [NSNumber]) -> Bool
}

public protocol PacketSession: AnyObject, Sendable {
    func writePacket(_ packet: Data) throws
    func readPacket() throws -> Data
    func close() throws
}

public enum PacketPumpError: Error, Equatable {
    case invalidBatch
    case invalidPacket
    case outputRejected
}

public final class PacketPump: @unchecked Sendable {
    private final class Run: @unchecked Sendable {
        let session: PacketSession
        let onFailure: @Sendable (Error) -> Void
        let reader = DispatchGroup()
        var running = true

        init(session: PacketSession, onFailure: @escaping @Sendable (Error) -> Void) {
            self.session = session
            self.onFailure = onFailure
        }
    }

    private let flow: PacketFlow
    private let maximumPacketSize: Int
    private let state = DispatchQueue(label: "FlClash.PacketPump.state")
    private let output = DispatchQueue(label: "FlClash.PacketPump.output")
    private var current: Run?
    private var inputReadPending = false

    public init(flow: PacketFlow, maximumPacketSize: Int = 65_535) {
        self.flow = flow
        self.maximumPacketSize = maximumPacketSize
    }

    public func start(session: PacketSession, onFailure: @escaping @Sendable (Error) -> Void) {
        state.async {
            if let current = self.current { self.terminate(current) }
            let run = Run(session: session, onFailure: onFailure)
            self.current = run
            run.reader.enter()
            self.output.async {
                defer { run.reader.leave() }
                self.readOutput(run)
            }
            self.readInput()
        }
    }

    public func stop(completion: @escaping @Sendable () -> Void) {
        state.async {
            guard let run = self.current else {
                completion()
                return
            }
            self.terminate(run)
            run.reader.notify(queue: self.state) { [weak run] in
                if self.current === run { self.current = nil }
                completion()
            }
        }
    }

    private func readInput() {
        guard let run = current, run.running, !inputReadPending else { return }
        inputReadPending = true
        flow.readPackets { [weak self, weak run] packets, families in
            guard let self else { return }
            self.state.async { [weak run] in
                self.inputReadPending = false
                if let run, self.current === run, run.running {
                    self.writeInput(packets, families: families, run: run)
                }
                self.readInput()
            }
        }
    }

    private func writeInput(_ packets: [Data], families: [NSNumber], run: Run) {
        guard packets.count == families.count else { return }
        do {
            for (packet, family) in zip(packets, families) {
                guard packetFamily(packet) == family.int32Value else { continue }
                try run.session.writePacket(packet)
            }
        } catch {
            terminate(run, error: error)
        }
    }

    private func readOutput(_ run: Run) {
        do {
            while true {
                let shouldContinue = try autoreleasepool {
                    let packet = try run.session.readPacket()
                    return state.sync {
                        guard current === run, run.running else { return false }
                        if let family = packetFamily(packet) {
                            // A rejected datagram must not tear down unrelated connections.
                            _ = flow.writePackets([packet], withProtocols: [NSNumber(value: family)])
                        }
                        return true
                    }
                }
                if !shouldContinue { return }
            }
        } catch {
            state.async { self.terminate(run, error: error) }
        }
    }

    private func terminate(_ run: Run, error: Error? = nil) {
        guard run.running else { return }
        run.running = false
        var failure = error
        do { try run.session.close() } catch { failure = failure ?? error }
        if let failure { run.onFailure(failure) }
    }

    private func packetFamily(_ packet: Data) -> Int32? {
        guard let first = packet.first, packet.count <= maximumPacketSize else {
            return nil
        }
        switch first >> 4 {
        case 4 where packet.count >= 20: return AF_INET
        case 6 where packet.count >= 40: return AF_INET6
        default: return nil
        }
    }
}

public final class NetworkExtensionPacketFlow: PacketFlow, @unchecked Sendable {
    private let flow: NEPacketTunnelFlow

    public init(_ flow: NEPacketTunnelFlow) {
        self.flow = flow
    }

    public func readPackets(completionHandler: @escaping @Sendable ([Data], [NSNumber]) -> Void) {
        flow.readPackets(completionHandler: completionHandler)
    }

    public func writePackets(_ packets: [Data], withProtocols protocols: [NSNumber]) -> Bool {
        flow.writePackets(packets, withProtocols: protocols)
    }
}
