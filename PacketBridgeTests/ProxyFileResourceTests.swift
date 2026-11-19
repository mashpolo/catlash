import Foundation
import XCTest
@testable import PacketBridge

final class ProxyFileResourceTests: XCTestCase {
    func testExistingDesktopCertificateRequiresExplicitAssociation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let certificate = root.appendingPathComponent("desktop.pem")
        try Data("private local file".utf8).write(to: certificate)
        let yaml = Data("proxies: [{name: node, type: trojan, certificate: '\(certificate.path)'}]".utf8)
        let preparer = ProfileResourcePreparer(bundleStore: ResourceBundleStore(root: root.appendingPathComponent("cache")))
        do {
            _ = try await preparer.prepare(yaml: yaml)
            XCTFail("A YAML path must not authorize reading a host file")
        } catch let ProfileResourceError.missingLocalFile(kind, _, path) {
            XCTAssertEqual(kind.rawValue, "proxy-file")
            XCTAssertEqual(path, certificate.path)
        }
    }

    func testAuthorizedCertificateIsDeduplicatedAcrossNodesAndProviderPayload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ResourceBundleStore(root: root)
        let preparer = ProfileResourcePreparer(bundleStore: store)
        let yaml = Data("""
        # keep the original desktop path
        proxies:
          - {name: first, type: trojan, certificate: /desktop/cert.pem}
          - {name: second, type: trojan, certificate: /desktop/cert.pem}
        proxy-providers:
          nodes:
            type: inline
            payload:
              - {name: ssh, type: ssh, private-key: ../key.pem}
        """.utf8)
        let values = ["/desktop/cert.pem": Data("certificate bytes".utf8), "../key.pem": Data("key bytes".utf8)]
        let prepared = try await preparer.prepare(yaml: yaml, localFiles: values)
        let id = try XCTUnwrap(prepared)
        let directory = try store.directory(id: id)
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("manifest.json"))) as? [String: Any])
        let entries = try XCTUnwrap(manifest["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(Set(entries.compactMap { $0["name"] as? String }), Set(values.keys))
        XCTAssertTrue(entries.allSatisfy { $0["kind"] as? String == "proxy-file" })
        XCTAssertTrue(String(decoding: yaml, as: UTF8.self).contains("# keep the original desktop path"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy { $0 == "manifest.json" || $0.count == 64 })
    }

    func testProtocolKeysAndInlinePEMAreNotTreatedAsFilePaths() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let preparer = ProfileResourcePreparer(bundleStore: ResourceBundleStore(root: root))
        let yaml = Data("""
        proxies:
          - {name: wireguard, type: wireguard, private-key: base64-key}
          - {name: masque, type: masque, private-key: base64-key}
          - name: ssh
            type: ssh
            private-key: |-
              -----BEGIN OPENSSH PRIVATE KEY-----
              inline
              -----END OPENSSH PRIVATE KEY-----
        """.utf8)
        let result = try await preparer.prepare(yaml: yaml)
        XCTAssertNil(result)
    }
}
