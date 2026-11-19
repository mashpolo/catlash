import Foundation

public struct TunnelResourceStatus: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case preparing
        case applying
        case failed
        case ready
    }

    public let phase: Phase
    public let operationID: UUID?
    public let message: String

    public init(phase: Phase, message: String, operationID: UUID? = nil) {
        self.operationID = operationID
        self.phase = phase
        self.message = message
    }
}
