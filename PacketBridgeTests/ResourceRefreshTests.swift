import Foundation
import XCTest
@testable import PacketBridge

final class ResourceRefreshTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testOnlyPositiveHTTPProviderIntervalsScheduleRefresh() throws {
        let yaml = Data("""
        proxy-providers:
          disabled: {type: http, interval: 0}
          local: {type: file, interval: 1}
          nodes: {type: http, interval: 600}
        rule-providers:
          rules: {type: http, interval: 120}
          inline: {type: inline, interval: 2}
        """.utf8)
        XCTAssertEqual(try ResourceRefreshSchedule.interval(yaml: yaml), 120)
        XCTAssertNil(try ResourceRefreshSchedule.interval(yaml: Data("proxy-providers: {a: {type: http, interval: -1}}".utf8)))
        XCTAssertNil(try ResourceRefreshSchedule.interval(yaml: Data("mode: direct".utf8)))
    }

    func testAttemptAndFailureBackoffSurviveRelaunchAndRemainPerProfile() async throws {
        let file = root.appendingPathComponent("refresh.json")
        let start = Date(timeIntervalSince1970: 1000)
        let first = ResourceRefreshSchedule(url: file)
        let initial = try await first.claim(profileID: "a.yaml", interval: 10, now: start)
        XCTAssertFalse(initial)
        let due = try await first.claim(profileID: "a.yaml", interval: 10, now: start.addingTimeInterval(10))
        XCTAssertTrue(due)
        try await first.finish(profileID: "a.yaml", succeeded: false)
        let restarted = ResourceRefreshSchedule(url: file)
        let tooSoon = try await restarted.claim(profileID: "a.yaml", interval: 10, now: start.addingTimeInterval(20))
        XCTAssertFalse(tooSoon)
        let retry = try await restarted.claim(profileID: "a.yaml", interval: 10, now: start.addingTimeInterval(70))
        XCTAssertTrue(retry)
        try await restarted.finish(profileID: "a.yaml", succeeded: true)
        let regular = try await restarted.claim(profileID: "a.yaml", interval: 10, now: start.addingTimeInterval(80))
        XCTAssertTrue(regular)
        let independent = try await restarted.claim(profileID: "b.yaml", interval: 10, now: start.addingTimeInterval(80))
        XCTAssertFalse(independent)
    }

    @MainActor
    func testLateAutomaticRefreshCannotReplaceExplicitUserPending() async throws {
        let store = SnapshotStore(root: root.appendingPathComponent("Snapshots"))
        let commits = SnapshotCommitCoordinator()
        let automatic = commits.begin()
        let delayed = try store.prepare(configuration: RuntimeConfiguration(outbound: .mihomo(yaml: "mode: rule\n")))
        let user = commits.begin()
        let selected = try store.prepare(configuration: RuntimeConfiguration(mtu: 1500))
        let expected = try commits.commit(selected, to: store, intent: user)
        XCTAssertThrowsError(try commits.commit(delayed, to: store, intent: automatic))
        XCTAssertEqual(try store.pendingRevision(), expected)
    }

    func testDefaultClashUserAgentAndExplicitProviderOverrideReachHTTPRequest() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResourceHTTPFixture.self]
        let downloader = URLSessionProfileDownloader(configuration: configuration)
        for custom in [nil, "Provider-Agent"] as [String?] {
            var request = URLRequest(url: URL(string: "https://resource.fixture/provider")!)
            if let custom { request.setValue(custom, forHTTPHeaderField: "User-Agent") }
            let response = try await downloader.download(request: request, maximumBytes: 1024)
            XCTAssertEqual(String(decoding: response, as: UTF8.self), custom ?? "Clash/FlClash-iOS")
        }
    }
}

private final class ResourceHTTPFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((request.value(forHTTPHeaderField: "User-Agent") ?? "missing").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
