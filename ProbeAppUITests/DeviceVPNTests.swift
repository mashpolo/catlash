import XCTest

final class DeviceVPNTests: XCTestCase {
    func testManualCloudDirectoryAndBookmarkRestore() throws {
#if targetEnvironment(simulator)
        throw XCTSkip("Requires a physical iPhone, iCloud Drive, and manual directory selection.")
#else
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["首页"].waitForExistence(timeout: 15))
        openClientPage("cloud", in: app)
        let directory = app.staticTexts["FlClash-iOS-Device-Test-20261117"]
        if !directory.exists {
        app.buttons["选择同步文件夹"].tap()
            XCTAssertTrue(directory.waitForExistence(timeout: 240), "Select the dedicated iCloud Drive directory on the iPhone.")
        }
        let firstSync = app.buttons["开始首次同步"]
        let sync = app.buttons["立即同步"]
        XCTAssertTrue(waitUntil(timeout: 240) { firstSync.isEnabled || sync.isEnabled })
        let action = firstSync.exists ? firstSync : sync
        reveal(action, in: app)
        action.tap()
        if app.buttons["confirmFirstCloudSync"].waitForExistence(timeout: 2) { app.buttons["confirmFirstCloudSync"].tap() }
        XCTAssertTrue(app.staticTexts["目录扫描完成，请查看各文件状态。"].waitForExistence(timeout: 30))
        record(app.debugDescription, name: "Device iCloud initial scan")
        app.terminate()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["首页"].waitForExistence(timeout: 15))
        openClientPage("cloud", in: app)
        XCTAssertTrue(directory.waitForExistence(timeout: 10))
        XCTAssertEqual(app.switches["自动同步"].value as? String, "1")
        XCTAssertTrue(waitUntil(timeout: 20) { sync.isEnabled })
        reveal(sync, in: app)
        sync.tap()
        XCTAssertTrue(app.staticTexts["目录扫描完成，请查看各文件状态。"].waitForExistence(timeout: 30))
        record(app.debugDescription, name: "Device iCloud bookmark restored")
