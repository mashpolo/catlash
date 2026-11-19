import Foundation
import Network
import XCTest
@testable import PacketBridge

final class YAMLResourceActivationTests: XCTestCase {
    func testDeferredActivationDoesNotWaitForUnavailableRulesOrGeo() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let yaml = """
        rule-providers:
          remote: {type: http, behavior: domain, url: 'http://127.0.0.1:9/unavailable'}
        geox-url: {mmdb: 'http://127.0.0.1:9/Country.mmdb'}
        rules: ['RULE-SET,remote,DIRECT', 'GEOIP,CN,DIRECT', 'MATCH,DIRECT']
        """
        let base = RuntimeConfiguration(outbound: .mihomo(yaml: yaml))
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as? [String: Any])
        value["allowDeferredResources"] = true
        let deferred = try RuntimeConfiguration.decode(JSONSerialization.data(withJSONObject: value))
        let store = SnapshotStore(root: root)
        let revision = try store.stage(configuration: deferred)
        let input = try store.load(revision: revision)
        let active = try await prepare(.init(revision: revision, configuration: input), root: root)
        XCTAssertEqual(active.revision, revision)
        XCTAssertEqual(active.configuration, input)
    }

    func testTemporarySelectionSurvivesPreparationWithoutEnteringPersistedRevision() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try ActivationHTTPServer(body: Data("payload: [10.0.0.0/8]\n".utf8))
        defer { server.close() }
        let yaml = """
        profile: {store-selected: false}
        proxy-groups: [{name: MAIN, type: select, proxies: [REJECT, DIRECT]}]
        rule-providers:
          rules: {type: http, behavior: ipcidr, proxy: MAIN, url: '\(server.url)'}
        rules: ['RULE-SET,rules,REJECT', 'MATCH,DIRECT']
        """
        let store = SnapshotStore(root: root)
        let seed = try store.stage(configuration: .init(outbound: .mihomo(yaml: yaml)))
        let temporary = RuntimeConfiguration(outbound: .mihomo(yaml: yaml, selections: ["MAIN": "DIRECT"]))
        let active = try await prepare(.init(revision: seed, configuration: JSONEncoder().encode(temporary)), root: root)
        let running = try RuntimeConfiguration.decode(active.configuration)
        XCTAssertEqual(running.outbound, temporary.outbound)
        let persisted = try RuntimeConfiguration.decode(store.load(revision: active.revision))
        XCTAssertEqual(persisted.outbound, .mihomo(yaml: yaml))
        let resources = try ResourceBundleStore(root: root.appendingPathComponent("Resources"))
            .directory(id: XCTUnwrap(running.resources))
        let session = try GoPacketSession(configuration: String(decoding: active.configuration, as: UTF8.self), resourceRoot: resources)
        XCTAssertEqual(try session.proxyCatalog().proxies.first { $0.name == "MAIN" }?.now, "DIRECT")
        try session.close()
        let fresh = try GoPacketSession(configuration: String(decoding: store.load(revision: active.revision), as: UTF8.self), resourceRoot: resources)
        defer { try? fresh.close() }
        XCTAssertEqual(try fresh.proxyCatalog().proxies.first { $0.name == "MAIN" }?.now, "REJECT")
    }

    func testNamedResourceDownloadCreatesImmutableRevisionWithoutChangingPending() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try ActivationHTTPServer(body: Data("payload:\n - 10.0.0.0/8\n".utf8))
        defer { server.close() }
        let yaml = """
        # Keep the original source and its download proxy.
        proxy-groups: [{name: MAIN, type: select, proxies: [REJECT, DIRECT]}]
        rule-providers:
          rules: {type: http, behavior: ipcidr, proxy: MAIN, url: '\(server.url)'}
        rules: ['RULE-SET,rules,REJECT', 'MATCH,DIRECT']
        """
        let store = SnapshotStore(root: root)
        let seed = try store.stage(configuration: RuntimeConfiguration(outbound: .mihomo(yaml: yaml, selections: ["MAIN": "DIRECT"])))
        let activation = try await prepare(.init(revision: seed, configuration: store.load(revision: seed)), root: root)
        XCTAssertNotEqual(activation.revision, seed)
        XCTAssertEqual(try store.pendingRevision(), seed)
        XCTAssertNil(try store.lastSuccessfulRevision())
        let final = try RuntimeConfiguration.decode(activation.configuration)
        XCTAssertEqual(final.outbound, .mihomo(yaml: yaml, selections: ["MAIN": "DIRECT"]))
        let bundleID = try XCTUnwrap(final.resources)
        let resourceRoot = try ResourceBundleStore(root: root.appendingPathComponent("Resources")).directory(id: bundleID)
        let session = try GoPacketSession(configuration: String(decoding: activation.configuration, as: UTF8.self), resourceRoot: resourceRoot)
        try session.close()
        server.close()
        let restored = try await prepare(activation, root: root)
        XCTAssertEqual(restored.revision, activation.revision)
        XCTAssertEqual(restored.configuration, activation.configuration)
    }

    func testCompleteProviderTopologyRestoresNineGroupsAndPreparesTwentyFiveRuleSources() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try ActivationHTTPServer(body: Data("payload:\n - 10.0.0.0/8\n".utf8))
        defer { server.close() }
        var yaml = "proxy-providers:\n"
        for name in ["sourceA", "sourceB"] {
            yaml += "  \(name): {type: http, proxy: DIRECT, url: 'https://seed.invalid/\(name)'}\n"
        }
        yaml += "proxies:\n"
        for index in 0..<4 { yaml += "  - {name: inline\(index), type: direct}\n" }
        yaml += "proxy-groups:\n"
        for index in 0..<9 { yaml += "  - {name: group\(index), type: select, proxies: [REJECT, inline0], use: [sourceA, sourceB]}\n" }
        yaml += "rule-providers:\n"
        for index in 0..<25 { yaml += "  rules\(index): {type: http, behavior: ipcidr, proxy: group0, url: '\(server.url)'}\n" }
        yaml += "rules:\n"
        for index in 0..<25 { yaml += "  - RULE-SET,rules\(index),REJECT\n" }
        yaml += "  - MATCH,DIRECT\n"
        let bundles = ResourceBundleStore(root: root.appendingPathComponent("Resources"))
        let preparer = ProfileResourcePreparer(bundleStore: bundles, download: { request, _ in
            guard let name = request.url?.lastPathComponent, ["sourceA", "sourceB"].contains(name) else {
                throw ResourceBundleError.invalidEntry
            }
            return Data("proxies: [{name: \(name), type: direct}]\n".utf8)
        })
        let seedBundle = try await preparer.prepare(yaml: Data(yaml.utf8), deferProxyDownloads: true)
        let selections = Dictionary(uniqueKeysWithValues: (0..<9).map { ("group\($0)", "sourceB") })
        let store = SnapshotStore(root: root)
        let seed = try store.stage(configuration: RuntimeConfiguration(outbound: .mihomo(yaml: yaml, selections: selections), resources: seedBundle))
        let activation = try await prepare(.init(revision: seed, configuration: store.load(revision: seed)), root: root)
        let final = try RuntimeConfiguration.decode(activation.configuration)
        let directory = try bundles.directory(id: XCTUnwrap(final.resources))
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("manifest.json"))) as? [String: Any]
        XCTAssertEqual((manifest?["entries"] as? [Any])?.count, 27)
        let session = try GoPacketSession(configuration: String(decoding: activation.configuration, as: UTF8.self), resourceRoot: directory)
        defer { try? session.close() }
        let catalog = try session.proxyCatalog()
        for index in 0..<9 { XCTAssertEqual(catalog.proxies.first { $0.name == "group\(index)" }?.now, "sourceB") }
        XCTAssertEqual(final.outbound, .mihomo(yaml: yaml, selections: selections))
        XCTAssertEqual(try store.pendingRevision(), seed)
    }

    private func prepare(_ activation: TunnelLifecycle.Activation, root: URL) async throws -> TunnelLifecycle.Activation {
        try await withCheckedThrowingContinuation { continuation in
            _ = YAMLResourceActivation.prepare(activation, snapshotRoot: { root }, stateRoot: { root.appendingPathComponent("CoreState") }) {
                continuation.resume(with: $0)
            }
        }
    }
}

private final class ActivationHTTPServer {
    private let listener: NWListener
    let url: String

    init(body: Data) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        let queue = DispatchQueue(label: "YAMLResourceActivationTests.HTTP")
        let response = Data("HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, _, _ in
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 2) == .success, let port = listener.port else {
            listener.cancel()
            throw NSError(domain: "ActivationHTTPServer", code: 1)
        }
        url = "http://127.0.0.1:\(port.rawValue)/rules"
    }

    func close() { listener.cancel() }
    deinit { listener.cancel() }
}
