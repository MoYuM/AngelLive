import SwiftUI
import AngelLiveCore

struct DanmakuKeywordBlocklistForm: View {
    @Bindable var settings: DanmuSettingModel
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("输入要屏蔽的关键词", text: $draft)
                    .onSubmit(addKeyword)
                Button("添加", action: addKeyword)
                    .disabled(!canAddKeyword)
            }

            if settings.blockedKeywords.isEmpty {
                Text("命中关键词的弹幕不会显示在聊天或飞屏中")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(settings.blockedKeywords, id: \.self) { keyword in
                    HStack {
                        Text(keyword)
                            .lineLimit(1)
                        Spacer()
                        Button("删除", role: .destructive) {
                            settings.removeBlockedKeyword(keyword)
                        }
                        .accessibilityLabel("删除关键词 \(keyword)")
                    }
                }
            }
        }
    }

    private var normalizedDraft: String? {
        DanmuSettingModel.normalizedBlockedKeywords([draft]).first
    }

    private var canAddKeyword: Bool {
        guard let normalizedDraft else { return false }
        return !settings.blockedKeywords.contains {
            $0.compare(normalizedDraft, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) == .orderedSame
        }
    }

    private func addKeyword() {
        guard let normalizedDraft, canAddKeyword else { return }
        settings.addBlockedKeyword(normalizedDraft)
        draft = ""
    }
}
