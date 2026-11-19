import Foundation
import Yams

public actor ResourceRefreshSchedule {
    private struct Attempt: Codable {
        var startedAt: Date
        var failures: Int
    }
    private let url: URL
    private var attempts: [String: Attempt]?

    public init(url: URL) { self.url = url }

    public nonisolated static func interval(yaml: Data) throws -> TimeInterval? {
        let document = try EffectiveYAML.compose(data: yaml)
        var intervals: [TimeInterval] = []
        for key in ["proxy-providers", "rule-providers"] {
            for (_, provider) in document[key]?.mapping ?? Node.Mapping() {
                guard provider["type"]?.string == "http", let seconds = provider["interval"]?.int, seconds > 0 else { continue }
                intervals.append(TimeInterval(seconds))
            }
        }
        return intervals.min()
    }

    public func claim(profileID: String, interval: TimeInterval, now: Date = Date()) throws -> Bool {
        try load()
        guard interval > 0 else { return false }
        let previous = attempts?[profileID]
        if let previous {
            let backoff = previous.failures == 0 ? 0 : min(3600, 60 * pow(2, Double(previous.failures - 1)))
            guard now.timeIntervalSince(previous.startedAt) >= max(interval, backoff) else { return false }
        }
        attempts?[profileID] = Attempt(startedAt: now, failures: previous?.failures ?? 0)
        try persist()
        return previous != nil
    }

    public func finish(profileID: String, succeeded: Bool) throws {
        try load()
        guard var attempt = attempts?[profileID] else { return }
        attempt.failures = succeeded ? 0 : min(7, attempt.failures + 1)
        attempts?[profileID] = attempt
        try persist()
    }

    private func load() throws {
        guard attempts == nil else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            attempts = try JSONDecoder().decode([String: Attempt].self, from: Data(contentsOf: url))
        } else { attempts = [:] }
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(attempts).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
