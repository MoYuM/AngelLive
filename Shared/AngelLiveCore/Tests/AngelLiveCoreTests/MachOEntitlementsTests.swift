import Foundation
import Testing

@testable import AngelLiveCore

/// `CKContainer(identifier:)` 在二进制**实际签名**的 entitlements 里没声明该容器时直接
/// `EXC_BREAKPOINT`(CloudKit 在 `_checkRequiredEntitlements` 里 `brk`),所以碰它之前
/// 必须先问准一件事:**我这个二进制到底 claim 了哪些 CloudKit 容器**。
///
/// 描述文件回答不了这个问题——它给的是"签名**允许**声明哪些容器"的上界,
/// 而实际 claim 是 `.entitlements` 的内容,两者关系是 `claim ⊆ profile`,
/// 合法地可以不一致(profile 有、二进制没 claim,签名和上传都不会报错)。
/// 线上 2.1.1(build 10) 启动即崩就是踩在这个错位上。
///
/// 这里解析的是代码签名 SuperBlob 里的 entitlements slot ——
/// 与 CloudKit 检查的是同一份数据,不存在错位。
@Suite("Mach-O 代码签名 entitlements 解析")
struct MachOEntitlementsTests {

  @Test("从 thin 64 位 Mach-O 的签名 slot 里解析出 entitlements")
  func parsesThinBinary() throws {
    let data = MachOFixture.thin(entitlements: MachOFixture.icloudPlist)
    let parsed = try #require(MachOEntitlements.parse(machO: data))
    #expect(parsed["com.apple.developer.icloud-container-identifiers"] as? [String] == ["iCloud.com.moyum.angellive"])
  }

  @Test("universal(FAT)二进制也能取到当前架构 slice 的 entitlements")
  func parsesFatBinary() throws {
    let data = MachOFixture.fat(slices: [
      MachOFixture.thin(entitlements: MachOFixture.icloudPlist)
    ])
    let parsed = try #require(MachOEntitlements.parse(machO: data))
    #expect(parsed["com.apple.developer.icloud-container-identifiers"] as? [String] == ["iCloud.com.moyum.angellive"])
  }

  @Test("有代码签名但没有 entitlements slot 时给出空字典,而不是 nil")
  func distinguishesSignedButUnentitled() throws {
    // 「签得好好的、但一条 entitlement 都没声明」是确定的事实(判不可用),
    // 必须与「根本没读懂这个二进制」区分开。
    let parsed = try #require(MachOEntitlements.parse(machO: MachOFixture.thin(entitlements: nil)))
    #expect(parsed.isEmpty)
  }

  @Test("完全没有 LC_CODE_SIGNATURE 时返回 nil(读不出,不是读出了空)")
  func returnsNilWhenUnsigned() {
    #expect(MachOEntitlements.parse(machO: MachOFixture.thin(entitlements: nil, includeSignature: false)) == nil)
  }

  @Test("数据被截断/不是 Mach-O 时返回 nil 而不是崩溃", arguments: [
    Data(),
    Data([0x00, 0x01, 0x02]),
    Data("not a mach-o at all".utf8),
  ])
  func survivesGarbage(garbage: Data) {
    #expect(MachOEntitlements.parse(machO: garbage) == nil)
  }

  @Test("签名段越界时返回 nil 而不是越界读")
  func survivesTruncatedSignature() {
    var data = MachOFixture.thin(entitlements: MachOFixture.icloudPlist)
    data = data.prefix(data.count / 2)   // 砍掉后半段,签名段指向文件外
    #expect(MachOEntitlements.parse(machO: data) == nil)
  }

  @Test("读当前测试进程自己的可执行文件不抛不崩")
  func readsOwnExecutableWithoutCrashing() throws {
    // 不断言内容(测试宿主的签名因环境而异),只要求这条真实路径可走通。
    let url = try #require(Bundle.main.executableURL)
    _ = MachOEntitlements.parse(machOAt: url)
  }
}

// MARK: - 合成 Mach-O 夹具

/// 手工拼最小可解析的 Mach-O 字节。用真二进制当夹具太大且随构建漂移,
/// 合成字节能精确覆盖边界(无签名 / 无 entitlements / FAT / 截断)。
enum MachOFixture {
  static let icloudPlist = """
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
  <plist version="1.0"><dict>
  <key>com.apple.developer.icloud-container-identifiers</key>
  <array><string>iCloud.com.moyum.angellive</string></array>
  <key>com.apple.developer.icloud-services</key>
  <array><string>CloudKit</string></array>
  </dict></plist>
  """

