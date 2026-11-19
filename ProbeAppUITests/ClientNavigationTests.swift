import XCTest

final class ClientNavigationTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testHomeExitIPDoesNotInventDisconnectedData() {
        let app = XCUIApplication()
        app.launch()
        let ip = app.staticTexts["home-exit-ip"]
        XCTAssertTrue(ip.waitForExistence(timeout: 15))
        XCTAssertEqual(ip.label, "连接后检测 IP")
        XCTAssertEqual(app.staticTexts["home-ip-organization"].label, "—")
        XCTAssertEqual(app.staticTexts["home-ip-quality"].label, "质量 未知")
        XCTAssertFalse(app.buttons["home-ip-refresh"].isEnabled)
        app.buttons["home-ip-details"].tap()
        XCTAssertTrue(app.navigationBars["出口 IP 与质量"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["连接后可检测出口 IP。"].exists)
        XCTAssertFalse(app.buttons["ip-quality-refresh"].isEnabled)
        let hideIP = app.switches["hide-exit-ip"]
        XCTAssertTrue(hideIP.exists)
        let original = hideIP.value as? String
        hideIP.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let changed = hideIP.value as? String
        XCTAssertNotEqual(changed, original)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["home-ip-details"].waitForExistence(timeout: 15))
        app.buttons["home-ip-details"].tap()
        XCTAssertTrue(hideIP.waitForExistence(timeout: 5))
        XCTAssertEqual(hideIP.value as? String, changed)
        hideIP.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(hideIP.value as? String, original)
        capture(app, name: "出口 IP 未连接状态")
        app.buttons["完成"].tap()
        capture(app, name: "新版首页状态卡")
    }

    func testHomeScrollReachesProfileLibrary() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["home-connect"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.navigationBars["Catlash"].exists)

        let homeScroll = app.scrollViews.containing(.button, identifier: "home-connect").firstMatch
        XCTAssertTrue(homeScroll.exists, "首页连接按钮应位于纵向 ScrollView 中")
        let profiles = homeScroll.buttons["home-profiles"]
        XCTAssertTrue(profiles.exists)
        XCTAssertFalse(profiles.isHittable, "本回归需要当前配置入口位于首屏之外")
        capture(app, name: "首页滚动前")

        // Swipe the actual home scroll container. Tapping an offscreen element
        // could let XCTest reveal it automatically and hide this regression.
        for _ in 0..<4 {
            homeScroll.swipeUp(velocity: .slow)
            if profiles.isHittable { break }
        }
        XCTAssertTrue(profiles.isHittable, "首页上滑后应能触及当前配置入口")
        capture(app, name: "首页滚动后可见配置入口")
        profiles.tap()
        XCTAssertTrue(app.navigationBars["配置"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["添加配置"].exists)
        capture(app, name: "从首页滚动进入配置库")
    }

    func testHomeModeButtonsRequireAnActiveYAMLSession() {
        let app = XCUIApplication()
        app.launch()
        for mode in ["rule", "global", "direct"] {
            let button = app.buttons["home-mode-" + mode]
            XCTAssertTrue(button.waitForExistence(timeout: 15))
            XCTAssertFalse(button.isEnabled)
        }
        XCTAssertTrue(app.navigationBars["Catlash"].exists)
        XCTAssertTrue(app.staticTexts["连接 YAML 配置后可切换模式"].exists)
    }

    func testToolsAndMoreDetailsReturnToTheirTabs() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["home-connect"].waitForExistence(timeout: 15))
        capture(app, name: "首页")
        app.tabBars.buttons["工具"].tap()
        capture(app, name: "工具")
        for (entry, title) in [
            ("activity", "活动"), ("quality", "网络质量"), ("stun", "STUN 与 NAT"),
            ("dns", "DNS 查询"), ("sharing", "代理共享"), ("runtime", "运行状况"),
            ("resources", "外部资源"), ("reports", "诊断收件箱"),
        ] {
            let link = app.buttons["tools-" + entry]
            scrollToClientControl(link, in: app)
            link.tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
            capture(app, name: title)
            app.navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(app.navigationBars["工具"].exists)
        }
        app.tabBars.buttons["更多"].tap()
        capture(app, name: "更多")
        for (entry, title) in [
            ("ondemand", "按需连接"), ("vpn", "VPN"), ("client", "客户端设置"),
            ("appearance", "外观"), ("cloud", "iCloud 同步"), ("geo", "Geo 资源"),
            ("storage", "存储空间"), ("about", "关于 Catlash"),
        ] {
            let link = app.buttons["more-" + entry]
            scrollToClientControl(link, in: app)
            link.tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
            capture(app, name: title)
            app.navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(app.navigationBars["更多"].exists)
        }
    }

    func testAppearanceSurvivesRelaunch() {
        let app = XCUIApplication()
        app.launch()
        openAppearance(in: app)
        app.buttons["appearance-dark"].tap()
        app.buttons["appearance-accent-teal"].tap()
        app.terminate()
        app.launch()
        openAppearance(in: app)
        XCTAssertTrue(app.buttons["appearance-dark"].isSelected)
        XCTAssertTrue(app.buttons["appearance-accent-teal"].isSelected)
        capture(app, name: "深色外观")
        app.buttons["appearance-system"].tap()
        app.buttons["appearance-accent-blue"].tap()
    }

    func testDiagnosticsGeneratesAnActualReport() {
        let app = XCUIApplication()
        app.launch()
        app.tabBars.buttons["工具"].tap()
        let reports = app.buttons["tools-reports"]
        scrollToClientControl(reports, in: app)
        reports.tap()
        app.buttons["generate-diagnostic-report"].tap()
        let report = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "diagnostic-report-")).firstMatch
        XCTAssertTrue(report.waitForExistence(timeout: 10))
        report.tap()
        XCTAssertTrue(app.buttons["export-diagnostic-report"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "模拟器")).firstMatch.exists)
        capture(app, name: "诊断报告详情")
    }

    func testActivityShowsDisconnectedStateWithoutInventingRuntimeData() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["home-upload-total"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["home-upload-total"].value as? String, "未采集")
        XCTAssertEqual(app.staticTexts["home-download-total"].value as? String, "未采集")
        XCTAssertTrue(app.tabBars.buttons["工具"].waitForExistence(timeout: 15))
        app.tabBars.buttons["工具"].tap()
        app.buttons["tools-activity"].tap()
        XCTAssertTrue(app.staticTexts["runtime-status"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["runtime-status"].label.contains("连接 VPN"))
        app.segmentedControls["activity-sections"].buttons["日志"].tap()
        XCTAssertTrue(app.staticTexts["尚无运行日志"].exists)
        XCTAssertFalse(app.buttons["runtime-export-logs"].isEnabled)
        app.segmentedControls["activity-sections"].buttons["请求"].tap()
        XCTAssertTrue(app.staticTexts["尚无请求记录"].exists)
    }

    private func openAppearance(in app: XCUIApplication) {
        XCTAssertTrue(app.tabBars.buttons["更多"].waitForExistence(timeout: 15))
        app.tabBars.buttons["更多"].tap()
        let appearance = app.buttons["more-appearance"]
        scrollToClientControl(appearance, in: app)
        appearance.tap()
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
