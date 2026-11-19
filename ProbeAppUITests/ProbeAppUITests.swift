import XCTest

final class ProbeAppUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testProfileSelectionSurvivesRelaunchWithoutStartingVPN() {
        let app = XCUIApplication()
        app.launch()
        openClientPage("profiles", in: app)
        let first = addDirectExample(in: app)
        let second = addDirectExample(in: app, previousID: first)
        XCTAssertNotEqual(first, second)
        let firstProfile = app.buttons[first]
        reveal(firstProfile, in: app)
        firstProfile.tap()
        XCTAssertTrue(waitUntil { firstProfile.exists && firstProfile.label.contains("已选择") })
        XCTAssertTrue(app.navigationBars["配置"].exists)
        let info = app.buttons["info-" + first.dropFirst("profile-".count)]
        reveal(info, in: app)
        info.tap()
        let select = app.buttons["选择此配置"]
        reveal(select, in: app)
        XCTAssertFalse(select.isEnabled)
        let selectedTitle = app.navigationBars.firstMatch.identifier

        app.terminate()
        app.launch()
        let current = app.buttons["home-current-profile"]
        scrollToClientControl(current, in: app)
        current.tap()
        let detail = app.navigationBars[selectedTitle]
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        XCTAssertTrue(select.exists)
        XCTAssertFalse(select.isEnabled)
        detail.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Catlash"].waitForExistence(timeout: 5))
        openClientPage("profiles", in: app)
        reveal(firstProfile, in: app)
        XCTAssertTrue(firstProfile.waitForExistence(timeout: 10))
        XCTAssertTrue(firstProfile.label.contains("已选择"), firstProfile.label)
        let secondProfile = app.buttons[second]
        reveal(secondProfile, in: app)
        XCTAssertTrue(secondProfile.exists)
        XCTAssertFalse(secondProfile.label.contains("已选择"), secondProfile.label)
        XCTAssertFalse(app.buttons["将选中配置保存为待应用快照"].exists)
        XCTAssertFalse(app.buttons["应用待应用快照（短暂重连）"].exists)
        openClientPage("diagnostics", in: app)
        XCTAssertFalse(app.buttons["保存为待应用快照"].exists)
        XCTAssertFalse(app.buttons["恢复最近成功快照"].exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "pendingRevision").firstMatch.exists)
        let probe = app.buttons["通过测试隧道查询 example.com"]
        reveal(probe, in: app)
        XCTAssertFalse(probe.isEnabled)
#if targetEnvironment(simulator)
        XCTAssertFalse(app.buttons["启动测试 VPN"].isEnabled)
#endif
    }

    func testYAMLProfileAndOfflineNodeSelectionSurviveRelaunch() {
        let app = XCUIApplication()
        app.launch()
        openClientPage("profiles", in: app)
        _ = addDirectExample(in: app)
        let nodesTab = app.tabBars.buttons["节点"]
        XCTAssertTrue(nodesTab.waitForExistence(timeout: 5))
        nodesTab.tap()
        XCTAssertTrue(app.navigationBars["节点"].exists)
        let defaultGroup = app.buttons["node-group-默认出口"]
        XCTAssertTrue(defaultGroup.waitForExistence(timeout: 5))
        XCTAssertEqual(defaultGroup.value as? String, "已收起")
        expandClientNodeGroup("默认出口", in: app)
        let reject = app.buttons["node-默认出口-REJECT"]
        XCTAssertTrue(reject.waitForExistence(timeout: 5))
        // Tap the trailing half of the row, just before the separate detail control.
        let row = app.cells.containing(.button, identifier: "node-默认出口-REJECT").firstMatch
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.5)).tap()
        XCTAssertTrue(waitUntil { reject.value as? String == "已选中" })
        let directInfo = app.buttons["node-info-默认出口-DIRECT"]
        directInfo.tap()
        XCTAssertTrue(app.navigationBars["DIRECT"].waitForExistence(timeout: 5))
        app.buttons["node-detail-close"].tap()
        XCTAssertTrue(waitUntil { !app.buttons["node-detail-close"].exists })
        XCTAssertTrue(waitUntil { reject.value as? String == "已选中" })
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "节点选择"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.terminate()
        app.launch()
        openClientPage("nodes", in: app)
        XCTAssertEqual(app.buttons["node-group-默认出口"].value as? String, "已收起")
        expandClientNodeGroup("默认出口", in: app)
        XCTAssertTrue(reject.waitForExistence(timeout: 10))
        XCTAssertEqual(reject.value as? String, "已选中")
        XCTAssertTrue(app.navigationBars["代理"].exists)
        XCTAssertTrue(app.buttons["close-proxies"].exists)
        openClientPage("diagnostics", in: app)
        let probe = app.buttons["通过测试隧道查询 example.com"]
        reveal(probe, in: app)
        XCTAssertFalse(probe.isEnabled)
