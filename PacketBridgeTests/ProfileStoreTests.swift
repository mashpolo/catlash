import Foundation
import XCTest
@testable import PacketBridge

final class ProfileStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    func testImportPreservesBytesMetadataAndOverviewAfterReopen() async throws {
        let repository = ProfileRepository(root: root)
        let source = URL(string: "https://example.test/subscription?token=test-only")!
        let record = try await repository.importData(data: sampleYAML, name: "测试配置", sourceURL: source)
        XCTAssertTrue(record.id.hasSuffix(".yaml"))
        XCTAssertEqual(record.validationStatus, .pendingCoreValidation)
        XCTAssertEqual(record.overview?.proxyNames, ["sample"])
        XCTAssertEqual(record.overview?.proxyGroups.first?.members, ["sample", "DIRECT"])
        let reopened = ProfileRepository(root: root)
        let records = try await reopened.list()
        XCTAssertEqual(records, [record])
        XCTAssertEqual(records.first?.sourceURL, source)
        let bytes = try await reopened.data(id: record.id)
        XCTAssertEqual(bytes, sampleYAML)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("test-only"))
    }

    func testStaleRevisionCannotOverwriteAnExternalEdit() async throws {
        let repository = ProfileRepository(root: root)
        let record = try await repository.importData(data: sampleYAML, name: "Test")
        let external = Data("# remote edit\nmode: direct\n".utf8)
        try external.write(to: repository.yamlDirectory.appendingPathComponent(record.id), options: .atomic)
        await assertError(.staleRevision) {
            _ = try await repository.update(id: record.id, data: sampleYAML, expectedRevision: record.revisionSHA)
        }
        let bytes = try await repository.data(id: record.id)
        XCTAssertEqual(bytes, external)
    }

    func testInvalidYAMLDoesNotReplaceExistingFile() async throws {
        let repository = ProfileRepository(root: root)
        let record = try await repository.importData(data: sampleYAML, name: "Test")
        for invalid in [Data("proxies: [unterminated".utf8), Data("---\nmode: direct\n---\nmode: rule\n".utf8), Data("- sequence\n".utf8), Data([0xff, 0xfe])] {
            do {
                _ = try await repository.update(id: record.id, data: invalid, expectedRevision: record.revisionSHA)
                XCTFail("Invalid document was accepted")
            } catch {}
            let bytes = try await repository.data(id: record.id)
            XCTAssertEqual(bytes, sampleYAML)
        }
    }

    func testRenameAndDuplicateDoNotSerializeTheOriginalYAML() async throws {
        let repository = ProfileRepository(root: root)
        let record = try await repository.importData(data: sampleYAML, name: "Original")
        let renamed = try await repository.rename(id: record.id, name: "Renamed")
        XCTAssertEqual(renamed.id, record.id)
        XCTAssertEqual(renamed.revisionSHA, record.revisionSHA)
        let copy = try await repository.duplicate(id: record.id)
        XCTAssertNotEqual(copy.id, record.id)
        let originalBytes = try await repository.data(id: record.id)
        let copiedBytes = try await repository.data(id: copy.id)
        XCTAssertEqual(originalBytes, sampleYAML)
        XCTAssertEqual(copiedBytes, sampleYAML)
        try await repository.delete(id: copy.id, expectedRevision: copy.revisionSHA)
        let records = try await repository.list()
        XCTAssertEqual(records.map(\.id), [record.id])
    }

    func testRefreshDiscoversRemoteFilenameAndPreservesExistingMetadata() async throws {
        let repository = ProfileRepository(root: root)
        let existing = try await repository.importData(data: sampleYAML, name: "Local label", sourceURL: URL(string: "https://example.test/sub")!)
        let changed = Data("# changed outside\nmode: direct\n".utf8)
        try changed.write(to: repository.yamlDirectory.appendingPathComponent(existing.id), options: .atomic)
        try sampleYAML.write(to: repository.yamlDirectory.appendingPathComponent("1700000000000.yml"), options: .atomic)
        try Data("proxies: [".utf8).write(to: repository.yamlDirectory.appendingPathComponent("invalid.yaml"))
        let records = try await repository.refresh()
        let retained = try XCTUnwrap(records.first { $0.id == existing.id })
        XCTAssertEqual(retained.displayName, "Local label")
        XCTAssertEqual(retained.sourceURL, existing.sourceURL)
        XCTAssertNotEqual(retained.revisionSHA, existing.revisionSHA)
        XCTAssertTrue(records.contains { $0.id == "1700000000000.yml" })
        XCTAssertEqual(records.first { $0.id == "invalid.yaml" }?.validationStatus, .invalidYAML)
    }

    func testSymlinkNonYAMLAndTraversalAreRejected() async throws {
        let repository = ProfileRepository(root: root)
        _ = try await repository.importData(data: sampleYAML, name: "Safe")
        try sampleYAML.write(to: root.appendingPathComponent("outside.yaml"))
        try FileManager.default.createSymbolicLink(at: repository.yamlDirectory.appendingPathComponent("linked.yaml"), withDestinationURL: root.appendingPathComponent("outside.yaml"))
        try sampleYAML.write(to: repository.yamlDirectory.appendingPathComponent("ignored.txt"))
        let records = try await repository.refresh()
        XCTAssertEqual(records.count, 1)
        await assertError(.unsafeFile) { _ = try await repository.data(id: "linked.yaml") }
        for invalid in ["../outside.yaml", "/outside.yaml", "ignored.txt", "folder/file.yaml", "folder\\file.yaml"] {
            await assertError(.invalidProfileID) { _ = try await repository.data(id: invalid) }
        }
    }

    func testDownloadCandidateNeverReplacesTheProfile() async throws {
        let candidate = Data("# downloaded\nmode: rule\n".utf8)
        let downloader = StubProfileDownloader { _, maximum in
            XCTAssertEqual(maximum, 16 * 1024 * 1024)
            return candidate
        }
        let repository = ProfileRepository(root: root, downloader: downloader)
        let record = try await repository.importData(data: sampleYAML, name: "Subscription", sourceURL: URL(string: "https://example.test/sub")!)
        let fetched = try await repository.fetchSubscriptionCandidate(id: record.id, expectedRevision: record.revisionSHA)
        XCTAssertEqual(fetched, candidate)
        let unchanged = try await repository.data(id: record.id)
        XCTAssertEqual(unchanged, sampleYAML)
        let updated = try await repository.update(id: record.id, data: fetched, expectedRevision: record.revisionSHA)
        XCTAssertNotEqual(updated.revisionSHA, record.revisionSHA)
    }

    func testOversizedAndFailedDownloadsKeepTheProfile() async throws {
        let original = ProfileRepository(root: root)
        let record = try await original.importData(data: sampleYAML, name: "Subscription", sourceURL: URL(string: "https://example.test/sub")!)
        let cases: [(StubProfileDownloader, ProfileStoreError)] = [
            (StubProfileDownloader { _, maximum in Data(repeating: 32, count: maximum + 1) }, .tooLarge),
            (StubProfileDownloader { _, _ in throw ProfileStoreError.httpStatus(503) }, .httpStatus(503)),
            (StubProfileDownloader { _, _ in Data("items: [".utf8) }, .invalidYAML),
        ]
        for (downloader, expected) in cases {
            let repository = ProfileRepository(root: root, downloader: downloader)
            await assertError(expected) {
                _ = try await repository.fetchSubscriptionCandidate(id: record.id, expectedRevision: record.revisionSHA)
            }
            let bytes = try await repository.data(id: record.id)
            XCTAssertEqual(bytes, sampleYAML)
        }
    }

    func testEditDuringDownloadInvalidatesCandidate() async throws {
        let began = expectation(description: "download began")
        let gate = GatedProfileDownloader(onStart: { began.fulfill() })
        let repository = ProfileRepository(root: root, downloader: gate)
        let record = try await repository.importData(data: sampleYAML, name: "Subscription", sourceURL: URL(string: "https://example.test/sub")!)
        let fetching = Task { try await repository.fetchSubscriptionCandidate(id: record.id, expectedRevision: record.revisionSHA) }
        await fulfillment(of: [began], timeout: 2)
        let local = Data("# local edit\nmode: direct\n".utf8)
        _ = try await repository.update(id: record.id, data: local, expectedRevision: record.revisionSHA)
        await gate.finish(sampleYAML)
        await assertError(.staleRevision) { _ = try await fetching.value }
        let bytes = try await repository.data(id: record.id)
        XCTAssertEqual(bytes, local)
    }

    func testInvalidSubscriptionSchemeNeverInvokesDownloader() async {
        let downloader = StubProfileDownloader { _, _ in
            XCTFail("Invalid URL reached downloader")
            return Data()
        }
        let repository = ProfileRepository(root: root, downloader: downloader)
        await assertError(.invalidSourceURL) { _ = try await repository.fetchCandidate(from: URL(fileURLWithPath: "/tmp/private.yaml")) }
    }

    private func assertError(_ expected: ProfileStoreError, operation: () async throws -> Void) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)")
        } catch {
            XCTAssertEqual(error as? ProfileStoreError, expected)
        }
    }
}

private let sampleYAML = Data("""
# keep this comment and key order
x-custom: retained
proxies:
  - name: sample
    type: socks5
    server: 127.0.0.1
    port: 1080
proxy-groups:
  - name: Proxy
    type: select
    proxies: [sample, DIRECT]
rules:
  - MATCH,Proxy

""".utf8)

private struct StubProfileDownloader: ProfileDownloader {
    let operation: @Sendable (URL, Int) async throws -> Data
    init(_ operation: @escaping @Sendable (URL, Int) async throws -> Data) { self.operation = operation }
    func download(from url: URL, maximumBytes: Int) async throws -> Data {
        try await operation(url, maximumBytes)
    }
}

private actor GatedProfileDownloader: ProfileDownloader {
    let onStart: @Sendable () -> Void
    private var continuation: CheckedContinuation<Data, Error>?
    init(onStart: @escaping @Sendable () -> Void) { self.onStart = onStart }
    func download(from url: URL, maximumBytes: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            onStart()
        }
    }
    func finish(_ data: Data) {
        continuation?.resume(returning: data)
        continuation = nil
    }
}
