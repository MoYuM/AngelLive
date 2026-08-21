import Foundation
import Testing

@testable import AngelLiveCore

/// 插件返回的房间信息里 liveState 字段格式并不统一——有的插件（如斗鱼自建插件）
/// 返回语义化字符串（"live"/"close"/"video"），有的直接返回宿主 `LiveState` 的
/// 数值 rawValue（"0"~"3"）。`toLiveModel` 必须把两种格式都归一化成宿主能
/// `LiveState(rawValue:)` 解析出来的数值字符串，否则收藏页会把这些房间全部
/// 判成"未知状态"（`LiveState(rawValue:)` 解析失败）。
@Suite("PluginRoomDTO liveState 归一化")
struct PluginRoomDTOLiveStateTests {
  @Test("插件返回语义化字符串 live/close/video 时归一化为宿主数值 rawValue", arguments: [
    ("live", LiveState.live),
    ("close", LiveState.close),
    ("video", LiveState.video),
    ("streaming", LiveState.live),
    ("offline", LiveState.close),
  ])
  func normalizesSemanticLiveState(raw: String, expected: LiveState) throws {
    let dto = try decode(liveState: raw)
    let model = dto.toLiveModel(liveType: "douyu")
    #expect(model.liveState == expected.rawValue)
    #expect(LiveState(rawValue: model.liveState ?? "") == expected)
  }

  @Test("插件已经返回宿主数值 rawValue 时保持兼容", arguments: [
    ("0", LiveState.close),
    ("1", LiveState.live),
    ("2", LiveState.video),
  ])
  func keepsNumericLiveStateCompatible(raw: String, expected: LiveState) throws {
    let dto = try decode(liveState: raw)
    let model = dto.toLiveModel(liveType: "douyu")
    #expect(model.liveState == expected.rawValue)
  }

  @Test("插件未返回 liveState 时保持 nil，不误判成任何具体状态")
  func keepsNilWhenMissing() throws {
    let dto = try decode(liveState: nil)
    let model = dto.toLiveModel(liveType: "douyu")
    #expect(model.liveState == nil)
  }

  private func decode(liveState: String?) throws -> PluginRoomDTO {
    var payload: [String: Any] = [
      "userName": "u", "roomTitle": "t", "roomCover": "", "userHeadImg": "",
      "userId": "1", "roomId": "1",
    ]
    if let liveState { payload["liveState"] = liveState }
    let data = try JSONSerialization.data(withJSONObject: payload)
    return try JSONDecoder().decode(PluginRoomDTO.self, from: data)
  }
}
