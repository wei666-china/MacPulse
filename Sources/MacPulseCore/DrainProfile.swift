import Foundation

/// 用电上下文。五个维度全部零成本可读。
///
/// 分档依据来自对真实历史的统计（4968 个放电分钟）：
/// CPU <5% 平均 1.41W、5–12% 4.70W、12–25% 7.45W、25–45% 12.12W、45%+ 23.68W。
/// 17 倍跨度且单调——这就是分桶均值能零调参捕捉、而线性拟合会在高档严重
/// 欠拟合的原因。而每档内部 0.5–18W 的宽散布，正是缺失的第二维：亮度。
public struct UsageContext: Codable, Sendable, Equatable, Hashable {
    public enum CPUBand: Int, Codable, Sendable, CaseIterable {
        case idle = 0, light = 1, moderate = 2, heavy = 3, intense = 4

        public init(cpuPercent: Double) {
            switch cpuPercent {
            case ..<5: self = .idle
            case ..<12: self = .light
            case ..<25: self = .moderate
            case ..<45: self = .heavy
            default: self = .intense
            }
        }

        public var title: String {
            switch self {
            case .idle: String(localized: "几乎空闲")
            case .light: String(localized: "轻负载")
            case .moderate: String(localized: "中等负载")
            case .heavy: String(localized: "重负载")
            case .intense: String(localized: "满载")
            }
        }
    }

    /// 亮度用背光电流（µA）而不是 nits 分档：µA 对功率线性。
    /// 但我们**从不把它换算成瓦特**——它只是个桶键，瓦特永远从真实放电里学。
    public enum DisplayBand: Int, Codable, Sendable, CaseIterable {
        case asleep = 0, low = 1, medium = 2, high = 3

        public init(backlightMicroAmps: Double?) {
            guard let value = backlightMicroAmps else { self = .medium; return }
            switch value {
            case ..<300: self = .asleep
            case ..<8_000: self = .low
            case ..<25_000: self = .medium
            default: self = .high
            }
        }

        public var title: String {
            switch self {
            case .asleep: String(localized: "屏幕关闭")
            case .low: String(localized: "低亮度")
            case .medium: String(localized: "中等亮度")
            case .high: String(localized: "高亮度")
            }
        }
    }

    public var cpuBand: CPUBand
    public var displayBand: DisplayBand
    public var lowPowerMode: Bool

    public init(cpuBand: CPUBand, displayBand: DisplayBand, lowPowerMode: Bool) {
        self.cpuBand = cpuBand
        self.displayBand = displayBand
        self.lowPowerMode = lowPowerMode
    }

    public init(cpuPercent: Double?, backlightMicroAmps: Double?, lowPowerMode: Bool) {
        cpuBand = CPUBand(cpuPercent: cpuPercent ?? 0)
        displayBand = DisplayBand(backlightMicroAmps: backlightMicroAmps)
        self.lowPowerMode = lowPowerMode
    }

    /// 三级键。回退阶梯用的是收缩而不是硬切换，见 `DrainProfile.expectedWatts`。
    public var tier0Key: String { "t0|cpu\(cpuBand.rawValue)|disp\(displayBand.rawValue)|lpm\(lowPowerMode ? 1 : 0)" }
    public var tier1Key: String { "t1|cpu\(cpuBand.rawValue)|lpm\(lowPowerMode ? 1 : 0)" }
    public var tier2Key: String { "t2|cpu\(cpuBand.rawValue)" }
}

/// 单个桶的统计量。
public struct DrainBucket: Codable, Sendable, Equatable {
    public var meanWatts: Double
    public var varianceAccumulator: Double
    public var sampleMinutes: Double
    public var lastUpdated: Date

    public init(meanWatts: Double = 0, varianceAccumulator: Double = 0, sampleMinutes: Double = 0, lastUpdated: Date = .distantPast) {
        self.meanWatts = meanWatts
        self.varianceAccumulator = varianceAccumulator
        self.sampleMinutes = sampleMinutes
        self.lastUpdated = lastUpdated
    }

    public var standardDeviation: Double {
        max(0, varianceAccumulator).squareRoot()
    }

    /// 桶内相对离散度。同一个桶里可能混着两种完全不同的用法
    /// （视频会议和编译都可能是 20% CPU），离散度大就该降低置信度、显示区间，
    /// 而不是给一个谁都不像的平均值。
    public var relativeSpread: Double {
        guard meanWatts > 0 else { return .infinity }
        return standardDeviation / meanWatts
    }

