import Foundation
import IOKit
import CoreWLAN
import MacPulseCore

// 芯片身份、全机网络/磁盘累计字节、Wi-Fi 链路信息。
// 全部公开接口:sysctl、IORegistry、CoreWLAN。

// MARK: - 芯片身份

public enum ChipInfoReader {
    /// 名称与核数是机器常量,进程里读一次就够。
    public static func read(gpuMaxFrequencyMHz: Double?) -> ChipIdentity {
        func sysctlString(_ name: String) -> String? {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
            var buffer = [UInt8](repeating: 0, count: size)
            guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
            return String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        func sysctlInt(_ name: String) -> Int? {
            var value: Int32 = 0
            var size = MemoryLayout<Int32>.size
            guard sysctlbyname(name, &value, &size, nil, 0) == 0, value > 0 else { return nil }
            return Int(value)
        }

        // perflevel0 = 性能核,perflevel1 = 能效核(苹果的固定排序)。
        let pCores = sysctlInt("hw.perflevel0.physicalcpu")
        let eCores = sysctlInt("hw.perflevel1.physicalcpu")
        let gpuCores = gpuCoreCount()

        // TFLOPs 是「核数 × 最高频 × 每核每周期 256 FLOP」的规格推算,
        // 界面必须标「理论峰值」;算不出宁缺。
        var fp32: Double?
        if let gpuCores, let maxMHz = gpuMaxFrequencyMHz, maxMHz > 0 {
            // 每核每 MHz 0.000256 TFLOPS(128 ALU × 2 FLOP/周期 ÷ 1e6)。
            fp32 = Double(gpuCores) * maxMHz * 0.000256
        }

        return ChipIdentity(
            name: sysctlString("machdep.cpu.brand_string"),
            coreCount: sysctlInt("hw.physicalcpu"),
            eCoreCount: eCores,
            pCoreCount: pCores,
            gpuCoreCount: gpuCores,
            tflopsFP32: fp32,
            tflopsFP16: fp32.map { $0 * 2 }
        )
    }

    private static func gpuCoreCount() -> Int? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("AGXAccelerator"),
            &iterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
            defer { IOObjectRelease(service) }
            guard let value = IORegistryEntryCreateCFProperty(
                service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() else { continue }
            if let number = value as? NSNumber, number.intValue > 0 {
                return number.intValue
            }
        }
        return nil
    }
}

// MARK: - 网络/磁盘速率

/// 有状态的速率读取:每次 sample 与上一次做差。
/// 首次调用没有基线,返回 nil——首帧宁缺,不给 0。
public final class ThroughputReader: @unchecked Sendable {
    public struct Rates: Sendable {
        public var networkInBytesPerSecond: Double?
        public var networkOutBytesPerSecond: Double?
        public var diskReadBytesPerSecond: Double?
        public var diskWriteBytesPerSecond: Double?
    }

    private struct Totals {
        var netIn: UInt64
        var netOut: UInt64
        var diskRead: UInt64
        var diskWrite: UInt64
        var at: Date
    }

    private var previous: Totals?

    public init() {}

    public func sample() -> Rates {
        let net = Self.networkTotals()
        let disk = Self.diskTotals()
        let now = Date()
        let current = Totals(
            netIn: net.inBytes, netOut: net.outBytes,
            diskRead: disk.read, diskWrite: disk.write, at: now
        )
        defer { previous = current }

        guard let previous else { return Rates() }
        let elapsed = now.timeIntervalSince(previous.at)
        guard elapsed > 0.1 else { return Rates() }

        // 计数器理论上单调,但接口下线重挂会回绕;回绕帧丢弃该项。
        func rate(_ new: UInt64, _ old: UInt64) -> Double? {
            guard new >= old else { return nil }
            return Double(new - old) / elapsed
        }
        return Rates(
            networkInBytesPerSecond: rate(current.netIn, previous.netIn),
            networkOutBytesPerSecond: rate(current.netOut, previous.netOut),
            diskReadBytesPerSecond: rate(current.diskRead, previous.diskRead),
            diskWriteBytesPerSecond: rate(current.diskWrite, previous.diskWrite)
        )
    }

    /// 全机网络累计字节:sysctl NET_RT_IFLIST2 的 64 位计数器,
    /// 剔除环回;虚拟接口(utun 等)保留——那也是真流量。
    private static func networkTotals() -> (inBytes: UInt64, outBytes: UInt64) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else {
            return (0, 0)
        }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 else {
            return (0, 0)
        }

        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= size {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                if Int32(header.ifm_type) == RTM_IFINFO2 {
                    let header2 = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if header2.ifm_flags & IFF_LOOPBACK == 0 {
                        totalIn &+= header2.ifm_data.ifi_ibytes
                        totalOut &+= header2.ifm_data.ifi_obytes
                    }
                }
                guard header.ifm_msglen > 0 else { break }
                offset += Int(header.ifm_msglen)
            }
        }
        return (totalIn, totalOut)
    }

    /// 本次开机以来的全机磁盘累计读写。给磁盘面板直读用;
    /// 内核计数器从开机起单调累计,掉电归零。
    public static func diskSessionTotals() -> (read: UInt64, write: UInt64)? {
        let totals = diskTotals()
        guard totals.read > 0 || totals.write > 0 else { return nil }
        return totals
    }

    /// 全机磁盘累计字节:IOBlockStorageDriver 的 Statistics 字典逐盘求和。
    private static func diskTotals() -> (read: UInt64, write: UInt64) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOBlockStorageDriver"),
            &iterator
        ) == KERN_SUCCESS else { return (0, 0) }
        defer { IOObjectRelease(iterator) }

        var read: UInt64 = 0
        var write: UInt64 = 0
        while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
            defer { IOObjectRelease(service) }
            guard let stats = IORegistryEntryCreateCFProperty(
                service, "Statistics" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? [String: Any] else { continue }
            read &+= (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            write &+= (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        return (read, write)
    }
}

// MARK: - 链路信息

public enum NetworkLinkReader {
    /// Wi-Fi 优先(在连即赢),没有就报 nil——以太网口的协商速率
    /// 各家驱动的属性名不统一,与其猜错不如先不报,列入后续。
    public static func read() -> NetworkLinkInfo? {
        guard let interface = CWWiFiClient.shared().interface() else { return nil }
        let rate = interface.transmitRate()
        guard rate > 0 else { return nil }

        let phyMode: String?
        let generation: String?
        switch interface.activePHYMode() {
        case .mode11a: phyMode = "802.11a"; generation = nil
        case .mode11b: phyMode = "802.11b"; generation = nil
        case .mode11g: phyMode = "802.11g"; generation = nil
        case .mode11n: phyMode = "802.11n"; generation = "Wi-Fi 4"
        case .mode11ac: phyMode = "802.11ac"; generation = "Wi-Fi 5"
        case .mode11ax: phyMode = "802.11ax"; generation = "Wi-Fi 6"
        case .modeNone: phyMode = nil; generation = nil
        default:
            // 新制式(Wi-Fi 7 及以后)宁可空着,也不套旧标签。
            phyMode = nil; generation = nil
        }

        return NetworkLinkInfo(
            interfaceName: interface.interfaceName,
            kind: .wifi,
            phyMode: phyMode,
            generation: generation,
            linkRateMbps: rate,
            isConnected: true
        )
    }
}
