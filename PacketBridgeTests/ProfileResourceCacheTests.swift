import Foundation
import XCTest
@testable import PacketBridge

final class ProfileResourceCacheTests: XCTestCase {
    private var root: URL!
    private var cache: URL { root.appendingPathComponent("DownloaderCache", isDirectory: true) }
    private var bundles: ResourceBundleStore { ResourceBundleStore(root: root.appendingPathComponent("Resources")) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }

    func testCompletedResourceIsReusedAfterPreparerReopens() async throws {
        let downloads = CacheDownloadFixture(payload: Data("proxies: []\n".utf8))
        let first = try await preparer(downloads).prepare(yaml: provider())
        let progress = ResourceProgressRecorder()
        let reopened = preparer(downloads)
        let second = try await reopened.prepare(yaml: provider(), progress: { await progress.record($0) })
        XCTAssertEqual(first, second)
        let count = await downloads.count
        XCTAssertEqual(count, 1)
        let events = await progress.events
        XCTAssertEqual(events.map(\.phase), [.cached])
        XCTAssertEqual(events.first?.kind, .proxyProvider)
        XCTAssertEqual(events.first?.name, "Jeeyio")
    }

    func testForceRefreshDownloadsAndReplacesCachedContent() async throws {
        let downloads = CacheDownloadFixture(payload: Data("proxies: []\n".utf8))
        let preparer = preparer(downloads)
        let original = try await preparer.prepare(yaml: provider())
        await downloads.replace(with: Data("proxies: [{name: DIRECT, type: direct}]\n".utf8))
        let progress = ResourceProgressRecorder()
        let refreshed = try await preparer.prepare(yaml: provider(), forceRefresh: true, progress: { await progress.record($0) })
        XCTAssertNotEqual(original, refreshed)
        let reopened = try await self.preparer(downloads).prepare(yaml: provider())
        XCTAssertEqual(reopened, refreshed)
        let count = await downloads.count
        XCTAssertEqual(count, 2)
        let policies = await downloads.policies
        XCTAssertEqual(policies, [.useProtocolCachePolicy, .reloadIgnoringLocalCacheData])
        let events = await progress.events
        XCTAssertEqual(events.map(\.phase), [.downloading])
    }

    func testCacheIdentityIncludesFullURLAndAuthenticationHeaders() async throws {
        let downloads = CacheDownloadFixture(payload: Data("proxies: []\n".utf8))
        let preparer = preparer(downloads)
        for (url, header) in [
            ("https://private.test/nodes?token=first", "Authorization: Bearer first"),
            ("https://private.test/nodes?token=second", "Authorization: Bearer first"),
            ("https://private.test/nodes?token=first", "Authorization: Bearer second"),
            ("https://private.test/nodes?token=first", "authorization: Bearer first"),
        ] {
            _ = try await preparer.prepare(yaml: provider(url: url, header: header))
        }
        let count = await downloads.count
        XCTAssertEqual(count, 3, "Header names are case insensitive; credentials and URL queries are not")
        let names = try FileManager.default.contentsOfDirectory(atPath: cache.path)
        XCTAssertEqual(names.count, 3)
        XCTAssertTrue(names.allSatisfy { $0.count == 64 && $0.allSatisfy(\.isHexDigit) })
        for name in names {
            let contents = try Data(contentsOf: cache.appendingPathComponent(name))
            for secret in ["private.test", "token=", "Authorization", "Bearer first", "Bearer second"] {
                XCTAssertNil(contents.range(of: Data(secret.utf8)))
            }
        }
    }

