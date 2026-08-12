import Foundation

/// 「我这台机器的内存到底够不够」——Mac 用户问得最多、又最没人正面回答的问题。
///
/// 判据不看「用了多少」(现代 macOS 会把空闲内存全用作缓存,占用高是**好事**),
/// 只看三个真正说明吃紧的信号:
/// 1. **换页出磁盘的量**(swap used):内存装不下了才会往盘上倒
/// 2. **压缩内存占比**:系统在拼命压缩腾地方
/// 3. **系统压力等级**:macOS 自己的判断,最权威
///
/// 三者都正常 = 内存充裕,不管「已用」显示多高。
public struct MemorySnapshotExtras: Codable, Sendable, Equatable {
    /// 已换出到磁盘的字节。持续大于 0 是内存不足的最硬证据。
    public var swapUsedBytes: UInt64?
    public var swapTotalBytes: UInt64?
    /// 系统内存压力等级:1 正常、2 警告、4 紧急(sysctl 原值)。
    public var pressureLevel: Int?

    public init(swapUsedBytes: UInt64? = nil, swapTotalBytes: UInt64? = nil, pressureLevel: Int? = nil) {
        self.swapUsedBytes = swapUsedBytes
        self.swapTotalBytes = swapTotalBytes
        self.pressureLevel = pressureLevel
    }
}

public struct MemoryDiagnosis: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// 内存充裕,占用高只是缓存。
        case comfortable
        /// 偶有吃紧:开始换页,但压力等级仍正常。
        case occasionalPressure
        /// 长期不足:压力等级报警或换页量大,该考虑升级了。
        case insufficient
    }

    public var kind: Kind
    public var summary: String
    public var detail: String
    /// 给出的行动建议;没有可行动的事时为 nil。
    public var advice: String?
    public var isWarning: Bool { kind == .insufficient }

    public init(kind: Kind, summary: String, detail: String, advice: String? = nil) {
        self.kind = kind
        self.summary = summary
        self.detail = detail
        self.advice = advice
    }

    /// 判据阈值。
    /// - 换页 1GB:偶发换页每台 Mac 都有,1GB 以内不值得说。
    /// - 换页 4GB:到这个量说明内存长期不够,机器会明显变卡且额外磨损 SSD。
    /// - 压缩占比 25%:系统把四分之一的内存拿去压缩,是在硬撑。
    public static let mildSwapBytes: UInt64 = 1_073_741_824
    public static let heavySwapBytes: UInt64 = 4 * 1_073_741_824
    public static let heavyCompressionRatio: Double = 0.25

    public static func diagnose(
        breakdown: MemoryBreakdown,
        extras: MemorySnapshotExtras
    ) -> MemoryDiagnosis? {
        guard breakdown.totalBytes > 0 else { return nil }

        let totalGB = Double(breakdown.totalBytes) / 1_073_741_824
        let totalText = String(format: "%.0f GB", totalGB)
        let swap = extras.swapUsedBytes ?? 0
        let swapGB = Double(swap) / 1_073_741_824
        let compressionRatio = Double(breakdown.compressedBytes) / Double(breakdown.totalBytes)
        let pressure = extras.pressureLevel ?? 1

        // 系统自己报了压力,或换页量已经很大 → 长期不足。
        if pressure >= 2 || swap >= heavySwapBytes {
            return MemoryDiagnosis(
                kind: .insufficient,
                summary: "内存长期不足",
                detail: String(
                    format: "%@ 内存已换出 %.1f GB 到磁盘%@。内存装不下时系统要反复读写硬盘,机器会明显变卡,SSD 也多受一份磨损。",
                    totalText, swapGB, pressure >= 2 ? ",且系统正报告内存压力" : ""
                ),
                advice: "如果这是常态,下次换机建议直接上更大内存;眼下可以少开几个占内存的 App(内存页里按占用排序能看出是谁)。"
            )
        }

        if swap >= mildSwapBytes || compressionRatio >= heavyCompressionRatio {
            return MemoryDiagnosis(
                kind: .occasionalPressure,
                summary: "偶尔吃紧,但还撑得住",
                detail: String(
                    format: "%@ 内存换出了 %.1f GB,压缩内存占 %.0f%%——系统在腾地方,但还没到报警的程度。",
                    totalText, swapGB, compressionRatio * 100
                ),
                advice: "多发生在同时开很多 App 时。想更顺手可以关掉不用的窗口,不必急着加内存。"
            )
        }

        return MemoryDiagnosis(
            kind: .comfortable,
            summary: "内存充裕",
            detail: String(
                format: "%@ 内存,换页 %.1f GB、压缩占 %.0f%%,都在健康范围。「已用」偏高是正常的——macOS 会把闲置内存拿来做缓存,那是好事,不是不够用。",
                totalText, swapGB, compressionRatio * 100
            ),
            advice: nil
        )
    }
}
