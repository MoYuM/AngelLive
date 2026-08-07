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
//  改用 FileManager.url(forUbiquityContainerIdentifier:) 探测:这是 Apple 官方给的、专门
//  设计成"探测不到就安静返回 nil"的公开 API(entitlements 没声明该容器、或者设备没登录
//  iCloud,都只是 nil,不崩溃),不像 CKContainer 那样对缺失的 entitlements 零容忍。
//  (SecTaskCopyValueForEntitlement 在 iOS/tvOS 公开 SDK 里没有暴露,编译不过,弃用。)
//  这样各平台/target 各自的 entitlements 状态变化(比如以后给 tvOS 补上 iCloud 容器)会
//  自动生效,不需要再手动回来改代码里的开关。
//
//  这个探测调用有首次的同步 I/O 开销,按 identifier 缓存一次,不让每次业务调用都重新探测。
//

import Foundation
import os

enum CloudKitAvailability {
    private static let cache = OSAllocatedUnfairLock(initialState: [String: Bool]())

    static func isContainerAvailable(_ identifier: String) -> Bool {
        cache.withLock { cached in
            if let available = cached[identifier] { return available }
            let available = FileManager.default.url(forUbiquityContainerIdentifier: identifier) != nil
            cached[identifier] = available
            return available
        }
    }
}
