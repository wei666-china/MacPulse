import Foundation
import IOKit

// pmgr 频率表:把 IOReport 性能档位(V0/V1/…)换算成 MHz 的对照表。
// 表位选择与单位启发式改编自 mactop(MIT)的 loadCpuFrequencies/loadGpuFrequencies。

public struct ClusterFrequencyTables: Sendable {
    /// 各档频率,MHz,按档位序。
    public let eCluster: [Double]
    public let pCluster: [Double]
    /// M5 Pro/Max 一类有第三集群的芯片才有;基础款为空。
    public let sCluster: [Double]
    public let gpu: [Double]

    /// 8 字节一条记录,前 4 字节小端是频率。单位随芯片代际变过一次:
    /// ≥1e8 按 Hz(M1–M4),≥1e5 按 kHz(M5 起),再小的当哨兵丢弃。
    /// 这两个阈值就是跨代兼容的全部秘密,改动前先想清楚会碰到哪代芯片。
    public static func parseFrequencies(_ data: Data) -> [Double] {
        var result: [Double] = []
        var offset = 0
        while offset + 8 <= data.count, result.count < 64 {
            let raw = data.subdata(in: offset..<(offset + 4)).withUnsafeBytes {
                $0.loadUnaligned(as: UInt32.self).littleEndian
            }
            offset += 8
            let value = Double(raw)
            if value >= 1e8 {
                result.append(value / 1e6)      // Hz → MHz
            } else if value >= 1e5 {
                result.append(value / 1e3)      // kHz → MHz
            }
            // 更小的值(0、占位)不入表:宁可短表,不放垃圾档。
        }
        return result
    }

    /// 从 IORegistry 的 pmgr 节点读全部表。找不到就各表为空——
    /// 消费方读不到频率显示「不可用」,不猜。
    public static func load() -> ClusterFrequencyTables {
        guard let properties = pmgrProperties() else {
            return ClusterFrequencyTables(eCluster: [], pCluster: [], sCluster: [], gpu: [])
        }
        func table(_ keys: [String]) -> [Double] {
            for key in keys {
                if let data = properties[key] as? Data {
                    let parsed = parseFrequencies(data)
                    if !parsed.isEmpty { return parsed }
                }
            }
            return []
        }
        // 表位含义(来自 mactop 跨代实测):1=E 集群,5=P 集群(M5 上是超大核),
        // 22/23/3=第三集群,9=GPU。-sram 变体优先。
        return ClusterFrequencyTables(
            eCluster: table(["voltage-states1-sram", "voltage-states9-sram", "voltage-states1"]),
            pCluster: table(["voltage-states5-sram", "voltage-states5"]),
            sCluster: table(["voltage-states22-sram", "voltage-states23-sram", "voltage-states3-sram"]),
            gpu: table(["voltage-states9-sram", "voltage-states9"])
        )
    }

    private static func pmgrProperties() -> [String: Any]? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("AppleARMIODevice"),
            &iterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
            defer { IOObjectRelease(service) }
            var nameBuffer = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(service, &nameBuffer)
            let name = nameBuffer.withUnsafeBufferPointer {
                String(decoding: $0.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
            guard name == "pmgr" else { continue }

            var propertiesRef: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(
                service, &propertiesRef, kCFAllocatorDefault, 0
            ) == KERN_SUCCESS else { return nil }
            return propertiesRef?.takeRetainedValue() as? [String: Any]
        }
        return nil
    }

    public init(eCluster: [Double], pCluster: [Double], sCluster: [Double], gpu: [Double]) {
        self.eCluster = eCluster
        self.pCluster = pCluster
        self.sCluster = sCluster
        self.gpu = gpu
    }
}
