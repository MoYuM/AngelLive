//
//  DanmuSettingModel.swift
//  AngelLiveCore
//
//  Created by Claude on 11/1/25.
//

import Foundation
import SwiftUI
import Observation

@Observable
public final class DanmuSettingModel {

    public static let globalShowDanmu = "SimpleLive.Setting.showDanmu"
    public static let globalShowColorDanmu = "SimpleLive.Setting.showColorDanmu"
    public static let globalDanmuTopMargin = "SimpleLive.Setting.danmuTopMargin"
    public static let globalDanmuBottomMargin = "SimpleLive.Setting.danmuBottomMargin"
    public static let globalDanmuFontSize = "SimpleLive.Setting.danmuFontSize"
    public static let globalDanmuSpeed = "SimpleLive.Setting.danmuSpeed"
    public static let globalDanmuAlpha = "SimpleLive.Setting.danmuAlpha"
    public static let globalDanmuAreaIndex = "SimpleLive.Setting.danmuAreaIndex"
    public static let globalDanmuFontSizeIndex = "SimpleLive.Setting.danmuFontSizeIndex"
    public static let globalDanmuSpeedIndex = "SimpleLive.Setting.danmuSpeedIndex"
    public static let globalDanmuBlockedKeywords = "SimpleLive.Setting.danmuBlockedKeywords"

    public init() {}

    nonisolated public static let danmuAreaArray: [String] = ["顶部1/4", "顶部1/2", "全屏", "底部1/2", "底部1/4"]
    nonisolated public static let danmuSpeedArray: [String] = ["慢速", "正常", "快速"]
    nonisolated public static let danmuFontSizeArray: [String] = ["30", "40", "50", "60", "65"]

