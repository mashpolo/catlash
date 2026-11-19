import Foundation
import XCTest
@testable import PacketBridge

final class ResourceDownloadDiagnosticsTests: XCTestCase {
    func testURLSessionFailuresKeepNetworkCategoryWithoutRequestSecrets() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResourceTransportFailureProtocol.self]
        let downloader = URLSessionProfileDownloader(configuration: configuration)
        for (code, category) in [
            (URLError.Code.timedOut, "请求超时"),
            (.cannotFindHost, "DNS 解析失败"),
            (.dnsLookupFailed, "DNS 解析失败"),
            (.secureConnectionFailed, "TLS"),
            (.serverCertificateUntrusted, "TLS"),
            (.notConnectedToInternet, "没有网络连接"),
        ] {
            let url = URL(string: "https://private.example.test/\(code.rawValue)?token=download-secret")!
            do {
                _ = try await downloader.download(from: url, maximumBytes: 1024)
                XCTFail("A transport failure cannot return a download")
            } catch {
                XCTAssertEqual(error as? ProfileDownloadError, .transport(code))
                XCTAssertTrue(error.localizedDescription.contains(category), error.localizedDescription)
                for secret in ["private.example.test", "download-secret", "token="] {
                    XCTAssertFalse(error.localizedDescription.contains(secret))
                }
            }
        }
    }

    func testPartialHTTPResponseDoesNotBecomeACachedResource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResourceTransportFailureProtocol.self]
        let cache = root.appendingPathComponent("DownloaderCache")
        let preparer = ProfileResourcePreparer(
            downloader: URLSessionProfileDownloader(configuration: configuration),
            bundleStore: ResourceBundleStore(root: root.appendingPathComponent("Resources")),
            cacheDirectory: cache
        )
        let yaml = Data("proxy-providers: {Jeeyio: {type: http, url: 'https://private.test/partial?token=secret'}}".utf8)
        do {
            _ = try await preparer.prepare(yaml: yaml)
            XCTFail("A partial response followed by a network error must not be accepted")
        } catch {
            XCTAssertEqual(error as? ProfileResourceError, .downloadFailed(kind: .proxyProvider, name: "Jeeyio", error: .transport(.networkConnectionLost)))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Resources/bundles").path))
    }

    func testPreparationReportsWhichResourceTimedOut() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let preparer = ProfileResourcePreparer(bundleStore: ResourceBundleStore(root: root), download: { request, _ in
            throw URLError(.timedOut, userInfo: [NSURLErrorFailingURLStringErrorKey: request.url!.absoluteString])
        })
        for (yaml, kind, name) in [
            ("proxy-providers: {Jeeyio: {type: http, url: 'https://private.test/nodes?token=secret'}}", "proxy-provider", "Jeeyio"),
            ("geox-url: {geosite: 'https://private.test/site.dat?token=secret'}\nrules: ['GEOSITE,TEST,DIRECT']", "geosite-dat", "GeoSite.dat"),
        ] {
            do {
                _ = try await preparer.prepare(yaml: Data(yaml.utf8))
                XCTFail("The failing resource must stop preparation")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains(kind), error.localizedDescription)
                XCTAssertTrue(error.localizedDescription.contains(name), error.localizedDescription)
                XCTAssertTrue(error.localizedDescription.contains("请求超时"), error.localizedDescription)
                XCTAssertFalse(error.localizedDescription.contains("private.test"))
                XCTAssertFalse(error.localizedDescription.contains("token="))
            }
        }
    }
}

private final class ResourceTransportFailureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url!.lastPathComponent == "partial" {
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": "128"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("incomplete".utf8))
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        let code = URLError.Code(rawValue: Int(request.url!.lastPathComponent)!)
        client?.urlProtocol(self, didFailWithError: URLError(code, userInfo: [
            NSURLErrorFailingURLStringErrorKey: request.url!.absoluteString,
        ]))
    }
    override func stopLoading() {}
}
