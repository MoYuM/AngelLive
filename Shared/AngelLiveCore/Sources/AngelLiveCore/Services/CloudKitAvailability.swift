//
//  CloudKitAvailability.swift
//  AngelLiveCore
//
//  CKContainer 的任何入口(包括 .default()、init(identifier:)本身)在 entitlements 里没有
//  声明 icloud-container-identifiers 时都是硬崩溃(NSInvalidArgumentException/EXC_BREAKPOINT),
//  这是 Apple CloudKit 的既定行为,不是"未签名本地包"限定的问题——TestFlight 签名正式包一样会崩
//  (已通过线上崩溃日志确认:CKContainer.default() 在 +[CKContainer defaultContainer] 内部
//  直接 SIGTRAP)。
//
//  当前 iOS/AngelLive/AngelLive.entitlements 是空字典(注册这个 Bundle ID 的 Apple 开发者账号未
//  开通 iCloud 能力),因此这里不能再用"调用 CloudKit API 探测是否可用"的思路——探测本身就会崩。
//  只能在代码里用编译期已知的事实直接判定不可用,彻底不触碰 CKContainer。
//
//  如果之后在 entitlements 里补上了 icloud-container-identifiers,把下面 isEnabled 改回 true
//  (并按需恢复真正的容器匹配逻辑)。
//

enum CloudKitAvailability {
    /// AngelLive.entitlements 目前不含 iCloud 容器声明,任何 CKContainer 调用都会崩溃,
    /// 所以这里不导入 CloudKit、不做任何探测,直接返回不可用。
    private static let isEnabled = false

    static func isContainerAvailable(_ identifier: String) -> Bool {
        isEnabled
    }
}
