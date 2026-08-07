import Foundation
import CoreMedia

public class PlayerOptions: KSOptions, @unchecked Sendable {
    public var syncSystemRate: Bool = false

    // KSOptions.init() 只在 VLCKitSPM/VLCKit 的 KSPlayerFallback shim 里显式声明,
    // 真实 KSPlayer(LGPL 分支)那边没有可匹配的无参数指定初始化器,
    // 因此 override 是否需要取决于链接的是哪个内核,两条路径都要保持可编译。
    #if canImport(VLCKitSPM) || canImport(VLCKit)
    nonisolated required override public init() {
        super.init()
    }
    #else
    nonisolated required public init() {
        super.init()
    }
    #endif

    override public func updateVideo(refreshRate: Float, isDovi: Bool, formatDescription: CMFormatDescription) {
        guard syncSystemRate else { return }
        super.updateVideo(refreshRate: refreshRate, isDovi: isDovi, formatDescription: formatDescription)
    }
}
