import Foundation
import XCTest
@testable import PacketBridge

final class ProxyDelaySettingsTests: XCTestCase {
    func testDefaultsAndCustomSettingsCrossControlEnvelope() throws {
        XCTAssertEqual(ProxyDelaySettings().url, "https://www.gstatic.com/generate_204")
        XCTAssertEqual(ProxyDelaySettings().timeoutMilliseconds, 10_000)
        let settings = ProxyDelaySettings(url: "http://127.0.0.1:8123/check", timeoutMilliseconds: 60_000)
        try settings.validate()
        let request = TunnelControlRequest(action: .delay, node: "example", delaySettings: settings)
        let decoded = try JSONDecoder().decode(TunnelControlRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(decoded.delaySettings, settings)
        XCTAssertGreaterThan(settings.extensionTimeout, 60)
        XCTAssertGreaterThan(settings.clientTimeout, settings.extensionTimeout)
    }

    func testRejectsInvalidURLsAndTimeouts() {
        for url in ["", "file:///test", "https://user:password@example.com", "https://", "https://example.com/#fragment", "https://exa mple.com", "https://example.com:70000"] {
            XCTAssertThrowsError(try ProxyDelaySettings(url: url).validate(), url)
        }
        for timeout in [0, -1, 60_001] {
            XCTAssertThrowsError(try ProxyDelaySettings(timeoutMilliseconds: timeout).validate())
        }
    }

    func testPreferencesPersistLocallyAndRejectInvalidSave() throws {
        let suite = "ProxyDelayTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var preferences = ProxyDelayPreferences()
        preferences.settings = ProxyDelaySettings(url: "https://example.com/check", timeoutMilliseconds: 2500)
        preferences.sort = .name
        preferences.hideFailures = true
        try preferences.save(to: defaults)
        XCTAssertEqual(ProxyDelayPreferences.load(from: defaults), preferences)
        preferences.settings.timeoutMilliseconds = 0
        XCTAssertThrowsError(try preferences.save(to: defaults))
        XCTAssertEqual(ProxyDelayPreferences.load(from: defaults).settings.timeoutMilliseconds, 2500)
    }

    func testSortingAndHidingKeepUntestedNodesAndStableTies() {
        let nodes = ["untested", "slow", "failed", "timeout", "fast", "tie", "zero"]
        let results: [String: ProxyDelayResult] = ["slow": .measured(200), "failed": .failed, "timeout": .timedOut, "fast": .measured(20), "tie": .measured(20), "zero": .measured(0)]
        XCTAssertEqual(ProxyDelayPreferences.ordered(nodes, results: results, sort: .delay, hideFailures: true), ["zero", "fast", "tie", "slow", "untested"])
        XCTAssertEqual(ProxyDelayPreferences.ordered(nodes, results: results, sort: .original, hideFailures: false), nodes)
    }

    func testNameSortAndSearchKeepNumericOrderAndFailedCandidates() {
        let nodes = ["node10", "other", "node2", "node1"]
        let candidates = ProxyDelayPreferences.matching(nodes, search: "NODE")
        XCTAssertEqual(candidates, ["node10", "node2", "node1"])
        XCTAssertEqual(ProxyDelayPreferences.ordered(candidates, results: ["node2": .failed], sort: .name, hideFailures: true), ["node1", "node10"])
        XCTAssertEqual(ProxyDelayPreferences.ordered(candidates, results: [:], sort: .name, hideFailures: false), ["node1", "node2", "node10"])
        XCTAssertEqual(ProxyDelayPreferences.matching(nodes, search: "missing"), [])
        XCTAssertEqual(ProxyDelayPreferences.matching(nodes, search: ""), nodes)
    }

    func testLegacySortPreferenceMigratesWithoutLosingSettings() throws {
        let legacy = Data(#"{"settings":{"url":"https://example.com/check","timeoutMilliseconds":8000},"sortByDelay":true,"hideFailures":true}"#.utf8)
        let preferences = try JSONDecoder().decode(ProxyDelayPreferences.self, from: legacy)
        XCTAssertEqual(preferences.sort, .delay)
        XCTAssertEqual(preferences.settings.timeoutMilliseconds, 8000)
        XCTAssertTrue(preferences.hideFailures)
        XCTAssertEqual(try JSONDecoder().decode(ProxyDelayPreferences.self, from: JSONEncoder().encode(preferences)), preferences)
    }

    func testSameNodeResultsAreIsolatedByURLAndTimeout() {
        let first = ProxyDelayKey(node: "shared", settings: ProxyDelaySettings(url: "https://one.example/check"))
        let second = ProxyDelayKey(node: "shared", settings: ProxyDelaySettings(url: "https://two.example/check"))
        let longer = ProxyDelayKey(node: "shared", settings: ProxyDelaySettings(url: "https://one.example/check", timeoutMilliseconds: 20_000))
        let results: [ProxyDelayKey: ProxyDelayResult] = [first: .timedOut, second: .measured(42)]
        XCTAssertEqual(results[first], .timedOut)
        XCTAssertEqual(results[second], .measured(42))
        XCTAssertNil(results[longer])
    }
}

@MainActor
final class ProxyDelayBatchTests: XCTestCase {
    func testBatchBoundsConcurrencyAndDeliversEveryUniqueNode() async {
        let gate = DelayGate()
        var results: [String: ProxyDelayResult] = [:]
        let names = (0..<12).map(String.init)
        let task = Task {
            await ProxyDelayBatch.run(nodes: names + ["0"], test: { name in
                try await gate.measure(name)
            }, receive: { results[$0] = $1 })
        }
        await gate.waitForStarted(4)
        let initial = await gate.counts()
        XCTAssertEqual(initial.started, 4)
        await gate.releaseAll()
        await task.value
        let final = await gate.counts()
        XCTAssertLessThanOrEqual(final.maximum, 4)
        XCTAssertEqual(final.started, 12)
        XCTAssertEqual(results.count, 12)
        XCTAssertEqual(results["0"], .measured(20))
    }

    func testCancellationStopsQueuedNodesAndDiscardsLateReplies() async {
        let gate = DelayGate()
        var results: [String: ProxyDelayResult] = [:]
        let task = Task {
            await ProxyDelayBatch.run(nodes: (0..<12).map(String.init), test: { try await gate.measure($0) }, receive: { results[$0] = $1 })
        }
        await gate.waitForStarted(4)
        task.cancel()
        await gate.releaseAll()
        await task.value
        let counts = await gate.counts()
        XCTAssertEqual(counts.started, 4)
        XCTAssertTrue(results.isEmpty)
    }

    func testOneFailureDoesNotCancelOtherNodes() async {
        var results: [String: ProxyDelayResult] = [:]
        await ProxyDelayBatch.run(nodes: ["failed", "timeout", "valid"], test: { name in
            if name == "failed" { throw ProxyDelayFailure.failed }
            if name == "timeout" { throw ProxyDelayFailure.timeout }
            return 42
        }, receive: { results[$0] = $1 })
        XCTAssertEqual(results, ["failed": .failed, "timeout": .timedOut, "valid": .measured(42)])
    }
}

private actor DelayGate {
    private var started = 0
    private var active = 0
    private var maximum = 0
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []

    func measure(_ name: String) async throws -> Int64 {
        started += 1
        active += 1
        maximum = max(maximum, active)
        let ready = observers.filter { started >= $0.0 }
        observers.removeAll { started >= $0.0 }
        for observer in ready { observer.1.resume() }
        if !released { await withCheckedContinuation { waiters.append($0) } }
        active -= 1
        return 20
    }

    func waitForStarted(_ count: Int) async {
        if started < count { await withCheckedContinuation { observers.append((count, $0)) } }
    }

    func releaseAll() {
        released = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    func counts() -> (started: Int, maximum: Int) { (started, maximum) }
}
