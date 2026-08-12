import Foundation
import MacPulseSensors

/// 一个已挂载卷的容量事实。
struct VolumeInfo: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let totalBytes: Int64
    /// 立刻可用的空间(普通写入视角)。
    let availableBytes: Int64
    /// 系统在「重要用途」下能腾出来的空间——比上面多出的部分就是
    /// 可自动清理的缓存/快照(macOS 存储设置里的「可腾出」)。
    let importantAvailableBytes: Int64
    let isRoot: Bool
    let isInternal: Bool

    var usedBytes: Int64 { max(0, totalBytes - availableBytes) }
    /// 可自动腾出的空间。负值说明系统没报,按 0 处理。
    var purgeableBytes: Int64 { max(0, importantAvailableBytes - availableBytes) }
    /// 扣掉「可腾出」后的真实占用。容量条和图例必须用这个:
    /// usedBytes 已含 purgeable,再单独画一段 purgeable 就是重复计入,
    /// 三段之和会超过盘容量(审计高危)。
    var exclusiveUsedBytes: Int64 { max(0, usedBytes - purgeableBytes) }
    var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(totalBytes)
    }
}

/// 磁盘面板的一次快照。
struct DiskOverview: Sendable, Equatable {
    var volumes: [VolumeInfo] = []
    /// 本次开机以来全机累计读/写字节。读不到为 nil,界面显示「不可用」。
    var sessionReadBytes: UInt64?
    var sessionWriteBytes: UInt64?
    var sampledAt: Date = .distantPast
}

/// 卷容量走 FileManager(statfs 一层皮,便宜),累计读写走
/// IOBlockStorageDriver(MacPulseSensors 复用)。全公开接口,无需权限。
enum DiskStatsReader {
    static func read() -> DiskOverview {
        var overview = DiskOverview()
        overview.sampledAt = .now

        let keys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeIsRootFileSystemKey,
            .volumeIsInternalKey,
            .volumeIsBrowsableKey,
            .volumeUUIDStringKey
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys),
            options: [.skipHiddenVolumes]
        ) ?? []

        var volumes: [VolumeInfo] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.volumeIsBrowsable != false,
                  let total = values.volumeTotalCapacity, total > 0 else { continue }
            let available = Int64(values.volumeAvailableCapacity ?? 0)
            // importantUsage 读不到时退回普通可用值:purgeable 显示为 0,
            // 而不是编一个数。
            let important = values.volumeAvailableCapacityForImportantUsage ?? available
            volumes.append(VolumeInfo(
                id: values.volumeUUIDString ?? url.path,
                name: values.volumeName ?? url.lastPathComponent,
                totalBytes: Int64(total),
                availableBytes: available,
                importantAvailableBytes: max(important, available),
                isRoot: values.volumeIsRootFileSystem ?? false,
                isInternal: values.volumeIsInternal ?? false
            ))
        }
        // 启动卷置顶,其余按名称;同一 APFS 容器的系统卷已被 skipHidden 滤掉。
        overview.volumes = volumes.sorted { lhs, rhs in
            if lhs.isRoot != rhs.isRoot { return lhs.isRoot }
            return lhs.name.localizedCompare(rhs.name) == .orderedAscending
        }

        if let totals = ThroughputReader.diskSessionTotals() {
            overview.sessionReadBytes = totals.read
            overview.sessionWriteBytes = totals.write
        }
        return overview
    }
}