#if targetEnvironment(simulator)
        XCTAssertFalse(app.buttons["启动测试 VPN"].isEnabled)
#endif
    }

    func testNamedNodeSelectionAndAutomaticGroupDetails() {
        let app = XCUIApplication()
        app.launch()
        openClientPage("profiles", in: app)
        app.buttons["添加配置"].tap()
        app.buttons["粘贴 YAML"].firstMatch.tap()
        let editor = app.textViews["yamlEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText("""
        proxies:
          - {name: Tokyo, type: socks5, server: 192.0.2.1, port: 1080}
          - {name: Osaka, type: socks5, server: 192.0.2.2, port: 1080}
        proxy-groups:
          - {name: Manual, type: select, proxies: [Tokyo, Osaka]}
          - {name: Auto, type: url-test, proxies: [Tokyo, Osaka], url: https://example.com/, interval: 300}
        rules:
          - MATCH,Manual
        """)
        app.buttons["保存"].tap()
        XCTAssertTrue(app.navigationBars["配置"].waitForExistence(timeout: 10))
        openClientPage("nodes", in: app)
        XCTAssertFalse(app.buttons["strategyGroups"].exists)
        XCTAssertFalse(app.buttons["nodes-test-all"].isEnabled)

        let manual = app.buttons["node-group-Manual"]
        let automatic = app.buttons["node-group-Auto"]
        let osaka = app.buttons["node-Manual-Osaka"]
        let tokyo = app.buttons["node-Manual-Tokyo"]
        XCTAssertTrue(manual.waitForExistence(timeout: 5))
        XCTAssertEqual(manual.value as? String, "已收起")
        XCTAssertEqual(automatic.value as? String, "已收起")
        XCTAssertFalse(osaka.exists)
        XCTAssertFalse(tokyo.exists)
        XCTAssertEqual(app.buttons["nodes-toggle-all"].label, "全部展开")

        let initialSearch = app.textFields["nodes-search"]
        initialSearch.tap()
        initialSearch.typeText("Tokyo")
        XCTAssertTrue(waitUntil { tokyo.exists && manual.value as? String == "已展开" })
        app.buttons["清除搜索"].tap()
        XCTAssertTrue(waitUntil { manual.value as? String == "已收起" && automatic.value as? String == "已收起" && !tokyo.exists })
        expandClientNodeGroup("Manual", in: app)
        XCTAssertTrue(osaka.waitForExistence(timeout: 5))
        // The trailing blank area belongs to selection; the info button is separate.
        osaka.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
        XCTAssertTrue(waitUntil { osaka.value as? String == "已选中" })

        manual.tap()
        XCTAssertTrue(waitUntil { manual.value as? String == "已收起" && !osaka.exists })
        manual.tap()
        XCTAssertTrue(waitUntil { manual.value as? String == "已展开" && osaka.exists })
        app.buttons["nodes-toggle-all"].tap()
        XCTAssertTrue(waitUntil { manual.value as? String == "已收起" && automatic.value as? String == "已收起" })
        app.buttons["nodes-toggle-all"].tap()
        XCTAssertTrue(waitUntil { manual.value as? String == "已展开" && automatic.value as? String == "已展开" })

        let search = app.textFields["nodes-search"]
        search.tap()
        search.typeText("Tokyo")
        XCTAssertTrue(waitUntil { tokyo.exists && !osaka.exists })
        let locate = app.buttons["locate-group-Manual"]
        XCTAssertTrue(locate.isEnabled)
        locate.tap()
        XCTAssertTrue(waitUntil { osaka.exists && osaka.isHittable && osaka.value as? String == "已选中" })
        XCTAssertNotEqual(search.value as? String, "Tokyo")

        app.buttons["proxy-delay-display-options"].tap()
        XCTAssertTrue(app.navigationBars["显示选项"].waitForExistence(timeout: 5))
        app.segmentedControls.buttons["名称"].tap()
        app.segmentedControls.buttons["紧凑"].tap()
        app.segmentedControls.buttons["显示"].tap()
        app.buttons["node-display-options-close"].tap()
        XCTAssertTrue(waitUntil { !app.buttons["node-display-options-close"].exists })
        XCTAssertTrue(waitUntil { osaka.value as? String == "已选中" })
        XCTAssertLessThan(osaka.frame.minY, tokyo.frame.minY)
        app.buttons["proxy-delay-display-options"].tap()
        XCTAssertTrue(app.segmentedControls.buttons["名称"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.segmentedControls.buttons["名称"].isSelected)
        XCTAssertTrue(app.segmentedControls.buttons["紧凑"].isSelected)
        XCTAssertTrue(app.segmentedControls.buttons["显示"].isSelected)
        // Restore appearance preferences so later tests do not inherit this scenario.
        app.segmentedControls.buttons["默认"].tap()
        app.segmentedControls.buttons["标准"].tap()
        app.segmentedControls.buttons["关闭"].tap()
        app.buttons["node-display-options-close"].tap()

        let tokyoInfo = app.buttons["node-info-Manual-Tokyo"]
        scrollToClientControl(tokyoInfo, in: app)
        tokyoInfo.tap()
        XCTAssertTrue(app.navigationBars["Tokyo"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["使用此节点"].isEnabled)
        app.buttons["node-detail-close"].tap()
        XCTAssertTrue(waitUntil { !app.buttons["node-detail-close"].exists })
        XCTAssertTrue(waitUntil { osaka.value as? String == "已选中" })
        XCTAssertEqual(tokyo.value as? String, "未选中")

        XCTAssertFalse(app.buttons["node-Auto-Osaka"].exists)
        let autoDetails = app.buttons["node-info-Auto-Osaka"]
        scrollToClientControl(autoDetails, in: app)
        autoDetails.tap()
        XCTAssertTrue(app.navigationBars["Osaka"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["使用此节点"].exists)
        app.buttons["node-detail-close"].tap()
        XCTAssertTrue(waitUntil { !app.buttons["node-detail-close"].exists })
        scrollToClientControl(tokyo, in: app)
        tokyo.tap()
        XCTAssertTrue(waitUntil { tokyo.value as? String == "已选中" })
        app.buttons["close-proxies"].tap()
        XCTAssertTrue(waitUntil { !app.buttons["close-proxies"].exists })
        XCTAssertTrue(app.buttons["home-nodes"].exists)
        openClientPage("nodes", in: app)
        XCTAssertEqual(app.buttons["node-group-Manual"].value as? String, "已收起")
        expandClientNodeGroup("Manual", in: app)
        XCTAssertTrue(waitUntil { tokyo.value as? String == "已选中" })
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "命名节点切换"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func addDirectExample(in app: XCUIApplication, previousID: String? = nil) -> String {
        let selected = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "profile-", "已选择")).firstMatch
        let previous = previousID ?? (selected.exists ? selected.identifier : nil)
        let example = app.buttons["addDirectExample"]
        reveal(example, in: app)
        XCTAssertTrue(example.isEnabled)
        example.tap()
        XCTAssertTrue(waitUntil { selected.exists && selected.identifier != previous })
        return selected.identifier
    }

    private func waitUntil(_ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        scrollToClientControl(element, in: app)
    }
}
