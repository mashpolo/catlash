import Foundation
import NetworkExtension
import XCTest
@testable import PacketBridge

final class TunnelStartupDiagnosticsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }

    func testLegacyRecordReadableAndPublishedOnRestore() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = UUID()
        let data = try JSONEncoder().encode(TunnelStartupDiagnostic(attemptID: id, phase: .failed, revision: nil,
                                      message: "旧版故障", updatedAt: Date()))
        let old = root.appendingPathComponent("tunnel-startup.json")
        try data.write(to: old)
        let store = TunnelStartupDiagnosticsStore(root: root)
        XCTAssertEqual(try store.load()?.attemptID, id)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Library/Application Support/tunnel-startup.json")), data)
        let next = UUID()
        try store.begin(attemptID: next, revision: nil)
        XCTAssertEqual(try TunnelStartupDiagnosticsStore(root: root).load()?.attemptID, next)
        XCTAssertEqual(try Data(contentsOf: old), data)
    }

    func testRunningFailureDescribesPacketCauseAndSurvivesStop() throws {
        let store = TunnelStartupDiagnosticsStore(root: root)
        let id = UUID()
        try store.begin(attemptID: id, revision: nil)
        XCTAssertTrue(try store.record(attemptID: id, phase: .connected))
        let error = NSError(domain: "go", code: 1, userInfo: [NSLocalizedDescriptionKey: "packet queue is full"])
        XCTAssertTrue(try store.record(attemptID: id, phase: .failed, error: error))
        let failed = try XCTUnwrap(store.load())
        XCTAssertTrue(failed.message.contains("队列"))
        XCTAssertFalse(failed.message.contains("启动"))
        XCTAssertFalse(try store.record(attemptID: id, phase: .stopped, stopReason: .providerFailed))
        XCTAssertEqual(try store.load(), failed)
    }

    func testNetworkStopCanBeDistinguishedFromManualStop() throws {
        let store = TunnelStartupDiagnosticsStore(root: root)
        for reason in [NEProviderStopReason.userInitiated, .unrecoverableNetworkChange] {
            let id = UUID()
            try store.begin(attemptID: id, revision: nil)
            XCTAssertTrue(try store.record(attemptID: id, phase: .connected))
            XCTAssertTrue(try store.record(attemptID: id, phase: .stopped, stopReason: reason))
            let last = try XCTUnwrap(store.load())
            XCTAssertEqual(last.stopReason, reason.rawValue)
            if reason == .userInitiated { XCTAssertNil(last.disconnectMessage) }
            else { XCTAssertTrue(last.disconnectMessage?.contains("网络") == true) }
        }
    }

    func testLateAttemptCannotReplaceCurrentAttempt() throws {
        let store = TunnelStartupDiagnosticsStore(root: root)
        let old = UUID(), current = UUID()
        try store.begin(attemptID: old, revision: String(repeating: "a", count: 64))
        try store.begin(attemptID: current, revision: String(repeating: "b", count: 64))
        XCTAssertFalse(try store.record(attemptID: old, phase: .failed, error: ProfileStoreError.downloadFailed))
        XCTAssertTrue(try store.record(attemptID: current, phase: .connected))
        let reopened = try XCTUnwrap(TunnelStartupDiagnosticsStore(root: root).load())
        XCTAssertEqual(reopened.attemptID, current)
        XCTAssertEqual(reopened.phase, .connected)
        XCTAssertEqual(reopened.revision, String(repeating: "b", count: 64))
    }

    func testFailureSurvivesSystemStopAndLateProgress() throws {
        let store = TunnelStartupDiagnosticsStore(root: root)
        let attempt = UUID()
        try store.begin(attemptID: attempt, revision: nil)
        XCTAssertTrue(try store.record(attemptID: attempt, phase: .starting))
        XCTAssertTrue(try store.record(attemptID: attempt, phase: .failed, error: ProfileStoreError.downloadFailed))
        XCTAssertFalse(try store.record(attemptID: attempt, phase: .stopped))
        XCTAssertFalse(try store.record(attemptID: attempt, phase: .starting))
        let persisted = try XCTUnwrap(store.load())
        XCTAssertEqual(persisted.phase, .failed)
        XCTAssertTrue(persisted.message.contains("下载"))
    }

    func testDiagnosticExcludesUntrustedErrorContentAndRevision() throws {
        let store = TunnelStartupDiagnosticsStore(root: root)
        let attempt = UUID()
        let secret = "https://user:password@example.invalid/config?token=secret"
        try store.begin(attemptID: attempt, revision: secret)
        let error = ProfileResourceError.httpStatus(kind: .geoSiteDat, name: secret, status: 403)
        XCTAssertTrue(try store.record(attemptID: attempt, phase: .failed, error: error))
        let record = try XCTUnwrap(store.load())
        XCTAssertNil(record.revision)
        XCTAssertTrue(record.message.contains("GeoSite.dat"))
        XCTAssertTrue(record.message.contains("403"))
        let data = try Data(contentsOf: root.appendingPathComponent("Library/Application Support/tunnel-startup.json"))
        XCTAssertLessThan(data.count, 1024)
        let text = String(decoding: data, as: UTF8.self)
        for token in ["password", "example.invalid", "token=secret"] { XCTAssertFalse(text.contains(token)) }

        let unknownAttempt = UUID()
        try store.begin(attemptID: unknownAttempt, revision: nil)
        let unknown = NSError(domain: secret, code: 7, userInfo: [NSLocalizedDescriptionKey: secret])
        XCTAssertTrue(try store.record(attemptID: unknownAttempt, phase: .failed, error: unknown))
        XCTAssertFalse(try XCTUnwrap(store.load()).message.contains(secret))
    }

    func testAtomicReadersAlwaysSeeACompleteRecord() async throws {
        let store = TunnelStartupDiagnosticsStore(root: root)
        XCTAssertNil(try store.load())
        try store.begin(attemptID: UUID(), revision: nil)
        let reader = TunnelStartupDiagnosticsStore(root: root)
        let writer = Task.detached {
            for _ in 0..<100 { try store.begin(attemptID: UUID(), revision: nil) }
        }
        for _ in 0..<200 {
            let record = try XCTUnwrap(reader.load())
            XCTAssertEqual(record.phase, .preparing)
            XCTAssertFalse(record.message.isEmpty)
        }
        try await writer.value
    }

    func testKnownCoreParseErrorKeepsOnlyItsFieldPath() {
        let message = "null is unsupported at lan-disallowed-ips"
        let error = NSError(domain: "go", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        XCTAssertEqual(TunnelStartupDiagnosticsStore.safeFailureMessage(error), message)
        for untrusted in [
            message + " https://example.invalid/?token=secret",
            message + "\npassword=secret",
            "null is unsupported at https://user:password@example.invalid",
        ] {
            let error = NSError(domain: "go", code: 1, userInfo: [NSLocalizedDescriptionKey: untrusted])
            let result = TunnelStartupDiagnosticsStore.safeFailureMessage(error)
            XCTAssertFalse(result.contains("secret"))
            XCTAssertFalse(result.contains("example.invalid"))
            XCTAssertTrue(result.contains("go"))
            XCTAssertTrue(result.contains("1"))
        }
    }

    func testKnownCoreResourceFailuresKeepSpecificCauseAndRedactPersistedDetails() throws {
        let privateDetails = "PrivateProvider https://user:password@example.invalid/resource?token=secret Authorization: Bearer private-header"
        let cases = [
            ("resource download proxy dependency cannot be prepared: proxy-provider \(privateDetails): invalid provider health-check options", "节点订阅健康检查设置无效。"),
            ("proxy-provider \(privateDetails): invalid provider health-check options", "节点订阅健康检查设置无效。"),
            ("resource download proxy dependency cannot be prepared: proxy-provider \(privateDetails): HTTP 503", "资源下载所需代理节点无法加载。"),
            ("rule-provider \(privateDetails) download failed: context deadline exceeded", "规则资源下载超时。"),
            ("rule-provider \(privateDetails) download failed: request timeout", "规则资源下载超时。"),
            ("resource download proxy dependency cannot be prepared: rule-provider \(privateDetails) download failed: context deadline exceeded", "规则资源下载超时。"),
        ]
        let store = TunnelStartupDiagnosticsStore(root: root)
        for (description, expected) in cases {
            let attempt = UUID()
            let error = NSError(domain: "go", code: 1, userInfo: [NSLocalizedDescriptionKey: description])
            XCTAssertEqual(TunnelStartupDiagnosticsStore.safeFailureMessage(error), expected)
            try store.begin(attemptID: attempt, revision: nil)
            XCTAssertTrue(try store.record(attemptID: attempt, phase: .failed, error: error))
            XCTAssertEqual(try store.load()?.message, expected)
            let persisted = String(decoding: try Data(contentsOf: root.appendingPathComponent("Library/Application Support/tunnel-startup.json")), as: UTF8.self)
            for secret in ["PrivateProvider", "example.invalid", "password", "token=secret", "Authorization", "private-header"] {
                XCTAssertFalse(persisted.contains(secret))
            }
        }
    }

    func testUnmatchedCoreResourceErrorsKeepGenericFailure() {
        for description in [
            "rule-provider private download failed: HTTP 503",
            "rule-provider timeout-name download failed: HTTP 503",
            "context deadline exceeded",
            "resource download failed: private details",
        ] {
            let error = NSError(domain: "go", code: 1, userInfo: [NSLocalizedDescriptionKey: description])
            XCTAssertEqual(TunnelStartupDiagnosticsStore.safeFailureMessage(error), "隧道启动失败（go，代码 1）。")
        }
    }

    func testResourceFailuresKeepTypeAndNetworkCauseWithoutPrivateFields() {
        let secret = "https://user:password@example.invalid/config?token=secret"
        let timeout = ProfileResourceError.downloadFailed(kind: .ruleProvider, name: secret, error: .transport(.timedOut))
        let message = TunnelStartupDiagnosticsStore.safeFailureMessage(timeout)
        XCTAssertTrue(message.contains("规则资源"))
        XCTAssertTrue(message.contains("超时"))
        XCTAssertFalse(message.contains(secret))
        let untrusted = ProfileResourceError.failed(kind: .proxyProvider, name: secret, reason: secret)
        XCTAssertEqual(TunnelStartupDiagnosticsStore.safeFailureMessage(untrusted), "节点资源准备失败。")
    }
}
