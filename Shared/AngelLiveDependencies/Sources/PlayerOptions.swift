import Foundation
import CoreMedia
#if canImport(KSPlayer)
// 上游的 KSOptions.firstPlayerType / secondPlayerType 是没有隔离标注的可变静态,
// Swift 6 语言模式下直接访问会报 "not concurrency-safe"。@preconcurrency 把这类
// 来自上游模块的诊断降级为警告 —— 上游自己就是这么用的,行为不变。
@preconcurrency import KSPlayer
#endif

public class PlayerOptions: KSOptions, @unchecked Sendable {
    public var syncSystemRate: Bool = false

    // VLC fallback 的 KSOptions shim 自带 playerTypes,只有走真 KSPlayer 时才需要在这补。
    #if canImport(KSPlayer)
    /// 本次会话的播放内核优先级（[主, 备]）。
    ///
    /// 上游公开版 KSPlayer 按全局静态 `KSOptions.firstPlayerType` / `secondPlayerType`
    /// 选内核，赞助制私有分支才是 per-options 的数组。这里保留数组语义（业务层按流格式
    /// 决定走 KSMEPlayer 还是 KSAVPlayer），赋值时同步写进全局静态。
    ///
    /// 依赖一个前提：同一时刻只有一路播放会话在起播。三端播放页都是单例式进入，
    /// 成立；哪天要做多路同播，这里就得跟着上游一起改成实例级。
    public var playerTypes: [MediaPlayerProtocol.Type] = [] {
        didSet {
            guard let first = playerTypes.first else { return }
            KSOptions.firstPlayerType = first
            KSOptions.secondPlayerType = playerTypes.dropFirst().first
        }
    }

    /// 是否直播流。
    ///
    /// 私有分支拿它切直播模式（缓冲/重连策略）；上游公开版没有对应开关，自行按
    /// duration 判定。这里保留字段供业务层读写与日志，对内核不再有直接作用。
    public var isLive: Bool = false
    #endif

    // 上游公开版 KSPlayer 与 VLC fallback shim 的 KSOptions 都有无参 designated init,
    // 两条路径统一 override 即可(赞助制私有分支没有,当时才需要按内核分叉)。
    nonisolated required override public init() {
        super.init()
    }

    override public func updateVideo(refreshRate: Float, isDovi: Bool, formatDescription: CMFormatDescription?) {
        guard syncSystemRate else { return }
        super.updateVideo(refreshRate: refreshRate, isDovi: isDovi, formatDescription: formatDescription)
    }
}
