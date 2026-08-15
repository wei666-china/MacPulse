import Foundation

/// `vm_statistics64` 里的累计计数,开机起单调递增,单位是**内核页**。
/// 摘成纯值类型,差分逻辑才能离线单测。
public struct VMCumulativeCounters: Sendable, Equatable {
    /// 从盘读入的页(文件页错页 + 交换读回路径都计入)。
    public var pageins: UInt64
    /// 分页器写盘的页。
    public var pageouts: UInt64
    /// 从交换文件读回压缩器的页。
    public var swapins: UInt64
    /// 压缩器写入交换文件的页。
    public var swapouts: UInt64
    /// 进压缩器的页。
    public var compressions: UInt64
    /// 出压缩器的页。
    public var decompressions: UInt64

    public init(
        pageins: UInt64,
        pageouts: UInt64,
        swapins: UInt64,
        swapouts: UInt64,
        compressions: UInt64,
        decompressions: UInt64
    ) {
        self.pageins = pageins
        self.pageouts = pageouts
        self.swapins = swapins
        self.swapouts = swapouts
        self.compressions = compressions
        self.decompressions = decompressions
    }
}

/// 两次计数快照的差分速率,单位一律**字节/秒**(页数 × 内核页大小)。
///
/// 为什么必须是速率而不是 swap 用量:`swapUsedBytes` 是历史遗迹——一台曾经
/// 换过页但已恢复的机器,它仍然很大。只有「此刻每秒换多少」才能判
/// 「正在疯狂换页」。这是瓶颈诊断对内存维度的核心证据。
public struct MemoryRates: Sendable, Equatable {
    public var pageinBytesPerSecond: Double
    public var pageoutBytesPerSecond: Double
    public var swapinBytesPerSecond: Double
    public var swapoutBytesPerSecond: Double
    public var compressionBytesPerSecond: Double
    public var decompressionBytesPerSecond: Double

    public init(
        pageinBytesPerSecond: Double,
        pageoutBytesPerSecond: Double,
        swapinBytesPerSecond: Double,
        swapoutBytesPerSecond: Double,
        compressionBytesPerSecond: Double,
        decompressionBytesPerSecond: Double
    ) {
        self.pageinBytesPerSecond = pageinBytesPerSecond
        self.pageoutBytesPerSecond = pageoutBytesPerSecond
        self.swapinBytesPerSecond = swapinBytesPerSecond
        self.swapoutBytesPerSecond = swapoutBytesPerSecond
        self.compressionBytesPerSecond = compressionBytesPerSecond
        self.decompressionBytesPerSecond = decompressionBytesPerSecond
    }

    /// 交换的双向合计,判「thrash」的主信号。
    public var swapBidirectionalBytesPerSecond: Double {
        swapinBytesPerSecond + swapoutBytesPerSecond
    }

    /// 差分。任一计数回绕(current < previous,理论不发生但内核计数非严格原子)
    /// 或 elapsed ≤ 0 时返回 nil——宁可这一拍不可用,也不给负数或除零。
    public static func compute(
        previous: VMCumulativeCounters,
        current: VMCumulativeCounters,
        elapsed: TimeInterval,
        pageSize: UInt64
    ) -> MemoryRates? {
        guard elapsed > 0 else { return nil }
        guard current.pageins >= previous.pageins,
              current.pageouts >= previous.pageouts,
              current.swapins >= previous.swapins,
              current.swapouts >= previous.swapouts,
              current.compressions >= previous.compressions,
              current.decompressions >= previous.decompressions
        else { return nil }

        func rate(_ now: UInt64, _ then: UInt64) -> Double {
            Double(now - then) * Double(pageSize) / elapsed
        }
        return MemoryRates(
            pageinBytesPerSecond: rate(current.pageins, previous.pageins),
            pageoutBytesPerSecond: rate(current.pageouts, previous.pageouts),
            swapinBytesPerSecond: rate(current.swapins, previous.swapins),
            swapoutBytesPerSecond: rate(current.swapouts, previous.swapouts),
            compressionBytesPerSecond: rate(current.compressions, previous.compressions),
            decompressionBytesPerSecond: rate(current.decompressions, previous.decompressions)
        )
    }
}
