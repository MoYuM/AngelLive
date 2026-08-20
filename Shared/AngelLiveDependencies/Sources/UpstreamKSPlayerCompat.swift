#if canImport(KSPlayer)
import os
import MediaPlayer
import SwiftUI
import KSPlayer

// 抹平「上游公开版 KSPlayer」与「赞助制私有分支」之间的命名差异。
//
// 私有分支把远程控制事件、画中画这些能力拆在 `KSComplexPlayerLayer` 里；上游公开版
// 直接并进了 `KSPlayerLayer`(registerRemoteControllEvent / player.pipController 都在它身上)。
// 这里给个别名，调用点不用改。
//
// 注意语义差别:`x is KSComplexPlayerLayer` 在私有分支上是「这一路支持 PiP」的判据，
// 别名之后恒为 true。真要判 PiP 能力，用 `player.pipController != nil`。
public typealias KSComplexPlayerLayer = KSPlayerLayer

/// 字幕数据源。上游把类型名拼成了 `SubtitleDataSouce`（少一个 r），私有分支改正成
/// `SubtitleDataSource`，iOS 端沿用的是后者。别名对齐，调用点不动。
public typealias SubtitleDataSource = SubtitleDataSouce

/// 解码方式。上游公开版 `KSOptions` 只有 `hardwareDecode: Bool`，私有分支给的是带
/// `rawValue` 的枚举，三端统计面板直接读 `videoDecodeType.rawValue` 展示。
/// 名字和取值跟 VLC fallback 里的同名枚举对齐。
public enum KSDecodeType: String {
    case hardware
    case software
}

public extension KSOptions {
    var videoDecodeType: KSDecodeType { hardwareDecode ? .hardware : .software }
}

// MARK: - 私有分支独有的全局开关

// 上游公开版的 KSOptions 没有这两个静态开关。extension 不能加存储属性，
// 用带锁的独立存储 + 静态计算属性代理（可变全局按项目规范走 OSAllocatedUnfairLock）。
private let hudLogStorage = OSAllocatedUnfairLock(initialState: false)
// 必须写全 SwiftUI.Image：KSPlayer 自己也导出了一个跨平台的 Image 别名,裸写会歧义。
private let subtitleDynamicRangeStorage = OSAllocatedUnfairLock(
    initialState: Optional<SwiftUI.Image.DynamicRange>.none
)

public extension KSOptions {
    /// 播放器 HUD 调试浮层开关。三端启动时都置 false。
    static var hudLog: Bool {
        get { hudLogStorage.withLock { $0 } }
        set { hudLogStorage.withLock { $0 = newValue } }
    }

    /// 字幕层允许的动态范围，iOS 端传给 SwiftUI 的 `allowedDynamicRange(_:)`。
    /// 默认 nil = 不额外限制，交给系统决定。
    static var subtitleDynamicRange: SwiftUI.Image.DynamicRange? {
        get { subtitleDynamicRangeStorage.withLock { $0 } }
        set { subtitleDynamicRangeStorage.withLock { $0 = newValue } }
    }
}

public extension KSPlayerLayer {
    /// 当前是否处于画中画。
    ///
    /// 私有分支把它挂在 layer 上；上游只暴露 `player.pipController`，
    /// 这里照搬上游自己在 KSPlayerLayer 内部的判定写法。
    var isPictureInPictureActive: Bool {
        if #available(tvOS 14.0, iOS 14.0, macOS 11.0, *) {
            return player.pipController?.isPictureInPictureActive == true
        }
        return false
    }

    /// 开始画中画。
    ///
    /// 私有分支把 PiP 的启停做成了 layer 上的一对方法；上游唯一的公开入口是
    /// `isPipActive`，它的 didSet 负责驱动 `pipController.start/stop`。
    ///
    /// 这里可以放心地重复赋同一个值：上游那个 didSet 没有 `oldValue != newValue` 判断，
    /// 每次赋值都会真的走一遍 start —— 这点很关键，因为 `isPipActive` 只是「意图」标志，
    /// 用户直接点掉 PiP 小窗时上游只走 `didStopPictureInPicture`、不复位它，
    /// 若 didSet 挑值才触发，PiP 就再也起不来了。
    func pipStart() {
        isPipActive = true
    }

    /// 退出画中画。
    ///
    /// 参数在当前配置下无实际作用：上游 `isPipActive = false` 固定走
    /// `stop(restoreUserInterface: true)`，而 `stop` 里恢复 UI 那段被
    /// `KSOptions.isPipPopViewController` 挡着（默认 false，本项目是纯 SwiftUI，
    /// 不需要它去 pop/push UIViewController），传 true 传 false 都只做
    /// `stopPictureInPicture()` + 摘 delegate。保留形参是为了调用点不动。
    func pipStop(restoreUserInterface _: Bool) {
        isPipActive = false
    }

    /// 停止并复位到可重新起播的状态。
    ///
    /// 私有分支有 `reset()`；上游把等价语义放在 `stop()` 里（state 归 .initialized +
    /// player.shutdown()），之后照常 `prepareToPlay()` 即可重新起播。
    func reset() {
        stop()
    }

    /// 注销远程控制事件。
    ///
    /// 上游只提供了 `registerRemoteControllEvent()`，配对的注销内联在 `deinit` 里，
    /// 没有单独的公开方法；而播放会话管理需要在「交出远程控制权」时主动注销。
    /// 这里照搬上游 deinit 里那组 removeTarget，命令集合保持一致。
    func removeRemoteControllEvent() {
        let remoteCommand = MPRemoteCommandCenter.shared()
        remoteCommand.playCommand.removeTarget(nil)
        remoteCommand.pauseCommand.removeTarget(nil)
        remoteCommand.togglePlayPauseCommand.removeTarget(nil)
        remoteCommand.stopCommand.removeTarget(nil)
        remoteCommand.nextTrackCommand.removeTarget(nil)
        remoteCommand.previousTrackCommand.removeTarget(nil)
        remoteCommand.changeRepeatModeCommand.removeTarget(nil)
        remoteCommand.changePlaybackRateCommand.removeTarget(nil)
        remoteCommand.skipForwardCommand.removeTarget(nil)
        remoteCommand.skipBackwardCommand.removeTarget(nil)
        remoteCommand.changePlaybackPositionCommand.removeTarget(nil)
        remoteCommand.enableLanguageOptionCommand.removeTarget(nil)
    }
}
#endif
