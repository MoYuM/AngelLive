//
//  CloudKitAvailability.swift
//  AngelLiveCore
//
//  只回答一个问题:**本 App 的代码签名里到底有没有 claim 这个 CloudKit 容器**。
//
//  这是"调 `CKContainer` 会不会崩"的充要条件,也是这个类型存在的唯一理由。
//  `CKContainer` 的任何入口(含 `.default()`、`init(identifier:)` 本身)在没有对应
//  entitlement 时都是硬崩溃——CloudKit 在 `-[CKContainerImplementation
//  _checkRequiredEntitlements]` 里直接 `brk`,拿不到任何可捕获的错误,
//  所以**不能用"调用 CloudKit API 试试看"的思路探测:探测本身就会崩**。
//
//  「用户登没登录 iCloud」「网络通不通」不归它管——那些由 `CKContainer.accountStatus()`
//  如实回报(`FavoriteService.getCloudState()` 已按状态给出准确文案)。
//
//  **判据必须是二进制实际 claim 的 entitlements,不能是内嵌描述文件。**
//  描述文件说的是"这个签名**允许**声明哪些能力",是**上界**;实际 claim 的是
//  `.entitlements` 的内容。两者关系是 `claim ⊆ profile`,**合法地可以不一致**,
//  签名与上传都不会因此报错。拿上界当实际值用,就会在"profile 有、二进制没 claim"
//  的包上判可用然后崩——线上 2.1.1(build 10) 启动即崩就是这个错位。
//  何况 App Store 重签还会把描述文件整个剥掉,那时连上界都读不到。
//
//  **不确定时一律判不可用**,因为两边代价极不对称:判成不可用只是收藏退回纯本地(功能降级,
//  App 照常能用);判成可用而实际没有,就是启动即崩(整个 App 不可用)。
//
//  模拟器不需要特判:模拟器构建的代码签名里本就一条 entitlement 都没有(实测为空),
//  按同一套判据自然得出"不可用",与真机走的是同一条逻辑。
//

import Foundation

enum CloudKitAvailability {
    static func isContainerAvailable(_ identifier: String) -> Bool {
        guard let declaredContainers else { return false }
        return declaredContainers.contains(identifier)
    }

    /// 判定本体(纯函数,便于测试):`entitlements` 为 `nil` 表示读不出签名。
    static func isContainerAvailable(_ identifier: String, declaredIn entitlements: [String: Any]?) -> Bool {
        guard let containers = iCloudContainers(in: entitlements) else { return false }
        return containers.contains(identifier)
    }

    /// entitlements 里声明的 CloudKit 容器集合;传入 `nil`(读不出签名)时原样返回 `nil`。
    /// 字段类型不是字符串数组时按"没声明"处理,不猜。
    private static func iCloudContainers(in entitlements: [String: Any]?) -> Set<String>? {
        guard let entitlements else { return nil }
        return Set(entitlements["com.apple.developer.icloud-container-identifiers"] as? [String] ?? [])
    }

    /// 本可执行文件签名里声明的容器;读不出时为 `nil`(见上:按不可用处理)。
    /// `static let` 天然只解析一次。存 `Set<String>` 而不是整个 entitlements 字典,
    /// 因为 `[String: Any]` 不是 `Sendable`,做不了并发安全的全局量。
    private static let declaredContainers: Set<String>? = {
        guard let url = Bundle.main.executableURL else {
            Logger.error("拿不到自身可执行文件路径,CloudKit 一律按不可用处理", category: .cloudKit)
            return nil
        }
        guard let entitlements = MachOEntitlements.parse(machOAt: url) else {
            // 二进制没签名或格式没读懂:CloudKit 功能静默降级为纯本地,
            // 留日志以便把"同步没生效"与"用户没登录 iCloud"区分开。
            Logger.error("读不出自身签名 entitlements,CloudKit 一律按不可用处理", category: .cloudKit)
            return nil
        }
        return iCloudContainers(in: entitlements)
    }()
}