    /// 一分钟一次的 EWMA 更新。
    ///
    /// α 从 1/(n+1) 起步并以 1/240 为下限 —— 相当于 240 分钟的滑动窗口：
    /// 数小时内适应新习惯，一个月内忘掉旧习惯。
    public mutating func update(watts: Double, at date: Date) {
        let alpha = max(0.02, 1 / min(sampleMinutes + 1, 240))
        let delta = watts - meanWatts
        meanWatts += alpha * delta
        varianceAccumulator += alpha * (delta * (watts - meanWatts) - varianceAccumulator)
        sampleMinutes = min(sampleMinutes + 1, 10_000)
        lastUpdated = date
    }

    /// 加载时按时间衰减样本权重：30 天减半。
    public func decayed(to now: Date) -> DrainBucket {
        guard lastUpdated > .distantPast else { return self }
        let days = max(0, now.timeIntervalSince(lastUpdated) / 86_400)
        guard days > 0 else { return self }
        var copy = self
        copy.sampleMinutes *= pow(0.5, days / 30)
        return copy
    }
}

/// 充电速率档案，按电量分段。
///
/// **不能用「瞬时功率 × 剩余能量」估充满时间。** 锂电池在 80% 左右从恒流转恒压，
/// 电流开始衰减；用高电量段之前的瞬时功率外推，会把最后 20% 需要的时间严重低估。
/// 所以这里学的是「每一段各自的 Wh/min」，把剩余各段分别算完再相加。
public struct ChargeProfile: Codable, Sendable, Equatable {
    /// 分段边界。80% 之后越切越细，因为衰减就发生在那里。
    public static let bandBounds: [(lower: Double, upper: Double)] = [
        (0, 20), (20, 40), (40, 60), (60, 80), (80, 90), (90, 95), (95, 100)
    ]

    /// 出厂先验的衰减形状：80% 以下按额定功率走，之后逐段递减。
    /// 这些系数是保守估计，一旦有实测就会被 EWMA 盖过。
    public static let taperPrior: [Double] = [1.0, 1.0, 1.0, 1.0, 0.45, 0.20, 0.10]

    /// 键形如 `"band3|adapter1"`。适配器档位不同，充电速率差别很大。
    public var bands: [String: DrainBucket]

    public init(bands: [String: DrainBucket] = [:]) {
        self.bands = bands
    }

    public static func bandIndex(for soc: Double) -> Int {
        for (index, bound) in bandBounds.enumerated() where soc < bound.upper {
            return index
        }
        return bandBounds.count - 1
    }

    /// 适配器档位：≤30W / ≤70W / 更大。
    public static func adapterTier(_ ratedWatts: Double?) -> Int {
        guard let watts = ratedWatts, watts > 0 else { return 1 }
        if watts <= 30 { return 0 }
        if watts <= 70 { return 1 }
        return 2
    }

    public static func key(bandIndex: Int, adapterTier: Int) -> String {
        "band\(bandIndex)|adapter\(adapterTier)"
    }

    public mutating func record(wattHoursPerMinute: Double, soc: Double, adapterRatedWatts: Double?, at date: Date) {
        guard wattHoursPerMinute.isFinite, wattHoursPerMinute > 0 else { return }
        let key = Self.key(
            bandIndex: Self.bandIndex(for: soc),
            adapterTier: Self.adapterTier(adapterRatedWatts)
        )
        var bucket = bands[key] ?? DrainBucket()
        bucket.update(watts: wattHoursPerMinute, at: date)
        bands[key] = bucket
    }

    /// 从当前电量充到满还需要多少分钟。
    ///
    /// 逐段累加，而不是拿一个平均速率乘剩余量——后者正是 80% 以上会大幅低估的原因。
    public func minutesToFull(
        fromSoc soc: Double,
        wattHoursPerPercent: Double,
        adapterRatedWatts: Double?,
        observedWattHoursPerMinute: Double?
    ) -> Int? {
        guard soc < 100, wattHoursPerPercent > 0 else { return nil }
        let tier = Self.adapterTier(adapterRatedWatts)

        // 基准速率：优先用当前实测，其次用已学到的低电量段，最后按适配器额定推算。
        let baseline: Double
        if let observed = observedWattHoursPerMinute, observed > 0 {
            baseline = observed
        } else if let learned = bands[Self.key(bandIndex: 0, adapterTier: tier)]?.meanWatts, learned > 0 {
            baseline = learned
        } else if let watts = adapterRatedWatts, watts > 0 {
            // 额定功率里只有一部分真正进电芯。
            baseline = watts * 0.75 / 60
        } else {
            return nil
        }

        var minutes = 0.0
        for (index, bound) in Self.bandBounds.enumerated() {
            let lower = Swift.max(soc, bound.lower)
            guard lower < bound.upper else { continue }
            let percentInBand = bound.upper - lower
            let wattHoursNeeded = percentInBand * wattHoursPerPercent

            let rate: Double
            if let learned = bands[Self.key(bandIndex: index, adapterTier: tier)],
               learned.sampleMinutes >= 20,
               learned.meanWatts > 0 {
                rate = learned.meanWatts
            } else {
                rate = baseline * Self.taperPrior[index]
            }
            guard rate > 0 else { continue }
            minutes += wattHoursNeeded / rate
        }

        guard minutes.isFinite, minutes > 0 else { return nil }
        return Int(Swift.min(1_080, Swift.max(1, minutes)))
    }
}

