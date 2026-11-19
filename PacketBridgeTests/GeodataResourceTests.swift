import Foundation
import XCTest
@testable import PacketBridge

final class GeodataResourceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }

    func testSnifferGeoRequirementsRespectModeFieldsAndActivation() async throws {
        for datMode in [false, true] {
            for field in ["force-domain", "skip-domain"] {
                let yaml = Data("geodata-mode: \(datMode)\nsniffer: {enable: true, \(field): ['geosite:TEST']}\n".utf8)
                let bundle = try await localPreparer().prepare(yaml: yaml, localFiles: fixtures)
                XCTAssertEqual(try Set(manifestEntries(XCTUnwrap(bundle)).compactMap { $0["kind"] as? String }), ["geosite-dat"])
            }
            for field in ["skip-src-address", "skip-dst-address"] {
                let yaml = Data("geodata-mode: \(datMode)\nsniffer: {enable: true, \(field): ['geoip:LAN,TEST', '10.0.0.0/8']}\n".utf8)
                let bundle = try await localPreparer().prepare(yaml: yaml, localFiles: fixtures)
                XCTAssertEqual(try Set(manifestEntries(XCTUnwrap(bundle)).compactMap { $0["kind"] as? String }),
                               [datMode ? "geoip-dat" : "geoip-mmdb"])
            }
        }
        for yaml in [
            "sniffer: {enable: false, force-domain: ['geosite:TEST'], skip-dst-address: ['geoip:TEST']}",
            "sniffer: {enable: true, force-domain: ['example.invalid'], skip-src-address: ['geoip:LAN'], skip-dst-address: ['10.0.0.0/8']}",
        ] {
            let bundle = try await localPreparer().prepare(yaml: Data(yaml.utf8))
            XCTAssertNil(bundle)
        }
    }

    func testDeferredClassicalProviderCarriesOnlyAuthorizedGeoCandidates() async throws {
        let yaml = Data("rule-providers: {rules: {type: http, behavior: classical, proxy: MAIN, url: 'https://never.invalid/rules'}}\n".utf8)
        let local = ["GeoSite.dat": geositeFixture, "unrelated-private-file": Data("do not copy".utf8)]
        let prepared = try await localPreparer().prepare(yaml: yaml, localFiles: local, deferProxyDownloads: true)
        XCTAssertEqual(try manifestEntries(XCTUnwrap(prepared)).compactMap { $0["kind"] as? String }, ["geosite-dat"])
        let noDeferred = try await localPreparer().prepare(yaml: Data("mode: rule".utf8), localFiles: local, deferProxyDownloads: true)
        XCTAssertNil(noDeferred)
        let domain = Data("rule-providers: {rules: {type: http, behavior: domain, proxy: MAIN, url: 'https://never.invalid/rules'}}\n".utf8)
        let noGeoNeed = try await localPreparer().prepare(yaml: domain, localFiles: local, deferProxyDownloads: true)
        XCTAssertNil(noGeoNeed)
    }

    func testGeoHTTPFailureIdentifiesDatabaseWithoutExposingURL() async throws {
        let preparer = ProfileResourcePreparer(bundleStore: ResourceBundleStore(root: root), download: { _, _ in
            throw ProfileStoreError.httpStatus(403)
        })
        let yaml = Data("geox-url: {geosite: 'https://example.test/site.dat?token=secret'}\nrules: ['GEOSITE,TEST,DIRECT']\n".utf8)
        do {
            _ = try await preparer.prepare(yaml: yaml)
            XCTFail("The failing Geo database must be identified")
        } catch {
            XCTAssertEqual(error.localizedDescription, "The geosite-dat 'GeoSite.dat' server returned HTTP 403.")
            XCTAssertFalse(error.localizedDescription.contains("example.test"))
            XCTAssertFalse(error.localizedDescription.contains("secret"))
        }
    }

    func testUnusedGeoURLsAndLANRulesDoNotDownload() async throws {
        let preparer = localPreparer()
        let yaml = """
        geox-url:
          geoip: https://must-not-download.invalid/ip.dat
          geosite: https://must-not-download.invalid/site.dat
          mmdb: https://must-not-download.invalid/country.mmdb
          asn: https://must-not-download.invalid/asn.mmdb
        rules:
          - GEOIP,LAN,DIRECT
          - SRC-GEOIP,lan,DIRECT
          - DOMAIN-REGEX,(GEOSITE,test),DIRECT
          - MATCH,DIRECT
        """
        let bundle = try await preparer.prepare(yaml: Data(yaml.utf8))
        XCTAssertNil(bundle)
    }

    func testLogicalAndSubRulesCollectOnlyActualGeoPredicates() async throws {
        let yaml = Data("""
        geodata-mode: true
        rules:
          - AND,((NETWORK,TCP),(OR,((GEOIP,TEST),(IP-ASN,64512)))),REJECT
          - NOT,((GEOSITE,TEST)),DIRECT
          - SUB-RULE,(SRC-GEOIP,LAN),children
          - DOMAIN-REGEX,(GEOIP,ignored),DIRECT
        sub-rules:
          children: ['MATCH,DIRECT']
          unused: ['SRC-IP-ASN,64512,DIRECT']
        """.utf8)
        let bundle = try await localPreparer().prepare(yaml: yaml, localFiles: fixtures)
        XCTAssertEqual(try Set(manifestEntries(XCTUnwrap(bundle)).compactMap { $0["kind"] as? String }),
                       ["geoip-dat", "geosite-dat", "asn-mmdb"])
        let subOnly = Data("rules: ['SUB-RULE,(GEOIP,TEST),child']\nsub-rules: {child: ['GEOSITE,TEST,DIRECT']}\n".utf8)
        let subBundle = try await localPreparer().prepare(yaml: subOnly, localFiles: fixtures)
        XCTAssertEqual(try Set(manifestEntries(XCTUnwrap(subBundle)).compactMap { $0["kind"] as? String }), ["geoip-mmdb", "geosite-dat"])
    }

    func testClassicalAndDNSLogicalRulesDiscoverNestedGeo() async throws {
        let yaml = Data("""
        dns:
          enable: true
          enhanced-mode: fake-ip
          fake-ip-filter-mode: rule
          fake-ip-filter: ['NOT,((GEOSITE,TEST)),fake-ip']
        rule-providers:
          logical:
            type: inline
            behavior: classical
            payload: ['AND,((NETWORK,TCP),(OR,((GEOIP,TEST),(SRC-IP-ASN,64512))))']
        """.utf8)
        let bundle = try await localPreparer().prepare(yaml: yaml, localFiles: fixtures)
        XCTAssertEqual(try Set(manifestEntries(XCTUnwrap(bundle)).compactMap { $0["kind"] as? String }),
                       ["geoip-mmdb", "geosite-dat", "asn-mmdb"])
    }

    func testGeoModeSelectsOnlyRequiredDatabasesAndDefaultNames() async throws {
        for datMode in [false, true] {
            let yaml = """
            geodata-mode: \(datMode)
            rules: ["GEOIP,CN,DIRECT", "SRC-GEOIP,US,DIRECT", "GEOSITE,TEST,DIRECT", "IP-ASN,64512,DIRECT", "SRC-IP-ASN,64513,DIRECT"]
            """
            let prepared = try await localPreparer().prepare(yaml: Data(yaml.utf8), localFiles: fixtures)
            let entries = try manifestEntries(XCTUnwrap(prepared))
            XCTAssertEqual(Set(entries.compactMap { $0["kind"] as? String }),
                           [datMode ? "geoip-dat" : "geoip-mmdb", "geosite-dat", "asn-mmdb"])
            XCTAssertTrue(entries.allSatisfy { $0["name"] as? String == "default" })
        }
    }

    func testMissingGeoResourceRequestsTheFixedLocalAssociation() async throws {
        do {
            _ = try await localPreparer().prepare(yaml: Data("rules: ['GEOIP,CN,DIRECT']\n".utf8))
            XCTFail("A Geo rule cannot silently omit its database")
        } catch let error as ProfileResourceError {
            XCTAssertEqual(error, .missingLocalFile(kind: .geoIPMMDB, name: "default", path: "Country.mmdb"))
        }
    }

    func testOnlyExplicitRequiredURLDownloadsAndLocalChoiceTakesPriority() async throws {
        let spy = GeoDownloadSpy(payload: geositeFixture)
        let preparer = ProfileResourcePreparer(bundleStore: ResourceBundleStore(root: root), download: { await spy.download($0, maximum: $1) })
        let yaml = Data("""
        geox-url:
          geoip: https://example.test/unneeded.dat
          geosite: https://example.test/selected.dat
          mmdb: https://example.test/unneeded.mmdb
        rules: ['GEOSITE,TEST,DIRECT']
        """.utf8)
        let downloaded = try await preparer.prepare(yaml: yaml)
        XCTAssertNotNil(downloaded)
        let requests = await spy.requests
        XCTAssertEqual(requests.map { $0.url?.absoluteString }, ["https://example.test/selected.dat"])
        let limits = await spy.maximums
        XCTAssertEqual(limits, [ResourceBundleStore.maximumResourceBytes])
        let local = try await localPreparer().prepare(yaml: yaml, localFiles: ["GeoSite.dat": geositeFixture])
        XCTAssertEqual(downloaded, local)
    }

    func testDisabledDNSAndInactiveFakeIPSettingsDoNotRequireGeoFiles() async throws {
        for enabled in [false, true] {
            let yaml = """
            dns:
              enable: \(enabled)
              enhanced-mode: redir-host
              fake-ip-filter: ['geosite:TEST']
              fallback-filter: {geoip: true, geosite: [TEST]}
            rules: ['MATCH,DIRECT']
            """
            let bundle = try await localPreparer().prepare(yaml: Data(yaml.utf8))
            XCTAssertNil(bundle)
        }
        let disabledPolicy = Data("dns: {enable: false, nameserver-policy: {'geosite:TEST': [1.1.1.1]}, fallback: [8.8.8.8]}\n".utf8)
        let disabled = try await localPreparer().prepare(yaml: disabledPolicy)
        XCTAssertNil(disabled)
    }

    func testDNSPolicyFakeIPAndFallbackRequirementsRespectTheirActivation() async throws {
        let cases: [(String, Set<String>)] = [
            ("nameserver-policy: {'geosite:TEST,!OTHER@cn': [1.1.1.1]}", ["geosite-dat"]),
            ("proxy-server-nameserver-policy: {'geosite:TEST': [1.1.1.1]}", ["geosite-dat"]),
            ("enhanced-mode: fake-ip\n  fake-ip-filter: ['geosite:TEST']", ["geosite-dat"]),
            ("enhanced-mode: fake-ip\n  fake-ip-filter-mode: rule\n  fake-ip-filter: ['GEOSITE,TEST,fake-ip']", ["geosite-dat"]),
            ("fallback: [8.8.8.8]", ["geoip-mmdb"]),
            ("fallback: [8.8.8.8]\n  fallback-filter: {geoip: false, geosite: [TEST]}", ["geosite-dat"]),
            ("fallback: [8.8.8.8]\n  fallback-filter: {geoip: true, geoip-code: LAN}", []),
        ]
        for (settings, expected) in cases {
            let yaml = Data("dns:\n  enable: true\n  \(settings)\n".utf8)
            let prepared = try await localPreparer().prepare(yaml: yaml, localFiles: fixtures)
            let kinds = try prepared.map { Set(try manifestEntries($0).compactMap { $0["kind"] as? String }) } ?? []
            XCTAssertEqual(kinds, expected, settings)
        }
    }

    func testClassicalProviderYAMLTextAndInlineRulesDiscoverGeoNeeds() async throws {
        for (format, body) in [
            ("yaml", "payload: ['GEOSITE,TEST', 'GEOIP,LAN']\n"),
            ("text", "# GEOIP,CN is a comment\nGEOSITE,TEST\nGEOIP,LAN\n"),
        ] {
            let yaml = Data("rule-providers: {rules: {type: file, behavior: classical, format: \(format), path: rules.txt}}\n".utf8)
            let prepared = try await localPreparer().prepare(yaml: yaml, localFiles: ["rules.txt": Data(body.utf8), "GeoSite.dat": geositeFixture])
            let kinds = try Set(manifestEntries(XCTUnwrap(prepared)).compactMap { $0["kind"] as? String })
            XCTAssertEqual(kinds, ["rule-provider", "geosite-dat"])
        }
        let inline = Data("rule-providers: {rules: {type: inline, behavior: classical, payload: ['SRC-IP-ASN,64512']}}\n".utf8)
        let prepared = try await localPreparer().prepare(yaml: inline, localFiles: fixtures)
        XCTAssertEqual(try manifestEntries(XCTUnwrap(prepared)).compactMap { $0["kind"] as? String }, ["asn-mmdb"])
    }

    func testGeoKindsRejectNondefaultManifestNamesAndOversizedBytes() async throws {
        let store = ResourceBundleStore(root: root)
        XCTAssertThrowsError(try store.stage(entries: [.init(kind: .geoSiteDat, name: "other", data: geositeFixture)]))
        let large = Data(repeating: 1, count: ResourceBundleStore.maximumResourceBytes + 1)
        do {
            _ = try await localPreparer().prepare(yaml: Data("rules: ['GEOSITE,TEST,DIRECT']\n".utf8), localFiles: ["GeoSite.dat": large])
            XCTFail("Geodata must use the same byte limit as provider resources")
        } catch {}
    }

    func testLogicalGeoAndSubRulesCrossGoBridge() async throws {
        let yaml = """
        geodata-mode: true
        dns: {enable: true, enhanced-mode: redir-host, nameserver: ['127.0.0.1:1']}
        rules:
          - SUB-RULE,(NETWORK,TCP),children
          - AND,((GEOIP,TEST),(NOT,((IP-ASN,64512)))),DIRECT
          - MATCH,REJECT
        sub-rules:
          children: ['OR,((GEOSITE,TEST),(GEOIP,TEST)),DIRECT', 'MATCH,REJECT']
        """
        let prepared = try await localPreparer().prepare(yaml: Data(yaml.utf8), localFiles: fixtures)
        let bundle = try XCTUnwrap(prepared)
        let configuration = RuntimeConfiguration(outbound: .mihomo(yaml: yaml), resources: bundle)
        let session = try GoPacketSession(
            configuration: String(decoding: JSONEncoder().encode(configuration), as: UTF8.self),
            resourceRoot: ResourceBundleStore(root: root).directory(id: bundle)
        )
        defer { try? session.close() }
        XCTAssertTrue(try session.proxyCatalog().proxies.contains { $0.name == "DIRECT" })
    }

    func testRealGeodataFixturesCrossGoBridgeAndInvalidDatabasesAreRejected() async throws {
        let cases: [(ResourceKind, String, Bool)] = [
            (.geoIPDat, "GEOIP,TEST,DIRECT", true),
            (.geoSiteDat, "GEOSITE,TEST,DIRECT", false),
            (.geoIPMMDB, "GEOIP,us,DIRECT", false),
            (.asnMMDB, "IP-ASN,64512,DIRECT", false),
        ]
        let store = ResourceBundleStore(root: root)
        for (kind, rule, datMode) in cases {
            let yaml = """
            geodata-mode: \(datMode)
            dns: {enable: true, enhanced-mode: redir-host, nameserver: ['127.0.0.1:1']}
            rules: ['\(rule)', 'MATCH,REJECT']
            """
            let prepared = try await localPreparer().prepare(yaml: Data(yaml.utf8), localFiles: fixtures)
            let bundle = try XCTUnwrap(prepared)
            let configuration = RuntimeConfiguration(outbound: .mihomo(yaml: yaml), resources: bundle)
            _ = try GoPacketSession.networkPlan(configuration: configuration)
            let text = String(decoding: try JSONEncoder().encode(configuration), as: UTF8.self)
            let session = try GoPacketSession(configuration: text, resourceRoot: store.directory(id: bundle))
            defer { try? session.close() }
            XCTAssertTrue(try session.proxyCatalog().proxies.contains { $0.name == "DIRECT" })
            try session.close()
            let invalid = try store.stage(entries: [.init(kind: kind, name: "default", data: Data([0xff, 0xff]))])
            let invalidConfiguration = RuntimeConfiguration(outbound: .mihomo(yaml: yaml), resources: invalid)
            let invalidText = String(decoding: try JSONEncoder().encode(invalidConfiguration), as: UTF8.self)
            XCTAssertThrowsError(try GoPacketSession(configuration: invalidText, resourceRoot: store.directory(id: invalid)))
        }
    }

    private func localPreparer() -> ProfileResourcePreparer {
        ProfileResourcePreparer(bundleStore: ResourceBundleStore(root: root), download: { _, _ in
            XCTFail("No implicit geodata download is allowed")
            return Data()
        })
    }

    private func manifestEntries(_ id: String) throws -> [[String: Any]] {
        let directory = try ResourceBundleStore(root: root).directory(id: id)
        let data = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(manifest["entries"] as? [[String: Any]])
    }

    private var fixtures: [String: Data] {
        ["GeoIP.dat": Data(base64Encoded: "ChAKBFRFU1QSCAoEywBxABAY")!, "GeoSite.dat": geositeFixture,
         "Country.mmdb": Data(base64Encoded: "AAARAAABAAAAAAAAAAAAAAAAAAAAAEJ1c6vN701heE1pbmQuY29t50pub2RlX2NvdW50xAAAAAFLcmVjb3JkX3NpemXEAAAAGEppcF92ZXJzaW9uxAAAAARNZGF0YWJhc2VfdHlwZUpzaW5nLWdlb2lwW2JpbmFyeV9mb3JtYXRfbWFqb3JfdmVyc2lvbsQAAAACW2JpbmFyeV9mb3JtYXRfbWlub3JfdmVyc2lvbsQAAAAAS2Rlc2NyaXB0aW9u4UJlblJsb2NhbCB0ZXN0IGZpeHR1cmU=")!,
         "ASN.mmdb": Data(base64Encoded: "AAARAAABAAAAAAAAAAAAAAAAAAAAAOJYYXV0b25vbW91c19zeXN0ZW1fbnVtYmVyxAAA/ABdAWF1dG9ub21vdXNfc3lzdGVtX29yZ2FuaXphdGlvbk10ZXN0IG9wZXJhdG9yq83vTWF4TWluZC5jb23nSm5vZGVfY291bnTEAAAAAUtyZWNvcmRfc2l6ZcQAAAAYSmlwX3ZlcnNpb27EAAAABE1kYXRhYmFzZV90eXBlTEdlb0xpdGUyLUFTTltiaW5hcnlfZm9ybWF0X21ham9yX3ZlcnNpb27EAAAAAltiaW5hcnlfZm9ybWF0X21pbm9yX3ZlcnNpb27EAAAAAEtkZXNjcmlwdGlvbuFCZW5SbG9jYWwgdGVzdCBmaXh0dXJl")!]
    }

    private var geositeFixture: Data {
        Data(base64Encoded: "ChsKBFRFU1QSEwgCEg9leGFtcGxlLmludmFsaWQ=")!
    }
}

private actor GeoDownloadSpy {
    let payload: Data
    var requests: [URLRequest] = []
    var maximums: [Int] = []
    init(payload: Data) { self.payload = payload }
    func download(_ request: URLRequest, maximum: Int) -> Data {
        requests.append(request)
        maximums.append(maximum)
        return payload
    }
}
