import Foundation
import IOKit

// AppleSMC 用户客户端读取。结构体布局、选择子与解码公式改编自
// Stats(MIT,Copyright (c) 2019 Serhiy Mytrovtsiy),见 THIRD_PARTY_NOTICES.md。
// 只读,不含任何风扇控制/写键路径。改编时修掉了上游三个已知问题:
// 1. sp 系列定点数不做符号扩展(负温度会解成 +255 档)——这里用 Int16 位型转换;
// 2. 每键每 tick 重复查 keyInfo(两次内核往返)——这里首读后缓存,之后一次往返;
// 3. 无锁并发调用 IOConnectCallStructMethod——这里加串行锁。

/// SMC 四字符键。3 字符键必须补空格(如 "FS! ")。
private func fourCC(_ key: String) -> UInt32 {
    precondition(key.utf8.count == 4, "SMC 键必须恰好 4 字节:\(key)")
    var value: UInt32 = 0
    for byte in key.utf8 { value = value << 8 | UInt32(byte) }
    return value
}

private func fourCCString(_ value: UInt32) -> String {
    let bytes = [
        UInt8((value >> 24) & 0xFF),
        UInt8((value >> 16) & 0xFF),
        UInt8((value >> 8) & 0xFF),
        UInt8(value & 0xFF)
    ]
    return String(bytes: bytes, encoding: .utf8) ?? ""
}

/// 与内核约定的 80 字节调用结构。
///
/// **布局警告**:Swift 对嵌套结构体按 size(9 字节)而不是 stride 排布
/// `keyInfo`,`padding` 字段的存在就是为了把偏移量拉回与 C 版一致
/// (result@40、data8@42、data32@44、bytes@48)。删掉它不会报错,
/// 但 data32/bytes 会静默错位,读出来全是垃圾。
private struct SMCKeyData {
    struct Version {
        var major: CUnsignedChar = 0
        var minor: CUnsignedChar = 0
        var build: CUnsignedChar = 0
        var reserved: CUnsignedChar = 0
        var release: CUnsignedShort = 0
    }
    struct LimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }
    struct KeyInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    var key: UInt32 = 0
    var vers = Version()
    var pLimitData = LimitData()
    var keyInfo = KeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

/// 一次成功读取的结果。
public struct SMCValue: Sendable {
    public let key: String
    /// 类型四字符码,如 "sp78"、"flt "、"{fds"。
    public let type: String
    public let bytes: [UInt8]

    /// 按类型解码成 Double。未知类型返回 nil——绝不猜。
    public var doubleValue: Double? {
        switch type {
        case "ui8 ": return bytes.count >= 1 ? Double(bytes[0]) : nil
        case "ui16": return bytes.count >= 2 ? Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) : nil
        case "ui32":
            guard bytes.count >= 4 else { return nil }
            let v = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
            return Double(v)
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            // SMC 的 flt 是小端 IEEE754。
            let raw = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            let f = Float(bitPattern: raw)
            return f.isFinite ? Double(f) : nil
        case "fpe2":
            guard bytes.count >= 2 else { return nil }
            return Double((Int(bytes[0]) << 6) + (Int(bytes[1]) >> 2))
        case "sp1e", "sp3c", "sp4b", "sp5a", "sp69", "sp78", "sp87", "sp96", "spa5", "spb4", "spf0":
            guard bytes.count >= 2 else { return nil }
            // sp 系列是**有符号**定点数:高字节带符号位。上游按无符号解,
            // 负温度(低温环境/传感器故障)会变成 +250℃ 一类的鬼值。
            let raw = Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
            let divisor: Double
            switch type {
            case "sp1e": divisor = 16384
            case "sp3c": divisor = 4096
            case "sp4b": divisor = 2048
            case "sp5a": divisor = 1024
            case "sp69": divisor = 512
            case "sp78": divisor = 256
            case "sp87": divisor = 128
            case "sp96": divisor = 64
            case "spa5": divisor = 32
            case "spb4": divisor = 16
            default: divisor = 1
            }
            return Double(raw) / divisor
        default:
            return nil
        }
    }
}

/// AppleSMC 连接。整个进程共用一条连接(打开/关闭成本高且无并发收益),
/// 所有调用过一把串行锁。
public final class SMCClient: @unchecked Sendable {
    private var connection: io_connect_t = 0
    private let lock = NSLock()
    /// 键元数据缓存:dataSize/dataType 对一台机器是常量,查一次就够。
    private var keyInfoCache: [UInt32: SMCKeyData.KeyInfo] = [:]

    private static let kernelIndex: UInt32 = 2
    private static let opReadBytes: UInt8 = 5
    private static let opReadIndex: UInt8 = 8
    private static let opReadKeyInfo: UInt8 = 9

    public init?() {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("AppleSMC"),
            &iterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        let device = IOIteratorNext(iterator)
        guard device != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(device) }
        guard IOServiceOpen(device, mach_task_self_, 0, &connection) == KERN_SUCCESS else {
            return nil
        }
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    private func call(_ input: inout SMCKeyData, _ output: inout SMCKeyData) -> Bool {
        var outputSize = MemoryLayout<SMCKeyData>.stride
        let result = IOConnectCallStructMethod(
            connection,
            Self.kernelIndex,
            &input,
            MemoryLayout<SMCKeyData>.stride,
            &output,
            &outputSize
        )
        return result == KERN_SUCCESS && output.result == 0
    }

    private func keyInfo(for keyCode: UInt32) -> SMCKeyData.KeyInfo? {
        if let cached = keyInfoCache[keyCode] { return cached }
        var input = SMCKeyData()
        var output = SMCKeyData()
        input.key = keyCode
        input.data8 = Self.opReadKeyInfo
        guard call(&input, &output), output.keyInfo.dataSize > 0 else { return nil }
        keyInfoCache[keyCode] = output.keyInfo
        return output.keyInfo
    }

    /// 读一个键的原始值。键不存在或类型信息拿不到时返回 nil。
    public func read(_ key: String) -> SMCValue? {
        let keyCode = fourCC(key)
        lock.lock()
        defer { lock.unlock() }

        guard let info = keyInfo(for: keyCode) else { return nil }

        var input = SMCKeyData()
        var output = SMCKeyData()
        input.key = keyCode
        input.keyInfo.dataSize = info.dataSize
        input.data8 = Self.opReadBytes
        guard call(&input, &output) else { return nil }

        let size = min(Int(info.dataSize), 32)
        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(size)) }
        return SMCValue(key: key, type: fourCCString(info.dataType), bytes: bytes)
    }

    /// 读一个键并解码为 Double。
    public func readDouble(_ key: String) -> Double? {
        read(key)?.doubleValue
    }

    /// 枚举全部键名(#KEY 计数 + 按索引读)。一台机器上是常量,调用方只该做一次。
    public func allKeys() -> [String] {
        guard let countValue = readDouble("#KEY"), countValue > 0 else { return [] }
        let count = Int(countValue)

        lock.lock()
        defer { lock.unlock() }

        var keys: [String] = []
        keys.reserveCapacity(count)
        for index in 0..<count {
            var input = SMCKeyData()
            var output = SMCKeyData()
            input.data8 = Self.opReadIndex
            input.data32 = UInt32(index)
            guard call(&input, &output) else { continue }
            let name = fourCCString(output.key)
            if !name.isEmpty { keys.append(name) }
        }
        return keys
    }
}
