//
//  AngelLiveUITests.swift
//  AngelLiveUITests
//
//  端测：验证「装好插件源 → 进入斗鱼分类 → 点进一个房间 → 播放页正常出现且 App 未崩溃」这条最短主链路，
//  以及「进房间后再返回」这条链路。
//  通过 UITEST_DEEPLINK_INSTALL_SOURCE 环境变量触发 ContentView 里的 DEBUG-only 深链安装钩子，
//  跳过「启动 Safari 输入 URL 唤起 App」这条在自动化环境下不稳定的路径。
//

import XCTest

final class AngelLiveUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testEnterDouyuRoomStartsPlayback() throws {
        let app = XCUIApplication()
        let playerContent = enterFirstDouyuRoom(app: app)

        // 如果确实进了播放分支，再多等一会——之前的崩溃(Now Playing 封面图)是在真正开始播放、
        // 系统查询锁屏信息时才触发的，仅仅“出现播放器视图”这一刻还不够，要看它撑不撑得住。
        if playerContent.exists {
            attachScreenshot(named: "player_t0", to: app)
            Thread.sleep(forTimeInterval: 4)
            attachScreenshot(named: "player_t4", to: app)
            XCTAssertEqual(app.state, .runningForeground, "播放开始后的几秒内 App 崩溃了")
            Thread.sleep(forTimeInterval: 8)
            attachScreenshot(named: "player_t12", to: app)
            XCTAssertEqual(app.state, .runningForeground, "播放开始后的几秒内 App 崩溃了")
            // 弹幕是异步到达的实时数据，给到最后再多等一会儿方便截图里能看到。
            Thread.sleep(forTimeInterval: 10)
            attachScreenshot(named: "player_t22", to: app)
        }
    }

    func testEnterDouyinRoomStartsPlayback() throws {
        let app = XCUIApplication()
        let playerContent = enterFirstRoom(app: app, pluginId: "douyin", platformTitle: "抖音直播")
        attachScreenshot(named: "douyin_entered", to: app)
        XCTAssertTrue(playerContent.exists, "抖音房间没有进入正常播放分支（报错或判成下播）。当前可见的元素:\n\(app.debugDescription)")

        Thread.sleep(forTimeInterval: 4)
        attachScreenshot(named: "douyin_player_t4", to: app)
        XCTAssertEqual(app.state, .runningForeground, "抖音播放开始后的几秒内 App 崩溃了")
        // 弹幕是异步到达的实时数据，多等一会儿方便截图里能看到。
        Thread.sleep(forTimeInterval: 12)
        attachScreenshot(named: "douyin_player_t16", to: app)
        XCTAssertEqual(app.state, .runningForeground, "抖音播放十几秒后 App 崩溃了")
    }

    func testGoBackFromRoomDoesNotCrash() throws {
        let app = XCUIApplication()
        let playerContent = enterFirstDouyuRoom(app: app)
        try XCTSkipUnless(playerContent.exists, "没有进到正常播放分支(可能下播/报错),跳过返回测试")

        Thread.sleep(forTimeInterval: 2)
        attachScreenshot(named: "before_back", to: app)
        XCTAssertEqual(app.state, .runningForeground, "进播放页 2 秒后 App 已经崩溃了")

        // 控制层(含返回按钮) 5 秒无操作会自动隐藏(UnifiedPlayerControlOverlay 的 autoHideTask),
        // 而 enterFirstDouyuRoom 光是等起播就要耗掉好几秒 —— 靠"缩短等待挤进 5 秒窗口"是跟
        // 计时器赛跑,起播快慢一变就翻车(这条测试已经为此改过两轮)。改成跟真人一样:
        // 没看到按钮就单击播放区把控制层唤回来。已经显示时不要盲点,那一下反而会把它切掉。
        let backButton = app.buttons["UnifiedPlayerControlOverlay.backButton"]
        if !backButton.waitForExistence(timeout: 3) {
            // 这个 identifier 在视图树里有多个匹配(SwiftUI 容器套了几层),直接取会报
            // "Multiple matching elements",要 firstMatch。
            let playerSurface = app.otherElements
                .matching(identifier: "DetailPlayerView.playerContent")
                .firstMatch
            playerSurface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(
            backButton.waitForExistence(timeout: 3),
            "唤起控制层后返回按钮仍未出现。当前可见的元素:\n\(app.debugDescription)"
        )

        let douyuNavBar = app.navigationBars["斗鱼直播"]
        let wentBack = tapUntil(backButton, until: douyuNavBar)

        XCTAssertEqual(app.state, .runningForeground, "点返回后 App 崩溃了")
        attachScreenshot(named: "after_back", to: app)

        XCTAssertTrue(
            wentBack,
            "点返回按钮多次重试后仍未回到房间列表页。当前可见的元素:\n\(app.debugDescription)"
        )

        // 返回后再多等几秒，防止是异步清理(取消播放任务/断开弹幕连接等)延迟触发的崩溃。
        Thread.sleep(forTimeInterval: 5)
        XCTAssertEqual(app.state, .runningForeground, "返回房间列表后几秒内 App 崩溃了")
    }

    /// 插件源地址：默认线上源；本地调试可用 UITEST_PLUGIN_SOURCE 环境变量覆盖（如 http://127.0.0.1:8765/plugins.json）。
    private var pluginSourceURL: String {
        ProcessInfo.processInfo.environment["UITEST_PLUGIN_SOURCE"]
            ?? "https://ghfast.top/https://raw.githubusercontent.com/MoYuM/angellive-plugins/main/plugins.json"
    }

    private func enterFirstDouyuRoom(app: XCUIApplication) -> XCUIElement {
        enterFirstRoom(app: app, pluginId: "douyu", platformTitle: "斗鱼直播")
    }

    /// 走完整链路：装插件源 → 进指定平台分类 → 点第一个房间 → 到达播放页三态之一。
    /// 返回 playerContent 元素，调用方通过 `.exists` 判断是否真的进了正常播放分支。
    private func enterFirstRoom(app: XCUIApplication, pluginId: String, platformTitle: String) -> XCUIElement {
        app.launchEnvironment["UITEST_DEEPLINK_INSTALL_SOURCE"] = pluginSourceURL
        app.launch()

        dismissWelcomeIfPresent(app)

        let platformsTab = app.tabBars.buttons["配置"]
        XCTAssertTrue(platformsTab.waitForExistence(timeout: 10), "找不到「配置」tab")
        platformsTab.tap()

        // 源里含带登录能力的插件时，宿主会先弹凭证风险确认框，点「继续安装」才会真正下载。
        let consentButton = app.alerts.buttons["继续安装"]
        if consentButton.waitForExistence(timeout: 15) {
            consentButton.tap()
        }

        // 插件源安装是异步网络流程（拉索引 + 下载 zip + 解压 + 校验），给足超时。
        let platformCard = app.buttons["PlatformCard.\(pluginId)"]
        XCTAssertTrue(platformCard.waitForExistence(timeout: 60), "\(platformTitle)插件在 60s 内没有安装完成/出现在平台网格里")

        let platformNavBar = app.navigationBars[platformTitle]
        let navigated = tapUntil(platformCard, until: platformNavBar)
        XCTAssertTrue(navigated, "点击\(platformTitle)卡片多次重试后仍未跳转到平台详情页。当前可见的元素:\n\(app.debugDescription)")

        let firstRoomCell = app.collectionViews.cells["RoomCell_0"]
        XCTAssertTrue(firstRoomCell.waitForExistence(timeout: 90), "\(platformTitle)房间列表在 90s 内没有加载出任何房间。当前可见的元素:\n\(app.debugDescription)")

        let playerContent = app.otherElements["DetailPlayerView.playerContent"]
        let errorView = app.otherElements["DetailPlayerView.errorView"]
        let offlineView = app.otherElements["DetailPlayerView.streamerOfflineView"]

        let enteredRoom = tapUntil(firstRoomCell, untilAnyOf: [playerContent, errorView, offlineView])
        XCTAssertTrue(
            enteredRoom,
            "点击房间多次重试后既没有进播放器、也没有报错/下播提示。当前可见的元素:\n\(app.debugDescription)"
        )
        XCTAssertEqual(app.state, .runningForeground, "进入播放页后 App 已经不在前台运行（崩溃/被系统终止）")

        return playerContent
    }

    private func attachScreenshot(named name: String, to app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func dismissWelcomeIfPresent(_ app: XCUIApplication) {
        let startButton = app.buttons["开始使用"]
        if startButton.waitForExistence(timeout: 5) {
            startButton.tap()
        }
    }

    /// 点击 element，短超时内确认某个目标元素出现；没出现就重试。
    ///
    /// 两个问题在这条链路上都遇到过，用同一个 helper 兜底：
    /// 1. NavigationLink/fullScreenCover 转场动画期间 `element.tap()` 可能落空
    ///    （existence 不等于真正可点击到）。
    /// 2. UICollectionView 刚布局出的 cell 偶发 "Activation point invalid" ——
    ///    改用坐标点击（自己算中心点）而不是让 XCUITest 自动推断命中点。
    @discardableResult
    private func tapUntil(_ element: XCUIElement, until target: XCUIElement, attempts: Int = 5) -> Bool {
        tapUntil(element, untilAnyOf: [target], attempts: attempts)
    }

    @discardableResult
    private func tapUntil(_ element: XCUIElement, untilAnyOf targets: [XCUIElement], attempts: Int = 5) -> Bool {
        for _ in 0..<attempts {
            if element.isHittable {
                element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
            if targets.contains(where: { $0.waitForExistence(timeout: 3) }) {
                return true
            }
        }
        return false
    }
}
