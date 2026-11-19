import Foundation
import XCTest
@testable import PacketBridge

final class ResourcePreparationScopeTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }

    func testConnectionHandsAllRemoteProvidersToMihomoWithoutCallingDownloader() async throws {
        let requests = PreparationScopeRequests()
        let store = ResourceBundleStore(root: root)
        let preparer = ProfileResourcePreparer(bundleStore: store, download: { request, _ in try await requests.download(request) })
        let prepared = try await preparer.prepare(yaml: yaml, localFiles: ["node.pem": Data("certificate".utf8)], scope: .connection)
        let bundle = try XCTUnwrap(prepared)
        let paths = await requests.paths
        XCTAssertTrue(paths.isEmpty)
        XCTAssertTrue(try store.entries(id: bundle, kind: .proxyProvider).isEmpty)
        XCTAssertEqual(try store.entries(id: bundle, kind: .proxyFile).map(\.name), ["node.pem"])
        XCTAssertTrue(try store.entries(id: bundle, kind: .ruleProvider).isEmpty)
        XCTAssertTrue(try store.entries(id: bundle, kind: .geoIPDat).isEmpty)
    }

    func testCompleteAndDefaultPreparationStillFetchRulesAndReportGeoFailure() async throws {
        for explicit in [false, true] {
            let requests = PreparationScopeRequests()
            let preparer = ProfileResourcePreparer(bundleStore: ResourceBundleStore(root: root), download: { request, _ in try await requests.download(request) })
            do {
                if explicit {
                    _ = try await preparer.prepare(yaml: yaml, localFiles: ["node.pem": Data("certificate".utf8)], scope: .complete)
                } else {
                    _ = try await preparer.prepare(yaml: yaml, localFiles: ["node.pem": Data("certificate".utf8)])
                }
                XCTFail("Complete preparation must surface the Geo download failure")
            } catch {
                XCTAssertEqual(error as? ProfileResourceError, .httpStatus(kind: .geoIPDat, name: "GeoIP.dat", status: 403))
            }
            let paths = await requests.paths
            XCTAssertEqual(paths, ["/nodes", "/rules", "/geoip"])
        }
    }

    func testConnectionStillRequiresReferencedNodeCertificate() async throws {
        let requests = PreparationScopeRequests()
        let preparer = ProfileResourcePreparer(bundleStore: ResourceBundleStore(root: root), download: { request, _ in try await requests.download(request) })
        do {
            _ = try await preparer.prepare(yaml: yaml, scope: .connection)
            XCTFail("A required node certificate must not be deferred")
        } catch {
            XCTAssertEqual(error as? ProfileResourceError, .missingLocalFile(kind: .proxyFile, name: "node.pem", path: "node.pem"))
        }
        let paths = await requests.paths
        XCTAssertTrue(paths.isEmpty)
    }

    private var yaml: Data {
        Data("""
        proxies: [{name: inline, type: trojan, certificate: node.pem}]
        geodata-mode: true
        proxy-providers:
          nodes: {type: http, url: 'https://example.invalid/nodes'}
        rule-providers:
          domains: {type: http, behavior: domain, url: 'https://example.invalid/rules'}
        geox-url: {geoip: 'https://example.invalid/geoip'}
        rules: ['RULE-SET,domains,DIRECT', 'GEOIP,TEST,DIRECT']
        """.utf8)
    }
}

private actor PreparationScopeRequests {
    var paths: [String] = []

    func download(_ request: URLRequest) throws -> Data {
        let path = request.url!.path
        paths.append(path)
        switch path {
        case "/nodes": return Data("proxies: [{name: node, type: trojan, certificate: node.pem}]".utf8)
        case "/rules": return Data("payload: ['+.example.invalid']".utf8)
        default: throw ProfileStoreError.httpStatus(403)
        }
    }
}
