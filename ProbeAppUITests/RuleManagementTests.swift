import XCTest

final class RuleManagementTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testRuleEditingPersistsAndRuntimePagesHandleDisconnectedState() {
        let app = XCUIApplication()
        app.launch()
        openClientPage("profiles", in: app)
        app.buttons["添加配置"].tap()
        app.buttons["粘贴 YAML"].firstMatch.tap()
        let editor = app.textViews["yamlEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText("""
        # Rule editor regression
        proxy-groups:
          - {name: Manual, type: select, proxies: [DIRECT, REJECT]}
        rules:
          - DOMAIN,original.example,DIRECT
          - DOMAIN,other.example,DIRECT
          - MATCH,Manual
        """)
        app.buttons["保存"].tap()
        XCTAssertTrue(app.navigationBars["配置"].waitForExistence(timeout: 10))
        openClientPage("rules", in: app)
        let direct = app.buttons["rule-group-DIRECT"]
        let manual = app.buttons["rule-group-Manual"]
        XCTAssertTrue(direct.waitForExistence(timeout: 5))
        XCTAssertTrue(manual.exists)
        XCTAssertLessThan(direct.frame.minY, manual.frame.minY)
        XCTAssertEqual(direct.value as? String, "2 条规则，已收起")
        XCTAssertFalse(app.buttons["rule-row-0"].exists)
        direct.tap()
        let original = app.buttons["rule-row-0"]
        XCTAssertTrue(original.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["rule-row-2"].exists)
        original.tap()
        let condition = app.textFields["rule-editor-condition"]
        XCTAssertTrue(condition.waitForExistence(timeout: 5))
        XCTAssertEqual(condition.value as? String, "original.example")
        app.buttons["rule-editor-cancel"].tap()
        direct.tap()
        XCTAssertFalse(original.exists)
        app.buttons["rules-add"].tap()
        let rule = app.textFields["rule-editor-condition"]
        XCTAssertTrue(rule.waitForExistence(timeout: 5))
        rule.tap()
        rule.typeText("added.example")
        app.buttons["rule-editor-target"].tap()
        app.buttons["REJECT"].firstMatch.tap()
        app.buttons["rule-editor-save"].tap()
        XCTAssertTrue(app.buttons["rules-save"].waitForExistence(timeout: 5))
        app.buttons["rules-save"].tap()
        let saved = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == false"), object: app.buttons["rules-save"])
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 10), .completed)

        app.terminate()
        app.launch()
        openClientPage("rules", in: app)
        let search = app.searchFields.firstMatch.exists ? app.searchFields.firstMatch : app.textFields["rules-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("added.example")
        let result = app.buttons["rule-row-2"]
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["rule-group-REJECT"].exists)
        result.tap()
        XCTAssertTrue(condition.waitForExistence(timeout: 5))
        XCTAssertEqual(condition.value as? String, "added.example")
        app.buttons["rule-editor-cancel"].tap()
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "已保存规则搜索"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
        app.launch()
        openClientPage("effective-configuration", in: app)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "effective-configuration-offline").firstMatch.waitForExistence(timeout: 5))
        app.tabBars.buttons["工具"].tap()
        let resources = app.buttons["tools-resources"]
        scrollToClientControl(resources, in: app)
        resources.tap()
        XCTAssertTrue(app.staticTexts["remote-resources-offline"].waitForExistence(timeout: 5))
    }
}
