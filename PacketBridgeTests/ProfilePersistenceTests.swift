import Foundation
import XCTest
@testable import PacketBridge

final class ProfilePersistenceTests: XCTestCase {
    func testStoreSelectedUsesMihomoDefaultAndReadsExplicitFalse() throws {
        XCTAssertNotEqual(try YAMLDocument.validate(data: Data("mode: rule\n".utf8)).storeSelected, false)
        XCTAssertEqual(try YAMLDocument.validate(data: Data("profile: {store-selected: true}\n".utf8)).storeSelected, true)
        XCTAssertEqual(try YAMLDocument.validate(data: Data("profile: {store-selected: false}\n".utf8)).storeSelected, false)
    }

    func testInvalidStoreSelectedTypeIsNotTreatedAsEnabled() throws {
        XCTAssertThrowsError(try YAMLDocument.validate(data: Data("profile: {store-selected: later}\n".utf8)))
    }

    func testDisabledSelectionIsExcludedFromRuntimeSnapshotInput() throws {
        let choices = ["Proxy": "REJECT"]
        let disabled = try YAMLDocument.validate(data: Data("profile: {store-selected: false}\n".utf8))
        XCTAssertEqual(disabled.selectionsForStorage(choices), [:])
        let enabled = try YAMLDocument.validate(data: Data("profile: {store-selected: true}\n".utf8))
        XCTAssertEqual(enabled.selectionsForStorage(choices), choices)
    }
}
