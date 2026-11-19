import Foundation

public struct ProcessMemorySample: Codable, Sendable {
    public let physicalFootprintBytes: UInt64
    public let residentBytes: UInt64
    public let sampledAt: Date

    public init(physicalFootprintBytes: UInt64, residentBytes: UInt64, sampledAt: Date = Date()) {
        self.physicalFootprintBytes = physicalFootprintBytes
        self.residentBytes = residentBytes
        self.sampledAt = sampledAt
    }
}

public struct DiagnosticReport: Codable, Sendable {
    public enum Connection: String, Codable, Sendable { case simulator, disconnected, connecting, connected }
    public let schemaVersion: Int
    public let generatedAt: Date
    public let appVersion: String
    public let operatingSystem: String
    public let connection: Connection
    public let pendingRevision: String?
    public let successfulRevision: String?
    public let extensionMemory: ProcessMemorySample?

    public init(appVersion: String, operatingSystem: String, connection: Connection,
                pendingRevision: String?, successfulRevision: String?, extensionMemory: ProcessMemorySample?) {
        schemaVersion = 1
        generatedAt = Date()
        self.appVersion = appVersion
        self.operatingSystem = operatingSystem
        self.connection = connection
        self.pendingRevision = pendingRevision
        self.successfulRevision = successfulRevision
        self.extensionMemory = extensionMemory
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
