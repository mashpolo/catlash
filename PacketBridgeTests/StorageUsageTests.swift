import Foundation
import XCTest
@testable import PacketBridge

final class StorageUsageTests: XCTestCase {
    func testSymbolicLinkRootPreservesCategoriesAndTotal() throws {
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? manager.removeItem(at: temporary) }
        let actual = temporary.appendingPathComponent("actual/deeper/NativeProfiles")
        let snapshots = temporary.appendingPathComponent("snapshots")
        let alias = temporary.appendingPathComponent("linkedRoot")
        let profiles = alias.appendingPathComponent("NativeProfiles")
        for (path, bytes) in [("yaml/test.yaml", 101), ("ResourceLinks/resource.bin", 202),
                              ("SyncState/backup/data", 303), ("index.json", 404)] {
            let file = actual.appendingPathComponent(path)
            try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 1, count: bytes).write(to: file)
        }
        try manager.createDirectory(at: snapshots, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 505).write(to: snapshots.appendingPathComponent("snapshot.json"))
        try manager.createSymbolicLink(at: alias, withDestinationURL: actual.deletingLastPathComponent())
        try manager.createSymbolicLink(at: actual.appendingPathComponent("yaml/linked-resource"),
                                       withDestinationURL: snapshots)

        let result = try StorageUsage.measure(profiles: profiles, snapshots: snapshots)
        XCTAssertEqual(result.sizes, [101, 202, 505, 303, 404])
        XCTAssertEqual(result.total, 1515)
        XCTAssertEqual(try StorageUsage.measure(profiles: actual, snapshots: snapshots).sizes, result.sizes)
    }
}
