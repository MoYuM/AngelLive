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
//  **拿不到描述文件时不能一刀切**,两种情况结论正好相反:
//  - **模拟器**:构建产物的代码签名里一条 entitlement 都没有(`codesign -d --entitlements`
//    实测为空),碰 CKContainer 必崩 —— 实测 `EXC_BREAKPOINT` 落在
//    `CKContainer.__allocating_init(identifier:)`,由 `FavoriteSyncEngine.shared` 触发。
//    这里必须判不可用。
//  - **App Store / TestFlight**:Apple 重签时会把 embedded.mobileprovision 剥掉,
//    但 entitlements 留在代码签名里(导出的 ipa 上 `codesign -d` 查得到)。而且**上传时
//    Apple 会校验 entitlements 与描述文件是否匹配** —— tvOS 少一个 aps-environment
//    当场就被拒 —— 所以能装到设备上的正式包,必然带着 .entitlements 里声明的容器。
//    这里判可用。
//
//  早先这里把两种情况都当成"不可用"返回空集,正式包于是一律降级;
//  一度又都当成"可用",模拟器立刻崩。两边都踩过,所以现在按环境分开。
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
            let available: Bool
            if let declared = entitledCloudKitContainers {
                available = declared.contains(identifier)
            } else {
                // 没有描述文件可读,按环境判定,理由见文件头。
                #if targetEnvironment(simulator)
                available = false
                #else
                available = true
                #endif
            }
            cached[identifier] = available
            return available
        }
    }

    /// 内嵌描述文件里声明的 CloudKit 容器集合;bundle 里没有描述文件时为 `nil`。
    ///
    /// 区分 `nil` 与空集是有意的:空集表示"有描述文件、但它一个 CloudKit 容器都没声明"
    /// (真的不可用),`nil` 表示"根本没有描述文件可读"(正式分发包或模拟器,按可用处理)。
    private static let entitledCloudKitContainers: Set<String>? = {
        // iOS/tvOS 叫 embedded.mobileprovision,macOS 叫 embedded.provisionprofile。
        let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
            ?? Bundle.main.url(forResource: "embedded", withExtension: "provisionprofile")
        guard let url, let data = try? Data(contentsOf: url) else { return nil }

        // 以下解析失败一律返回空集而不是 nil:描述文件明明在、却读不出内容,
        // 属于"有证据但看不懂",按不可用处理(顶多少同步,不会去踩 CKContainer 崩溃)。
        //
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
