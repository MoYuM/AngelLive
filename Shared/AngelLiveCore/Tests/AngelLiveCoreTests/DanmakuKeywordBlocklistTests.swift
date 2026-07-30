import Testing
@testable import AngelLiveCore

@Suite("Danmaku keyword blocklist")
struct DanmakuKeywordBlocklistTests {
    @Test("keywords are trimmed and deduplicated case-insensitively")
    func normalizesKeywords() {
        #expect(
            DanmuSettingModel.normalizedBlockedKeywords(["  spam ", "SPAM", "", "剧透", "\n剧透\t"])
                == ["spam", "剧透"]
        )
    }

    @Test("a matching keyword suppresses danmaku regardless of case")
    func matchesKeywordInMessage() {
        #expect(DanmuSettingModel.shouldBlockDanmu("This is SPAM content", keywords: ["spam"]))
        #expect(DanmuSettingModel.shouldBlockDanmu("请不要剧透结局", keywords: ["剧透"]))
    }

    @Test("blank and nonmatching keywords do not suppress danmaku")
    func ignoresBlankAndNonmatchingKeywords() {
        #expect(!DanmuSettingModel.shouldBlockDanmu("正常弹幕", keywords: ["", "   ", "广告"]))
    }
}
