import Foundation
import Testing

@testable import AngelLiveCore

/// 判据只有一条:**本二进制的代码签名里有没有 claim 这个容器**——这正是
/// `CKContainer(identifier:)` 会不会 `EXC_BREAKPOINT` 的充要条件。
///
/// 两边的代价极不对称,所以不确定时必须判**不可用**:
/// - 该可用判成不可用 → 收藏退回纯本地,功能降级,App 照常能用;
/// - 该不可用判成可用 → `CKContainer` 直接 trap,**启动即崩**,整个 App 不可用。
/// 线上 2.1.1(build 10) 正是赌了后者(读不到描述文件时默认判可用)才全量崩溃的。
@Suite("CloudKit 容器可用性判定")
struct CloudKitAvailabilityTests {

  private let target = "iCloud.com.moyum.angellive"

  @Test("签名里 claim 了目标容器 → 可用")
  func availableWhenDeclared() {
    let entitlements: [String: Any] = [
      "com.apple.developer.icloud-container-identifiers": [target],
      "com.apple.developer.icloud-services": ["CloudKit"],
    ]
    #expect(CloudKitAvailability.isContainerAvailable(target, declaredIn: entitlements))
  }

  @Test("签名里只有别的容器 → 不可用")
  func unavailableWhenDifferentContainer() {
    let entitlements: [String: Any] = [
      "com.apple.developer.icloud-container-identifiers": ["iCloud.com.example.other"],
    ]
    #expect(!CloudKitAvailability.isContainerAvailable(target, declaredIn: entitlements))
  }

  @Test("签名在、但一条 iCloud entitlement 都没有 → 不可用(模拟器构建即此形态)")
  func unavailableWhenSignedButUnentitled() {
    #expect(!CloudKitAvailability.isContainerAvailable(target, declaredIn: [:]))
  }

  @Test("读不出签名(nil)→ 判不可用,绝不赌「大概有吧」")
  func unavailableWhenUnreadable() {
    // 这条是崩溃的直接教训:读不出时的默认值必须是 false。
    #expect(!CloudKitAvailability.isContainerAvailable(target, declaredIn: nil))
  }

  @Test("容器字段类型异常时不崩、判不可用")
  func unavailableOnMalformedEntitlements() {
    // entitlements 来自二进制里的 plist,理论上格式固定,但解析出的类型不合预期时
    // 只能判不可用——猜错的代价是崩溃。
    let malformed: [[String: Any]] = [
      ["com.apple.developer.icloud-container-identifiers": "不是数组"],
      ["com.apple.developer.icloud-container-identifiers": [1, 2, 3]],
      ["com.apple.developer.icloud-container-identifiers": NSNull()],
      ["com.apple.developer.icloud-services": ["CloudKit"]],   // 声明了服务却没声明容器
    ]
    for entitlements in malformed {
      #expect(!CloudKitAvailability.isContainerAvailable(target, declaredIn: entitlements))
    }
  }
}
