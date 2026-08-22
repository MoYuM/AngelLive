//
//  MachOEntitlements.swift
//  AngelLiveCore
//
//  读出**本二进制代码签名里实际 claim 的 entitlements**。
//
//  为什么需要它:像 `CKContainer(identifier:)` 这类 API,在 entitlements 里没声明对应容器时
//  是直接 `EXC_BREAKPOINT`(CloudKit 在 `-[CKContainerImplementation _checkRequiredEntitlements]`
//  里 `brk`),没有任何可捕获的错误——只能在碰它**之前**问准"我到底 claim 了什么"。
//
//  为什么不能拿描述文件回答:embedded.mobileprovision 说的是"这个签名**允许**声明哪些能力",
//  是**上界**;二进制实际 claim 的是 `.entitlements` 的内容。两者关系是 `claim ⊆ profile`,
//  **合法地可以不一致**——profile 带 iCloud 而二进制没 claim 时,签名与上传都不会报错,
//  于是"profile 里有 → 不会崩"的推断不成立。2.1.1(build 10) 线上启动即崩就是这个错位:
//  探测读 profile 判可用,而实际签名里没有 iCloud entitlement。
//
//  这里读的是代码签名 SuperBlob 的 entitlements slot,**与内核校验、CloudKit 检查的是同一份
//  数据**,不存在错位;也不依赖描述文件在不在(App Store 重签会剥掉它)。全部是公开 API
//  (读自己 bundle 里的文件 + 解析字节),没有用 `SecTask*`(iOS/tvOS 未公开)。
//
//  只处理小端 Mach-O(现代 Apple 平台唯一形态)与大端 FAT 头,这是 codesign 的格式约定。
//

import Foundation

enum MachOEntitlements {

    /// 解析指定可执行文件的签名 entitlements。
    /// - Returns: 解析出的 entitlements 字典;二进制没有代码签名或读不懂时为 `nil`。
    ///   **空字典与 `nil` 含义不同**:空字典 = 签名在、但一条都没声明(确定的"没有");
    ///   `nil` = 没读出来(不确定)。调用方对这两者的处置往往不同。
    static func parse(machOAt url: URL) -> [String: Any]? {
        // mmap:二进制动辄几十 MB,只需要碰 header 与签名段那几处,别整个读进内存。
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        return parse(machO: data)
    }

    static func parse(machO data: Data) -> [String: Any]? {
        // FAT 头是大端;thin Mach-O 头按主机序(Apple 现役平台一律小端)。
        switch data.beUInt32(at: 0) {
        case 0xcafe_babe, 0xcafe_babf:
            return parseFat(data)
        default:
            return parseSlice(data, sliceOffset: 0)
        }
    }

    // MARK: - FAT

    private static func parseFat(_ data: Data) -> [String: Any]? {
        guard let count = data.beUInt32(at: 4), count > 0, count < 64 else { return nil }
        let is64 = data.beUInt32(at: 0) == 0xcafe_babf
        let archSize = is64 ? 32 : 20

        // 优先当前架构;取不到就退回第一个能解析出来的 slice——同一个二进制的各架构
        // claim 的 entitlements 必然一致(同一份 .entitlements 签进去的)。
        var fallback: [String: Any]?
        for index in 0 ..< Int(count) {
            let base = 8 + index * archSize
            guard let cpuType = data.beUInt32(at: base) else { continue }
            let sliceOffset: Int?
            if is64 {
                sliceOffset = data.beUInt64(at: base + 8).map(Int.init)
            } else {
                sliceOffset = data.beUInt32(at: base + 8).map(Int.init)
            }
            guard let sliceOffset, let parsed = parseSlice(data, sliceOffset: sliceOffset) else { continue }
            if cpuType == currentCPUType { return parsed }
            if fallback == nil { fallback = parsed }
        }
        return fallback
    }

    private static var currentCPUType: UInt32 {
        #if arch(arm64)
        return 0x0100_000c   // CPU_TYPE_ARM64
        #elseif arch(x86_64)
        return 0x0100_0007   // CPU_TYPE_X86_64
        #else
        return 0
        #endif
    }

    // MARK: - thin slice

