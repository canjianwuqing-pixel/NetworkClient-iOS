import XCTest

final class LaunchTests: XCTestCase {
    @MainActor
    func testConfigurationUnavailableUsesOnlyLocalAssetsAndRetry() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--offline", "--ui-config-unavailable", "-ios.language", "zh-Hans",
        ]
        app.launch()

        XCTAssertTrue(app.staticTexts["无法获取服务配置"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.images["brand.logo"].exists)
        XCTAssertTrue(app.staticTexts["请检查网络后重试"].exists)
        XCTAssertTrue(app.buttons["configuration.retry"].exists)
        XCTAssertFalse(app.staticTexts["brand.name"].exists)
        XCTAssertFalse(app.staticTexts["brand.loginTitle"].exists)
        XCTAssertFalse(app.buttons["auth.submit"].exists)
        XCTAssertFalse(app.buttons["shortcut.website"].exists)
        XCTAssertFalse(app.buttons["shortcut.support"].exists)
        XCTAssertFalse(app.buttons["configuration.disconnectVPN"].exists)
    }

    @MainActor
    func testAuthenticationBrandHeaderOnlyAppearsOnLogin() {
        let app = XCUIApplication()
        app.launchArguments = ["--offline", "-ios.language", "zh-Hans"]
        app.launch()

        XCTAssertTrue(app.images["brand.logo"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["brand.name"].exists)
        XCTAssertFalse(app.staticTexts["brand.loginTitle"].exists)

        app.buttons["注册账户"].tap()
        XCTAssertTrue(app.staticTexts["创建账号"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.images["brand.logo"].exists)
        XCTAssertFalse(app.staticTexts["brand.name"].exists)
        XCTAssertTrue(app.buttons["auth.submit"].exists)
        back(app)

        app.buttons["忘记密码"].tap()
        XCTAssertTrue(app.staticTexts["找回密码"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.images["brand.logo"].exists)
        XCTAssertFalse(app.staticTexts["brand.name"].exists)
        XCTAssertTrue(app.buttons["auth.submit"].exists)
    }

    @MainActor
    func testAuthenticationScreensDoNotExposeDeveloperDiagnostics() {
        let app = XCUIApplication()
        app.launchArguments = ["--offline", "-ios.language", "zh-Hans"]
        app.launch()
        XCTAssertTrue(app.buttons["auth.submit"].waitForExistence(timeout: 10))
        assertNoDeveloperUI(app)

        app.buttons["注册账户"].tap()
        XCTAssertTrue(app.buttons["auth.submit"].waitForExistence(timeout: 5))
        assertNoDeveloperUI(app)
        back(app)

        app.buttons["忘记密码"].tap()
        XCTAssertTrue(app.buttons["auth.submit"].waitForExistence(timeout: 5))
        assertNoDeveloperUI(app)
    }

    @MainActor
    func testAuthenticationScreensOnlyScrollWhenContentOverflows() {
        let app = XCUIApplication()
        app.launchArguments = ["--offline", "-ios.language", "zh-Hans"]
        app.launch()
        assertAuthScreenDoesNotMove(app)

        app.buttons["注册账户"].tap()
        assertAuthScreenDoesNotMove(app)
        XCTAssertTrue(app.buttons["auth.submit"].isHittable)
        back(app)

        app.buttons["忘记密码"].tap()
        assertAuthScreenDoesNotMove(app)
    }

    @MainActor
    func testAuthenticationKeyboardKeepsSubmitReachable() {
        let app = XCUIApplication()
        app.launchArguments = ["--offline", "-ios.language", "zh-Hans"]
        app.launch()
        let password = app.descendants(matching: .any)["auth.password"].firstMatch
        XCTAssertTrue(password.waitForExistence(timeout: 10))
        password.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let submit = app.buttons["auth.submit"]
        if !submit.isHittable {
            app.swipeUp()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertTrue(submit.isHittable)
    }

    @MainActor
    func testPasswordResetFieldOrderAndSixDigitCodeAdvancesFocus() {
        let app = XCUIApplication()
        app.launchArguments = ["--offline", "-ios.language", "zh-Hans"]
        app.launch()
        app.buttons["忘记密码"].tap()

        let email = app.descendants(matching: .any)["auth.email"].firstMatch
        let code = app.descendants(matching: .any)["auth.code"].firstMatch
        let newPassword = app.descendants(matching: .any)["auth.newPassword"].firstMatch
        let confirmation = app.descendants(matching: .any)["auth.confirmNewPassword"].firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 10))
        XCTAssertLessThan(email.frame.minY, code.frame.minY)
        XCTAssertLessThan(code.frame.minY, newPassword.frame.minY)
        XCTAssertLessThan(newPassword.frame.minY, confirmation.frame.minY)
        XCTAssertTrue(app.images["auth.code.icon"].exists)

        code.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        code.typeText("123456")
        let focused = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hasKeyboardFocus == true"),
            object: newPassword
        )
        XCTAssertEqual(XCTWaiter.wait(for: [focused], timeout: 3), .completed)
    }

    @MainActor
    func testRegistrationSixDigitCodeAdvancesFocus() {
        let app = XCUIApplication()
        app.launchArguments = ["--offline", "-ios.language", "zh-Hans"]
        app.launch()
        app.buttons["注册账户"].tap()

        let code = app.descendants(matching: .any)["auth.code"].firstMatch
        let password = app.descendants(matching: .any)["auth.password"].firstMatch
        XCTAssertTrue(password.waitForExistence(timeout: 10))
        XCTAssertTrue(app.images["auth.code.icon"].exists)

        code.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        code.typeText("123456")
        let focused = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hasKeyboardFocus == true"),
            object: password
        )
        XCTAssertEqual(XCTWaiter.wait(for: [focused], timeout: 3), .completed)
    }

    @MainActor
    func testNoNodesFailureHasOneCentralMessageAndRetry() {
        let app = XCUIApplication()
        app.launchArguments = ["--offline", "--ui-sample", "--ui-node-failure", "-ios.language", "zh-Hans"]
        app.launch()
        let entry = app.buttons["home.nodes"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        entry.tap()
        XCTAssertTrue(app.navigationBars["选择服务器"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts.matching(
            NSPredicate(format: "label == %@", "线路加载失败")
        ).count, 1)
        XCTAssertEqual(app.buttons.matching(
            NSPredicate(format: "label == %@", "请重试")
        ).count, 1)
        XCTAssertTrue(app.buttons["请重试"].isHittable)
    }

    @MainActor
    func testNodeInitialLoadingUsesContentFeedbackOnly() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--offline", "--ui-sample", "--ui-node-initial-loading",
            "-ios.language", "en",
        ]
        app.launch()

        let entry = app.buttons["home.nodes"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        entry.tap()
        XCTAssertTrue(app.navigationBars["Select Server"].waitForExistence(timeout: 5))

        let refresh = app.buttons["nodes.refresh"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 5))
        XCTAssertFalse(refresh.isEnabled)
        XCTAssertEqual(refresh.label, "Refresh Nodes")
        XCTAssertTrue(app.images["nodes.refresh.icon"].exists)
        XCTAssertTrue(app.staticTexts["Loading Nodes…"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["nodes.initial-loading"].exists)
        XCTAssertFalse(app.buttons["nodes.latency.test_all"].isEnabled)
    }

    @MainActor
    func testNodeRefreshKeepsRowsAndUsesActionFeedbackOnly() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--offline", "--ui-sample", "--ui-node-sample", "--ui-node-refreshing",
            "-ios.language", "en",
        ]
        app.launch()

        let entry = app.buttons["home.nodes"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        entry.tap()
        XCTAssertTrue(app.navigationBars["Select Server"].waitForExistence(timeout: 5))

        let refresh = app.buttons["nodes.refresh"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 5))
        XCTAssertFalse(refresh.isEnabled)
        XCTAssertEqual(refresh.label, "Updating servers")
        XCTAssertFalse(app.images["nodes.refresh.icon"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["nodes.initial-loading"].exists)
        XCTAssertFalse(app.staticTexts["Loading Nodes…"].exists)
        let taiwanRow = app.buttons["nodes.row.ui-node-tw"]
        let japanRow = app.buttons["nodes.row.ui-node-jp"]
        XCTAssertTrue(taiwanRow.exists)
        XCTAssertTrue(japanRow.exists)
        XCTAssertTrue(taiwanRow.isEnabled)
        XCTAssertTrue(japanRow.isEnabled)
        japanRow.tap()
        XCTAssertTrue(taiwanRow.isSelected)
        XCTAssertFalse(japanRow.isSelected)
        XCTAssertFalse(app.buttons["nodes.latency.test_all"].isEnabled)
    }

    @MainActor
    func testNodeBatchLatencyKeepsRowsUndimmedAndBlocksSelection() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--offline", "--ui-sample", "--ui-node-sample", "--ui-node-testing-all",
            "-ios.language", "en",
        ]
        app.launch()

        let entry = app.buttons["home.nodes"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        entry.tap()
        XCTAssertTrue(app.navigationBars["Select Server"].waitForExistence(timeout: 5))

        let cancel = app.buttons["nodes.latency.cancel_all"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        let taiwanRow = app.buttons["nodes.row.ui-node-tw"]
        let japanRow = app.buttons["nodes.row.ui-node-jp"]
        XCTAssertTrue(taiwanRow.exists)
        XCTAssertTrue(japanRow.exists)
        XCTAssertTrue(taiwanRow.isEnabled)
        XCTAssertTrue(japanRow.isEnabled)
        japanRow.tap()
        XCTAssertTrue(taiwanRow.isSelected)
        XCTAssertFalse(japanRow.isSelected)
        XCTAssertFalse(app.staticTexts["42 ms"].exists)
    }

    @MainActor
    func testNodeActionsUseAlignedTouchTargetsWithoutHorizontalOverflow() {
        let app = XCUIApplication()
        app.launchArguments = ["--offline", "--ui-sample", "-ios.language", "en"]
        app.launch()
        let entry = app.buttons["home.nodes"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        entry.tap()
        XCTAssertTrue(app.navigationBars["Select Server"].waitForExistence(timeout: 5))
        let refresh = app.buttons["nodes.refresh"]
        let testAll = app.buttons["nodes.latency.test_all"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 10))
        XCTAssertTrue(testAll.exists)
        XCTAssertEqual(testAll.label, "Test Latency")
        XCTAssertGreaterThanOrEqual(refresh.frame.height, 44)
        XCTAssertGreaterThanOrEqual(testAll.frame.height, 44)
        XCTAssertLessThan(refresh.frame.maxX, testAll.frame.minX)
        XCTAssertGreaterThanOrEqual(refresh.frame.minX, app.frame.minX)
        XCTAssertLessThanOrEqual(testAll.frame.maxX, app.frame.maxX)
        XCTAssertFalse(testAll.isEnabled) // The offline fixture has no subscribed nodes.
        XCTAssertFalse(app.searchFields.firstMatch.exists)
        XCTAssertFalse(app.buttons["nodes.latency.single"].exists)
        XCTAssertFalse(app.staticTexts["nodes.latency.progress"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["nodes.initial-loading"].exists)
        XCTAssertFalse(app.staticTexts["Loading Nodes…"].exists)
        capture(app, "nodes-actions")
    }

    @MainActor
    func testNodeRowSelectionStaysBelowActionsAndKeepsLatencyOnReentry() {
        let app = XCUIApplication()
        app.launchArguments = ["--offline", "--ui-sample", "--ui-node-sample", "-ios.language", "en"]
        app.launch()
        let entry = app.buttons["home.nodes"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        entry.tap()

        let refresh = app.buttons["nodes.refresh"]
        let testAll = app.buttons["nodes.latency.test_all"]
        let first = app.buttons["nodes.row.ui-node-tw"]
        let second = app.buttons["nodes.row.ui-node-jp"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(second.exists)
        XCTAssertLessThan(refresh.frame.maxY, first.frame.minY)
        XCTAssertLessThan(testAll.frame.maxY, first.frame.minY)
        XCTAssertGreaterThanOrEqual(first.frame.height, 44)
        XCTAssertGreaterThanOrEqual(app.staticTexts.matching(
            NSPredicate(format: "label == %@", "42 ms")
        ).count, 2)
        let firstFrame = first.frame
        let secondFrame = second.frame

        second.tap()
        XCTAssertTrue(second.isSelected)
        XCTAssertEqual(first.frame.minY, firstFrame.minY, accuracy: 1)
        XCTAssertEqual(second.frame.minY, secondFrame.minY, accuracy: 1)
        XCTAssertEqual(first.frame.height, firstFrame.height, accuracy: 1)
        XCTAssertGreaterThanOrEqual(app.staticTexts.matching(
            NSPredicate(format: "label == %@", "42 ms")
        ).count, 2)
        XCTAssertTrue(refresh.isEnabled)
        XCTAssertTrue(testAll.isEnabled)

        app.navigationBars.buttons.element(boundBy: 0).tap()
        entry.tap()
        XCTAssertTrue(app.buttons["nodes.row.ui-node-jp"].isSelected)
        XCTAssertGreaterThanOrEqual(app.staticTexts.matching(
            NSPredicate(format: "label == %@", "42 ms")
        ).count, 2)
    }

    @MainActor
    func testAuthenticationConfigurationStatusIsOnlyOnLogin() {
        let app = XCUIApplication()
        app.launchArguments = ["--offline", "-ios.language", "zh-Hans"]
        app.launch()
        let status = app.staticTexts["auth.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertEqual(status.label, "客户端配置已就绪，请输入账号密码登录。")
        XCTAssertFalse(app.staticTexts["远程配置"].exists)
        XCTAssertFalse(app.buttons["重新加载配置"].exists)

        app.buttons["注册账户"].tap()
        XCTAssertTrue(app.buttons["auth.submit"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["auth.status"].exists)
        XCTAssertFalse(app.buttons["重新加载配置"].exists)
        XCTAssertFalse(app.staticTexts["安装 Logo"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()

        app.buttons["忘记密码"].tap()
        XCTAssertTrue(app.buttons["auth.submit"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["auth.status"].exists)
        XCTAssertFalse(app.buttons["重新加载配置"].exists)
    }

    @MainActor
    func testEnglishAuthenticationStatusFitsNarrowPhone() {
        let app = XCUIApplication()
        app.launchArguments = ["--offline", "-ios.language", "en"]
        app.launch()
        let status = app.staticTexts["auth.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertEqual(status.label, "Client configuration is ready. Enter your email and password to sign in.")
        XCTAssertGreaterThanOrEqual(status.frame.minX, app.frame.minX)
        XCTAssertLessThanOrEqual(status.frame.maxX, app.frame.maxX)
        XCTAssertGreaterThan(status.frame.minY, app.buttons["auth.submit"].frame.maxY)
        XCTAssertFalse(app.buttons["Reload Configuration"].exists)
        app.buttons["Create Account"].tap()
        XCTAssertTrue(app.buttons["auth.submit"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["auth.status"].exists)
        XCTAssertFalse(app.buttons["Reload Configuration"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Forgot Password"].tap()
        XCTAssertTrue(app.buttons["auth.submit"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["auth.status"].exists)
    }

    @MainActor
    func testUnauthenticatedLaunchCannotBrowseProtectedPages() {
        let app = XCUIApplication(); app.launchArguments = ["--offline", "-ios.language", "zh-Hans"]; app.launch()
        XCTAssertTrue(app.textFields["auth.email"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["auth.submit"].isEnabled)
        XCTAssertFalse(app.buttons["auth.browse"].exists)
        XCTAssertFalse(app.buttons["浏览客户端"].exists)
        XCTAssertFalse(app.buttons["navigation.0"].exists)
        XCTAssertFalse(app.buttons["navigation.1"].exists)
        XCTAssertFalse(app.buttons["navigation.2"].exists)
        XCTAssertFalse(app.buttons["home.nodes"].exists)
        app.buttons["注册账户"].tap()
        XCTAssertTrue(app.buttons["auth.submit"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["navigation.0"].exists)
    }

    /// Opt-in on an authorized physical device only. The test never supplies
    /// credentials or selects a different account/node, and always requests
    /// disconnection before it finishes.
    @MainActor
    func testAuthorizedDeviceVPNConnectAndDisconnect() throws {
        guard ProcessInfo.processInfo.environment["NETWORKCLIENT_DEVICE_VPN_TEST"] == "1" else {
            throw XCTSkip("Requires an explicitly authorized physical-device run")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-ios.language", "zh-Hans"]
        app.launchEnvironment["NETWORKCLIENT_OFFLINE"] = "0"
        app.launch()
        let button = app.buttons["vpn.connect"]
        guard button.waitForExistence(timeout: 45) else {
            XCTFail("The signed-in home screen did not become ready within the bounded launch wait")
            return
        }
        guard app.staticTexts["未连接"].waitForExistence(timeout: 10) else {
            XCTFail("The VPN was not safely disconnected before the test")
            return
        }
        // Production joins the authenticated subscription bootstrap itself.
        // An explicit test refresh would conceal the cold-start race.
        defer {
            app.activate()
            let current = app.buttons["vpn.connect"]
            if current.exists && current.isEnabled && app.staticTexts["已连接"].exists {
                current.tap()
            }
        }
        button.tap()
        guard app.staticTexts["已连接"].waitForExistence(timeout: 65) else {
            XCTFail("The system and extension did not both report a running tunnel")
            return
        }
        print("BUILD12_DEVICE_VPN_CONNECTED")
        for _ in 0..<14 { Thread.sleep(forTimeInterval: 5) }
        app.activate()
        guard app.staticTexts["已连接"].waitForExistence(timeout: 10) else {
            XCTFail("Tunnel did not remain connected during the observation period")
            return
        }
        button.tap()
        guard app.staticTexts["未连接"].waitForExistence(timeout: 20) else {
            XCTFail("Tunnel did not return to the disconnected state")
            return
        }
        print("BUILD12_DEVICE_VPN_DISCONNECTED")
    }

    /// Recovery action for an interrupted device test. It only stops the
    /// current test identity's tunnel and never removes its VPN configuration.
    @MainActor
    func testAuthorizedDeviceVPNDisconnectIfConnected() throws {
        guard ProcessInfo.processInfo.environment["NETWORKCLIENT_DEVICE_VPN_TEST"] == "1" else {
            throw XCTSkip("Requires an explicitly authorized physical-device run")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-ios.language", "zh-Hans"]
        app.launch()
        let button = app.buttons["vpn.connect"]
        guard button.waitForExistence(timeout: 45) else {
            XCTFail("The signed-in home screen did not become ready")
            return
        }
        if app.staticTexts["已连接"].exists {
            button.tap()
        }
        XCTAssertTrue(app.staticTexts["未连接"].waitForExistence(timeout: 30))
    }

    /// Read-only regression against the preserved device session. It does not
    /// refresh, select a node, open a payment flow, or alter VPN state.
    @MainActor
    func testAuthorizedDeviceReadOnlyBusinessScreens() throws {
        guard ProcessInfo.processInfo.environment["NETWORKCLIENT_DEVICE_VPN_TEST"] == "1" else {
            throw XCTSkip("Requires an explicitly authorized physical-device run")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-ios.language", "zh-Hans"]
        app.launchEnvironment["NETWORKCLIENT_OFFLINE"] = "0"
        app.launch()
        XCTAssertTrue(app.buttons["home.nodes"].waitForExistence(timeout: 45))
        XCTAssertTrue(app.staticTexts["未连接"].exists)

        app.buttons["home.nodes"].tap()
        XCTAssertTrue(app.navigationBars["选择服务器"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["nodes.refresh"].exists)
        XCTAssertTrue(app.buttons["nodes.latency.test_all"].exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "nodes.latency.single."
        )).firstMatch.exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()

        app.buttons["navigation.1"].tap()
        XCTAssertTrue(app.buttons["立即购买"].firstMatch.waitForExistence(timeout: 30))

        app.buttons["navigation.2"].tap()
        XCTAssertTrue(app.buttons["profile.orders"].waitForExistence(timeout: 10))
        app.buttons["profile.orders"].tap()
        XCTAssertTrue(app.navigationBars["我的订单"].waitForExistence(timeout: 15))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        XCTAssertFalse(app.buttons["profile.announcements"].exists)
        scrollTo(app.buttons["profile.aboutSupport"], app)
        app.buttons["profile.aboutSupport"].tap()
        XCTAssertTrue(app.navigationBars["关于"].waitForExistence(timeout: 15))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        scrollTo(app.buttons["profile.settings"], app)
        app.buttons["profile.settings"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.descendants(matching: .any)["settings.language"].firstMatch.exists)
    }
    @MainActor
    func testFourReferenceScreenshots() {
        let app = XCUIApplication(); app.launchArguments = ["--offline", "-ios.language", "zh-Hans"]; app.launch()
        XCTAssertTrue(app.textFields["auth.email"].waitForExistence(timeout: 10))
        let brandName = app.staticTexts["brand.name"].firstMatch.label
        capture(app, "01-login")
        app.terminate(); app.launchArguments = ["--offline", "--ui-sample", "-ios.language", "zh-Hans"]; app.launch()
        XCTAssertTrue(app.buttons["vpn.connect"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["brand.name"].firstMatch.label, brandName)
        // A simulator without usable VPN preferences may honestly show an
        // unavailable state. Neither state may claim protected traffic.
        XCTAssertTrue(app.staticTexts["未连接"].exists || app.staticTexts["VPN 不可用"].exists)
        XCTAssertFalse(app.staticTexts["已连接"].exists)
        XCTAssertFalse(app.staticTexts["测试版 VPN：请先验证路由与防泄漏效果，再依赖其保护"].exists)
        capture(app, "02-home")
        app.buttons["navigation.1"].tap()
        XCTAssertTrue(app.buttons["立即购买"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["立即购买"].isEnabled)
        XCTAssertTrue(app.buttons["刷新套餐"].exists)
        let plansScroll = app.scrollViews["purchase.plans.scroll"]
        XCTAssertTrue(plansScroll.exists)
        let refreshFrame = app.buttons["刷新套餐"].frame
        plansScroll.swipeUp()
        XCTAssertEqual(app.buttons["刷新套餐"].frame.minY, refreshFrame.minY, accuracy: 1)
        XCTAssertTrue(app.buttons["我的订单"].exists)
        XCTAssertEqual(app.staticTexts["brand.name"].firstMatch.label, brandName)
        capture(app, "03-purchase")
        app.buttons["navigation.2"].tap()
        XCTAssertTrue(app.buttons["profile.settings"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["brand.name"].firstMatch.label, brandName)
        capture(app, "04-profile")
    }

    @MainActor
    func testPurchasePrimaryAndDisclosureActionsUseAccessibleTouchTargets() {
        let app = XCUIApplication()
        app.launchArguments = ["--offline", "--ui-sample", "-ios.language", "zh-Hans"]
        app.launch()
        app.buttons["navigation.1"].tap()

        let refresh = app.buttons["刷新套餐"]
        let orders = app.buttons["我的订单"]
        let disclosure = app.buttons["展开更多"]
        let buy = app.buttons["立即购买"].firstMatch
        XCTAssertTrue(buy.waitForExistence(timeout: 10))
        XCTAssertTrue(refresh.exists)
        XCTAssertTrue(orders.exists)
        XCTAssertTrue(disclosure.exists)
        for action in [refresh, orders, disclosure, buy] {
            assertMinimumTouchTarget(action)
        }
        XCTAssertLessThan(refresh.frame.maxX, orders.frame.minX)

        disclosure.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        let collapse = app.buttons["收起"]
        XCTAssertTrue(collapse.waitForExistence(timeout: 5))
        assertMinimumTouchTarget(collapse)
        XCTAssertLessThan(collapse.frame.maxY, buy.frame.minY)

        orders.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
        XCTAssertTrue(app.buttons["profile.orders.refresh"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testUnifiedConsentDeclineAndAgreeGateConnectExactlyOnce() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--offline", "--ui-sample",
            "--ui-unified-consent-reset", "--ui-unified-consent-only",
            "-ios.language", "en",
        ]
        app.launch()

        let connect = app.buttons["vpn.connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 10))
        connect.tap()

        let title = app.staticTexts["global.modal.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, "Dear User")
        XCTAssertEqual(
            app.staticTexts["global.modal.message"].label,
            "Please read and agree to the Terms of Use and Privacy Notice first."
        )
        let cancel = app.buttons["unified.consent.decline"]
        XCTAssertTrue(cancel.exists)
        cancel.tap()
        XCTAssertTrue(title.waitForNonExistence(timeout: 5))

        connect.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5), "Cancel must not acknowledge")
        let confirm = app.buttons["unified.consent.agree"]
        XCTAssertTrue(confirm.exists)
        confirm.tap()
        XCTAssertTrue(title.waitForNonExistence(timeout: 5))

        connect.tap()
        XCTAssertFalse(
            title.waitForExistence(timeout: 1),
            "The accepted unified version must make later gates silent"
        )
    }

    @MainActor
    func testUnifiedConsentGatesPurchaseBeforeOrderCreation() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--offline", "--ui-sample",
            "--ui-unified-consent-reset", "--ui-unified-consent-purchase",
            "-ios.language", "en",
        ]
        app.launch()
        app.buttons["navigation.1"].tap()

        let buy = app.buttons["purchase.plan.1.buy"]
        XCTAssertTrue(buy.waitForExistence(timeout: 10))
        XCTAssertTrue(buy.isEnabled)
        buy.tap()

        let title = app.staticTexts["global.modal.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, "Dear User")
        app.buttons["unified.consent.decline"].tap()
        XCTAssertTrue(title.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Create Order"].exists)

        buy.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        app.buttons["unified.consent.agree"].tap()
        XCTAssertTrue(app.buttons["Create Order"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["unified.consent.agree"].exists)
        app.buttons["Cancel"].tap()
    }

    @MainActor
    func testLoginAndRegistrationShareUnifiedConsentAndDocumentDoesNotAutoAccept() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--offline", "--ui-unified-consent-reset", "--ui-unified-consent-auth",
            "-ios.language", "en",
        ]
        app.launch()

        let checkbox = app.buttons["auth.consent.checkbox"]
        XCTAssertTrue(checkbox.waitForExistence(timeout: 10))
        XCTAssertFalse(checkbox.isSelected)

        app.buttons["auth.consent.document.link"].tap()
        XCTAssertTrue(app.staticTexts["Terms of Use & Privacy Notice"].waitForExistence(timeout: 5))
        for title in [
            "Terms of Service", "Privacy Policy", "VPN Data Use",
            "Account Deletion & Policy Updates",
        ] {
            XCTAssertTrue(app.staticTexts[title].exists)
        }
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertFalse(checkbox.isSelected)

        app.buttons["auth.submit"].tap()
        let title = app.staticTexts["global.modal.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        app.buttons["unified.consent.decline"].tap()
        XCTAssertTrue(title.waitForNonExistence(timeout: 5))
        XCTAssertFalse(checkbox.isSelected)

        app.buttons["auth.submit"].tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        app.buttons["unified.consent.agree"].tap()
        XCTAssertTrue(title.waitForNonExistence(timeout: 5))
        XCTAssertTrue(checkbox.isSelected)

        app.buttons["Create Account"].tap()
        let registrationCheckbox = app.buttons["auth.consent.checkbox"]
        XCTAssertTrue(registrationCheckbox.waitForExistence(timeout: 5))
        XCTAssertTrue(registrationCheckbox.isSelected)
    }

    @MainActor
    func testRegistrationStartsUncheckedWithoutUnifiedConsent() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--offline", "--ui-unified-consent-reset", "--ui-unified-consent-auth",
            "-ios.language", "en",
        ]
        app.launch()
        app.buttons["Create Account"].tap()

        let checkbox = app.buttons["auth.consent.checkbox"]
        XCTAssertTrue(checkbox.waitForExistence(timeout: 5))
        XCTAssertFalse(checkbox.isSelected)

        let submit = app.buttons["auth.submit"]
        XCTAssertTrue(submit.isEnabled)
        submit.tap()
        XCTAssertTrue(app.staticTexts["global.modal.title"].waitForExistence(timeout: 5))
        app.buttons["unified.consent.decline"].tap()
        XCTAssertFalse(checkbox.isSelected)
    }

    @MainActor
    func testPurchaseConditionalInlineActionsUseAccessibleTouchTargets() {
        let app = XCUIApplication()
        let cases: [(argument: String, identifier: String)] = [
            ("--ui-purchase-initial-error", "purchase.plans.retry"),
            ("--ui-purchase-stale-error", "purchase.plans.retry"),
            ("--ui-purchase-pending-ready", "purchase.pending.continue"),
            ("--ui-purchase-pending-error", "purchase.pending.retry"),
        ]
        for item in cases {
            app.terminate()
            app.launchArguments = [
                "--offline", "--ui-sample", item.argument,
                "-ios.language", "zh-Hans",
            ]
            app.launch()
            app.buttons["navigation.1"].tap()
            let action = app.buttons[item.identifier]
            XCTAssertTrue(action.waitForExistence(timeout: 10), item.argument)
            assertMinimumTouchTarget(action, item.argument)
        }
    }

    @MainActor
    func testPurchaseTouchTargetsRemainSeparatedInDarkModeAndLargeText() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--offline", "--ui-sample",
            "-AppleInterfaceStyle", "Dark",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge",
            "-ios.language", "en",
        ]
        app.launch()
        app.buttons["navigation.1"].tap()

        let refresh = app.buttons["purchase.plans.refresh"]
        let orders = app.buttons["purchase.orders.open"]
        let disclosure = app.buttons["purchase.plan.1.disclosure"]
        XCTAssertTrue(disclosure.waitForExistence(timeout: 10))
        for action in [refresh, orders, disclosure] {
            assertMinimumTouchTarget(action)
            XCTAssertGreaterThanOrEqual(action.frame.minX, app.frame.minX)
            XCTAssertLessThanOrEqual(action.frame.maxX, app.frame.maxX)
        }
        XCTAssertLessThan(refresh.frame.maxX, orders.frame.minX)
    }
    @MainActor
    func testEnglishSwitchUpdatesVisibleUIAndPersists() {
        let app = XCUIApplication()
        app.launchArguments = ["--offline", "--ui-sample", "-ios.language", "zh-Hans"]
        app.launch()
        XCTAssertTrue(app.buttons["navigation.2"].waitForExistence(timeout: 10))
        app.buttons["navigation.2"].tap()
        app.buttons["profile.settings"].tap()
        let languageRow = app.descendants(matching: .any)["settings.language"].firstMatch
        XCTAssertTrue(languageRow.waitForExistence(timeout: 5))
        XCTAssertTrue(app.images["settings.title.icon"].exists)
        languageRow.tap()
        let modal = app.descendants(matching: .any)["global.modal"].firstMatch
        XCTAssertTrue(modal.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["global.modal.selection.zh-Hans"].isSelected)
        app.staticTexts["global.modal.title"].tap()
        XCTAssertTrue(modal.exists, "Tapping inside the card must not dismiss it")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.5)).tap()
        XCTAssertFalse(modal.exists)
        XCTAssertTrue(languageRow.label.contains("简体中文"))

        languageRow.tap()
        XCTAssertTrue(app.buttons["global.modal.selection.zh-Hans"].isSelected)
        let english = app.buttons["global.modal.selection.en"]
        XCTAssertTrue(english.waitForExistence(timeout: 5))
        english.tap()
        XCTAssertFalse(modal.exists)
        XCTAssertTrue(app.staticTexts["General Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["settings.appearance"].firstMatch.exists)
        XCTAssertFalse(app.buttons["settings.developer-diagnostics"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["settings.vpn-state"].firstMatch.exists)

        let appearanceRow = app.descendants(matching: .any)["settings.appearance"].firstMatch
        appearanceRow.tap()
        XCTAssertTrue(app.buttons["global.modal.selection.system"].isSelected)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.5)).tap()
        XCTAssertFalse(modal.exists)
        XCTAssertTrue(appearanceRow.label.contains("System"))

        appearanceRow.tap()
        XCTAssertTrue(app.buttons["global.modal.selection.system"].isSelected)
        app.buttons["global.modal.selection.dark"].tap()
        XCTAssertFalse(modal.exists)
        appearanceRow.tap()
        XCTAssertTrue(app.buttons["global.modal.selection.dark"].isSelected)
        app.buttons["global.modal.selection.system"].tap()
        XCTAssertFalse(modal.exists)

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["Traffic Details"].exists)
        XCTAssertEqual(app.buttons["profile.checkUpdate"].label, "Check for Updates")
        app.buttons["navigation.0"].tap()
        let protection = app.staticTexts["Disconnected"].exists
            ? app.staticTexts["Disconnected"] : app.staticTexts["VPN Unavailable"]
        XCTAssertTrue(protection.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Connected"].exists)
        XCTAssertGreaterThanOrEqual(protection.frame.minX, app.frame.minX)
        XCTAssertLessThanOrEqual(protection.frame.maxX, app.frame.maxX)
        app.buttons["navigation.1"].tap()
        XCTAssertTrue(app.buttons["Buy Now"].waitForExistence(timeout: 5))

        app.terminate()
        app.launchArguments = ["--offline", "--ui-sample"]
        app.launch()
        XCTAssertTrue(app.buttons["navigation.2"].waitForExistence(timeout: 10))
        app.buttons["navigation.2"].tap()
        app.buttons["profile.settings"].tap()
        XCTAssertTrue(app.navigationBars["General Settings"].waitForExistence(timeout: 5))

        let persistedRow = app.descendants(matching: .any)["settings.language"].firstMatch
        persistedRow.tap()
        XCTAssertTrue(app.buttons["global.modal.selection.en"].isSelected)
        let chinese = app.buttons["global.modal.selection.zh-Hans"]
        XCTAssertTrue(chinese.waitForExistence(timeout: 5))
        chinese.tap()
        XCTAssertTrue(app.staticTexts["常规设置"].waitForExistence(timeout: 5))
    }
    @MainActor
    func testBrandSwitchPropagatesWithoutPreviousBrandResidue() {
        let app = XCUIApplication(); app.launchArguments = ["--offline", "--ui-sample", "--brand-switch-tests", "-ios.language", "zh-Hans"]; app.launch()
        XCTAssertTrue(app.buttons["navigation.2"].waitForExistence(timeout: 10))
        app.buttons["navigation.2"].tap(); app.buttons["profile.settings"].tap()
        for _ in 0..<4 { if app.buttons["brand.switch.0"].isHittable { break }; app.swipeUp() }
        app.buttons["brand.switch.0"].tap()
        let nameA = app.staticTexts["settings.brand.name"].label
        let logoA = app.images["brand.logo"].firstMatch.value as? String
        let accentA = app.staticTexts["settings.brand.accent"].label
        let supportA = app.staticTexts["settings.brand.support"].label
        app.buttons["brand.switch.1"].tap()
        let nameB = app.staticTexts["settings.brand.name"].label
        XCTAssertNotEqual(nameA, nameB)
        XCTAssertNotEqual(logoA, app.images["brand.logo"].firstMatch.value as? String)
        XCTAssertNotEqual(accentA, app.staticTexts["settings.brand.accent"].label)
        XCTAssertNotEqual(supportA, app.staticTexts["settings.brand.support"].label)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertEqual(app.staticTexts["brand.name"].firstMatch.label, nameB)
        XCTAssertFalse(app.staticTexts[nameA].exists)
        app.buttons["navigation.1"].tap()
        XCTAssertEqual(app.staticTexts["brand.name"].firstMatch.label, nameB)
        app.buttons["navigation.0"].tap()
        XCTAssertEqual(app.staticTexts["brand.name"].firstMatch.label, nameB)
        capture(app, "05-switched-brand")
    }
    @MainActor
    func testProfileSettingsLayoutAndEntryNavigation() {
        let app = XCUIApplication(); app.launchArguments = ["--offline", "--ui-sample", "-ios.language", "zh-Hans"]; app.launch()
        XCTAssertTrue(app.buttons["navigation.2"].waitForExistence(timeout: 10))
        app.buttons["navigation.2"].tap()
        let ids = [
            "profile.orders", "profile.invitations", "profile.traffic",
            "profile.changePassword", "profile.settings", "profile.checkUpdate",
            "profile.aboutSupport", "profile.deleteAccount"
        ]
        XCTAssertFalse(app.buttons["profile.announcements"].exists)
        let profileTabY = app.buttons["navigation.2"].frame.minY
        XCTAssertEqual(app.buttons["navigation.2"].frame.minY, profileTabY, accuracy: 1)
        let website = app.descendants(matching: .any)["shortcut.website"].firstMatch
        let support = app.buttons["shortcut.support"]
        XCTAssertTrue(website.isHittable); XCTAssertTrue(support.isHittable)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "shortcut.website").count, 1)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "在线客服")).count, 1)
        XCTAssertGreaterThanOrEqual(website.frame.width, 44); XCTAssertGreaterThanOrEqual(support.frame.height, 44)

        for id in ids {
            let button = app.buttons[id]
            XCTAssertTrue(button.waitForExistence(timeout: 5), id)
            XCTAssertEqual(app.buttons.matching(identifier: id).count, 1)
            scrollTo(button, app)
            XCTAssertGreaterThanOrEqual(button.frame.height, 56)
            XCTAssertTrue(button.isHittable, id)
        }
        XCTAssertEqual(app.buttons["profile.aboutSupport"].label, "关于")
        for title in ["TG 群组", "系统日志", "版本", "开发者诊断"] {
            XCTAssertFalse(app.staticTexts[title].exists)
        }
        let signOut = app.buttons["profile.signout"]
        scrollTo(signOut, app)
        XCTAssertTrue(signOut.isHittable)
        XCTAssertGreaterThanOrEqual(signOut.frame.height, 56)
        XCTAssertEqual(
            signOut.frame.minY,
            app.buttons["profile.deleteAccount"].frame.maxY + 1,
            accuracy: 1
        )
        let marketingVersion = app.staticTexts["profile.marketing-version"]
        scrollTo(marketingVersion, app)
        XCTAssertTrue(marketingVersion.isHittable)
        XCTAssertTrue(marketingVersion.label.hasPrefix("版本："))
        XCTAssertFalse(app.buttons["profile.marketing-version"].exists)
        XCTAssertGreaterThan(marketingVersion.frame.minY, signOut.frame.maxY)
        let versionToNavigationGap = app.buttons["navigation.2"].frame.minY
            - marketingVersion.frame.maxY
        XCTAssertGreaterThanOrEqual(versionToNavigationGap, 18)
        XCTAssertLessThanOrEqual(versionToNavigationGap, 44)
        let navY = app.buttons["navigation.2"].frame.minY
        app.swipeUp()
        XCTAssertEqual(app.buttons["navigation.2"].frame.minY, navY, accuracy: 1)
        for _ in 0..<4 { app.swipeDown() }
        let tablet = app.frame.width > 700
        capture(app, tablet ? "layout-ipad-portrait-my" : "layout-iphone-my")
        if tablet {
            XCTAssertEqual(app.buttons["profile.settings"].frame.midX, app.frame.midX, accuracy: 2)
            XCTAssertLessThanOrEqual(app.buttons["profile.settings"].frame.width, 430)
            XCUIDevice.shared.orientation = .landscapeLeft
            waitForLandscape(app)
            XCTAssertTrue(app.buttons["profile.settings"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.buttons["profile.settings"].frame.midX, app.frame.midX, accuracy: 2)
            XCTAssertLessThanOrEqual(app.buttons["profile.settings"].frame.width, 430)
            capture(app, "layout-ipad-landscape-my")
            XCUIDevice.shared.orientation = .portrait
            waitForPortrait(app)
        }

        scrollTo(app.buttons["profile.orders"], app)
        app.buttons["profile.orders"].tap()
        let ordersRefresh = app.buttons["profile.orders.refresh"]
        XCTAssertTrue(ordersRefresh.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(ordersRefresh.frame.width, 44)
        XCTAssertGreaterThanOrEqual(ordersRefresh.frame.height, 44)
        back(app)

        scrollTo(app.buttons["profile.traffic"], app)
        app.buttons["profile.traffic"].tap()
        XCTAssertTrue(app.navigationBars["流量明细"].waitForExistence(timeout: 5))
        let trafficRefresh = app.buttons["profile.traffic.refresh"]
        XCTAssertTrue(trafficRefresh.exists)
        XCTAssertGreaterThanOrEqual(trafficRefresh.frame.width, 44)
        XCTAssertGreaterThanOrEqual(trafficRefresh.frame.height, 44)
        XCTAssertTrue(app.staticTexts["记录时间"].exists)
        XCTAssertTrue(app.staticTexts["实际上传"].exists)
        XCTAssertTrue(app.staticTexts["实际下载"].exists)
        XCTAssertTrue(app.staticTexts["合计"].exists)
        XCTAssertTrue(app.staticTexts["535.87 KB"].exists)
        XCTAssertTrue(app.staticTexts["4.84 MB"].exists)
        XCTAssertFalse(app.staticTexts["当前显示账户汇总，按日历史记录尚未接入。"].exists)
        assertShortPageDoesNotScroll(app.staticTexts["535.87 KB"], app)
        back(app)

        scrollTo(app.buttons["profile.invitations"], app)
        app.buttons["profile.invitations"].tap()
        XCTAssertTrue(app.navigationBars["邀请好友"].waitForExistence(timeout: 5))
        let invitationsRefresh = app.buttons["profile.invites.refresh"]
        XCTAssertTrue(invitationsRefresh.exists)
        XCTAssertGreaterThanOrEqual(invitationsRefresh.frame.width, 44)
        XCTAssertGreaterThanOrEqual(invitationsRefresh.frame.height, 44)
        assertShortPageDoesNotScroll(invitationsRefresh, app)
        back(app)

        scrollTo(app.buttons["profile.changePassword"], app)
        app.buttons["profile.changePassword"].tap()
        XCTAssertTrue(app.navigationBars["修改密码"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.images["change-password.title.icon"].exists)
        for field in ["current", "new", "confirmation"] {
            XCTAssertTrue(app.images["change-password.\(field).icon"].exists)
            XCTAssertTrue(app.secureTextFields["change-password.\(field)"].exists)
            XCTAssertTrue(app.buttons["change-password.\(field).visibility"].exists)
        }
        let currentVisibility = app.buttons["change-password.current.visibility"]
        currentVisibility.tap()
        XCTAssertTrue(app.textFields["change-password.current"].waitForExistence(timeout: 2))
        currentVisibility.tap()
        XCTAssertTrue(app.secureTextFields["change-password.current"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["change-password.submit"].exists)
        assertShortPageDoesNotScroll(app.buttons["change-password.submit"], app)
        back(app)

        scrollTo(app.buttons["profile.deleteAccount"], app)
        XCTAssertEqual(app.buttons["profile.deleteAccount"].label, "删除账户")
        app.buttons["profile.deleteAccount"].tap()
        XCTAssertTrue(app.navigationBars["删除账户"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.images["account-deletion.title.icon"].exists)
        XCTAssertTrue(app.staticTexts["此操作将提交永久删除账户申请。"].exists)
        XCTAssertTrue(app.staticTexts["管理员将在 7 日内处理您的申请。"].exists)
        XCTAssertTrue(app.buttons["account-deletion.submit"].exists)
        app.buttons["account-deletion.submit"].tap()
        XCTAssertTrue(app.staticTexts["确认提交永久删除账户申请？提交后管理员将在 7 日内处理。"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["global.modal.primary"].exists)
        XCTAssertTrue(app.buttons["global.modal.secondary"].exists)
        app.buttons["global.modal.secondary"].tap()
        XCTAssertTrue(app.navigationBars["删除账户"].exists)
        back(app)

        scrollTo(app.buttons["profile.settings"], app)
        XCTAssertEqual(app.buttons["profile.settings"].label, "常规设置")
        app.buttons["profile.settings"].tap()
        XCTAssertTrue(app.staticTexts["常规设置"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.images["settings.title.icon"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["settings.language"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["settings.appearance"].firstMatch.exists)
        XCTAssertFalse(app.buttons["settings.developer-diagnostics"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["settings.vpn-state"].firstMatch.exists)
        XCTAssertFalse(app.buttons["settings.logs"].exists)
        XCTAssertFalse(app.buttons["settings.version"].exists)
        assertShortPageDoesNotScroll(
            app.descendants(matching: .any)["settings.language"].firstMatch,
            app
        )
        capture(app, tablet ? "layout-ipad-settings" : "layout-iphone-settings")
        if tablet {
            XCUIDevice.shared.orientation = .landscapeLeft
            waitForLandscape(app)
            XCTAssertTrue(app.navigationBars["常规设置"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.descendants(matching: .any)["settings.appearance"].firstMatch.exists)
            XCUIDevice.shared.orientation = .portrait
            waitForPortrait(app)
        }
        back(app)

        let checkUpdate = app.buttons["profile.checkUpdate"]
        scrollTo(checkUpdate, app)
        XCTAssertEqual(checkUpdate.label, "检查更新")
        XCTAssertFalse(app.descendants(matching: .any)["global.modal"].firstMatch.exists)
        checkUpdate.tap()
        XCTAssertTrue(app.staticTexts["暂时无法检查更新，请稍后重试"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["确定"].exists)
        app.buttons["确定"].tap()

        scrollTo(app.buttons["profile.aboutSupport"], app)
        XCTAssertEqual(app.buttons["profile.aboutSupport"].label, "关于")
        let profileMenuRowHeight = app.buttons["profile.aboutSupport"].frame.height
        app.buttons["profile.aboutSupport"].tap()
        XCTAssertTrue(app.navigationBars["关于"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.images["about.title.icon"].exists)
        XCTAssertFalse(app.staticTexts["关于与支持"].exists)
        let aboutPrivacy = app.descendants(matching: .any)["about.privacy"].firstMatch
        let aboutTerms = app.descendants(matching: .any)["about.terms"].firstMatch
        let aboutWebsite = app.descendants(matching: .any)["about.website"].firstMatch
        let aboutDiagnostics = app.descendants(matching: .any)["about.diagnostics"].firstMatch
        let aboutTelegram = app.descendants(matching: .any)["about.telegram"].firstMatch
        XCTAssertTrue(aboutPrivacy.exists)
        XCTAssertTrue(aboutTerms.exists)
        XCTAssertTrue(aboutWebsite.exists)
        XCTAssertEqual(aboutWebsite.label, "官方网站")
        XCTAssertTrue(aboutDiagnostics.exists)
        XCTAssertTrue(aboutTelegram.exists)
        let aboutRows = [
            aboutPrivacy, aboutTerms, aboutWebsite, aboutDiagnostics, aboutTelegram
        ]
        for row in aboutRows {
            XCTAssertEqual(row.frame.height, profileMenuRowHeight, accuracy: 1)
            XCTAssertEqual(row.frame.minX, aboutPrivacy.frame.minX, accuracy: 1)
            XCTAssertEqual(row.frame.maxX, aboutPrivacy.frame.maxX, accuracy: 1)
        }
        XCTAssertFalse(app.buttons["about.version"].exists)
        XCTAssertFalse(app.staticTexts["版本信息"].exists)
        XCTAssertLessThan(
            aboutPrivacy.frame.minY,
            aboutTerms.frame.minY
        )
        XCTAssertLessThan(
            aboutTerms.frame.minY,
            aboutWebsite.frame.minY
        )
        XCTAssertLessThan(
            aboutWebsite.frame.minY,
            aboutDiagnostics.frame.minY
        )
        XCTAssertLessThan(
            aboutDiagnostics.frame.minY,
            aboutTelegram.frame.minY
        )
        assertShortPageDoesNotScroll(aboutDiagnostics, app)

        aboutPrivacy.tap()
        XCTAssertTrue(app.staticTexts["隐私政策暂时无法打开，请稍后重试"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["确定"].exists)
        app.buttons["确定"].tap()
        aboutTerms.tap()
        XCTAssertTrue(app.staticTexts["服务条款暂时无法打开，请稍后重试"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["确定"].exists)
        app.buttons["确定"].tap()

        aboutDiagnostics.tap()
        XCTAssertTrue(app.navigationBars["诊断日志"].waitForExistence(timeout: 5)); back(app)
        back(app)

        scrollTo(signOut, app)
        signOut.tap()
        let signOutConfirmation = app.staticTexts["确定要退出当前账号吗？"]
        XCTAssertTrue(signOutConfirmation.waitForExistence(timeout: 5))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.5)).tap()
        XCTAssertTrue(signOutConfirmation.exists)
        if app.buttons["取消"].exists { app.buttons["取消"].tap() }
        else { app.otherElements["PopoverDismissRegion"].tap() }
        XCTAssertTrue(app.buttons["profile.settings"].exists)
    }

    @MainActor
    func testProfileLargeTextKeepsBottomContentAccessible() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--offline", "--ui-sample",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge",
            "-ios.language", "zh-Hans",
        ]
        app.launch()
        XCTAssertTrue(app.buttons["navigation.2"].waitForExistence(timeout: 10))
        app.buttons["navigation.2"].tap()

        let orders = app.buttons["profile.orders"]
        XCTAssertTrue(orders.waitForExistence(timeout: 10))
        for _ in 0..<4 { app.swipeDown() }
        let navigationY = app.buttons["navigation.2"].frame.minY

        app.swipeUp()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(app.buttons["navigation.2"].frame.minY, navigationY, accuracy: 1)

        let signOut = app.buttons["profile.signout"]
        let version = app.staticTexts["profile.marketing-version"]
        scrollTo(signOut, app)
        XCTAssertTrue(signOut.isHittable)
        scrollTo(version, app)
        XCTAssertTrue(version.isHittable)
    }

    @MainActor
    func testProfileCompactHeightKeepsRealOverflowScrollable() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--offline", "--ui-sample", "-ios.language", "zh-Hans"]
        app.launch()
        guard app.frame.height < 800 else {
            throw XCTSkip("Compact-height Profile coverage runs on a small iPhone simulator")
        }
        XCTAssertTrue(app.buttons["navigation.2"].waitForExistence(timeout: 10))
        app.buttons["navigation.2"].tap()

        let orders = app.buttons["profile.orders"]
        XCTAssertTrue(orders.waitForExistence(timeout: 10))
        for _ in 0..<4 { app.swipeDown() }
        let initialOrdersY = orders.frame.minY
        let navigationY = app.buttons["navigation.2"].frame.minY

        app.swipeUp()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertLessThan(orders.frame.minY, initialOrdersY - 1)
        XCTAssertEqual(app.buttons["navigation.2"].frame.minY, navigationY, accuracy: 1)

        let signOut = app.buttons["profile.signout"]
        let version = app.staticTexts["profile.marketing-version"]
        scrollTo(signOut, app)
        XCTAssertTrue(signOut.isHittable)
        scrollTo(version, app)
        XCTAssertTrue(version.isHittable)
    }

    @MainActor
    func testTrafficLongFixtureKeepsHeaderFixedAndScrollsToLastRow() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--offline", "--ui-sample", "--ui-traffic-long-list",
            "-ios.language", "zh-Hans"
        ]
        app.launch()
        XCTAssertTrue(app.buttons["navigation.2"].waitForExistence(timeout: 10))
        app.buttons["navigation.2"].tap()
        scrollTo(app.buttons["profile.traffic"], app)
        app.buttons["profile.traffic"].tap()

        let navigationTitle = app.navigationBars["流量明细"]
        let dateHeader = app.staticTexts["记录时间"]
        let uploadHeader = app.staticTexts["实际上传"]
        let downloadHeader = app.staticTexts["实际下载"]
        let totalHeader = app.staticTexts["合计"]
        XCTAssertTrue(navigationTitle.waitForExistence(timeout: 5))
        XCTAssertTrue(dateHeader.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["2026/10/31"].exists)

        let navigationY = navigationTitle.frame.minY
        let headerFrames = [dateHeader, uploadHeader, downloadHeader, totalHeader].map(\.frame)
        let lastDate = app.staticTexts["2026/09/22"]
        for _ in 0..<10 {
            if lastDate.isHittable { break }
            app.swipeUp()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        XCTAssertTrue(lastDate.waitForExistence(timeout: 5))
        XCTAssertTrue(lastDate.isHittable)
        XCTAssertEqual(navigationTitle.frame.minY, navigationY, accuracy: 1)
        let finalHeaderFrames = [dateHeader, uploadHeader, downloadHeader, totalHeader].map(\.frame)
        for (before, after) in zip(headerFrames, finalHeaderFrames) {
            XCTAssertEqual(after.minX, before.minX, accuracy: 1)
            XCTAssertEqual(after.minY, before.minY, accuracy: 1)
        }
        XCTAssertGreaterThanOrEqual(lastDate.frame.minX, 0)
        XCTAssertLessThanOrEqual(lastDate.frame.maxX, app.frame.maxX)
        XCTAssertLessThanOrEqual(
            lastDate.frame.maxY + 10,
            app.buttons["navigation.2"].frame.minY
        )
    }
    @MainActor
    func testDiagnosticsLongFixtureKeepsNavigationFixedAndScrollsToLastRow() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--offline", "--ui-sample", "--ui-diagnostics-long-list",
            "-ios.language", "zh-Hans"
        ]
        app.launch()
        XCTAssertTrue(app.buttons["navigation.2"].waitForExistence(timeout: 10))
        app.buttons["navigation.2"].tap()
        scrollTo(app.buttons["profile.aboutSupport"], app)
        app.buttons["profile.aboutSupport"].tap()
        let diagnostics = app.descendants(matching: .any)["about.diagnostics"].firstMatch
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 5))
        diagnostics.tap()

        let navigationTitle = app.navigationBars["诊断日志"]
        let titleIcon = app.images["diagnostics.title.icon"]
        let export = app.buttons["diagnostics.export"]
        let clear = app.buttons["diagnostics.clear"]
        let firstRow = app.descendants(matching: .any)[
            "diagnostics.row.00000000-0000-4000-8000-000000000001.message"
        ].firstMatch
        XCTAssertTrue(navigationTitle.waitForExistence(timeout: 5))
        XCTAssertTrue(titleIcon.exists)
        XCTAssertTrue(export.exists)
        XCTAssertTrue(clear.exists)
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(firstRow.frame.height, 20)
        for level in ["info", "success", "warning", "error"] {
            XCTAssertTrue(app.descendants(matching: .any)["diagnostics.level.\(level)"].firstMatch.exists)
        }
        let secondShortRow = app.descendants(matching: .any)[
            "diagnostics.row.00000000-0000-4000-8000-000000000002.message"
        ].firstMatch
        let thirdShortRow = app.descendants(matching: .any)[
            "diagnostics.row.00000000-0000-4000-8000-000000000003.message"
        ].firstMatch
        XCTAssertTrue(secondShortRow.exists)
        XCTAssertTrue(thirdShortRow.exists)
        let compactRowPitch = thirdShortRow.frame.minY - secondShortRow.frame.minY
        let baselineRowPitch = 73.33333333333331
        let reduction = 1 - compactRowPitch / baselineRowPitch
        print("DIAGNOSTICS_SHORT_ROW_PITCH=\(compactRowPitch)")
        print("DIAGNOSTICS_SHORT_ROW_REDUCTION=\(reduction)")
        XCTAssertEqual(reduction, 0.2, accuracy: 0.03)

        let navigationFrame = navigationTitle.frame
        let firstRowFrame = firstRow.frame
        app.swipeDown()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(firstRow.frame.minY, firstRowFrame.minY, accuracy: 1)

        let lastRow = app.descendants(matching: .any)[
            "diagnostics.row.00000000-0000-4000-8000-000000000040.message"
        ].firstMatch
        for _ in 0..<18 {
            if lastRow.isHittable { break }
            app.swipeUp()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        XCTAssertTrue(lastRow.waitForExistence(timeout: 5))
        XCTAssertTrue(lastRow.isHittable)
        XCTAssertEqual(navigationTitle.frame.minX, navigationFrame.minX, accuracy: 1)
        XCTAssertEqual(navigationTitle.frame.minY, navigationFrame.minY, accuracy: 1)
        XCTAssertLessThanOrEqual(
            lastRow.frame.maxY + 8,
            app.buttons["navigation.2"].frame.minY
        )
        capture(app, "diagnostics-long-list")
    }
    @MainActor
    func testIPadWindowResizePreservesPage() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--offline", "--ui-sample", "-ios.language", "zh-Hans"]; app.launch()
        XCTAssertTrue(app.buttons["navigation.2"].waitForExistence(timeout: 10))
        guard app.frame.width > 700 else { throw XCTSkip("iPad window resizing only") }
        app.buttons["navigation.2"].tap()
        let window = app.windows.firstMatch
        let before = window.frame
        let screen = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.99))
            .press(forDuration: 0.5, thenDragTo: screen.coordinate(withNormalizedOffset: CGVector(dx: 0.52, dy: 0.85)))
        print("Window resize before: \(before), after: \(window.frame)")
        capture(app, "layout-ipad-narrow-my")
        XCTAssertLessThan(window.frame.width, before.width - 50)
        XCTAssertGreaterThan(app.images["brand.logo"].firstMatch.frame.minY, window.frame.minY + 44)
        let settings = app.buttons["profile.settings"]
        XCTAssertTrue(settings.isHittable)
        XCTAssertLessThanOrEqual(settings.frame.width, 430)
        XCTAssertGreaterThanOrEqual(settings.frame.minX, window.frame.minX)
        XCTAssertLessThanOrEqual(settings.frame.maxX, window.frame.maxX)
        XCTAssertEqual(settings.frame.midX, window.frame.midX, accuracy: 2)
        XCTAssertTrue(app.buttons["navigation.2"].isHittable)
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.99))
            .press(forDuration: 0.5, thenDragTo: screen.coordinate(withNormalizedOffset: CGVector(dx: 0.995, dy: 0.995)))
        XCTAssertTrue(settings.isHittable)
        print("Restored window: \(window.frame)")
        XCTAssertGreaterThanOrEqual(window.frame.width, before.width - 10)
    }
    @MainActor private func waitForLandscape(_ app: XCUIApplication) {
        let landscape = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.frame.width > app.frame.height }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [landscape], timeout: 5), .completed)
    }
    @MainActor private func waitForPortrait(_ app: XCUIApplication) {
        let portrait = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.frame.height > app.frame.width }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [portrait], timeout: 5), .completed)
    }
    @MainActor private func assertNoDeveloperUI(_ app: XCUIApplication) {
        XCTAssertFalse(app.buttons["auth.developer-diagnostics"].exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Developer")
        ).firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "开发者")
        ).firstMatch.exists)
    }
    @MainActor private func assertAuthScreenDoesNotMove(_ app: XCUIApplication) {
        let email = app.descendants(matching: .any)["auth.email"].firstMatch
        XCTAssertTrue(email.waitForExistence(timeout: 10))
        let initialFrame = email.frame
        app.swipeUp()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(email.frame.minY, initialFrame.minY, accuracy: 1)
        app.swipeDown()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(email.frame.minY, initialFrame.minY, accuracy: 1)
    }
    @MainActor private func assertShortPageDoesNotScroll(
        _ anchor: XCUIElement,
        _ app: XCUIApplication
    ) {
        XCTAssertTrue(anchor.waitForExistence(timeout: 5))
        let initialFrame = anchor.frame
        app.swipeUp()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(anchor.frame.minY, initialFrame.minY, accuracy: 1)
        app.swipeDown()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(anchor.frame.minY, initialFrame.minY, accuracy: 1)
    }
    @MainActor private func assertMinimumTouchTarget(
        _ element: XCUIElement,
        _ message: String = ""
    ) {
        // Core Animation may report an exact 44pt layout as 43.999999pt.
        XCTAssertGreaterThanOrEqual(element.frame.width + 0.01, 44, message)
        XCTAssertGreaterThanOrEqual(element.frame.height + 0.01, 44, message)
    }
    @MainActor private func back(_ app: XCUIApplication) { app.navigationBars.buttons.element(boundBy: 0).tap() }
    @MainActor private func scrollTo(_ element: XCUIElement, _ app: XCUIApplication) {
        for _ in 0..<7 { if element.isHittable { return }; app.swipeUp() }
    }
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
