import XCTest
@testable import PacketBridge

final class RuntimeFilterTests: XCTestCase {
    func testConnectionFiltersCombineFieldsAndKeepStableSorting() {
        let first = connection("1", host: "api.example", network: "tcp", source: "198.18.0.2:1234", proxy: "office", download: 100)
        let second = connection("2", host: "dns.example", network: "udp", source: "198.18.0.3:1234", proxy: "home", download: 200)
        let ended = connection("3", host: "api.example", network: "tcp", source: "198.18.0.2:1234", proxy: "office", download: 100, ended: 3, error: "refused")
        var filter = RuntimeConnectionFilter()
        filter.query = "EXAMPLE office"
        filter.source = "0.2"
        filter.network = "tcp"
        filter.status = .active
        XCTAssertEqual(filter.apply([second, ended, first]).map(\.id), ["1"])
        filter.status = .failed
        XCTAssertEqual(filter.apply([first, second, ended]).map(\.id), ["3"])
        filter = RuntimeConnectionFilter()
        filter.order = .download
        XCTAssertEqual(filter.apply([ended, first, second]).map(\.id), ["2", "1", "3"])
        filter.host = "no-match"
        XCTAssertTrue(filter.apply([first, second]).isEmpty)
    }

    func testDNSFiltersCombineCacheStatusTypeAndAnswers() throws {
        let values = try JSONDecoder().decode([RuntimeDNSQuery].self, from: Data("""
        [{"id":"a","domain":"api.example","type":"A","initiator":"app","upstream":"udp://127.0.0.1:53","mode":"resolver","cached":true,"startedAt":1,"durationMS":0,"status":"success","responseCode":"NOERROR","answers":["203.0.113.1"],"omittedAnswers":0},
         {"id":"b","domain":"other.example","type":"AAAA","initiator":"proxy","upstream":"","mode":"resolver","cached":false,"startedAt":2,"durationMS":50,"status":"timeout","responseCode":"","answers":[],"omittedAnswers":0}]
        """.utf8))
        var filter = RuntimeDNSFilter()
        filter.query = "API 203.0.113"
        filter.type = "A"
        filter.cache = .hit
        XCTAssertEqual(filter.apply(values).map(\.id), ["a"])
        filter = RuntimeDNSFilter()
        filter.status = "timeout"
        XCTAssertEqual(filter.apply(values).map(\.id), ["b"])
        filter = RuntimeDNSFilter()
        filter.order = .duration
        XCTAssertEqual(filter.apply(values).map(\.id), ["b", "a"])
    }

    private func connection(_ id: String, host: String, network: String, source: String, proxy: String,
                            download: Int64, ended: Int64 = 0, error: String = "") -> RuntimeConnection {
        RuntimeConnection(id: id, network: network, source: source, destination: "203.0.113.1:443", host: host,
                          rule: "DOMAIN", proxy: proxy, startedAt: 1, endedAt: ended, upload: 5, download: download, error: error)
    }
}