  /// thin 的 arm64 Mach-O:header + LC_CODE_SIGNATURE + 尾部签名 SuperBlob。
  static func thin(entitlements: String?, includeSignature: Bool = true) -> Data {
    let signature = includeSignature ? superBlob(entitlements: entitlements) : Data()
    let headerSize = 32
    let commandSize = includeSignature ? 16 : 0
    let signatureOffset = headerSize + commandSize

    var data = Data()
    data.appendLE(UInt32(0xfeed_facf))          // MH_MAGIC_64
    data.appendLE(UInt32(0x0100_000c))          // CPU_TYPE_ARM64
    data.appendLE(UInt32(0))                    // cpusubtype
    data.appendLE(UInt32(2))                    // MH_EXECUTE
    data.appendLE(UInt32(includeSignature ? 1 : 0))  // ncmds
    data.appendLE(UInt32(commandSize))          // sizeofcmds
    data.appendLE(UInt32(0))                    // flags
    data.appendLE(UInt32(0))                    // reserved

    if includeSignature {
      data.appendLE(UInt32(0x1d))               // LC_CODE_SIGNATURE
      data.appendLE(UInt32(16))                 // cmdsize
      data.appendLE(UInt32(signatureOffset))    // dataoff
      data.appendLE(UInt32(signature.count))    // datasize
    }
    data.append(signature)
    return data
  }

  /// FAT 容器,把若干 thin slice 包起来(fat header 是大端)。
  static func fat(slices: [Data]) -> Data {
    var header = Data()
    header.appendBE(UInt32(0xcafe_babe))        // FAT_MAGIC
    header.appendBE(UInt32(slices.count))

    let headerSize = 8 + slices.count * 20
    var offset = headerSize
    var body = Data()
    for slice in slices {
      header.appendBE(UInt32(0x0100_000c))      // CPU_TYPE_ARM64
      header.appendBE(UInt32(0))                // cpusubtype
      header.appendBE(UInt32(offset))
      header.appendBE(UInt32(slice.count))
      header.appendBE(UInt32(14))               // align 2^14
      body.append(slice)
      offset += slice.count
    }
    return header + body
  }

  /// 代码签名的 SuperBlob。内部字节序一律大端,这是 codesign 的格式约定。
  private static func superBlob(entitlements: String?) -> Data {
    var blobs: [(type: UInt32, payload: Data)] = []

    // CSSLOT_CODEDIRECTORY:内容与本次解析无关,占位即可,但必须占住一个 slot,
    // 以验证解析器是按 slot type 找 entitlements 而不是碰巧撞上第一个 blob。
    var codeDirectory = Data()
    codeDirectory.appendBE(UInt32(0xfade_0c02))
    codeDirectory.appendBE(UInt32(8 + 4))
    codeDirectory.appendBE(UInt32(0))
    blobs.append((type: 0, payload: codeDirectory))

    if let entitlements {
      let xml = Data(entitlements.utf8)
      var blob = Data()
      blob.appendBE(UInt32(0xfade_7171))        // CSMAGIC_EMBEDDED_ENTITLEMENTS
      blob.appendBE(UInt32(8 + xml.count))
      blob.append(xml)
      blobs.append((type: 5, payload: blob))    // CSSLOT_ENTITLEMENTS
    }

    let indexSize = blobs.count * 8
    var offset = 12 + indexSize
    var index = Data()
    var payloads = Data()
    for blob in blobs {
      index.appendBE(blob.type)
      index.appendBE(UInt32(offset))
      payloads.append(blob.payload)
      offset += blob.payload.count
    }

    var data = Data()
    data.appendBE(UInt32(0xfade_0cc0))          // CSMAGIC_EMBEDDED_SIGNATURE
    data.appendBE(UInt32(12 + indexSize + payloads.count))
    data.appendBE(UInt32(blobs.count))
    data.append(index)
    data.append(payloads)
    return data
  }
}

private extension Data {
  mutating func appendLE(_ value: UInt32) {
    Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
  }

  mutating func appendBE(_ value: UInt32) {
    Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
  }
}
