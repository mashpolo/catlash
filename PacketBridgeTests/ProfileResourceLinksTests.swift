import Foundation
import XCTest
@testable import PacketBridge

final class ProfileResourceLinksTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }

    func testLocalResourceHistorySurvivesRemovingTheLastAssociation() async throws {
        let store = ProfileResourceLinks(root: root)
        _ = try await store.list(profileID: "profile.yaml")
        let untouched = try await store.hasLocalResourceHistory(profileID: "profile.yaml")
        XCTAssertFalse(untouched, "Reading an unused profile must not mark it as having local resources")
        _ = try await store.associate(profileID: "profile.yaml", path: "GeoSite.dat", displayName: "local.dat", data: Data("local database".utf8))
        try await store.remove(profileID: "profile.yaml", path: "GeoSite.dat")
        let reopened = ProfileResourceLinks(root: root)
        let files = try await reopened.localFiles(profileID: "profile.yaml")
        XCTAssertTrue(files.isEmpty)
        let removed = try await reopened.hasLocalResourceHistory(profileID: "profile.yaml")
        XCTAssertTrue(removed, "An empty legacy manifest must still prevent reuse of its old local files")
        let other = try await reopened.hasLocalResourceHistory(profileID: "other.yaml")
        XCTAssertFalse(other)
    }

    func testChosenResourceReopensWithoutFollowingYAMLPath() async throws {
        let store = ProfileResourceLinks(root: root)
        let data = Data("payload: [example.com]\n".utf8)
        let link = try await store.associate(profileID: "profile.yaml", path: "../../private/provider.yaml", displayName: "chosen.yaml", data: data)
        let reopened = ProfileResourceLinks(root: root)
        let listing = try await reopened.list(profileID: "profile.yaml")
        let files = try await reopened.localFiles(profileID: "profile.yaml")
        XCTAssertEqual(listing, [link])
        XCTAssertEqual(files, ["../../private/provider.yaml": data])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("private").path))
    }

    func testProfilesKeepIndependentLinksAcrossCopyReplacementAndDelete() async throws {
        let store = ProfileResourceLinks(root: root)
        let original = Data("original".utf8)
        _ = try await store.associate(profileID: "one.yaml", path: "rules", displayName: "one", data: original)
        try await store.copy(from: "one.yaml", to: "two.yaml")
        _ = try await store.associate(profileID: "one.yaml", path: "rules", displayName: "new", data: Data("new".utf8))
        let copied = try await store.localFiles(profileID: "two.yaml")
        XCTAssertEqual(copied["rules"], original)
        try await store.delete(profileID: "one.yaml")
        let deleted = try await store.list(profileID: "one.yaml")
        XCTAssertTrue(deleted.isEmpty)
        let remaining = try await store.localFiles(profileID: "two.yaml")
        XCTAssertEqual(remaining["rules"], original)
        try await store.remove(profileID: "two.yaml", path: "rules")
        let removed = try await store.localFiles(profileID: "two.yaml")
        XCTAssertTrue(removed.isEmpty)
    }

    func testOversizedReplacementPreservesPreviousAssociation() async throws {
        let store = ProfileResourceLinks(root: root)
        let original = Data("safe".utf8)
        _ = try await store.associate(profileID: "one.yaml", path: "rules", displayName: "one", data: original)
        do {
            _ = try await store.associate(profileID: "one.yaml", path: "rules", displayName: "too large", data: Data(repeating: 0, count: ResourceBundleStore.maximumResourceBytes + 1))
            XCTFail("Oversized data was accepted")
        } catch ResourceBundleError.resourceTooLarge { }
        let files = try await store.localFiles(profileID: "one.yaml")
        XCTAssertEqual(files["rules"], original)
    }

    func testTotalLimitPreservesExistingLinks() async throws {
        let store = ProfileResourceLinks(root: root)
        let data = Data(repeating: 1, count: ResourceBundleStore.maximumResourceBytes)
        for index in 0..<4 { _ = try await store.associate(profileID: "one.yaml", path: "\(index)", displayName: "resource", data: data) }
        do {
            _ = try await store.associate(profileID: "one.yaml", path: "fifth", displayName: "extra", data: Data([1]))
            XCTFail("Total limit was ignored")
        } catch ResourceBundleError.bundleTooLarge { }
        let links = try await store.list(profileID: "one.yaml")
        XCTAssertEqual(links.count, 4)
    }

    func testTamperedResourceIsNotReturned() async throws {
        let store = ProfileResourceLinks(root: root)
        let link = try await store.associate(profileID: "one.yaml", path: "rules", displayName: "one", data: Data("good".utf8))
        try Data("evil".utf8).write(to: root.appendingPathComponent("data").appendingPathComponent(link.sha256))
        do {
            _ = try await store.localFiles(profileID: "one.yaml")
            XCTFail("Corrupted content was returned")
        } catch ProfileResourceLinkError.corruptStorage { }
    }
}
