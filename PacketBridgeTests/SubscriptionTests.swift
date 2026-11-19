import Foundation
import XCTest
@testable import PacketBridge

final class SubscriptionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }

    func testUsageParsesCountersAndExpirationWithoutInventingMissingValues() {
        let usage = SubscriptionUsage(header: "upload=123; download=456; total=1000; expire=2000000000")
        XCTAssertEqual(usage?.upload, 123)
        XCTAssertEqual(usage?.download, 456)
        XCTAssertEqual(usage?.total, 1000)
        XCTAssertEqual(usage?.expiresAt, Date(timeIntervalSince1970: 2_000_000_000))
        XCTAssertNil(SubscriptionUsage(header: "unknown=1; upload=-1; download=nan; total=99999999999999999999999"))
        let partial = SubscriptionUsage(header: "download=12; expire=0")
        XCTAssertEqual(partial?.download, 12)
        XCTAssertNil(partial?.upload)
        XCTAssertNil(partial?.expiresAt)
    }

    func testHTTPDownloaderCapturesUserInfoAndKeepsBody() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SubscriptionHTTPProtocol.self]
        let downloader = URLSessionProfileDownloader(configuration: configuration)
        let result = try await downloader.downloadSubscription(from: URL(string: "https://subscription.test/profile")!, maximumBytes: 1024)
        XCTAssertEqual(result.data, Data("mode: rule\n".utf8))
        XCTAssertEqual(result.usage?.download, 456)
        XCTAssertEqual(result.usage?.total, 1000)
    }

    func testCandidateDoesNotWriteUsageUntilAcceptedAndRefreshRetainsIt() async throws {
        let downloader = SubscriptionFixtureDownloader { _ in
            SubscriptionDownload(data: Data("mode: direct\n".utf8), usage: SubscriptionUsage(header: "upload=10;download=20;total=90"))
        }
        let repository = ProfileRepository(root: root, downloader: downloader)
        let original = try await repository.importData(data: Data("mode: rule\n".utf8), name: "Subscription", sourceURL: subscriptionURL)
        let candidate = try await repository.fetchSubscriptionDownload(id: original.id, expectedRevision: original.revisionSHA)
        var records = try await repository.list()
        XCTAssertNil(records.first?.subscription?.usage)
        let updated = try await repository.applySubscription(candidate, id: original.id, expectedRevision: original.revisionSHA)
        XCTAssertEqual(updated.subscription?.usage?.download, 20)
        records = try await ProfileRepository(root: root).refresh()
        XCTAssertEqual(records.first?.subscription?.usage, updated.subscription?.usage)
        XCTAssertNotNil(records.first?.subscription?.checkedAt)
        let edited = try await repository.update(id: updated.id, data: Data("mode: global\n".utf8), expectedRevision: updated.revisionSHA)
        XCTAssertEqual(edited.subscription, updated.subscription)
    }

    func testStaleCandidateCannotReplaceFileOrSubscriptionStatistics() async throws {
        let repository = ProfileRepository(root: root)
        let profile = try await repository.importData(data: Data("mode: rule\n".utf8), name: "Original", sourceURL: subscriptionURL)
        let edited = try await repository.update(id: profile.id, data: Data("mode: global\n".utf8), expectedRevision: profile.revisionSHA)
        do {
            _ = try await repository.applySubscription(.init(data: Data("mode: direct\n".utf8), usage: SubscriptionUsage(header: "total=200")), id: profile.id, expectedRevision: profile.revisionSHA)
            XCTFail("A stale download replaced an edit")
        } catch { XCTAssertEqual(error as? ProfileStoreError, .staleRevision) }
        let current = try await repository.list().first
        XCTAssertEqual(current?.revisionSHA, edited.revisionSHA)
        XCTAssertNil(current?.subscription?.usage)
    }

    func testManualOrderSurvivesReopenUpdatesAndRemoteDiscovery() async throws {
        let repository = ProfileRepository(root: root)
        let first = try await repository.importData(data: Data("mode: rule\n".utf8), name: "First")
        let second = try await repository.importData(data: Data("mode: direct\n".utf8), name: "Second")
        try await repository.reorder(ids: [second.id, first.id])
        _ = try await repository.rename(id: first.id, name: "Renamed")
        try Data("mode: global\n".utf8).write(to: repository.yamlDirectory.appendingPathComponent("remote.yaml"))
        let reopened = ProfileRepository(root: root)
        let records = try await reopened.list()
        XCTAssertEqual(records.map(\.id), [second.id, first.id, "remote.yaml"])
        try await reopened.delete(id: second.id)
        let remaining = try await reopened.list()
        XCTAssertEqual(remaining.map(\.id), [first.id, "remote.yaml"])
    }

    func testScheduledAttemptPersistsAndFailedAttemptDoesNotRetryEveryTick() async throws {
        let repository = ProfileRepository(root: root)
        let profile = try await repository.importData(data: Data("mode: rule\n".utf8), name: "Timed", sourceURL: subscriptionURL)
        let now = Date()
        try await repository.setSubscriptionInterval(id: profile.id, seconds: 3600)
        try await repository.recordSubscriptionAttempt(id: profile.id, expectedRevision: profile.revisionSHA, at: now)
        let saved = try await ProfileRepository(root: root).list().first
        XCTAssertFalse(saved!.subscription!.isDue(at: now.addingTimeInterval(3599)))
        XCTAssertTrue(saved!.subscription!.isDue(at: now.addingTimeInterval(3600)))
        try await repository.setSubscriptionInterval(id: profile.id, seconds: nil)
        let disabled = try await repository.list().first
        XCTAssertFalse(disabled!.subscription!.isDue(at: now.addingTimeInterval(7200)))
    }

    func testBatchReportsFailureAndContinuesWithoutChangingOtherFiles() async throws {
        let repository = ProfileRepository(root: root, downloader: SubscriptionFixtureDownloader { url in
            if url.lastPathComponent == "failed" { throw ProfileStoreError.httpStatus(503) }
            return SubscriptionDownload(data: Data("mode: direct\n".utf8), usage: SubscriptionUsage(header: "download=50"))
        })
        let failed = try await repository.importData(data: Data("mode: rule\n".utf8), name: "Failed", sourceURL: URL(string: "https://subscription.test/failed")!)
        let success = try await repository.importData(data: Data("mode: rule\n".utf8), name: "Success", sourceURL: subscriptionURL)
        let results = await repository.updateSubscriptions([failed, success])
        guard case .failed = results[0].status else { return XCTFail("Failure was not reported") }
        XCTAssertEqual(results[1].status, .updated)
        let records = try await repository.list()
        XCTAssertEqual(records.first { $0.id == failed.id }?.revisionSHA, failed.revisionSHA)
        XCTAssertEqual(records.first { $0.id == success.id }?.subscription?.usage?.download, 50)
    }

    func testBatchChecksSyncBeforeCommitAndPreservesConflictingProfile() async throws {
        let repository = ProfileRepository(root: root, downloader: SubscriptionFixtureDownloader { _ in
            SubscriptionDownload(data: Data("mode: direct\n".utf8))
        })
        let profile = try await repository.importData(data: Data("mode: rule\n".utf8), name: "Conflict", sourceURL: subscriptionURL)
        let gate = SubscriptionSyncGate()
        let results = await repository.updateSubscriptions([profile], checkSync: { _ in try await gate.check() })
        guard case .failed = results[0].status else { return XCTFail("Conflict was not reported") }
        let current = try await repository.list().first
        XCTAssertEqual(current?.revisionSHA, profile.revisionSHA)
    }

    func testCancellationDuringDownloadNeverCommitsOrStartsNextSubscription() async throws {
        let started = expectation(description: "download started")
        let downloader = CancelSubscriptionDownloader(started: { started.fulfill() })
        let repository = ProfileRepository(root: root, downloader: downloader)
        let first = try await repository.importData(data: Data("mode: rule\n".utf8), name: "First", sourceURL: subscriptionURL)
        let second = try await repository.importData(data: Data("mode: rule\n".utf8), name: "Second", sourceURL: subscriptionURL)
        let task = Task { await repository.updateSubscriptions([first, second]) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        await downloader.finish()
        let results = await task.value
        XCTAssertEqual(results.map(\.status), [.cancelled, .cancelled])
        let calls = await downloader.calls
        XCTAssertEqual(calls, 1)
        let records = try await repository.list()
        XCTAssertEqual(records.map(\.revisionSHA), [first.revisionSHA, second.revisionSHA])
    }
}

