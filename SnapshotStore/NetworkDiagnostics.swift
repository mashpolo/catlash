import Darwin
import Foundation
import Network

public enum NetworkDiagnosticError: LocalizedError {
    case invalidInput(String), invalidResponse(String), timeout
    public var errorDescription: String? {
        switch self {
        case let .invalidInput(message), let .invalidResponse(message): return message
        case .timeout: return "请求超时，服务器未在期限内返回有效响应。"
        }
    }
}

public enum DNSDiagnosticType: UInt16, CaseIterable, Sendable {
    case a = 1, aaaa = 28
    public var title: String { self == .a ? "A" : "AAAA" }
}

public struct DNSDiagnosticResult: Sendable {
    public let addresses: [String]
    public let responseCode: Int
    public let answerCount: Int
}

public struct DNSDiagnosticQuery: Sendable {
    public let domain: String
    public let type: DNSDiagnosticType
    public let id: UInt16
    public let packet: Data

    public init(domain: String, type: DNSDiagnosticType, id: UInt16 = UInt16.random(in: .min ... .max)) throws {
        let normalized = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let name = normalized.hasSuffix(".") ? String(normalized.dropLast()) : normalized
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard !name.isEmpty, name.utf8.count <= 253,
              labels.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 63 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 } }) else {
            throw NetworkDiagnosticError.invalidInput("请输入有效的 ASCII 域名；国际域名请使用 Punycode。")
        }
        self.domain = name; self.type = type; self.id = id
        var bytes: [UInt8] = [UInt8(id >> 8), UInt8(id & 255), 1, 0, 0, 1, 0, 0, 0, 0, 0, 0]
        for label in labels { bytes.append(UInt8(label.utf8.count)); bytes.append(contentsOf: label.utf8) }
        bytes += [0, 0, UInt8(type.rawValue), 0, 1]
        packet = Data(bytes)
    }

    public func parse(_ data: Data) throws -> DNSDiagnosticResult {
        let bytes = Array(data)
        guard bytes.count >= 12, read16(bytes, 0) == id, bytes[2] & 0x80 != 0,
              bytes[2] & 0x78 == 0, read16(bytes, 4) == 1 else { throw NetworkDiagnosticError.invalidResponse("DNS 响应头或事务编号不匹配。") }
        guard bytes[2] & 2 == 0 else { throw NetworkDiagnosticError.invalidResponse("DNS UDP 响应被截断，请更换解析器；本查询工具尚不自动重试 TCP。") }
        var offset = 12
        let question = try dnsName(bytes, offset: &offset)
        guard question.lowercased() == domain, offset + 4 <= bytes.count,
              read16(bytes, offset) == type.rawValue, read16(bytes, offset + 2) == 1 else { throw NetworkDiagnosticError.invalidResponse("DNS 响应问题与请求不匹配。") }
        offset += 4
        let answerCount = Int(read16(bytes, 6))
        var addresses: [String] = []
        for _ in 0..<answerCount {
            _ = try dnsName(bytes, offset: &offset)
            guard offset + 10 <= bytes.count else { throw NetworkDiagnosticError.invalidResponse("DNS 回答不完整。") }
            let kind = read16(bytes, offset), recordClass = read16(bytes, offset + 2)
            let length = Int(read16(bytes, offset + 8))
            offset += 10
            guard offset + length <= bytes.count else { throw NetworkDiagnosticError.invalidResponse("DNS 数据长度不完整。") }
            if recordClass == 1, kind == type.rawValue,
               (kind == 1 && length == 4) || (kind == 28 && length == 16) {
                addresses.append(try addressText(Array(bytes[offset..<(offset + length)])))
            }
            offset += length
        }
        return DNSDiagnosticResult(addresses: addresses, responseCode: Int(bytes[3] & 15), answerCount: answerCount)
    }
}

private func dnsName(_ bytes: [UInt8], offset: inout Int) throws -> String {
    var cursor = offset, visited: Set<Int> = [], labels: [String] = [], jumped = false, length = 0
    while cursor < bytes.count {
        guard visited.insert(cursor).inserted, visited.count <= 128 else { throw NetworkDiagnosticError.invalidResponse("DNS 名称压缩指针循环。") }
        let count = Int(bytes[cursor])
        if count & 0xc0 == 0xc0 {
            guard cursor + 1 < bytes.count else { throw NetworkDiagnosticError.invalidResponse("DNS 压缩指针不完整。") }
            if !jumped { offset = cursor + 2; jumped = true }
            cursor = (count & 0x3f) << 8 | Int(bytes[cursor + 1])
            continue
        }
        guard count <= 63, cursor + 1 + count <= bytes.count else { throw NetworkDiagnosticError.invalidResponse("DNS 名称长度错误。") }
        cursor += 1
        if count == 0 { if !jumped { offset = cursor }; return labels.joined(separator: ".") }
        length += count + 1
        guard length <= 255, let label = String(bytes: bytes[cursor..<(cursor + count)], encoding: .ascii) else { throw NetworkDiagnosticError.invalidResponse("DNS 名称无效。") }
        labels.append(label); cursor += count
    }
    throw NetworkDiagnosticError.invalidResponse("DNS 名称不完整。")
}

