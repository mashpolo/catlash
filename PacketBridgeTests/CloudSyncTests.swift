import Foundation
import XCTest
@testable import PacketBridge

final class CloudSyncTests: XCTestCase {
    func testInitialUploadDownloadPreserveOriginalBytesAndNames() async throws {
        let fixture = try CloudFixture()
        let local = Data("# local comment\nproxies: []\nunknown: 'verbatim'\n".utf8)
        let remote = Data("# remote comment\r\nproxies: []\r\n".utf8)
        try fixture.put(local, "local.yaml", in: fixture.local)
        try fixture.put(remote, "remote.yml", in: fixture.remote)
        let report = try await fixture.engine().synchronize()
        XCTAssertEqual(report.files.count, 2)
        XCTAssertEqual(try fixture.read("local.yaml", in: fixture.remote), local)
        XCTAssertEqual(try fixture.read("remote.yml", in: fixture.local), remote)
        let second = try await fixture.engine().synchronize()
        XCTAssertTrue(second.files.allSatisfy { $0.status == .identical })
    }

    func testBaselineAllowsOneSidedChangesAndBacksUpReplacedBytes() async throws {
        let fixture = try CloudFixture()
        let first = fixture.valid("first")
        try fixture.put(first, in: fixture.local)
        _ = try await fixture.engine().synchronize()
        let second = fixture.valid("second")
        try fixture.put(second, in: fixture.local)
        let upload = try await fixture.engine().synchronize()
        XCTAssertEqual(upload.files.first?.status, .uploaded)
        XCTAssertEqual(try fixture.read(in: fixture.remote), second)
        let third = fixture.valid("third")
        try fixture.put(third, in: fixture.remote)
        let download = try await fixture.engine().synchronize()
        XCTAssertEqual(download.files.first?.status, .downloaded)
        XCTAssertEqual(try fixture.read(in: fixture.local), third)
        let backups = try fixture.backupContents()
        XCTAssertTrue(backups.contains(first))
        XCTAssertTrue(backups.contains(second))
    }

    func testConflictRequiresCurrentBothHashesAndResolutionBacksUpLoser() async throws {
        let fixture = try CloudFixture()
        try fixture.put(fixture.valid("base"), in: fixture.local)
        _ = try await fixture.engine().synchronize()
        let local = fixture.valid("local")
        let remote = fixture.valid("remote")
        try fixture.put(local, in: fixture.local)
        try fixture.put(remote, in: fixture.remote)
        let engine = fixture.engine()
        let report = try await engine.synchronize()
        guard case .conflict(let conflict) = try XCTUnwrap(report.files.first?.status) else {
            return XCTFail("Expected content conflict")
        }
        XCTAssertEqual(conflict.localData, local)
        XCTAssertEqual(conflict.remoteData, remote)
        let newer = fixture.valid("new remote")
        try fixture.put(newer, in: fixture.remote)
        do {
            _ = try await engine.resolve(file: "profile.yaml", choice: .local,
                                         expectedL: conflict.localHash, expectedR: conflict.remoteHash)
            XCTFail("Stale conflict must not overwrite new edit")
        } catch YAMLSyncError.staleConflict {}
        XCTAssertEqual(try fixture.read(in: fixture.remote), newer)
        guard case .conflict(let current) = try await engine.synchronize().files.first?.status else {
            return XCTFail("Expected refreshed conflict")
        }
        let result = try await engine.resolve(file: "profile.yaml", choice: .remote,
                                              expectedL: current.localHash, expectedR: current.remoteHash)
        XCTAssertEqual(result.status, .downloaded)
        XCTAssertEqual(try fixture.read(in: fixture.local), newer)
        XCTAssertTrue(try fixture.backupContents().contains(local))
    }

    func testLongYAMLFileNameCanUpdateAndPreserveBackup() async throws {
        let fixture = try CloudFixture()
        let name = String(repeating: "a", count: 200) + ".yaml"
        let initial = fixture.valid("original")
        try fixture.put(initial, name, in: fixture.remote)
        _ = try await fixture.engine().synchronize()
        let edited = fixture.valid("edited")
        try fixture.put(edited, name, in: fixture.remote)
        let report = try await fixture.engine().synchronize()
        XCTAssertEqual(report.files.first?.status, .downloaded)
        XCTAssertEqual(try fixture.read(name, in: fixture.local), edited)
        XCTAssertTrue(try fixture.backupContents().contains(initial))
    }

