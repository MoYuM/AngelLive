//
//  AngelLiveUITests.swift
//  AngelLiveUITests
//
//  端测：验证「装好插件源 → 进入斗鱼分类 → 点进一个房间 → 播放页正常出现且 App 未崩溃」这条最短主链路。
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
        app.launchEnvironment["UITEST_DEEPLINK_INSTALL_SOURCE"] =
            "https://ghfast.top/https://raw.githubusercontent.com/MoYuM/angellive-plugins/main/plugins.json"
        app.launch()

        dismissWelcomeIfPresent(app)

        let platformsTab = app.tabBars.buttons["配置"]
        XCTAssertTrue(platformsTab.waitForExistence(timeout: 10), "找不到「配置」tab")
        platformsTab.tap()

        // 插件源安装是异步网络流程（拉索引 + 下载 zip + 解压 + 校验），给足超时。
        let douyuCard = app.buttons["PlatformCard.douyu"]
        XCTAssertTrue(douyuCard.waitForExistence(timeout: 60), "斗鱼插件在 60s 内没有安装完成/出现在平台网格里")

        let douyuNavBar = app.navigationBars["斗鱼直播"]
        let navigated = tapUntil(douyuCard, until: douyuNavBar)
        XCTAssertTrue(navigated, "点击斗鱼卡片多次重试后仍未跳转到平台详情页。当前可见的元素:\n\(app.debugDescription)")

        let firstRoomCell = app.collectionViews.cells["RoomCell_0"]
        XCTAssertTrue(firstRoomCell.waitForExistence(timeout: 90), "斗鱼房间列表在 90s 内没有加载出任何房间。当前可见的元素:\n\(app.debugDescription)")

        let playerContent = app.otherElements["DetailPlayerView.playerContent"]
        let errorView = app.otherElements["DetailPlayerView.errorView"]
        let offlineView = app.otherElements["DetailPlayerView.streamerOfflineView"]

        let enteredRoom = tapUntil(firstRoomCell, untilAnyOf: [playerContent, errorView, offlineView])
        XCTAssertTrue(
            enteredRoom,
            "点击房间多次重试后既没有进播放器、也没有报错/下播提示。当前可见的元素:\n\(app.debugDescription)"
        )

        XCTAssertEqual(app.state, .runningForeground, "进入播放页后 App 已经不在前台运行（崩溃/被系统终止）")

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