    @ObservationIgnored
    public var showDanmu: Bool {
        get {
            access(keyPath: \.showDanmu)
            return UserDefaults.shared.value(forKey: DanmuSettingModel.globalShowDanmu, synchronize: true) as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.showDanmu) {
                UserDefaults.shared.set(newValue, forKey: DanmuSettingModel.globalShowDanmu, synchronize: true)
            }
        }
    }

    public var showColorDanmu: Bool {
        get {
            access(keyPath: \.showColorDanmu)
            return UserDefaults.shared.value(forKey: DanmuSettingModel.globalShowColorDanmu, synchronize: true) as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.showColorDanmu) {
                UserDefaults.shared.set(newValue, forKey: DanmuSettingModel.globalShowColorDanmu, synchronize: true)
            }
        }
    }

    public var danmuTopMargin: Double {
        get {
            access(keyPath: \.danmuTopMargin)
            return UserDefaults.shared.value(forKey: DanmuSettingModel.globalDanmuTopMargin, synchronize: true) as? Double ?? 0.0
        }
        set {
            withMutation(keyPath: \.danmuTopMargin) {
                UserDefaults.shared.set(newValue, forKey: DanmuSettingModel.globalDanmuTopMargin, synchronize: true)
            }
        }
    }

    public var danmuBottomMargin: Double {
        get {
            access(keyPath: \.danmuBottomMargin)
            return UserDefaults.shared.value(forKey: DanmuSettingModel.globalDanmuBottomMargin, synchronize: true) as? Double ?? 0.0
        }
        set {
            withMutation(keyPath: \.danmuBottomMargin) {
                UserDefaults.shared.set(newValue, forKey: DanmuSettingModel.globalDanmuBottomMargin, synchronize: true)
            }
        }
    }

    public var danmuFontSize: Int {
        get {
            access(keyPath: \.danmuFontSize)
            #if os(tvOS)
            return UserDefaults.shared.value(forKey: DanmuSettingModel.globalDanmuFontSize, synchronize: true) as? Int ?? 50
            #else
            return UserDefaults.shared.value(forKey: DanmuSettingModel.globalDanmuFontSize, synchronize: true) as? Int ?? 15
            #endif
        }
        set {
            withMutation(keyPath: \.danmuFontSize) {
                UserDefaults.shared.set(newValue, forKey: DanmuSettingModel.globalDanmuFontSize, synchronize: true)
            }
        }
    }

    public var danmuSpeed: Double {
        get {
            access(keyPath: \.danmuSpeed)
            return UserDefaults.shared.value(forKey: DanmuSettingModel.globalDanmuSpeed, synchronize: true) as? Double ?? 0.7
        }
        set {
            withMutation(keyPath: \.danmuSpeed) {
                UserDefaults.shared.set(newValue, forKey: DanmuSettingModel.globalDanmuSpeed, synchronize: true)
            }
        }
    }

    public var danmuAlpha: Double {
        get {
            access(keyPath: \.danmuAlpha)
            return UserDefaults.shared.value(forKey: DanmuSettingModel.globalDanmuAlpha, synchronize: true) as? Double ?? 1.0
        }
        set {
            withMutation(keyPath: \.danmuAlpha) {
                UserDefaults.shared.set(newValue, forKey: DanmuSettingModel.globalDanmuAlpha, synchronize: true)
            }
        }
    }

    public var danmuAreaIndex: Int {
        get {
            access(keyPath: \.danmuAreaIndex)
            return UserDefaults.shared.value(forKey: DanmuSettingModel.globalDanmuAreaIndex, synchronize: true) as? Int ?? 2
        }
        set {
            withMutation(keyPath: \.danmuAreaIndex) {
                UserDefaults.shared.set(newValue, forKey: DanmuSettingModel.globalDanmuAreaIndex, synchronize: true)
            }
        }
    }

    public var danmuFontSizeIndex: Int {
        get {
            access(keyPath: \.danmuFontSizeIndex)
            return UserDefaults.shared.value(forKey: DanmuSettingModel.globalDanmuFontSizeIndex, synchronize: true) as? Int ?? 1
        }
        set {
            withMutation(keyPath: \.danmuFontSizeIndex) {
                UserDefaults.shared.set(newValue, forKey: DanmuSettingModel.globalDanmuFontSizeIndex, synchronize: true)
            }
        }
    }

    public var danmuSpeedIndex: Int {
        get {
            access(keyPath: \.danmuSpeedIndex)
            return UserDefaults.shared.value(forKey: DanmuSettingModel.globalDanmuSpeedIndex, synchronize: true) as? Int ?? 1
        }
        set {
            withMutation(keyPath: \.danmuSpeedIndex) {
                UserDefaults.shared.set(newValue, forKey: DanmuSettingModel.globalDanmuSpeedIndex, synchronize: true)
            }
        }
    }

    /// User-defined terms that are suppressed before they reach either danmaku surface.
    public var blockedKeywords: [String] {
        get {
            access(keyPath: \.blockedKeywords)
            let stored = UserDefaults.shared.value(forKey: DanmuSettingModel.globalDanmuBlockedKeywords) as? [String] ?? []
            return Self.normalizedBlockedKeywords(stored)
        }
        set {
            withMutation(keyPath: \.blockedKeywords) {
                UserDefaults.shared.set(
                    Self.normalizedBlockedKeywords(newValue),
                    forKey: DanmuSettingModel.globalDanmuBlockedKeywords,
                    synchronize: true
                )
            }
        }
    }

    public func addBlockedKeyword(_ keyword: String) {
        blockedKeywords = blockedKeywords + [keyword]
    }

    public func removeBlockedKeyword(_ keyword: String) {
        blockedKeywords = blockedKeywords.filter { $0 != keyword }
    }

    public func shouldBlockDanmu(_ text: String) -> Bool {
        Self.shouldBlockDanmu(text, keywords: blockedKeywords)
    }

    public static func normalizedBlockedKeywords(_ keywords: [String]) -> [String] {
        var seen = Set<String>()
        return keywords.compactMap { keyword in
            let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let identity = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            return seen.insert(identity).inserted ? trimmed : nil
        }
    }

    public static func shouldBlockDanmu(_ text: String, keywords: [String]) -> Bool {
        let normalizedKeywords = normalizedBlockedKeywords(keywords)
        return normalizedKeywords.contains { keyword in
            text.range(
                of: keyword,
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                range: nil,
                locale: .current
            ) != nil
        }
    }

    public var danmuAlphaString = ""

    public func getDanmuArea() -> (CGFloat, CGFloat) {
        switch danmuAreaIndex {
        case 0:
            return (1080 * 0.25, (1080 * 0.25))
        case 1:
            return (1080 * 0.5, 0)
        case 2:
            return (1080, 0)
        case 3:
            return (1080 * 0.5, 1080 / 2)
        case 4:
            return (1080 * 0.25, 1080 / 4)
        default:
            return (1080, 0)
        }
    }

    public func getDanmuSize() {
        switch danmuFontSizeIndex {
        case 0:
            danmuFontSize = 30
        case 1:
            danmuFontSize = 40
        case 2:
            danmuFontSize = 50
        case 3:
            danmuFontSize = 60
        case 4:
            danmuFontSize = 65
        default:
            danmuFontSize = 50
        }
    }

    public func getDanmuSpeed(index: Int) {
        danmuSpeedIndex = index
        switch index {
        case 0:
            danmuSpeed = 0.5
        case 1:
            danmuSpeed = 0.7
        case 2:
            danmuSpeed = 0.85
        default:
            danmuSpeed = 0.7
        }
    }
}