public struct STUNDiagnosticResult: Sendable {
    public let address: String
    public let port: UInt16
}

public struct STUNDiagnosticQuery: Sendable {
    public let transaction: [UInt8]
    public init() { transaction = (0..<12).map { _ in UInt8.random(in: .min ... .max) } }
    init(transaction: [UInt8]) { self.transaction = transaction }
    public var packet: Data { Data([0, 1, 0, 0, 0x21, 0x12, 0xa4, 0x42] + transaction) }

    public func parse(_ data: Data) throws -> STUNDiagnosticResult {
        let bytes = Array(data)
        guard bytes.count >= 20, read16(bytes, 0) == 0x0101,
              Array(bytes[4..<8]) == [0x21, 0x12, 0xa4, 0x42], Array(bytes[8..<20]) == transaction,
              Int(read16(bytes, 2)) + 20 == bytes.count, read16(bytes, 2) % 4 == 0 else {
            throw NetworkDiagnosticError.invalidResponse("STUN 响应类型、长度或事务编号不匹配。")
        }
        var offset = 20
        while offset + 4 <= bytes.count {
            let kind = read16(bytes, offset), length = Int(read16(bytes, offset + 2))
            offset += 4
            guard offset + length <= bytes.count else { throw NetworkDiagnosticError.invalidResponse("STUN 属性不完整。") }
            if kind == 0x0020 {
                guard length >= 4 else { throw NetworkDiagnosticError.invalidResponse("STUN 地址属性不完整。") }
                let family = bytes[offset + 1]
                let size = family == 1 ? 4 : family == 2 ? 16 : 0
                guard size > 0, length == size + 4 else { throw NetworkDiagnosticError.invalidResponse("STUN 地址族或长度无效。") }
                let mask: [UInt8] = [0x21, 0x12, 0xa4, 0x42] + transaction
                let address = (0..<size).map { bytes[offset + 4 + $0] ^ mask[$0] }
                return STUNDiagnosticResult(address: try addressText(address), port: read16(bytes, offset + 2) ^ 0x2112)
            }
            offset += (length + 3) & ~3
        }
        throw NetworkDiagnosticError.invalidResponse("服务器未返回 XOR-MAPPED-ADDRESS。")
    }
}

private func read16(_ bytes: [UInt8], _ offset: Int) -> UInt16 { UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1]) }

private func addressText(_ bytes: [UInt8]) throws -> String {
    var result = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
    let success = bytes.withUnsafeBytes { inet_ntop(bytes.count == 4 ? AF_INET : AF_INET6, $0.baseAddress, &result, socklen_t(result.count)) }
    guard success != nil else { throw NetworkDiagnosticError.invalidResponse("服务器返回无效地址。") }
    return String(cString: result)
}

public enum NetworkDiagnostics {
    public static func dns(domain: String, type: DNSDiagnosticType, server: String, port: UInt16) async throws -> DNSDiagnosticResult {
        let query = try DNSDiagnosticQuery(domain: domain, type: type)
        let data = try await DatagramDiagnosticExchange(host: server, port: port).run(query.packet)
        return try query.parse(data)
    }
    public static func stun(server: String, port: UInt16) async throws -> STUNDiagnosticResult {
        let query = STUNDiagnosticQuery()
        let data = try await DatagramDiagnosticExchange(host: server, port: port).run(query.packet)
        return try query.parse(data)
    }
}

final class DatagramDiagnosticExchange: @unchecked Sendable {
    private let queue = DispatchQueue(label: "FlClash.NetworkDiagnostic")
    private let connection: NWConnection
    private let timeout: TimeInterval
    private var continuation: CheckedContinuation<Data, Error>?
    private var cancelled = false

    init(host: String, port: UInt16, timeout: TimeInterval = 5) throws {
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !host.contains(where: { $0.isWhitespace }), port > 0,
              let endpointPort = NWEndpoint.Port(rawValue: port) else { throw NetworkDiagnosticError.invalidInput("请输入服务器地址和 1–65535 端口。") }
        connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .udp)
        self.timeout = timeout
    }

    func run(_ packet: Data) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    self.continuation = continuation
                    if cancelled { finish(.failure(CancellationError())); return }
                    connection.stateUpdateHandler = { [weak self] state in
                        guard let self else { return }
                        switch state {
                        case .ready:
                            self.connection.send(content: packet, completion: .contentProcessed { [weak self] error in
                                if let error { self?.finish(.failure(error)) }
                            })
                            self.connection.receiveMessage { [weak self] data, _, _, error in
                                if let error { self?.finish(.failure(error)) }
                                else if let data { self?.finish(.success(data)) }
                                else { self?.finish(.failure(NetworkDiagnosticError.invalidResponse("服务器返回空数据。"))) }
                            }
                        case let .failed(error): self.finish(.failure(error))
                        default: break
                        }
                    }
                    connection.start(queue: queue)
                    queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish(.failure(NetworkDiagnosticError.timeout)) }
                }
            }
        } onCancel: {
            self.queue.async { self.cancelled = true; self.finish(.failure(CancellationError())) }
        }
    }

    private func finish(_ result: Result<Data, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation.resume(with: result)
    }
}