#endif
    }

    func testYAMLNodeSwitchAndExtensionMemory() throws {
#if targetEnvironment(simulator)
        throw XCTSkip("Requires a physical iPhone and manual VPN authorization.")
#else
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["首页"].waitForExistence(timeout: 15))
        addTeardownBlock {
            app.activate()
            self.openClientPage("diagnostics", in: app)
            let stop = app.buttons["停止测试 VPN"]
            if !stop.exists, app.navigationBars.buttons.firstMatch.exists {
                app.navigationBars.buttons.firstMatch.tap()
            }
            if stop.exists {
                self.reveal(stop, in: app)
                stop.tap()
            }
        }
        openClientPage("diagnostics", in: app)
        let initialStop = app.buttons["停止测试 VPN"]
        reveal(initialStop, in: app)
        initialStop.tap()
        XCTAssertTrue(waitUntil(timeout: 15) { !app.buttons["通过测试隧道查询 example.com"].isEnabled })
        openClientPage("profiles", in: app)
        reveal(app.buttons["addDirectExample"], in: app)
        app.buttons["addDirectExample"].tap()
        let feedback = app.staticTexts["profile-operation-status"]
        reveal(feedback, in: app)
        XCTAssertTrue(waitUntil(timeout: 15) { feedback.label.hasPrefix("配置已保存") }, app.debugDescription)
        showHome(in: app)
        let connect = app.buttons["home-connect"]
        reveal(connect, in: app)
        XCTAssertTrue(connect.isEnabled)
        connect.tap()
        openClientPage("diagnostics", in: app)
        let start = app.buttons["启动测试 VPN"]
        let probe = app.buttons["通过测试隧道查询 example.com"]
        XCTAssertTrue(waitUntil(timeout: 30) { probe.isEnabled })
        checkDNS(in: app, name: "YAML DIRECT baseline")
        checkRuntimeActivity(in: app, cycle: 1)
        checkHomeTrafficIncreases(in: app)
        checkHomeExitIP(in: app)

        openClientPage("nodes", in: app)
        expandClientNodeGroup("默认出口", in: app)
        let reject = app.buttons["node-默认出口-REJECT"]
        XCTAssertTrue(reject.waitForExistence(timeout: 10))
        reject.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { reject.value as? String == "已选中" })
        XCTAssertTrue(app.staticTexts["节点已切换，选择已保存到实际运行配置。"].exists)
        openClientPage("diagnostics", in: app)
        reveal(probe, in: app)
        probe.tap()
        let rejected = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "DNS 探测超时。")).firstMatch
        XCTAssertTrue(rejected.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertFalse(rejected.label.contains("收到 DNS 响应："))
        record(rejected.label, name: "YAML REJECT query")
        checkHomeRoutingModes(in: app)

        openClientPage("nodes", in: app)
        expandClientNodeGroup("默认出口", in: app)
        let direct = app.buttons["node-默认出口-DIRECT"]
        XCTAssertTrue(direct.waitForExistence(timeout: 10))
        direct.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { direct.value as? String == "已选中" })
        app.terminate()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["首页"].waitForExistence(timeout: 15))
        openClientPage("diagnostics", in: app)
        XCTAssertTrue(waitUntil(timeout: 10) { probe.isEnabled })
        checkDNS(in: app, name: "YAML DIRECT after app relaunch")

        let diagnostics = app.buttons["诊断与内存"]
        reveal(diagnostics, in: app)
        diagnostics.tap()
        app.buttons["采样扩展内存"].tap()
        XCTAssertTrue(app.staticTexts["已读取扩展进程的当前内存"].waitForExistence(timeout: 10))
        record(app.debugDescription, name: "Physical device extension memory")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Physical device extension memory"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.navigationBars.buttons.firstMatch.tap()
        let stop = app.buttons["停止测试 VPN"]
        reveal(stop, in: app)
        stop.tap()
        XCTAssertTrue(waitUntil(timeout: 15) { start.isEnabled && !probe.isEnabled })
#endif
    }

    func testDirectPacketFlowAndRestart() throws {
#if targetEnvironment(simulator)
        throw XCTSkip("Requires a physical iPhone and manual VPN authorization.")
#else
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        openClientPage("diagnostics", in: app)
        let toggle = app.switches["使用 SOCKS5 出站"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 15))
        if toggle.value as? String == "1" {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        let stop = app.buttons["停止测试 VPN"]
        defer {
            if app.state == .runningForeground, stop.exists {
                reveal(stop, in: app)
                stop.tap()
            }
        }
        reveal(stop, in: app)
        stop.tap()
        let start = app.buttons["启动测试 VPN"]
        XCTAssertTrue(waitUntil(timeout: 10) { start.isEnabled })
        for cycle in 1...2 {
            reveal(start, in: app)
            start.tap()
            let probe = app.buttons["通过测试隧道查询 example.com"]
            XCTAssertTrue(waitUntil(timeout: 120) { probe.isEnabled }, "Authorize the VPN on the iPhone if prompted.")
            reveal(probe, in: app)
            probe.tap()
            let result = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "检测到双向数据包。")).firstMatch
            XCTAssertTrue(result.waitForExistence(timeout: 20), app.debugDescription)
            XCTAssertTrue(result.label.contains("收到 DNS 响应："), result.label)
            XCTAssertTrue(result.label.contains("返回码 0。"), result.label)
            XCTAssertFalse(result.label.contains("，0 条答案"), result.label)
            let evidence = XCTAttachment(string: result.label)
            evidence.name = "DIRECT packetFlow cycle \(cycle)"
            evidence.lifetime = .keepAlways
            add(evidence)
            checkRuntimeActivity(in: app, cycle: cycle)
            openClientPage("diagnostics", in: app)
            reveal(stop, in: app)
            stop.tap()
            XCTAssertTrue(waitUntil(timeout: 15) { start.isEnabled && !probe.isEnabled })
            app.terminate()
            app.launch()
            self.openClientPage("diagnostics", in: app)
            XCTAssertTrue(toggle.waitForExistence(timeout: 15))
            XCTAssertEqual(toggle.value as? String, "0")
            XCTAssertTrue(waitUntil(timeout: 10) { start.isEnabled && !probe.isEnabled })
            XCTAssertFalse(app.buttons["保存为待应用快照"].exists)
            XCTAssertFalse(app.buttons["恢复最近成功快照"].exists)
        }
