//
//  AngelLiveTVOSUITests.swift
//  AngelLiveTVOSUITests
//
//  端测第一步：验证 tvOS 端也能走通「装插件源 → 切到配置 tab → 斗鱼卡片出现」这条最短链路。
//  tvOS 是遥控器焦点导航，不是触屏 tap，用 XCUIRemote 模拟方向键 + select。
//  通过 UITEST_DEEPLINK_INSTALL_SOURCE 环境变量触发 ContentView 里的 DEBUG-only 安装钩子。
//

import XCTest

final class AngelLiveTVOSUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testInstallPluginAndSeeDouyuCard() throws {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_DEEPLINK_INSTALL_SOURCE"] =
            "https://ghfast.top/https://raw.githubusercontent.com/MoYuM/angellive-plugins/main/plugins.json"
        app.launch()

        let remote = XCUIRemote.shared

        let platformsTab = app.buttons["配置"]
        XCTAssertTrue(
            platformsTab.waitForExistence(timeout: 10),
            "找不到「配置」tab。当前可见元素:\n\(app.debugDescription)"
        )

        XCTAssertTrue(
            moveFocus(remote, direction: .right, to: platformsTab, maxPresses: 4),
            "方向键右移多次仍未把焦点移到「配置」tab。当前可见元素:\n\(app.debugDescription)"
        )
        remote.press(.select)

        // 插件源安装是异步网络流程（拉索引 + 下载 zip + 解压 + 校验），给足超时。
        let douyuCard = app.buttons["PlatformCard.douyu"]
        XCTAssertTrue(
            douyuCard.waitForExistence(timeout: 60),
            "斗鱼插件在 60s 内没有安装完成/出现在平台网格里。当前可见元素:\n\(app.debugDescription)"
        )
    }

    /// 验证进房间之后播放器不会卡死在 connecting：装插件 → 配置tab点斗鱼卡片 → 进房间列表 →
    /// 选第一个房间 → 播放器必须在合理时间内脱离"connecting"占位态。
    /// 这条测试是为了复现/验证 KSPlayerFallback.swift 里 Coordinator 没转发 VLC 播放状态导致的卡死 bug。
    func testEnterDouyuRoomStartsPlayback() throws {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_DEEPLINK_INSTALL_SOURCE"] =
            "https://ghfast.top/https://raw.githubusercontent.com/MoYuM/angellive-plugins/main/plugins.json"
        app.launch()

        let remote = XCUIRemote.shared

        let platformsTab = app.buttons["配置"]
        XCTAssertTrue(platformsTab.waitForExistence(timeout: 10), "找不到「配置」tab")
        XCTAssertTrue(moveFocus(remote, direction: .right, to: platformsTab, maxPresses: 4), "焦点没能移到「配置」tab")
        remote.press(.select)

        let douyuCard = app.buttons["PlatformCard.douyu"]
        XCTAssertTrue(douyuCard.waitForExistence(timeout: 60), "斗鱼插件卡片没在 60s 内出现")
        XCTAssertTrue(waitForFocus(douyuCard, timeout: 5), "斗鱼卡片没有自动获得焦点")
        remote.press(.select)

        // 房间列表拉取是网络请求，给足超时；进列表后首个房间卡片会自动获得初始焦点。
        let firstRoomCell = app.buttons["RoomCell_0"]
        XCTAssertTrue(firstRoomCell.waitForExistence(timeout: 30), "斗鱼房间列表 30s 内没加载出来。当前可见元素:\n\(app.debugDescription)")
        XCTAssertTrue(waitForFocus(firstRoomCell, timeout: 10), "第一个房间卡片没有自动获得焦点")
        remote.press(.select)

        let playerContent = app.descendants(matching: .any)["DetailPlayerView.playerContent"]
        XCTAssertTrue(playerContent.waitForExistence(timeout: 15), "点击房间后没有进入播放页。当前可见元素:\n\(app.debugDescription)")

        let errorView = app.descendants(matching: .any)["DetailPlayerView.errorView"]
        let offlineView = app.descendants(matching: .any)["DetailPlayerView.streamerOfflineView"]
        let connectingPlaceholder = app.descendants(matching: .any)["TVStreamPlaceholder.connecting"]

        // 起播（VLC 收到首个 .playing 状态）比装插件慢得多但也不该无限久；20s 内必须脱离 connecting。
        let deadline = Date().addingTimeInterval(20)
        var leftConnectingState = false
        while Date() < deadline {
            if errorView.exists {
                XCTFail("播放失败，进入了错误页而不是卡在 connecting。当前可见元素:\n\(app.debugDescription)")
                return
            }
            if offlineView.exists {
                XCTFail("提示主播已下播，换一个房间重跑此测试。")
                return
            }
            if !connectingPlaceholder.exists {
                leftConnectingState = true
                break
            }
            Thread.sleep(forTimeInterval: 1)
        }

        XCTAssertTrue(
            leftConnectingState,
            "进房间 20s 后仍卡在 connecting 占位态，播放器状态回调没有正确驱动 UI。当前可见元素:\n\(app.debugDescription)"
        )
    }

    /// 沿指定方向按遥控器方向键，每次检查目标元素是否已获得焦点。
    /// tvOS 焦点导航跟 iOS tap 坐标完全是两套模型，不能直接复用 iOS 端测的 tapUntil。
    private func moveFocus(
        _ remote: XCUIRemote,
        direction: XCUIRemote.Button,
        to element: XCUIElement,
        maxPresses: Int
    ) -> Bool {
        for _ in 0..<maxPresses {
            if element.hasFocus { return true }
            remote.press(direction)
            Thread.sleep(forTimeInterval: 0.3)
        }
        return element.hasFocus
    }

    /// 轮询等待元素自动获得焦点（不发遥控器按键），用于列表/网格首次加载后系统自动置焦的场景。
    private func waitForFocus(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.hasFocus { return true }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return element.hasFocus
    }
}
