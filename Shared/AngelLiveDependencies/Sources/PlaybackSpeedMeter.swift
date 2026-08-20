#if canImport(KSPlayer)
import Foundation
import os
import QuartzCore
import KSPlayer

/// 补出 `DynamicInfo.networkSpeed`。
///
/// 上游公开版 KSPlayer 的 `DynamicInfo` 没有这个字段(它只存在于赞助制私有分支),
/// 但公开了 `bytesRead`，这里按需差分算出每秒字节数。
///
/// 不额外挂 Timer:KSMEPlayer 每秒更新一次 `@Published displayFPS`,订阅 `DynamicInfo`
/// 的 UI 本来就会每秒重绘,读取本身就是采样时机。没人看的时候不算,也不需要算。
///
/// 用锁而不是 `@MainActor`:统计日志有在非主线程读的路径,收口到主 actor 会 trap。
public enum PlaybackSpeedMeter {

    private struct Sample {
        var bytes: Int64
        var timestamp: CFTimeInterval
        var speed: Double
    }

    /// 取样最小间隔:短于此就复用上次结果,避免一次 body 里多处读取把差分窗口切得过碎。
    private static let minInterval: CFTimeInterval = 0.5
    /// 条目上限。key 是 ObjectIdentifier(不持有对象),播放器换代后旧条目不会自己消失,
    /// 超限时整体清空 —— 顶多让在用的那路重新预热一个采样周期。
    private static let maxEntries = 8

    private static let samples = OSAllocatedUnfairLock(initialState: [ObjectIdentifier: Sample]())

    static func speed(for info: DynamicInfo) -> Double {
        // bytesRead 会回调进 FFmpeg 取值,先在锁外读完再进临界区。
        let bytes = info.bytesRead
        let now = CACurrentMediaTime()
        let key = ObjectIdentifier(info)

        return samples.withLock { store in
            guard var sample = store[key] else {
                if store.count >= maxEntries { store.removeAll() }
                store[key] = Sample(bytes: bytes, timestamp: now, speed: 0)
                return 0
            }

            let elapsed = now - sample.timestamp
            guard elapsed >= minInterval else { return sample.speed }

            let delta = bytes - sample.bytes
            // 播放器重建后 bytesRead 会归零,delta 变负 —— 当作重新预热,不报负速度。
            sample.speed = delta > 0 ? Double(delta) / elapsed : 0
            sample.bytes = bytes
            sample.timestamp = now
            store[key] = sample
            return sample.speed
        }
    }
}

public extension DynamicInfo {
    /// 每秒字节数。
    ///
    /// 优先用 `bytesRead` 差分;它取自 FFmpeg `AVIOContext.bytes_read`,项目实测在部分
    /// 协议/内核组合下恒为 0,这时退回按流自身码率估算 —— 对直播来说码率≈吞吐,
    /// 比明知拿不到还显示 0 有用。
    var networkSpeed: Double {
        let measured = PlaybackSpeedMeter.speed(for: self)
        if measured > 0 { return measured }
        let bitsPerSecond = videoBitrate + audioBitrate
        return bitsPerSecond > 0 ? Double(bitsPerSecond) / 8.0 : 0
    }
}
#endif
