import Foundation

public struct RuntimeSnapshot: Codable, Sendable {
    public let sessionID: String
    public let sampledAt: Int64
    public let uploadTotal: Int64
    public let downloadTotal: Int64
    public let activeCount: Int
    public let connections: [RuntimeConnection]
    public let logs: [RuntimeLogEntry]
    public let droppedConnections: Int64
    public let droppedLogs: Int64
    public let dnsQueries: [RuntimeDNSQuery]?
    public let droppedDNSQueries: Int64?

    public init(sessionID: String, sampledAt: Int64, uploadTotal: Int64, downloadTotal: Int64, activeCount: Int,
                connections: [RuntimeConnection], logs: [RuntimeLogEntry], droppedConnections: Int64, droppedLogs: Int64,
                dnsQueries: [RuntimeDNSQuery]? = nil, droppedDNSQueries: Int64? = nil) {
        self.sessionID = sessionID
        self.sampledAt = sampledAt
        self.uploadTotal = uploadTotal
        self.downloadTotal = downloadTotal
        self.activeCount = activeCount
        self.connections = connections
        self.logs = logs
        self.droppedConnections = droppedConnections
        self.droppedLogs = droppedLogs
        self.dnsQueries = dnsQueries
        self.droppedDNSQueries = droppedDNSQueries
    }
}

public struct RuntimeConnection: Codable, Sendable, Identifiable {
    public let id: String
    public let network: String
    public let source: String
    public let destination: String
    public let host: String
    public let rule: String
    public let proxy: String
    public let startedAt: Int64
    public let endedAt: Int64
    public let upload: Int64
    public let download: Int64
    public let error: String
}

public struct RuntimeLogEntry: Codable, Sendable, Identifiable {
    public let id: Int64
    public let time: Int64
    public let level: String
    public let message: String
}

public struct RuntimeTrafficRate: Sendable {
    public let uploadBytesPerSecond: Double
    public let downloadBytesPerSecond: Double
}

public struct RuntimeTrafficTracker: Sendable {
    private var previous: RuntimeSnapshot?

    public init() {}

    public mutating func reset() { previous = nil }

    public mutating func sample(_ snapshot: RuntimeSnapshot) -> RuntimeTrafficRate? {
        defer { previous = snapshot }
        guard let previous, previous.sessionID == snapshot.sessionID,
              snapshot.sampledAt > previous.sampledAt,
              snapshot.uploadTotal >= previous.uploadTotal,
              snapshot.downloadTotal >= previous.downloadTotal else { return nil }
        let seconds = (Double(snapshot.sampledAt) - Double(previous.sampledAt)) / 1_000
        return RuntimeTrafficRate(
            uploadBytesPerSecond: (Double(snapshot.uploadTotal) - Double(previous.uploadTotal)) / seconds,
            downloadBytesPerSecond: (Double(snapshot.downloadTotal) - Double(previous.downloadTotal)) / seconds
        )
    }
}