/// 学到的耗电档案。
///
/// 刻意不用神经网络，理由有四：
/// ① 可解释——界面能直接说「你在这种用法下平均 7.4W」，用户可以对着同屏的
///    实时瓦数验证它；② 对缺失特征鲁棒——亮度读不到就降一级，回归模型得插补；
/// ③ O(1)、40 行、无优化器、无后台训练；④ 实测关系是分档强非线性且单调，
///    分桶均值零调参就能精确捕捉。没有值得用不可审计模型去换的精度剩余。
public struct DrainProfile: Codable, Sendable, Equatable {
    /// 桶成熟所需的分钟数。未成熟时按比例向父级收缩，不做硬切换。
    public static let maturityMinutes = 60.0

    public var buckets: [String: DrainBucket]
    /// 全局放电均值，作为倒数第二级兜底。
    public var globalBucket: DrainBucket
    /// 充电速率档案。与放电分开学——那是两个不同的物理过程。
    public var chargeProfile = ChargeProfile()
    /// 学到的「每 1% 电量对应多少 Wh」。
    ///
    /// 实测 7 段长放电积分得 67.3 Wh/100%（sd 3.4），而铭牌
    /// `AppleRawMaxCapacity × Voltage` 只有 63.1 —— **系统性偏低约 6%**，
    /// 因为 Voltage 是瞬时端电压，会随电量下垂。所以这个值本身就该学。
    public var learnedWattHoursPerPercent: Double?
    /// 观测到的最低结束电量，用来学关机保留量。
    public var observedFloorPercent: Double?

    public init(
        buckets: [String: DrainBucket] = [:],
        globalBucket: DrainBucket = DrainBucket(),
        learnedWattHoursPerPercent: Double? = nil,
        observedFloorPercent: Double? = nil
    ) {
        self.buckets = buckets
        self.globalBucket = globalBucket
        self.learnedWattHoursPerPercent = learnedWattHoursPerPercent
        self.observedFloorPercent = observedFloorPercent
    }

    private enum CodingKeys: String, CodingKey {
        case buckets, globalBucket, chargeProfile
        case learnedWattHoursPerPercent, observedFloorPercent
    }

