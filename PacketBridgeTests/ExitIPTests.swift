import Foundation
import XCTest
@testable import PacketBridge

@MainActor
final class ExitIPTests: XCTestCase {
    func testHostingIPv4AndOrganizationMatchTheActualResponse() throws {
        let result = try decode(#"{"ip":"203.0.113.7","isp":{"org":"Customer Route"},"location":{"country_code":"JP"},"risk":{"is_datacenter":true,"is_tor":false}}"#)
        XCTAssertEqual(result.ip, "203.0.113.7")
        XCTAssertEqual(result.countryCode, "JP")
        XCTAssertEqual(result.organization, "Customer Route")
        XCTAssertEqual(result.networkType, "机房")
        XCTAssertEqual(result.quality, "普通")
        XCTAssertTrue(result.qualityExplanation.contains("IPQuery"))
        XCTAssertEqual(try JSONDecoder().decode(ExitIP.self, from: JSONEncoder().encode(result)), result)
    }

    func testIPv6FallbackIsAcceptedAndFamilyIsExplicit() throws {
        let v4 = try decode(#"{"ip":"203.0.113.7"}"#)
        let v6 = try decode(#"{"ip":"2a12:a303:11a:77::a"}"#)
        XCTAssertEqual(v4.addressFamily, "IPv4")
        XCTAssertEqual(v6.addressFamily, "IPv6")
        XCTAssertEqual(v6.ip, "2a12:a303:11a:77::a")
        XCTAssertEqual(v6.quality, "未知")
        XCTAssertFalse(v6.qualityExplanation.contains("IPv4"))
    }

    func testMappedIPv4AndScopedIPv6AreRejected() throws {
        for ip in ["::ffff:203.0.113.7", "::ffff:cb00:7107", "0:0:0:0:0:ffff:cb00:7107", "fe80::1%en0"] {
            let data = try JSONSerialization.data(withJSONObject: ["ip": ip])
            XCTAssertThrowsError(try ExitIP.decodeIPQuery(data), ip)
        }
    }

    func testClassificationFailurePreservesTheConfirmedIPv4() throws {
        let result = try decode(#"{"ip":"203.0.113.7"}"#)
        XCTAssertEqual(result.ip, "203.0.113.7")
        XCTAssertEqual(result.quality, "未知")
        XCTAssertTrue(result.qualityExplanation.contains("已取得"))
    }

    func testUnknownClassificationDoesNotBecomeResidentialOrGood() throws {
        for raw in [#"{"ip":"1.1.1.1"}"#, #"{"ip":"1.1.1.1","risk":{"is_datacenter":false,"is_mobile":false,"is_tor":false}}"#] {
            let result = try decode(raw)
            XCTAssertEqual(result.networkType, "未分类")
            XCTAssertEqual(result.quality, "未知")
        }
        XCTAssertEqual(try decode(#"{"ip":"1.1.1.1","risk":{"is_mobile":true}}"#).quality, "良好")
        XCTAssertEqual(try decode(#"{"ip":"1.1.1.1","risk":{"is_mobile":true,"is_tor":true}}"#).quality, "有风险")
    }

    func testInvalidAndOversizedResponsesAreRejected() throws {
        for raw in [#"{"ip":"not-an-ip"}"#, #"{"ip":"127.0.0.999"}"#, #"{"ip":"fe80::1%en0"}"#,
                    #"{"error":"rate limited","ip":"1.1.1.1"}"#, #"{"error":[],"ip":"1.1.1.1"}"#,
                    #"[{"ip":"1.1.1.1"}]"#] {
            XCTAssertThrowsError(try decode(raw), raw)
        }
        XCTAssertThrowsError(try ExitIP.decodeIPQuery(Data(repeating: 32, count: 65_537)))
    }

    func testMalformedClassificationPreservesTheConfirmedIPv4() throws {
        for raw in [#"{"ip":"1.1.1.1","risk":"oops"}"#,
                    #"{"ip":"1.1.1.1","risk":{"is_datacenter":"true"}}"#,
                    #"{"ip":"1.1.1.1","location":{"country_code":123}}"#,
                    #"{"ip":"1.1.1.1","location":{"country_code":"JAPAN"}}"#,
                    #"{"ip":"1.1.1.1","isp":{"org":[]}}"#,
                    #"{"ip":"1.1.1.1","isp":{"org":""# + String(repeating: "x", count: 513) + #""}}"#] {
            let result = try decode(raw)
            XCTAssertEqual(result.ip, "1.1.1.1")
            XCTAssertNil(result.countryCode)
            XCTAssertNil(result.organization)
            XCTAssertEqual(result.networkType, "未分类")
            XCTAssertEqual(result.quality, "未知")
        }
        let partial = try decode(#"{"ip":"1.1.1.1","risk":"oops","location":{"country_code":"AU"},"isp":{"org":"Cloudflare"}}"#)
        XCTAssertEqual(partial.countryCode, "AU")
        XCTAssertEqual(partial.organization, "Cloudflare")
        XCTAssertEqual(partial.quality, "未知")
    }

    func testNewRouteIgnoresLateSuccessAndClearsPreviousResult() async throws {
        let monitor = ExitIPMonitor()
        let first = try decode(#"{"ip":"1.1.1.1"}"#)
        let second = try decode(#"{"ip":"8.8.8.8"}"#)
        await monitor.refresh { first }
        let requested = expectation(description: "old route request")
        var pending: CheckedContinuation<ExitIP, Never>?
        let old = Task {
            await monitor.refresh {
                await withCheckedContinuation { pending = $0; requested.fulfill() }
            }
        }
        await fulfillment(of: [requested], timeout: 2)
        XCTAssertNil(monitor.result)
        XCTAssertTrue(monitor.isLoading)
        await monitor.refresh { second }
        pending?.resume(returning: first)
        await old.value
        XCTAssertEqual(monitor.result?.ip, second.ip)
        XCTAssertFalse(monitor.isLoading)
        XCTAssertNil(monitor.error)
    }

    func testStopCancelsTheLookupAndRejectsLateFailure() async throws {
        let monitor = ExitIPMonitor()
        let requested = expectation(description: "lookup started")
        let cancelled = expectation(description: "lookup cancellation propagated")
        var pending: CheckedContinuation<ExitIP, Error>?
        let task = Task {
            await monitor.refresh {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { pending = $0; requested.fulfill() }
                } onCancel: { cancelled.fulfill() }
            }
        }
        await fulfillment(of: [requested], timeout: 2)
        monitor.stop()
        await fulfillment(of: [cancelled], timeout: 2)
        pending?.resume(throwing: URLError(.timedOut))
        await task.value
        XCTAssertNil(monitor.result)
        XCTAssertNil(monitor.error)
        XCTAssertFalse(monitor.isLoading)
    }

    func testNewRouteIgnoresLateFailure() async throws {
        let monitor = ExitIPMonitor()
        let current = try decode(#"{"ip":"8.8.8.8"}"#)
        let requested = expectation(description: "old route requested")
        var pending: CheckedContinuation<ExitIP, Error>?
        let old = Task {
            await monitor.refresh {
                try await withCheckedThrowingContinuation { pending = $0; requested.fulfill() }
            }
        }
        await fulfillment(of: [requested], timeout: 2)
        await monitor.refresh { current }
        pending?.resume(throwing: URLError(.cannotConnectToHost))
        await old.value
        XCTAssertEqual(monitor.result, current)
        XCTAssertNil(monitor.error)
        XCTAssertFalse(monitor.isLoading)
    }

    func testCancellingRefreshPropagatesToLookup() async throws {
        let monitor = ExitIPMonitor()
        let requested = expectation(description: "lookup requested")
        let cancelled = expectation(description: "caller cancellation reached lookup")
        let refresh = Task {
            await monitor.refresh {
                try await withTaskCancellationHandler {
                    requested.fulfill()
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                    throw URLError(.unknown)
                } onCancel: { cancelled.fulfill() }
            }
        }
        await fulfillment(of: [requested], timeout: 2)
        refresh.cancel()
        await fulfillment(of: [cancelled], timeout: 2)
        await refresh.value
        XCTAssertNil(monitor.result)
        XCTAssertNil(monitor.error)
        XCTAssertFalse(monitor.isLoading)
    }

    func testFailureShowsErrorWithoutInventingAnIP() async {
        let monitor = ExitIPMonitor()
        await monitor.refresh { throw URLError(.timedOut) }
        XCTAssertNil(monitor.result)
        XCTAssertNotNil(monitor.error)
        XCTAssertFalse(monitor.isLoading)
    }

    func testQualityEnvelopeCarriesSourceASNFlagsAndCacheTime() throws {
        let result = try ExitIP.decodeQuality(Data(#"{"ip":"203.0.113.7","countryCode":"jp","quality":{"source":"ipLocate","type":"business","organization":"Example Network","asn":64500,"isProxy":true,"isVpn":true,"isTor":false,"isAbuser":false,"inferred":false},"failures":[],"checkedAt":1700000000,"cached":true}"#.utf8))
        XCTAssertEqual(result.networkType, "商业")
        XCTAssertEqual(result.quality, "良好")
        XCTAssertEqual(result.countryCode, "JP")
        XCTAssertEqual(result.organization, "Example Network")
        XCTAssertEqual(result.qualityDetails?.source.label, "IPLocate")
        XCTAssertEqual(result.qualityDetails?.asn, 64500)
        XCTAssertEqual(result.qualityDetails?.flags, ["VPN", "代理"])
        XCTAssertEqual(result.checkedAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertTrue(result.cached)
        XCTAssertEqual(try JSONDecoder().decode(ExitIP.self, from: JSONEncoder().encode(result)), result)
    }

    func testQualityLevelsFollowNetworkTypeAndRiskFlags() throws {
        for (type, expected) in [("residential", "良好"), ("mobile", "良好"), ("business", "良好"), ("hosting", "普通")] {
            for flag in ["none", "isProxy", "isVpn", "isTor", "isAbuser"] {
                let quality: [String: Any] = ["source": "ipApiIs", "type": type, "isProxy": flag == "isProxy", "isVpn": flag == "isVpn", "isTor": flag == "isTor", "isAbuser": flag == "isAbuser", "inferred": false]
                let data = try JSONSerialization.data(withJSONObject: ["ip": "1.1.1.1", "quality": quality, "failures": [], "cached": false])
                let result = try ExitIP.decodeQuality(data)
                XCTAssertEqual(result.quality, flag == "isTor" || flag == "isAbuser" ? "有风险" : expected)
            }
        }
    }

    func testInferredResidentialIsExplainedAndFailuresKeepConfirmedIP() throws {
        let inferred = try ExitIP.decodeQuality(Data(#"{"ip":"1.1.1.1","quality":{"source":"ipQuery","type":"residential","isProxy":false,"isVpn":false,"isTor":false,"isAbuser":false,"inferred":true},"failures":[],"cached":false}"#.utf8))
        XCTAssertEqual(inferred.networkType, "住宅")
        XCTAssertTrue(inferred.qualityExplanation.contains("推断"))
        let failure = try ExitIP.decodeQuality(Data(#"{"ip":"1.1.1.1","failures":[{"source":"identMe","status":"ipMismatch"},{"source":"proxyCheck","status":"rateLimited"}],"cached":true}"#.utf8))
        XCTAssertEqual(failure.ip, "1.1.1.1")
        XCTAssertEqual(failure.quality, "未知")
        XCTAssertEqual(failure.failures.map(\.status.label), ["出站 IP 不一致", "限流"])
        XCTAssertNil(failure.qualityDetails)
    }

    func testQualityEnvelopeRejectsInvalidIPAndOversizedInput() throws {
        for ip in ["invalid", "::ffff:1.1.1.1", "fe80::1%en0"] {
            let data = try JSONSerialization.data(withJSONObject: ["ip": ip, "failures": [], "cached": false])
            XCTAssertThrowsError(try ExitIP.decodeQuality(data))
        }
        XCTAssertThrowsError(try ExitIP.decodeQuality(Data(repeating: 32, count: 65_537)))
    }

    func testForceRefreshSurvivesTunnelControlEncoding() throws {
        let request = TunnelControlRequest(action: .exitIP, forceRefresh: true)
        let decoded = try JSONDecoder().decode(TunnelControlRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(decoded.forceRefresh, true)
        let ordinary = try JSONDecoder().decode(TunnelControlRequest.self, from: JSONEncoder().encode(TunnelControlRequest(action: .exitIP)))
        XCTAssertNotEqual(ordinary.forceRefresh, true)
    }

    func testCancellationTargetsTheOriginalRequest() throws {
        let query = TunnelControlRequest(action: .exitIP)
        let cancellation = TunnelControlRequest(action: .cancelExitIP, cancellingRequestID: query.id)
        let decoded = try JSONDecoder().decode(TunnelControlRequest.self, from: JSONEncoder().encode(cancellation))
        XCTAssertEqual(decoded.action, .cancelExitIP)
        XCTAssertEqual(decoded.cancellingRequestID, query.id)
        XCTAssertNotEqual(decoded.id, query.id)
    }

    func testExpiredQualityWaitsForExplicitRefresh() async throws {
        let monitor = ExitIPMonitor()
        let repeated = expectation(description: "unexpected automatic lookup")
        repeated.isInverted = true
        let cached = try qualityResult(checkedAt: 1_700_000_000)
        let next = try decode(#"{"ip":"8.8.8.8"}"#)
        var calls = 0
        await monitor.refresh {
            calls += 1
            if calls > 1 { repeated.fulfill(); return next }
            return cached
        }
        await fulfillment(of: [repeated], timeout: 0.1)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(monitor.result, cached)
    }

    func testResumingUsesCompletedSuccessOrFailureUntilRouteChanges() async throws {
        let monitor = ExitIPMonitor()
        let first = try decode(#"{"ip":"1.1.1.1"}"#)
        let next = try decode(#"{"ip":"8.8.8.8"}"#)
        var calls = 0
        await monitor.refreshIfNeeded { calls += 1; return first }
        monitor.pause()
        await monitor.refreshIfNeeded { calls += 1; return next }
        XCTAssertEqual(monitor.result, first)
        XCTAssertEqual(calls, 1)

        monitor.stop()
        await monitor.refreshIfNeeded { calls += 1; throw URLError(.timedOut) }
        let failure = monitor.error
        XCTAssertNotNil(failure)
        monitor.pause()
        await monitor.refreshIfNeeded { calls += 1; return next }
        XCTAssertEqual(monitor.error, failure)
        XCTAssertEqual(calls, 2)

        await monitor.refresh { calls += 1; return next }
        XCTAssertEqual(monitor.result, next)
        XCTAssertEqual(calls, 3)
    }

    func testInterruptedLookupResumesOnceAndIgnoresLateBackgroundResult() async throws {
        let monitor = ExitIPMonitor()
        let first = try decode(#"{"ip":"1.1.1.1"}"#)
        let next = try decode(#"{"ip":"8.8.8.8"}"#)
        let started = expectation(description: "lookup started")
        var old: CheckedContinuation<ExitIP, Never>?
        let task = Task {
            await monitor.refreshIfNeeded {
                await withCheckedContinuation { old = $0; started.fulfill() }
            }
        }
        await fulfillment(of: [started], timeout: 2)
        await monitor.refreshIfNeeded { XCTFail("duplicate lookup"); return first }
        monitor.pause()
        await monitor.refreshIfNeeded { next }
        old?.resume(returning: first)
        await task.value
        XCTAssertEqual(monitor.result, next)
    }

    private func qualityResult(checkedAt: TimeInterval) throws -> ExitIP {
        let quality: [String: Any] = ["source": "ipApiIs", "type": "business", "isProxy": false, "isVpn": false, "isTor": false, "isAbuser": false, "inferred": false]
        let data = try JSONSerialization.data(withJSONObject: ["ip": "1.1.1.1", "quality": quality, "failures": [], "cached": true, "checkedAt": checkedAt])
        return try ExitIP.decodeQuality(data)
    }

    private func decode(_ json: String) throws -> ExitIP {
        try ExitIP.decodeIPQuery(Data(json.utf8))
    }
}