    func testRemoteDeletionBacksUpLocalAndAllowsRemoteRecreationAfterRestart() async throws {
        let fixture = try CloudFixture()
        let original = fixture.valid("original")
        try fixture.put(original, in: fixture.local)
        _ = try await fixture.engine().synchronize()
        try FileManager.default.removeItem(at: fixture.remote.appendingPathComponent("profile.yaml"))
        let removed = try await fixture.engine().synchronize()
        XCTAssertEqual(removed.files.first?.status, .deletedLocally)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.local.appendingPathComponent("profile.yaml").path))
        XCTAssertTrue((try? fixture.backupContents())?.contains(original) == true)
        let empty = try await fixture.engine().synchronize()
        XCTAssertTrue(empty.files.isEmpty)
        let recreated = fixture.valid("new remote file with the same name")
        try fixture.put(recreated, in: fixture.remote)
        let download = try await fixture.engine().synchronize()
        XCTAssertEqual(download.files.first?.status, .downloaded)
        XCTAssertEqual(try fixture.read(in: fixture.local), recreated)
    }

    func testDeletingOnlyLocalRetainsRemoteAndDoesNotReimportOnRestart() async throws {
        let fixture = try CloudFixture()
        let original = fixture.valid("original")
        try fixture.put(original, in: fixture.remote)
        _ = try await fixture.engine().synchronize()
        try FileManager.default.removeItem(at: fixture.local.appendingPathComponent("profile.yaml"))
        let report = try await fixture.engine().synchronize()
        XCTAssertEqual(report.files.first?.status, .missing)
        XCTAssertEqual(try fixture.read(in: fixture.remote), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.local.appendingPathComponent("profile.yaml").path))
    }

    func testRemoteDeletionWithLocalEditRequiresChoiceEvenAfterRestart() async throws {
        for choice in [YAMLConflictChoice.local, .remote] {
            let fixture = try CloudFixture()
            let remote = fixture.remote.appendingPathComponent("profile.yaml")
            try fixture.put(fixture.valid("base"), in: fixture.remote)
            _ = try await fixture.engine().synchronize()
            let edited = fixture.valid("local edit")
            try fixture.put(edited, in: fixture.local)
            try FileManager.default.removeItem(at: remote)
            guard case .remoteDeletionConflict(let hash) = try await fixture.engine().synchronize().files.first?.status else {
                return XCTFail("A locally edited file must survive remote deletion")
            }
            let restarted = fixture.engine()
            let report = try await restarted.synchronize()
            XCTAssertEqual(report.files.first?.status, .remoteDeletionConflict(localHash: hash))
            XCTAssertEqual(try fixture.read(in: fixture.local), edited)
            XCTAssertFalse(FileManager.default.fileExists(atPath: remote.path))

            let changed = fixture.valid("another edit before resolving")
            try fixture.put(changed, in: fixture.local)
            do {
                _ = try await restarted.resolveRemoteDeletion(file: "profile.yaml", choice: choice, expectedLocalHash: hash)
                XCTFail("A stale decision must preserve the newer local edit")
            } catch YAMLSyncError.staleConflict {}
            guard case .remoteDeletionConflict(let current) = try await restarted.synchronize().files.first?.status else {
                return XCTFail("The conflict must contain the new local hash")
            }
            let resolved = try await restarted.resolveRemoteDeletion(file: "profile.yaml", choice: choice, expectedLocalHash: current)
            if choice == .local {
                XCTAssertEqual(resolved.status, .uploaded)
                XCTAssertEqual(try fixture.read(in: fixture.remote), changed)
            } else {
                XCTAssertEqual(resolved.status, .deletedLocally)
                XCTAssertTrue(try fixture.backupContents().contains(changed))
                let empty = try await fixture.engine().synchronize()
                XCTAssertTrue(empty.files.isEmpty)
            }
        }
    }

    func testFailedBaselineCommitAfterLocalDeletionAllowsRecreatedRemoteFile() async throws {
        let fixture = try CloudFixture()
        let initial = fixture.valid("first remote")
        try fixture.put(initial, in: fixture.remote)
        _ = try await fixture.engine().synchronize()
        try FileManager.default.removeItem(at: fixture.remote.appendingPathComponent("profile.yaml"))
        let writes = CloudMutation()
        let interrupted = fixture.engine(persist: { data, url in
            if writes.next() == 2 { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: url, options: .atomic)
        })
        do {
            _ = try await interrupted.synchronize()
            XCTFail("Failure to commit the new baseline must surface")
        } catch let error as CocoaError {
            XCTAssertEqual(error.code, .fileWriteUnknown)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.local.appendingPathComponent("profile.yaml").path))
        XCTAssertTrue(try fixture.backupContents().contains(initial))
        let recreated = fixture.valid("second remote")
        try fixture.put(recreated, in: fixture.remote)
        let recovered = try await fixture.engine().synchronize()
        XCTAssertEqual(recovered.files.first?.status, .downloaded)
        XCTAssertEqual(try fixture.read(in: fixture.local), recreated)
    }

    func testDeletionRechecksRemoteAndLocalInsideCoordination() async throws {
        let fixture = try CloudFixture()
        let original = fixture.valid("original")
        try fixture.put(original, in: fixture.remote)
        _ = try await fixture.engine().synchronize()
        let remote = fixture.remote.appendingPathComponent("profile.yaml")
        let local = fixture.local.appendingPathComponent("profile.yaml")
        let changed = fixture.valid("concurrent edit")
        try FileManager.default.removeItem(at: remote)
        for target in [remote, local] {
            let reads = CloudMutation()
            let engine = fixture.engine(versions: { url in
                if url == target, reads.next() == 2 { try changed.write(to: url, options: .atomic) }
                return []
            })
            guard case .failed = try await engine.synchronize().files.first?.status else {
                return XCTFail("File changed before coordinated deletion")
            }
            XCTAssertEqual(try Data(contentsOf: target), changed)
            if target == remote {
                XCTAssertEqual(try fixture.read(in: fixture.local), original)
                try FileManager.default.removeItem(at: remote)
            }
        }
    }

    func testMissingRemoteDirectoryAndCloudPlaceholderKeepSyncedLocal() async throws {
        let fixture = try CloudFixture()
        let original = fixture.valid("original")
        try fixture.put(original, in: fixture.remote)
        _ = try await fixture.engine().synchronize()
        let relocated = fixture.root.appendingPathComponent("offline-directory")
        try FileManager.default.moveItem(at: fixture.remote, to: relocated)
        do {
            _ = try await fixture.engine().synchronize()
            XCTFail("An unavailable bound folder cannot confirm deletion")
        } catch {}
        XCTAssertEqual(try fixture.read(in: fixture.local), original)
        try FileManager.default.moveItem(at: relocated, to: fixture.remote)
        try FileManager.default.removeItem(at: fixture.remote.appendingPathComponent("profile.yaml"))
        try fixture.put(Data(), ".profile.yaml.icloud", in: fixture.remote)
        let report = try await fixture.engine().synchronize()
        XCTAssertEqual(report.files.first?.status, .waitingDownload)
        XCTAssertEqual(try fixture.read(in: fixture.local), original)
    }

    func testInvalidRemoteDoesNotReplaceLocalOrBaselineAndOtherFilesContinue() async throws {
        let fixture = try CloudFixture()
        let good = fixture.valid("good")
        try fixture.put(good, in: fixture.local)
        _ = try await fixture.engine().synchronize()
        try fixture.put(Data("invalid".utf8), in: fixture.remote)
        try fixture.put(fixture.valid("other"), "other.yml", in: fixture.local)
        let report = try await fixture.engine().synchronize()
        guard case .failed = report.files.first(where: { $0.fileName == "profile.yaml" })?.status else {
            return XCTFail("Expected invalid YAML error")
        }
        XCTAssertEqual(try fixture.read(in: fixture.local), good)
        XCTAssertEqual(try fixture.read("other.yml", in: fixture.remote), fixture.valid("other"))
        try fixture.put(fixture.valid("recovered"), in: fixture.remote)
        let recovered = try await fixture.engine().synchronize()
        XCTAssertEqual(recovered.files.first(where: { $0.fileName == "profile.yaml" })?.status, .downloaded)
    }

    func testPlaceholderIsWaitingNotMissingAndNeverOverwritten() async throws {
        let fixture = try CloudFixture()
        try fixture.put(fixture.valid("local"), in: fixture.local)
        try fixture.put(Data(), in: fixture.remote)
        let remote = fixture.remote.appendingPathComponent("profile.yaml")
        let engine = fixture.engine(availability: { url in url == remote ? .waitingDownload : .available })
        let report = try await engine.synchronize()
        XCTAssertEqual(report.files.first?.status, .waitingDownload)
        XCTAssertEqual(try fixture.read(in: fixture.remote), Data())
    }

    func testProviderConflictsArePreservedAndBlockAutomaticWrites() async throws {
        let fixture = try CloudFixture()
        let local = fixture.valid("local")
        let remote = fixture.valid("remote")
        let unresolved = fixture.valid("unresolved")
        try fixture.put(local, in: fixture.local)
        try fixture.put(remote, in: fixture.remote)
        let remoteURL = fixture.remote.appendingPathComponent("profile.yaml")
        let engine = fixture.engine(versions: { url in
            url == remoteURL ? [YAMLConflictVersion(identifier: "test-version", modificationDate: nil, data: unresolved)] : []
        })
        let report = try await engine.synchronize()
        guard case .providerConflict(let versions) = report.files.first?.status else {
            return XCTFail("Expected provider conflict")
        }
        XCTAssertEqual(versions.first?.data, unresolved)
        XCTAssertNotNil(versions.first?.backupURL)
        XCTAssertEqual(try fixture.read(in: fixture.local), local)
        XCTAssertEqual(try fixture.read(in: fixture.remote), remote)
        XCTAssertTrue(try fixture.backupContents().contains(unresolved))
    }

    func testRestartConvergesAfterContentWriteBeforeBaselinePersist() async throws {
        let fixture = try CloudFixture()
        let content = fixture.valid("original")
        try fixture.put(content, in: fixture.local)
        let interrupted = fixture.engine(persist: { _, _ in throw CocoaError(.fileWriteUnknown) })
        do {
            _ = try await interrupted.synchronize()
            XCTFail("State persistence failure must surface")
        } catch {}
        XCTAssertEqual(try fixture.read(in: fixture.remote), content)
        let recovered = try await fixture.engine().synchronize()
        XCTAssertEqual(recovered.files.first?.status, .identical)
        let edited = fixture.valid("new edit")
        try fixture.put(edited, in: fixture.remote)
        let downloaded = try await fixture.engine().synchronize()
        XCTAssertEqual(downloaded.files.first?.status, .downloaded)
        XCTAssertEqual(try fixture.read(in: fixture.local), edited)
    }

    func testRestartDoesNotOverwriteNewEditWhenBaselineWasNeverPersisted() async throws {
        let fixture = try CloudFixture()
        try fixture.put(fixture.valid("original"), in: fixture.local)
        _ = try? await fixture.engine(persist: { _, _ in throw CocoaError(.fileWriteUnknown) }).synchronize()
        let remote = fixture.valid("new remote")
        try fixture.put(remote, in: fixture.remote)
        let report = try await fixture.engine().synchronize()
        guard case .conflict = report.files.first?.status else { return XCTFail("Must preserve ambiguous edits") }
        XCTAssertEqual(try fixture.read(in: fixture.remote), remote)
    }

    func testOnlyTopLevelYAMLRejectsSymlinksAndOversizedFiles() async throws {
        let fixture = try CloudFixture()
        try fixture.put(fixture.valid("ignored"), "ignored.txt", in: fixture.local)
        let nested = fixture.local.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try fixture.put(fixture.valid("nested"), "nested.yaml", in: nested)
        let external = fixture.root.appendingPathComponent("outside.yaml")
        try fixture.valid("outside").write(to: external)
        try FileManager.default.createSymbolicLink(at: fixture.local.appendingPathComponent("link.yaml"), withDestinationURL: external)
        try fixture.put(Data(repeating: 65, count: 16 * 1024 * 1024 + 1), "large.yaml", in: fixture.local)
        let report = try await fixture.engine().synchronize()
        XCTAssertEqual(Set(report.files.map(\.fileName)), ["link.yaml", "large.yaml"])
        XCTAssertTrue(report.files.allSatisfy { if case .failed = $0.status { return true }; return false })
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.remote.path).isEmpty)
    }

    func testCorruptStateAndBookmarkFailExplicitly() async throws {
        let fixture = try CloudFixture()
        try Data("broken".utf8).write(to: fixture.state.appendingPathComponent("baseline.json"))
        do {
            _ = try await fixture.engine().synchronize()
            XCTFail("Corrupt baseline cannot be treated as first sync")
        } catch YAMLSyncError.invalidState {}
        let bookmark = fixture.root.appendingPathComponent("directory.bookmark")
        try Data("broken".utf8).write(to: bookmark)
        XCTAssertThrowsError(try DirectoryBookmarkStore(bookmarkURL: bookmark).restore())
    }

    func testAutomaticUploadRechecksDestinationInsideCoordination() async throws {
        let fixture = try CloudFixture()
        try fixture.put(fixture.valid("base"), in: fixture.local)
        _ = try await fixture.engine().synchronize()
        try fixture.put(fixture.valid("local edit"), in: fixture.local)
        let remoteURL = fixture.remote.appendingPathComponent("profile.yaml")
        let intervening = fixture.valid("intervening remote edit")
        let mutation = CloudMutation()
        let engine = fixture.engine(versions: { url in
            if url == remoteURL, mutation.next() == 2 { try intervening.write(to: url, options: .atomic) }
            return []
        })
        let report = try await engine.synchronize()
        guard case .failed = report.files.first?.status else { return XCTFail("Changed destination must reject CAS") }
        XCTAssertEqual(try fixture.read(in: fixture.remote), intervening)
        guard case .conflict = try await fixture.engine().synchronize().files.first?.status else {
            return XCTFail("The next scan must show the current conflict")
        }
    }

    func testUnavailableProviderDoesNotTurnIntoInitialUpload() async throws {
        let fixture = try CloudFixture()
        try fixture.put(fixture.valid("local"), in: fixture.local)
        let remoteURL = fixture.remote.appendingPathComponent("profile.yaml")
        let report = try await fixture.engine(availability: { url in
            if url == remoteURL { throw YAMLSyncError.unavailable("offline") }
            return .available
        }).synchronize()
        guard case .failed = report.files.first?.status else { return XCTFail("Expected an availability error") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: remoteURL.path))
    }

    func testChoosingLocalPreservesRemoteBackupAndConcurrentScansConverge() async throws {
        let fixture = try CloudFixture()
        let local = fixture.valid("local")
        let remote = fixture.valid("remote")
        try fixture.put(local, in: fixture.local)
        try fixture.put(remote, in: fixture.remote)
        let engine = fixture.engine()
        guard case .conflict(let conflict) = try await engine.synchronize().files.first?.status else {
            return XCTFail("First sync cannot choose between different files")
        }
        let result = try await engine.resolve(file: "profile.yaml", choice: .local,
                                              expectedL: conflict.localHash, expectedR: conflict.remoteHash)
        XCTAssertEqual(result.status, .uploaded)
        XCTAssertTrue(try fixture.backupContents().contains(remote))
        try await withThrowingTaskGroup(of: YAMLSyncReport.self) { group in
            for _ in 0..<50 { group.addTask { try await engine.synchronize() } }
            for try await report in group { XCTAssertEqual(report.files.first?.status, .identical) }
        }
        XCTAssertEqual(try fixture.read(in: fixture.remote), local)
    }
}

