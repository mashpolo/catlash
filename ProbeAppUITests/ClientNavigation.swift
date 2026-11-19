import XCTest

extension XCTestCase {
    func openClientPage(_ page: String, in app: XCUIApplication) {
        closeClientSheets(in: app)
        XCTAssertTrue(app.tabBars.buttons["首页"].waitForExistence(timeout: 15))
        app.tabBars.buttons["首页"].tap()
        for _ in 0..<8 {
            if app.buttons["home-profiles"].exists { break }
            let back = app.navigationBars.buttons.firstMatch
            guard back.exists else { break }
            back.tap()
        }
        let entry = app.buttons[page == "diagnostics" ? "home-recovery" : "home-" + page]
        scrollToClientControl(entry, in: app)
        entry.tap()
        let expected = ["profiles": "配置", "nodes": "代理", "cloud": "iCloud 同步", "diagnostics": "连接详情", "rules": "规则", "effective-configuration": "有效配置"][page]!
        XCTAssertTrue(app.navigationBars[expected].waitForExistence(timeout: 5), app.debugDescription)
        if page == "nodes" {
            XCTAssertTrue(app.buttons["close-proxies"].waitForExistence(timeout: 5))
        }
        if page == "diagnostics" {
            let diagnostics = app.buttons["基础连接诊断"]
            scrollToClientControl(diagnostics, in: app)
            diagnostics.tap()
        }
    }

    func expandClientNodeGroup(_ name: String, in app: XCUIApplication) {
        let group = app.buttons["node-group-" + name]
        scrollToClientControl(group, in: app)
        if group.value as? String == "已收起" { group.tap() }
        let expanded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "已展开"), object: group)
        XCTAssertEqual(XCTWaiter.wait(for: [expanded], timeout: 5), .completed)
    }

    func closeClientSheets(in app: XCUIApplication) {
        for identifier in ["node-detail-close", "node-display-options-close", "close-proxies"] {
            let close = app.buttons[identifier]
            if close.exists && close.isHittable {
                close.tap()
                let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: close)
                XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
            }
        }
    }

    func scrollToClientControl(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<12 {
            if element.exists, element.isHittable { return }
            let up = element.exists && element.frame.minY < 100
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.35 : 0.75))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.75 : 0.35))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTFail("Control is not visible: \(element.identifier)")
    }
}