    private static func parseSlice(_ data: Data, sliceOffset: Int) -> [String: Any]? {
        guard let magic = data.leUInt32(at: sliceOffset) else { return nil }
        let headerSize: Int
        switch magic {
        case 0xfeed_facf: headerSize = 32   // MH_MAGIC_64
        case 0xfeed_face: headerSize = 28   // MH_MAGIC(32 位)
        default: return nil
        }

        guard let commandCount = data.leUInt32(at: sliceOffset + 16), commandCount < 4096 else { return nil }

        var cursor = sliceOffset + headerSize
        for _ in 0 ..< Int(commandCount) {
            guard let command = data.leUInt32(at: cursor),
                  let commandSize = data.leUInt32(at: cursor + 4),
                  commandSize >= 8
            else { return nil }

            if command == 0x1d {   // LC_CODE_SIGNATURE
                guard let dataOffset = data.leUInt32(at: cursor + 8),
                      let dataSize = data.leUInt32(at: cursor + 12)
                else { return nil }
                return parseSignature(data, at: sliceOffset + Int(dataOffset), size: Int(dataSize))
            }
            cursor += Int(commandSize)
        }
        return nil   // 没有 LC_CODE_SIGNATURE:未签名,读不出 → nil
    }

    // MARK: - 代码签名 SuperBlob(内部一律大端)

    private static func parseSignature(_ data: Data, at offset: Int, size: Int) -> [String: Any]? {
        guard size > 12, data.hasBytes(at: offset, count: size) else { return nil }
        guard data.beUInt32(at: offset) == 0xfade_0cc0,          // CSMAGIC_EMBEDDED_SIGNATURE
              let blobCount = data.beUInt32(at: offset + 8),
              blobCount < 64
        else { return nil }

        for index in 0 ..< Int(blobCount) {
            let entry = offset + 12 + index * 8
            guard let slotType = data.beUInt32(at: entry),
                  let blobOffset = data.beUInt32(at: entry + 4)
            else { return nil }
            guard slotType == 5 else { continue }                // CSSLOT_ENTITLEMENTS

            let blob = offset + Int(blobOffset)
            guard data.beUInt32(at: blob) == 0xfade_7171,        // CSMAGIC_EMBEDDED_ENTITLEMENTS
                  let blobLength = data.beUInt32(at: blob + 4),
                  blobLength > 8,
                  data.hasBytes(at: blob, count: Int(blobLength))
            else { return nil }

            let start = data.startIndex + blob + 8
            let plist = data.subdata(in: start ..< (start + Int(blobLength) - 8))
            guard let parsed = try? PropertyListSerialization.propertyList(from: plist, format: nil),
                  let dictionary = parsed as? [String: Any]
            else { return nil }
            return dictionary
        }

        // 签名在、但没有 entitlements slot:这是确定的"一条都没声明",不是"读不出"。
        return [:]
    }
}

// MARK: - 越界安全的定长读取

private extension Data {
    func hasBytes(at offset: Int, count: Int) -> Bool {
        offset >= 0 && count >= 0 && offset &+ count <= self.count
    }

    /// 基于 `startIndex` 取值:切片(如 `data[a..<b]`)的索引不从 0 开始。
    func byte(at offset: Int) -> UInt8? {
        guard hasBytes(at: offset, count: 1) else { return nil }
        return self[startIndex + offset]
    }

    func leUInt32(at offset: Int) -> UInt32? {
        guard let b0 = byte(at: offset), let b1 = byte(at: offset + 1),
              let b2 = byte(at: offset + 2), let b3 = byte(at: offset + 3) else { return nil }
        return UInt32(b0) | UInt32(b1) << 8 | UInt32(b2) << 16 | UInt32(b3) << 24
    }

    func beUInt32(at offset: Int) -> UInt32? {
        guard let b0 = byte(at: offset), let b1 = byte(at: offset + 1),
              let b2 = byte(at: offset + 2), let b3 = byte(at: offset + 3) else { return nil }
        return UInt32(b3) | UInt32(b2) << 8 | UInt32(b1) << 16 | UInt32(b0) << 24
    }

    func beUInt64(at offset: Int) -> UInt64? {
        guard let high = beUInt32(at: offset), let low = beUInt32(at: offset + 4) else { return nil }
        return UInt64(high) << 32 | UInt64(low)
    }
}