#endif
    }

    private func showHome(in app: XCUIApplication) {
        closeClientSheets(in: app)
        app.tabBars.buttons["首页"].tap()
        for _ in 0..<8 {
            if app.buttons["home-connect"].exists { break }
            app.navigationBars.buttons.firstMatch.tap()
        }
    }

    private func checkHomeTrafficIncreases(in app: XCUIApplication) {
        showHome(in: app)
        let scope = app.staticTexts["home-runtime-scope"]
        XCTAssertTrue(waitUntil(timeout: 10) { scope.exists && scope.label.contains("默认路由") }, app.debugDescription)
        let upload = app.staticTexts["home-upload-total"]
        let download = app.staticTexts["home-download-total"]
        XCTAssertTrue(upload.waitForExistence(timeout: 10))
        XCTAssertTrue(download.waitForExistence(timeout: 10))
        let beforeUp = Int64(upload.value as? String ?? "") ?? -1
        let beforeDown = Int64(download.value as? String ?? "") ?? -1
        XCTAssertGreaterThanOrEqual(beforeUp, 0)
        XCTAssertGreaterThanOrEqual(beforeDown, 0)
        record(app.debugDescription, name: "Home real totals before second request")
        openClientPage("diagnostics", in: app)
        checkDNS(in: app, name: "Additional request for home byte delta")
        showHome(in: app)
        XCTAssertTrue(waitUntil(timeout: 10) {
            (Int64(upload.value as? String ?? "") ?? -1) > beforeUp &&
            (Int64(download.value as? String ?? "") ?? -1) > beforeDown
        }, app.debugDescription)
        XCTAssertNotEqual(app.staticTexts["home-upload-rate"].label, "—")
        XCTAssertNotEqual(app.staticTexts["home-download-rate"].label, "—")
        record(app.debugDescription, name: "Home real totals increased after request")
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "Home real traffic on YAML default route"
        image.lifetime = .keepAlways
        add(image)
    }

    private func checkRuntimeActivity(in app: XCUIApplication, cycle: Int) {
        app.tabBars.buttons["工具"].tap()
        if app.navigationBars["活动"].exists { app.navigationBars.buttons.firstMatch.tap() }
        let activity = app.buttons["tools-activity"]
        reveal(activity, in: app)
        activity.tap()
        let status = app.staticTexts["runtime-status"]
        XCTAssertTrue(waitUntil(timeout: 15) { status.exists && status.label.contains("每秒采样一次") }, app.debugDescription)
        let segments = app.segmentedControls["activity-sections"]
        segments.buttons["请求"].tap()
        XCTAssertTrue(app.staticTexts["1.1.1.1:53"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["udp"].exists)
        record(app.debugDescription, name: "Runtime requests and payload counts cycle \(cycle)")
        segments.buttons["日志"].tap()
        XCTAssertTrue(app.buttons["runtime-export-logs"].isEnabled)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Packet session starting")).firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        record(app.debugDescription, name: "Live core logs cycle \(cycle)")
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "Runtime core logs cycle \(cycle)"
        image.lifetime = .keepAlways
        add(image)
    }

    private func waitUntil(timeout: TimeInterval, _ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func checkHomeExitIP(in app: XCUIApplication) {
        showHome(in: app)
        let ip = app.staticTexts["home-exit-ip"]
        XCTAssertTrue(waitUntil(timeout: 20) { ip.exists && (ip.label.contains(".") || ip.label.contains(":")) }, app.debugDescription)
        XCTAssertNotEqual(app.staticTexts["home-ip-organization"].label, "—")
        record(app.debugDescription, name: "Home real exit IP and classification")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Home real exit IP card"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func checkHomeRoutingModes(in app: XCUIApplication) {
        openClientPage("nodes", in: app)
        expandClientNodeGroup("GLOBAL", in: app)
        let globalDirect = app.buttons["node-GLOBAL-DIRECT"]
        reveal(globalDirect, in: app)
        globalDirect.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { globalDirect.value as? String == "已选中" })
        for mode in ["direct", "global", "rule"] {
            showHome(in: app)
            let button = app.buttons["home-mode-" + mode]
            XCTAssertTrue(button.isEnabled)
            button.tap()
            XCTAssertTrue(waitUntil(timeout: 10) { button.isSelected }, app.debugDescription)
            XCTAssertTrue(app.navigationBars["Catlash"].exists)
            record(app.debugDescription, name: "Home confirmed mode " + mode)
            if mode == "global" {
                let chooser = app.buttons["home-nodes"]
                reveal(chooser, in: app)
                XCTAssertTrue(chooser.label.contains("GLOBAL · DIRECT"), chooser.label)
                chooser.tap()
                let group = app.buttons["node-group-GLOBAL"]
                XCTAssertTrue(group.waitForExistence(timeout: 5))
                XCTAssertEqual(group.value as? String, "已展开")
                XCTAssertEqual(globalDirect.value as? String, "已选中")
                app.buttons["close-proxies"].tap()
            }
            if mode == "rule" {
                XCTAssertTrue(waitUntil(timeout: 20) { app.staticTexts["home-exit-ip"].label == "IP 检测失败" })
                XCTAssertEqual(app.staticTexts["home-ip-organization"].label, "—")
            } else { checkHomeExitIP(in: app) }
            openClientPage("diagnostics", in: app)
            if mode == "rule" {
                let probe = app.buttons["通过测试隧道查询 example.com"]
                reveal(probe, in: app)
                probe.tap()
                let timeout = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "DNS 探测超时。")).firstMatch
                XCTAssertTrue(timeout.waitForExistence(timeout: 20), app.debugDescription)
                record(timeout.label, name: "Rule mode keeps REJECT route")
            } else {
                checkDNS(in: app, name: "Home " + mode + " bypasses rejecting rule")
            }
        }
        showHome(in: app)
        for mode in ["global", "rule", "direct"] { app.buttons["home-mode-" + mode].tap() }
        XCTAssertTrue(waitUntil(timeout: 10) { app.buttons["home-mode-direct"].isSelected })
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["home-mode-direct"].waitForExistence(timeout: 15))
        XCTAssertTrue(waitUntil(timeout: 10) { app.buttons["home-mode-direct"].isSelected })
        app.buttons["home-mode-rule"].tap()
        XCTAssertTrue(waitUntil(timeout: 10) { app.buttons["home-mode-rule"].isSelected })
    }

    private func checkDNS(in app: XCUIApplication, name: String) {
        let probe = app.buttons["通过测试隧道查询 example.com"]
        reveal(probe, in: app)
        probe.tap()
        let result = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "检测到双向数据包。")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(result.label.contains("收到 DNS 响应："), result.label)
        XCTAssertTrue(result.label.contains("返回码 0。"), result.label)
        XCTAssertFalse(result.label.contains("，0 条答案"), result.label)
        record(result.label, name: name)
    }

    private func record(_ text: String, name: String) {
        let evidence = XCTAttachment(string: text)
        evidence.name = name
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        scrollToClientControl(element, in: app)
    }
}
