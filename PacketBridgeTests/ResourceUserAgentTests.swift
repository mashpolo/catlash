import Foundation
import XCTest
@testable import PacketBridge

final class ResourceUserAgentTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }

    func testGlobalUserAgentReachesHTTPProvidersAndGeodata() async throws {
        let spy = UserAgentRequestSpy()
        let yaml = Data("""
        global-ua: Resource-Test/1.0
        proxy-providers:
          nodes: {type: http, url: 'https://example.test/nodes'}
        rule-providers:
          domains: {type: http, behavior: domain, url: 'https://example.test/domains'}
        geox-url: {geosite: 'https://example.test/site.dat'}
        rules: ['GEOSITE,TEST,DIRECT']
        """.utf8)
        _ = try await preparer(spy).prepare(yaml: yaml)
        let requests = await spy.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(Set(requests.compactMap { $0.value(forHTTPHeaderField: "User-Agent") }), ["Resource-Test/1.0"])
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "User-Agent") == "Resource-Test/1.0" })
    }

    func testExplicitProviderHeaderTakesPriorityOverGlobalUserAgent() async throws {
        let spy = UserAgentRequestSpy()
        let yaml = Data("""
        global-ua: Global-Test/1.0
        proxy-providers:
          nodes:
            type: http
            url: https://example.test/nodes
            header:
              user-agent: [Provider-Test/2.0]
              X-Resource-Test: keep
        """.utf8)
        _ = try await preparer(spy).prepare(yaml: yaml)
        let captured = await spy.firstRequest()
        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Provider-Test/2.0")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Resource-Test"), "keep")
    }

    func testAbsentGlobalUserAgentKeepsDownloaderDefaultBehavior() async throws {
        let spy = UserAgentRequestSpy()
        _ = try await preparer(spy).prepare(yaml: provider)
        let captured = await spy.firstRequest()
        let request = try XCTUnwrap(captured)
        XCTAssertNil(request.value(forHTTPHeaderField: "User-Agent"))
    }

    func testGlobalUserAgentChangesResourceCacheIdentity() async throws {
        let spy = UserAgentRequestSpy()
        let preparer = preparer(spy)
        for userAgent in ["Resource-Test/1.0", "Resource-Test/2.0", "Resource-Test/1.0"] {
            _ = try await preparer.prepare(yaml: Data("global-ua: \(userAgent)\n".utf8) + provider)
        }
        let requests = await spy.requests
        XCTAssertEqual(requests.map { $0.value(forHTTPHeaderField: "User-Agent") }, ["Resource-Test/1.0", "Resource-Test/2.0"])
    }

    func testGlobalUserAgentRejectsHeaderControlCharactersBeforeDownloading() async throws {
        for value in ["bad\\r\\nInjected: yes", "bad\\0value"] {
            let spy = UserAgentRequestSpy()
            let yaml = Data("global-ua: \"\(value)\"\n".utf8) + provider
            do {
                _ = try await preparer(spy).prepare(yaml: yaml)
                XCTFail("An invalid global User-Agent must not enter an HTTP request")
            } catch {
                XCTAssertEqual(error as? ProfileResourceError, .invalidHeader(kind: .proxyProvider, name: "nodes"))
            }
            let requests = await spy.requests
            XCTAssertTrue(requests.isEmpty)
        }
    }

    private var provider: Data {
        Data("proxy-providers: {nodes: {type: http, url: 'https://example.test/nodes'}}\n".utf8)
    }

    private func preparer(_ spy: UserAgentRequestSpy) -> ProfileResourcePreparer {
        ProfileResourcePreparer(
            bundleStore: ResourceBundleStore(root: root.appendingPathComponent("Resources")),
            cacheDirectory: root.appendingPathComponent("DownloaderCache"),
            download: { request, _ in await spy.download(request) }
        )
    }
}

private actor UserAgentRequestSpy {
    private(set) var requests: [URLRequest] = []
    func firstRequest() -> URLRequest? { requests.first }
    func download(_ request: URLRequest) -> Data {
        requests.append(request)
        return Data("proxies: []\n".utf8)
    }
}