private final class CloudMutation: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}

private final class CloudFixture: @unchecked Sendable {
    let root: URL
    let local: URL
    let remote: URL
    let state: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        local = root.appendingPathComponent("local")
        remote = root.appendingPathComponent("remote")
        state = root.appendingPathComponent("state")
        for directory in [local, remote, state] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    deinit { try? FileManager.default.removeItem(at: root) }
    func valid(_ marker: String) -> Data { Data("# \(marker)\nproxies: []\n".utf8) }
    func put(_ data: Data, _ name: String = "profile.yaml", in directory: URL) throws {
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }
    func read(_ name: String = "profile.yaml", in directory: URL) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(name))
    }
    func backupContents() throws -> [Data] {
        let directory = state.appendingPathComponent("backups")
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .map { try Data(contentsOf: $0) }
    }
    func engine(
        availability: @escaping @Sendable (URL) throws -> YAMLFileAvailability = { _ in .available },
        versions: @escaping @Sendable (URL) throws -> [YAMLConflictVersion] = { _ in [] },
        persist: @escaping @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }
    ) -> YAMLSyncEngine {
        YAMLSyncEngine(localDirectory: local, remoteDirectory: remote, stateDirectory: state,
                       validate: { data in
                           guard String(data: data, encoding: .utf8)?.contains("proxies:") == true else {
                               throw CocoaError(.fileReadCorruptFile)
                           }
                       }, availability: availability, versions: versions, persistState: persist)
    }
}