    /// 手写容错解码，每个键都 `decodeIfPresent`。
    ///
    /// 教训（实测踩过）：合成的 Decodable **不会**用属性默认值补缺失的键。
    /// 给这个类型加 `chargeProfile` 字段那次，旧档案里没有这个键，整个解码
    /// 抛错，加载方静默回退到出厂先验——**6900 分钟的回填学习被丢了**，
    /// 用独立复算对账才发现（空闲档正好停在先验种子值 1.41/n=20）。
    /// 在 SwiftData 上刻意绕开的 schema 演进坑，在自己的 JSON 上踩了一遍。
    /// 今后给本类型或 LearningState 加任何字段，都必须走 decodeIfPresent。
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        buckets = try values.decodeIfPresent([String: DrainBucket].self, forKey: .buckets) ?? [:]
        globalBucket = try values.decodeIfPresent(DrainBucket.self, forKey: .globalBucket) ?? DrainBucket()
        chargeProfile = try values.decodeIfPresent(ChargeProfile.self, forKey: .chargeProfile) ?? ChargeProfile()
        learnedWattHoursPerPercent = try values.decodeIfPresent(Double.self, forKey: .learnedWattHoursPerPercent)
        observedFloorPercent = try values.decodeIfPresent(Double.self, forKey: .observedFloorPercent)
    }

    /// 出厂先验，来自对真实历史的统计。样本权重刻意压低，
    /// 一旦有真实数据就会被迅速盖过。
    public static func shippingPrior() -> DrainProfile {
        var profile = DrainProfile()
        let base: [UsageContext.CPUBand: Double] = [
            .idle: 1.41, .light: 4.70, .moderate: 7.45, .heavy: 12.12, .intense: 23.68
        ]
        // 亮度对整机功耗的相对影响：屏幕关闭省一大截，高亮度多花一点。
        let displayFactor: [UsageContext.DisplayBand: Double] = [
            .asleep: 0.55, .low: 0.85, .medium: 1.0, .high: 1.25
        ]
        for (band, watts) in base {
            for (display, factor) in displayFactor {
                let context = UsageContext(cpuBand: band, displayBand: display, lowPowerMode: false)
                profile.buckets[context.tier0Key] = DrainBucket(
                    meanWatts: watts * factor,
                    sampleMinutes: 20,
                    lastUpdated: .distantPast
                )
            }
            let tier2 = UsageContext(cpuBand: band, displayBand: .medium, lowPowerMode: false)
            profile.buckets[tier2.tier2Key] = DrainBucket(meanWatts: watts, sampleMinutes: 20, lastUpdated: .distantPast)
        }
        profile.globalBucket = DrainBucket(meanWatts: 6.12, sampleMinutes: 20)
        return profile
    }

    public mutating func record(watts: Double, context: UsageContext, at date: Date) {
        guard watts.isFinite, watts > 0 else { return }
        // 三级各更新一次，共 3 次 upsert/分钟——不是每次采样。
        for key in [context.tier0Key, context.tier1Key, context.tier2Key] {
            var bucket = buckets[key] ?? DrainBucket()
            bucket.update(watts: watts, at: date)
            buckets[key] = bucket
        }
        globalBucket.update(watts: watts, at: date)
    }

    public struct Expectation: Sendable, Equatable {
        public var watts: Double
        /// 主桶已积累的分钟数，用于决定权重与置信度。
        public var maturityMinutes: Double
        /// 主桶内的相对离散度。
        public var relativeSpread: Double
    }

    /// 收缩式回退：未成熟的桶按 `n/60` 的比例贡献，其余交给父级，递归而下。
    /// 桶成熟时没有跳变。
    public func expectedWatts(for context: UsageContext, now: Date, sessionMeanWatts: Double? = nil) -> Expectation? {
        let ladder = [context.tier0Key, context.tier1Key, context.tier2Key]
        var remaining = 1.0
        var accumulated = 0.0
        var primaryMinutes = 0.0
        var primarySpread = Double.infinity

        for (index, key) in ladder.enumerated() {
            guard let bucket = buckets[key]?.decayed(to: now), bucket.sampleMinutes > 0 else { continue }
            let weight = min(1, bucket.sampleMinutes / Self.maturityMinutes)
            if index == 0 {
                primaryMinutes = bucket.sampleMinutes
                primarySpread = bucket.relativeSpread
            }
            accumulated += remaining * weight * bucket.meanWatts
            remaining *= (1 - weight)
            if remaining <= 0.001 { break }
        }

        if remaining > 0.001, let sessionMeanWatts, sessionMeanWatts > 0 {
            let weight = 0.5
            accumulated += remaining * weight * sessionMeanWatts
            remaining *= (1 - weight)
        }

        if remaining > 0.001, globalBucket.sampleMinutes > 0 {
            accumulated += remaining * globalBucket.meanWatts
            remaining = 0
        }

        guard accumulated > 0 else { return nil }
        // 若阶梯没走满，把已累计的部分归一化，避免系统性偏低。
        let watts = remaining > 0.001 ? accumulated / (1 - remaining) : accumulated
        guard watts.isFinite, watts > 0 else { return nil }

        return Expectation(
            watts: watts,
            maturityMinutes: primaryMinutes,
            relativeSpread: primarySpread
        )
    }

    /// 记录一次完整放电段测得的 Wh/%，用 EWMA 合并，并钳在铭牌 ±20% 内，
    /// 免得一段异常数据毁掉整个能量模型。
    public mutating func recordWattHoursPerPercent(_ value: Double, nameplate: Double?) {
        guard value.isFinite, value > 0 else { return }
        let clamped: Double
        if let nameplate, nameplate > 0 {
            clamped = min(nameplate * 1.2, max(nameplate * 0.8, value))
        } else {
            clamped = value
        }
        if let existing = learnedWattHoursPerPercent {
            learnedWattHoursPerPercent = existing * 0.7 + clamped * 0.3
        } else {
            learnedWattHoursPerPercent = clamped
        }
    }
}
