import Foundation

public struct SubscriptionUsage: Codable, Equatable, Sendable {
    public let upload: Int64?
    public let download: Int64?
    public let total: Int64?
    public let expiresAt: Date?

    public init?(header: String?) {
        guard let header else { return nil }
        var values: [String: Int64] = [:]
        for field in header.split(separator: ";") {
            let pair = field.split(separator: "=", maxSplits: 1)
            guard pair.count == 2,
                  let value = Int64(pair[1].trimmingCharacters(in: .whitespaces)), value >= 0 else { continue }
            values[pair[0].trimmingCharacters(in: .whitespaces).lowercased()] = value
        }
        upload = values["upload"]
        download = values["download"]
        total = values["total"]
        expiresAt = values["expire"].flatMap { $0 > 0 ? Date(timeIntervalSince1970: Double($0)) : nil }
        guard upload != nil || download != nil || total != nil || expiresAt != nil else { return nil }
    }
}

public struct SubscriptionDownload: Sendable {
    public let data: Data
    public let usage: SubscriptionUsage?
    public let receivedAt: Date

    public init(data: Data, usage: SubscriptionUsage? = nil, receivedAt: Date = Date()) {
        self.data = data
        self.usage = usage
        self.receivedAt = receivedAt
    }
}

public struct SubscriptionMetadata: Codable, Equatable, Sendable {
    public var usage: SubscriptionUsage?
    public var checkedAt: Date?
    public var attemptedAt: Date?
    public var interval: TimeInterval?

    public init(usage: SubscriptionUsage? = nil, checkedAt: Date? = nil, attemptedAt: Date? = nil, interval: TimeInterval? = nil) {
        self.usage = usage
        self.checkedAt = checkedAt
        self.attemptedAt = attemptedAt
        self.interval = interval
    }

    public func isDue(at now: Date) -> Bool {
        guard let interval, interval > 0 else { return false }
        guard let previous = [checkedAt, attemptedAt].compactMap({ $0 }).max() else { return true }
        return now.timeIntervalSince(previous) >= interval
    }
}