    func testCachedResourceCannotBypassNewSizeLimit() async throws {
        let downloads = CacheDownloadFixture(payload: Data(repeating: 1, count: 16))
        let preparer = preparer(downloads)
        let original = try await preparer.prepare(yaml: provider(limit: 32))
        do {
            _ = try await preparer.prepare(yaml: provider(limit: 8))
            XCTFail("The current provider size limit must apply to cached and downloaded bytes")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("proxy-provider"))
            XCTAssertTrue(error.localizedDescription.contains("Jeeyio"))
            XCTAssertTrue(error.localizedDescription.contains("8"))
        }
        let retained = try await preparer.prepare(yaml: provider(limit: 32))
        XCTAssertEqual(retained, original)
    }

    func testFailedRefreshPreservesPreviouslyCompletedCache() async throws {
        let downloads = CacheDownloadFixture(payload: Data("proxies: []\n".utf8))
        let original = try await preparer(downloads).prepare(yaml: provider())
        await downloads.fail(with: .timedOut)
        do {
            _ = try await preparer(downloads).prepare(yaml: provider(), forceRefresh: true)
            XCTFail("A failed explicit refresh must report its failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Jeeyio"))
            XCTAssertTrue(error.localizedDescription.contains("请求超时"))
        }
        let retained = try await preparer(downloads).prepare(yaml: provider())
        XCTAssertEqual(retained, original)
        let count = await downloads.count
        XCTAssertEqual(count, 2)
    }

    func testCancelledDownloadDoesNotPublishCacheOrBundle() async throws {
        let started = expectation(description: "download started")
        let gate = CacheDownloadGate { started.fulfill() }
        let preparer = ProfileResourcePreparer(bundleStore: bundles, cacheDirectory: cache, download: { _, _ in
            await gate.wait()
            return Data("proxies: []\n".utf8)
        })
        let yaml = provider()
        let task = Task { try await preparer.prepare(yaml: yaml) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        await gate.resume()
        do {
            _ = try await task.value
            XCTFail("Cancellation must remain cancellation even if a downloader returns late")
        } catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Resources/bundles").path))
    }

    func testCorruptedCacheIsNotUsedAsACompletedResource() async throws {
        let downloads = CacheDownloadFixture(payload: Data("proxies: []\n".utf8))
        _ = try await preparer(downloads).prepare(yaml: provider())
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil).first)
        try Data("partial download".utf8).write(to: file, options: .atomic)
        _ = try await preparer(downloads).prepare(yaml: provider())
        let count = await downloads.count
        XCTAssertEqual(count, 2)
    }

    func testNamedProxyResourcesRemainDeferredWithoutDirectDownloads() async throws {
        let downloads = CacheDownloadFixture(payload: Data("proxies: []\n".utf8))
        let progress = ResourceProgressRecorder()
        let yaml = Data("rule-providers: {blocked: {type: http, proxy: MAIN, behavior: domain, url: 'https://private.test/rules?token=secret'}}".utf8)
        let result = try await preparer(downloads).prepare(yaml: yaml, deferProxyDownloads: true, progress: { await progress.record($0) })
        XCTAssertNil(result)
        let count = await downloads.count
        XCTAssertEqual(count, 0)
        let events = await progress.events
        XCTAssertEqual(events.map(\.phase), [.deferred])
        XCTAssertEqual(events.first?.kind, .ruleProvider)
        XCTAssertEqual(events.first?.name, "blocked")
    }

    private func preparer(_ fixture: CacheDownloadFixture) -> ProfileResourcePreparer {
        ProfileResourcePreparer(bundleStore: bundles, cacheDirectory: cache, download: { request, maximum in
            try await fixture.download(request, maximum: maximum)
        })
    }

    private func provider(url: String = "https://private.test/nodes?token=secret", header: String = "Authorization: Bearer first", limit: Int = 4096) -> Data {
        Data("proxy-providers:\n  Jeeyio:\n    type: http\n    url: '\(url)'\n    size-limit: \(limit)\n    header: {\(header)}\n".utf8)
    }
}

private actor CacheDownloadFixture {
    private var payload: Data
    private var failure: URLError.Code?
    private(set) var count = 0
    private(set) var policies: [URLRequest.CachePolicy] = []
    init(payload: Data) { self.payload = payload }
    func replace(with payload: Data) { self.payload = payload; failure = nil }
    func fail(with code: URLError.Code) { failure = code }
    func download(_ request: URLRequest, maximum: Int) throws -> Data {
        count += 1
        policies.append(request.cachePolicy)
        if let failure { throw URLError(failure) }
        return payload
    }
}

private actor ResourceProgressRecorder {
    private(set) var events: [ProfileResourceProgress] = []
    func record(_ event: ProfileResourceProgress) { events.append(event) }
}

private actor CacheDownloadGate {
    private let started: @Sendable () -> Void
    private var continuation: CheckedContinuation<Void, Never>?
    init(started: @escaping @Sendable () -> Void) { self.started = started }
    func wait() async { await withCheckedContinuation { continuation = $0; started() } }
    func resume() { continuation?.resume(); continuation = nil }
}
