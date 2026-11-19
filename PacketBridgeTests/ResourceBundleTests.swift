import CryptoKit
import Foundation
import XCTest
@testable import PacketBridge

final class ResourceBundleTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testContentAddressedBundlePreservesBinaryResourcesAndStableOrdering() throws {
        let store = ResourceBundleStore(root: root)
        let rule = ResourceEntryData(kind: .ruleProvider, name: "rules", data: Data([0xff, 0, 1, 2]))
        let proxy = ResourceEntryData(kind: .proxyProvider, name: "../../provider", data: Data("base64-provider-content".utf8))
        let first = try store.stage(entries: [rule, proxy])
        XCTAssertEqual(first, try store.stage(entries: [proxy, rule]))
        let directory = try store.directory(id: first)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(names.count, 3)
        XCTAssertTrue(names.allSatisfy { $0 == "manifest.json" || $0.count == 64 })
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(resourceHash(rule.data))), rule.data)
        let changed = ResourceEntryData(kind: .ruleProvider, name: "rules", data: Data([0xff, 0, 1, 3]))
        XCTAssertNotEqual(first, try store.stage(entries: [changed, proxy]))
        XCTAssertEqual(try store.directory(id: first), directory)
    }

    func testReplacingOneProviderPreservesOtherResourcesAndOriginalRevision() throws {
        let store = ResourceBundleStore(root: root)
        let original = ResourceEntryData(kind: .proxyProvider, name: "shared", data: Data("old nodes".utf8))
        let untouched = ResourceEntryData(kind: .ruleProvider, name: "shared", data: Data("existing rules".utf8))
        let replacement = ResourceEntryData(kind: .proxyProvider, name: "shared", data: Data("new nodes".utf8))
        let before = try store.stage(entries: [original, untouched])
        let after = try store.stage(count: 1, preserving: before) { _ in replacement }
        XCTAssertEqual(after, try store.stage(entries: [replacement, untouched]))
        XCTAssertEqual(try store.entries(id: before, kind: .proxyProvider).first?.data, original.data)
        XCTAssertEqual(try store.entries(id: after, kind: .ruleProvider).first?.data, untouched.data)
    }

    func testCorruptExistingBlobCannotBeSilentlyRepaired() throws {
        let store = ResourceBundleStore(root: root)
        let entry = ResourceEntryData(kind: .proxyProvider, name: "nodes", data: Data("original".utf8))
        let id = try store.stage(entries: [entry])
        let directory = try store.directory(id: id)
        let blob = directory.appendingPathComponent(resourceHash(entry.data))
        let corrupt = Data("modified".utf8)
        try corrupt.write(to: blob, options: .atomic)
        XCTAssertThrowsError(try store.directory(id: id))
        XCTAssertThrowsError(try store.stage(entries: [entry]))
        XCTAssertEqual(try Data(contentsOf: blob), corrupt)
    }

    func testManifestPathsTraversalAndSymlinksAreRejected() throws {
        let store = ResourceBundleStore(root: root)
        XCTAssertThrowsError(try store.directory(id: "../outside"))
        let data = Data("payload".utf8)
        let id = try store.stage(entries: [.init(kind: .ruleProvider, name: "rules", data: data)])
        let directory = try store.directory(id: id)
        let blob = directory.appendingPathComponent(resourceHash(data))
        let external = root.appendingPathComponent("external")
        try data.write(to: external)
        try FileManager.default.removeItem(at: blob)
        try FileManager.default.createSymbolicLink(at: blob, withDestinationURL: external)
        XCTAssertThrowsError(try store.directory(id: id))
        let manifest: [String: Any] = ["version": 1, "entries": [["kind": "rule-provider", "name": "rules", "sha256": resourceHash(data), "size": data.count, "path": "../../external"]]]
        let bytes = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        let forgedID = resourceHash(bytes)
        let forged = root.appendingPathComponent("bundles").appendingPathComponent(forgedID)
        try FileManager.default.createDirectory(at: forged, withIntermediateDirectories: true)
        try bytes.write(to: forged.appendingPathComponent("manifest.json"))
        try data.write(to: forged.appendingPathComponent(resourceHash(data)))
        XCTAssertThrowsError(try store.directory(id: forgedID))
    }

    func testResourceAndBundleSizeLimits() throws {
        let store = ResourceBundleStore(root: root)
        let chunk = Data(repeating: 1, count: 16 * 1024 * 1024)
        XCTAssertThrowsError(try store.stage(entries: [.init(kind: .proxyProvider, name: "large", data: chunk + Data([1]))]))
        let entries = (0..<5).map { ResourceEntryData(kind: .proxyProvider, name: "provider-\($0)", data: chunk) }
        XCTAssertThrowsError(try store.stage(entries: entries))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("bundles").path))
    }

    func testPreparationHonorsHeadersAndLimitsWithoutParsingBinaryBodies() async throws {
        let store = ResourceBundleStore(root: root)
        let spy = ResourceDownloadSpy(payload: Data([0xff, 0, 0x81]))
        let preparer = ProfileResourcePreparer(bundleStore: store, download: { await spy.download($0, maximumBytes: $1) })
        let yaml = Data("""
        # preserve comments and unknown options
        proxy-providers:
          nodes:
            type: http
            url: https://example.test/nodes
            proxy: DIRECT
            size-limit: 4096
            header:
              X-Multiple: [first, second]
              Authorization: [Bearer test-only]
            override:
              udp: false
        rule-providers:
          binary:
            type: http
            url: https://example.test/rules
            behavior: ipcidr
            format: mrs
        unknown-field: keep
        """.utf8)
        let prepared = try await preparer.prepare(yaml: yaml)
        let id = try XCTUnwrap(prepared)
        let requests = await spy.requests
        let limits = await spy.limits
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(limits, [4096, 16 * 1024 * 1024])
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer test-only")
        let multiple = try XCTUnwrap(requests.first?.value(forHTTPHeaderField: "X-Multiple"))
        XCTAssertTrue(multiple.contains("first"))
        XCTAssertTrue(multiple.contains("second"))
        let directory = try store.directory(id: id)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(resourceHash(Data([0xff, 0, 0x81])))), Data([0xff, 0, 0x81]))
        XCTAssertTrue(String(decoding: yaml, as: UTF8.self).contains("# preserve comments"))
        XCTAssertTrue(String(decoding: yaml, as: UTF8.self).contains("unknown-field: keep"))
    }

    func testSeedPreparationDefersNamedProxyDownloadsAndKeepsDirectResources() async throws {
        let store = ResourceBundleStore(root: root)
        let preparer = ProfileResourcePreparer(bundleStore: store, download: { request, _ in
            XCTAssertEqual(request.url?.path, "/nodes")
            return Data("proxies: [{name: node, type: direct}]".utf8)
        })
        let yaml = Data("""
        proxy-providers:
          nodes: {type: http, proxy: DIRECT, url: 'https://example.test/nodes'}
        rule-providers:
          rules: {type: http, proxy: MAIN, behavior: domain, url: 'https://example.test/rules'}
        """.utf8)
        let result = try await preparer.prepare(yaml: yaml, deferProxyDownloads: true)
        let directory = try store.directory(id: XCTUnwrap(result))
        let manifest = String(decoding: try Data(contentsOf: directory.appendingPathComponent("manifest.json")), as: UTF8.self)
        XCTAssertTrue(manifest.contains("proxy-provider"))
        XCTAssertFalse(manifest.contains("rule-provider"))
    }

    func testLocalProviderRequiresExplicitAuthorizedBytesAndInlineNeedsNoBundle() async throws {
        let store = ResourceBundleStore(root: root)
        let preparer = ProfileResourcePreparer(bundleStore: store, download: { _, _ in XCTFail("No HTTP expected"); return Data() })
        let yaml = Data("rule-providers:\n  rules:\n    type: file\n    path: /never/read/from/host.mrs\n    format: mrs\n".utf8)
        do {
            _ = try await preparer.prepare(yaml: yaml)
            XCTFail("Missing authorized resource must fail")
        } catch let error as ProfileResourceError {
            XCTAssertEqual(error, .missingLocalFile(kind: .ruleProvider, name: "rules", path: "/never/read/from/host.mrs"))
        }
        let prepared = try await preparer.prepare(yaml: yaml, localFiles: ["/never/read/from/host.mrs": Data([1, 2, 3])])
        let id = try XCTUnwrap(prepared)
        _ = try store.directory(id: id)
        let inline = Data("proxy-providers:\n  inline:\n    type: inline\n    payload: []\n".utf8)
        let noBundle = try await preparer.prepare(yaml: inline)
        XCTAssertNil(noBundle)
    }

    func testProviderHTTPFailureIdentifiesResourceWithoutExposingRequest() async throws {
        let preparer = ProfileResourcePreparer(bundleStore: ResourceBundleStore(root: root), download: { _, _ in
            throw ProfileStoreError.httpStatus(400)
        })
        for (section, kind) in [("proxy-providers", "proxy-provider"), ("rule-providers", "rule-provider")] {
            let yaml = Data("\(section):\n  remote:\n    type: http\n    url: https://login:password@example.test/resource?token=secret\n    header:\n      Authorization: Bearer test-credential\n".utf8)
            do {
                _ = try await preparer.prepare(yaml: yaml)
                XCTFail("The failing resource must be identified")
            } catch {
                XCTAssertEqual(error.localizedDescription, "The \(kind) 'remote' server returned HTTP 400.")
                for secret in ["https:", "example.test", "token=", "password", "Authorization", "test-credential"] {
                    XCTAssertFalse(error.localizedDescription.contains(secret))
                }
            }
        }
    }

    func testHTTPFailurePreservesExistingBundle() async throws {
        let store = ResourceBundleStore(root: root)
        let id = try store.stage(entries: [.init(kind: .proxyProvider, name: "old", data: Data("last-good".utf8))])
        let preparer = ProfileResourcePreparer(bundleStore: store, download: { _, _ in throw ProfileStoreError.httpStatus(503) })
        do {
            _ = try await preparer.prepare(yaml: httpYAML)
            XCTFail("Failed HTTP request must not prepare a new bundle")
        } catch {}
        _ = try store.directory(id: id)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("bundles").path), [id])
    }

    func testNonDirectDownloadProxyIsExplicitlyRejected() async throws {
        let preparer = ProfileResourcePreparer(bundleStore: ResourceBundleStore(root: root), download: { _, _ in
            XCTFail("Proxy setting must not be ignored")
            return Data()
        })
        let yaml = Data("proxy-providers:\n  remote:\n    type: http\n    url: https://example.test/provider\n    proxy: MyProxy\n".utf8)
        do {
            _ = try await preparer.prepare(yaml: yaml)
            XCTFail("Unsupported proxy download must fail explicitly")
        } catch let error as ProfileResourceError {
            XCTAssertEqual(error, .requiresConnectedProxy(kind: .proxyProvider, name: "remote", proxy: "MyProxy"))
        }
    }

    func testCancellationAndBoundedFakeResponsesDoNotStageBundles() async throws {
        let store = ResourceBundleStore(root: root)
        let cancelled = ProfileResourcePreparer(bundleStore: store, download: { _, _ in throw CancellationError() })
        do {
            _ = try await cancelled.prepare(yaml: httpYAML)
            XCTFail("Cancellation must propagate")
        } catch is CancellationError {}
        let oversized = ProfileResourcePreparer(bundleStore: store, download: { _, _ in Data(repeating: 1, count: 8) })
        let yaml = Data("proxy-providers:\n  remote:\n    type: http\n    url: https://example.test/provider\n    size-limit: 7\n".utf8)
        do {
            _ = try await oversized.prepare(yaml: yaml)
            XCTFail("Downloader result must respect the resource limit")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("bundles").path))
    }

    func testCancellationWhileWaitingDoesNotPublishCompletedDownload() async throws {
        let started = expectation(description: "download started")
        let gate = ResourceDownloadGate { started.fulfill() }
        let preparer = ProfileResourcePreparer(bundleStore: ResourceBundleStore(root: root), download: { _, _ in
            await gate.wait()
            return Data("completed after cancellation".utf8)
        })
        let yaml = httpYAML
        let operation = Task { try await preparer.prepare(yaml: yaml) }
        await fulfillment(of: [started], timeout: 2)
        operation.cancel()
        await gate.resume()
        do {
            _ = try await operation.value
            XCTFail("A cancelled preparation must not publish its resource bundle")
        } catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("bundles").path))
    }

    func testPreparedProvidersCrossGoBridgeAndRejectLaterBlobCorruption() throws {
        let store = ResourceBundleStore(root: root)
        let nodes = Data("proxies: [{name: node, type: direct}, {name: discard, type: reject}]\n".utf8)
        let rules = Data("payload: ['+.example.invalid']\n".utf8)
        let bundle = try store.stage(entries: [
            .init(kind: .proxyProvider, name: "nodes", data: nodes),
            .init(kind: .ruleProvider, name: "domains", data: rules),
        ])
        let directory = try store.directory(id: bundle)
        let yaml = """
        mode: rule
        dns: {enable: true, enhanced-mode: redir-host, nameserver: ['127.0.0.1:1']}
        proxy-providers:
          nodes:
            type: file
            path: /must-not-read/from-host.yaml
            filter: '^node'
            override: {additional-prefix: 'cached-'}
            health-check: {enable: false}
        rule-providers:
          domains:
            type: http
            behavior: domain
            url: https://must-not-download.invalid/rules
        proxy-groups: [{name: Selection, type: select, use: [nodes]}]
        rules: ['RULE-SET,domains,REJECT', 'MATCH,Selection']
        """
        let configuration = RuntimeConfiguration(outbound: .mihomo(yaml: yaml), resources: bundle)
        let text = String(decoding: try JSONEncoder().encode(configuration), as: UTF8.self)
        let session = try GoPacketSession(configuration: text, resourceRoot: directory)
        defer { try? session.close() }
        let catalog = try session.proxyCatalog()
        XCTAssertEqual(catalog.proxies.first { $0.name == "Selection" }?.now, "cached-node")
        XCTAssertFalse(catalog.proxies.contains { $0.name == "discard" })
        try session.close()
        try Data("corrupt after Swift validation".utf8).write(to: directory.appendingPathComponent(resourceHash(nodes)), options: .atomic)
        XCTAssertThrowsError(try GoPacketSession(configuration: text, resourceRoot: directory))
    }

    private var httpYAML: Data {
        Data("proxy-providers:\n  remote:\n    type: http\n    url: https://example.test/provider\n".utf8)
    }
}

private actor ResourceDownloadSpy {
    let payload: Data
    var requests: [URLRequest] = []
    var limits: [Int] = []
    init(payload: Data) { self.payload = payload }
    func download(_ request: URLRequest, maximumBytes: Int) -> Data {
        requests.append(request)
        limits.append(maximumBytes)
        return payload
    }
}

private actor ResourceDownloadGate {
    private let started: @Sendable () -> Void
    private var continuation: CheckedContinuation<Void, Never>?
    init(started: @escaping @Sendable () -> Void) { self.started = started }
    func wait() async {
        await withCheckedContinuation {
            continuation = $0
            started()
        }
    }
    func resume() { continuation?.resume(); continuation = nil }
}

private func resourceHash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
