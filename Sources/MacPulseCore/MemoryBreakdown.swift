import Foundation

/// 内核给出的内存压力等级。
///
/// 来自 `kern.memorystatus_vm_pressure_level`，与 `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE`
/// 投递的是同一个信号。这是唯一权威的压力判据——颜色和徽标都应该由它驱动，
/// 而不是由下面那个近似百分比驱动。
public enum MemoryPressureLevel: Int, Codable, Sendable, Equatable {
    case unknown = 0
    case normal = 1
    case warning = 2
    case critical = 4

    public var title: String {
        switch self {
        case .normal: "正常"
        case .warning: "偏紧"
        case .critical: "紧张"
        case .unknown: "不可用"
        }
    }
}

/// `vm_statistics64` 里我们真正用到的页计数，摘成纯值类型。
///
/// 单独拎出来是为了让 `MemoryBreakdown` 能脱离 mach 调用做单元测试——
/// 换算公式的正确性不该依赖跑在什么机器上。
public struct VMPageCounts: Codable, Sendable, Equatable {
    public var free: UInt64
    public var active: UInt64
    public var inactive: UInt64
    public var speculative: UInt64
    public var wired: UInt64
    public var purgeable: UInt64
    /// 匿名页，对应 `vm_stat` 的 "Anonymous pages"。
    public var anonymous: UInt64
    /// 文件页，对应 `vm_stat` 的 "File-backed pages"。
    public var fileBacked: UInt64
    /// 压缩器实际占用的页数。
    public var compressorOccupied: UInt64
    /// 压缩前的原始页数，用来算「压缩节省」。
    public var uncompressedInCompressor: UInt64

    public init(
        free: UInt64 = 0,
        active: UInt64 = 0,
        inactive: UInt64 = 0,
        speculative: UInt64 = 0,
        wired: UInt64 = 0,
        purgeable: UInt64 = 0,
        anonymous: UInt64 = 0,
        fileBacked: UInt64 = 0,
        compressorOccupied: UInt64 = 0,
        uncompressedInCompressor: UInt64 = 0
    ) {
        self.free = free
        self.active = active
        self.inactive = inactive
        self.speculative = speculative
        self.wired = wired
        self.purgeable = purgeable
        self.anonymous = anonymous
        self.fileBacked = fileBacked
        self.compressorOccupied = compressorOccupied
        self.uncompressedInCompressor = uncompressedInCompressor
    }
}

/// 统一内存的分项占用，口径对齐「活动监视器 → 内存」。
///
/// 之前代码里同时存在三个互相矛盾的「已用内存」：mactop 的 `total − (free + inactive)`、
/// 本地回退读数的 `active + wired + compressor`、以及活动监视器的口径。采集器每重连
/// 一次，界面上的数字就跳一次。这个类型是唯一口径，且完全不依赖采集器。
public struct MemoryBreakdown: Codable, Sendable, Equatable {
    public var totalBytes: UInt64
    /// 应用内存：匿名页去掉可丢弃的部分。
    public var appBytes: UInt64
    /// 联动内存：不可换出、不可压缩。
    public var wiredBytes: UInt64
    /// 压缩内存：压缩器当前占用的物理内存。
    public var compressedBytes: UInt64
    /// 缓存文件：文件页 + 可丢弃页，随时可以让路，不算「已使用」。
    public var cachedFilesBytes: UInt64
    /// 已使用 = 应用 + 联动 + 压缩。缓存文件不计入，这与活动监视器一致。
    public var usedBytes: UInt64
    public var freeBytes: UInt64
    public var swapTotalBytes: UInt64?
    public var swapUsedBytes: UInt64?
    /// 压缩省下的物理内存（原始大小 − 压缩后占用）。
    public var compressorSavedBytes: UInt64?
    public var pressureLevel: MemoryPressureLevel
    /// 近似的连续压力值。Apple 从未公开活动监视器那条曲线的算法，
    /// 这里用「已联动 + 已压缩」占比估算，**界面上必须标注是近似值**。
    public var approximatePressurePercent: Double?

    public init(
        counts: VMPageCounts,
        pageSize: UInt64,
        totalBytes: UInt64,
        swapTotalBytes: UInt64? = nil,
        swapUsedBytes: UInt64? = nil,
        pressureLevel: MemoryPressureLevel = .unknown
    ) {
        self.totalBytes = totalBytes
        self.swapTotalBytes = swapTotalBytes
        self.swapUsedBytes = swapUsedBytes
        self.pressureLevel = pressureLevel

        // 匿名页里含可丢弃页，扣掉后才是真正「必须留着」的应用内存。
        // 用饱和减法：两个计数来自同一次快照，理论上不会倒挂，但内核统计
        // 并非严格原子，倒挂一次就会因无符号回绕炸成 16EB。
        let appPages = counts.anonymous >= counts.purgeable
            ? counts.anonymous - counts.purgeable
            : 0
        appBytes = appPages * pageSize
        wiredBytes = counts.wired * pageSize
        compressedBytes = counts.compressorOccupied * pageSize
        cachedFilesBytes = (counts.fileBacked + counts.purgeable) * pageSize
        usedBytes = appBytes + wiredBytes + compressedBytes

        let accounted = usedBytes + cachedFilesBytes
        freeBytes = totalBytes >= accounted ? totalBytes - accounted : 0

        compressorSavedBytes = counts.uncompressedInCompressor >= counts.compressorOccupied
            ? (counts.uncompressedInCompressor - counts.compressorOccupied) * pageSize
            : nil

        approximatePressurePercent = totalBytes > 0
            ? Double(wiredBytes + compressedBytes) / Double(totalBytes) * 100
            : nil
    }

    /// 已使用占比，供环形/条形进度使用。
    public var usedFraction: Double? {
        guard totalBytes > 0 else { return nil }
        return Double(usedBytes) / Double(totalBytes)
    }

    /// 四类之和通常小于物理内存——内核自身的分配不在这四类里（实测差约 700MB）。
    /// 界面上不要为这个差额单画一块「其他」，让堆叠条的余量就是「可用」即可。
    public var unaccountedBytes: UInt64 {
        let accounted = usedBytes + cachedFilesBytes
        return totalBytes >= accounted ? totalBytes - accounted : 0
    }
}