private let subscriptionURL = URL(string: "https://subscription.test/profile")!

private struct SubscriptionFixtureDownloader: ProfileDownloader {
    let operation: @Sendable (URL) async throws -> SubscriptionDownload
    func download(from url: URL, maximumBytes: Int) async throws -> Data { try await operation(url).data }
    func downloadSubscription(from url: URL, maximumBytes: Int) async throws -> SubscriptionDownload { try await operation(url) }
}

private actor SubscriptionSyncGate {
    private var checks = 0
    func check() throws {
        checks += 1
        if checks == 2 { throw ProfileStoreError.staleRevision }
    }
}

private actor CancelSubscriptionDownloader: ProfileDownloader {
    let started: @Sendable () -> Void
    var calls = 0
    var continuation: CheckedContinuation<Data, Error>?
    init(started: @escaping @Sendable () -> Void) { self.started = started }
    func download(from url: URL, maximumBytes: Int) async throws -> Data {
        calls += 1
        return try await withCheckedThrowingContinuation { continuation = $0; started() }
    }
    func finish() { continuation?.resume(returning: Data("mode: direct\n".utf8)); continuation = nil }
}

private final class SubscriptionHTTPProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Subscription-Userinfo": "upload=123; download=456; total=1000; expire=2000000000"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("mode: rule\n".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
