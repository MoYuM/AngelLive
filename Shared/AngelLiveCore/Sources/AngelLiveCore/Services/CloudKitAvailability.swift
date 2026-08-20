//
//  CloudKitAvailability.swift
//  AngelLiveCore
//
//  CKContainer 的任何入口(包括 .default()、init(identifier:)本身)在 entitlements 里没有
//  声明 icloud-container-identifiers 时都是硬崩溃(NSInvalidArgumentException/EXC_BREAKPOINT),
//  这是 Apple CloudKit 的既定行为,不是"未签名本地包"限定的问题——TestFlight 签名正式包一样会崩
//  (已通过线上崩溃日志确认:CKContainer.default() 在 +[CKContainer defaultContainer] 内部
//  直接 SIGTRAP)。所以不能用"调用 CloudKit API 探测是否可用"的思路——探测本身就会崩。
//
//  这里只回答一个问题:**本 App 的 entitlements 里到底有没有声明这个 CloudKit 容器**。
//  这正是"调 CKContainer 会不会崩"的判据,也是这个类型存在的唯一理由。
//  「用户登没登录 iCloud」「网络通不通」不归它管——那些由 CKContainer.accountStatus()
//  如实回报(FavoriteService.getCloudState() 已按状态给出准确文案)。
//
//  曾经用 FileManager.url(forUbiquityContainerIdentifier:) 探测,是错的,两个原因:
//  1. 那个 API 管的是 **ubiquity 容器**(iCloud Drive 文档存储),由另一套
//     com.apple.developer.ubiquity-container-identifiers 授权,与 CloudKit 容器不是一回事;
//     只开 CloudKit 时它照样返回 nil。
//  2. 它在"没声明 entitlement"和"用户没登录 iCloud"两种情况下都返回 nil,两者分不开,
//     于是没登录 iCloud 会被误报成"CloudKit 服务不可用",把真正的原因盖掉。
//  (SecTaskCopyValueForEntitlement 能直接读运行进程自己的 entitlements,但它在 iOS/tvOS
//  公开 SDK 里没有暴露,编译不过,弃用。)
//
//  退而求其次读内嵌的描述文件。注意它描述的是"这个签名**允许**哪些容器",而二进制实际
//  claim 的是 .entitlements 文件的内容,后者必须是前者的子集。两边由同一个仓库一起维护、
//  构建时也会因不匹配而签名失败,所以实践中一致;真要人为改到不一致,会在构建期就暴露。
//
//  解析结果按 identifier 缓存,不让每次业务调用都重新读文件。
//

import Foundation
import os

enum CloudKitAvailability {
    private static let cache = OSAllocatedUnfairLock(initialState: [String: Bool]())

    static func isContainerAvailable(_ identifier: String) -> Bool {
        cache.withLock { cached in
            if let available = cached[identifier] { return available }
            let available = entitledCloudKitContainers.contains(identifier)
            cached[identifier] = available
            return available
        }
    }

    /// 内嵌描述文件里声明的 CloudKit 容器集合。
    ///
    /// 模拟器构建没有内嵌描述文件,这里会是空集 —— 模拟器上不跑 CloudKit 同步,
    /// 收藏走纯本地那条路(本来就是本地优先),既不崩也不影响端测。
    private static let entitledCloudKitContainers: Set<String> = {
        // iOS/tvOS 叫 embedded.mobileprovision,macOS 叫 embedded.provisionprofile。
        let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
            ?? Bundle.main.url(forResource: "embedded", withExtension: "provisionprofile")
        guard let url, let data = try? Data(contentsOf: url) else { return [] }

        // 描述文件是 CMS 签名包着一段 XML plist。iOS/tvOS 没有公开的 CMS 解码 API
        // (CMSDecoder 只在 macOS),按通行做法直接在字节流里截出那段 plist。
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(
                  of: Data("</plist>".utf8),
                  options: [],
                  in: start.lowerBound ..< data.endIndex
              )
        else { return [] }

        guard let plist = try? PropertyListSerialization.propertyList(
            from: data[start.lowerBound ..< end.upperBound],
            format: nil
        ) as? [String: Any],
            let entitlements = plist["Entitlements"] as? [String: Any],
            let containers = entitlements["com.apple.developer.icloud-container-identifiers"] as? [String]
        else { return [] }

        return Set(containers)
    }()
}
