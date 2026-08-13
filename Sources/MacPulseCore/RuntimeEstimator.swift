import Foundation

/// 估算依据。界面上要把三个来源并排显示——这既是最诚实的做法，
/// 也让用户能自己判断该信哪个。
public enum RuntimeBasis: String, Codable, Sendable, CaseIterable {
    /// 按当前实测功耗。
    case instant
    /// 按学到的日常习惯。
    case learned
    /// 电池计量芯片自己的估计（`AvgTimeToEmpty` / `AvgTimeToFull`）。
    case gauge
    case blended

    public var title: String {
        switch self {
        case .instant: String(localized: "按当前负载")
        case .learned: String(localized: "按你的日常习惯")
        case .gauge: String(localized: "电池计量芯片")
        case .blended: String(localized: "综合估算")
        }
    }
}

public enum RuntimeConfidence: String, Codable, Sendable {
    case high, medium, low

    public var title: String {
        switch self {
        case .high: String(localized: "置信度高")
        case .medium: String(localized: "置信度中")
        case .low: String(localized: "负载波动较大，给出区间")
        }
    }
}

public struct RuntimeEstimate: Sendable, Equatable {
    public var minutes: Int?
    public var lowMinutes: Int?
    public var highMinutes: Int?
    public var basis: RuntimeBasis
    public var confidence: RuntimeConfidence
    /// 各来源各自的估计值，供界面并排展示。
    public var candidates: [RuntimeBasis: Int]
    /// 系统给的那个值。**只用于对照，绝不参与融合。**
    public var systemEstimateMinutes: Int?
    /// 被钳制拒绝的原因，便于解释「为什么和系统给的不一样」。
    public var rejectedSystemEstimate: Bool

    public init(
        minutes: Int? = nil,
        lowMinutes: Int? = nil,
        highMinutes: Int? = nil,
        basis: RuntimeBasis = .blended,
        confidence: RuntimeConfidence = .low,
        candidates: [RuntimeBasis: Int] = [:],
        systemEstimateMinutes: Int? = nil,
        rejectedSystemEstimate: Bool = false
    ) {
        self.minutes = minutes
        self.lowMinutes = lowMinutes
        self.highMinutes = highMinutes
        self.basis = basis
        self.confidence = confidence
        self.candidates = candidates
        self.systemEstimateMinutes = systemEstimateMinutes
        self.rejectedSystemEstimate = rejectedSystemEstimate
    }
}

public struct RuntimeEstimatorInput: Sendable {
    /// 当前电量百分比。
    ///
    /// 必须与 `wattHoursPerPercent` 用同一把尺子。实测表明
    /// `AppleRawCurrentCapacity / AppleRawMaxCapacity` 与系统显示的百分比
    /// 既非固定偏移也非固定比例（98% vs 93.18、40% vs 36.6），而 Wh/% 是拿
    /// 显示百分比标定的——混用两把尺子会让可用能量凭空偏 5%。
    public var socFinePercent: Double
    /// 每 1% 电量对应的 Wh。
    public var wattHoursPerPercent: Double
    /// 关机保留量（百分点）。
    public var reserveFloorPercent: Double
    /// 净功率，放电为负。
    public var netPowerWatts: Double?
    /// 计量芯片给的分钟数，已滤掉 65535 哨兵。
    public var gaugeMinutes: Int?
    /// `IOPSGetTimeRemainingEstimate` 的原始值。只作对照。
    public var systemEstimateMinutes: Int?
    public var context: UsageContext
    public var isCharging: Bool
    public var now: Date
    /// 采样间隔，用于 dt 感知的 EMA。
    public var sampleInterval: TimeInterval
    /// 本次放电段最近 15 分钟观测到的电量下降（百分点）与经过的分钟数。
    public var recentSocDropPercent: Double?
    public var recentWindowMinutes: Double?
    public var sessionMeanWatts: Double?
    /// 适配器额定功率，用于给充电分段选档。
    public var adapterRatedWatts: Double?

    public init(
        socFinePercent: Double,
        wattHoursPerPercent: Double,
        reserveFloorPercent: Double = 3,
        netPowerWatts: Double?,
        gaugeMinutes: Int?,
        systemEstimateMinutes: Int?,
        context: UsageContext,
        isCharging: Bool,
        now: Date,
        sampleInterval: TimeInterval = 2,
        recentSocDropPercent: Double? = nil,
        recentWindowMinutes: Double? = nil,
        sessionMeanWatts: Double? = nil,
        adapterRatedWatts: Double? = nil
    ) {
        self.socFinePercent = socFinePercent
        self.wattHoursPerPercent = wattHoursPerPercent
        self.reserveFloorPercent = reserveFloorPercent
        self.netPowerWatts = netPowerWatts
        self.gaugeMinutes = gaugeMinutes
        self.systemEstimateMinutes = systemEstimateMinutes
        self.context = context
        self.isCharging = isCharging
        self.now = now
        self.sampleInterval = sampleInterval
        self.recentSocDropPercent = recentSocDropPercent
        self.recentWindowMinutes = recentWindowMinutes
        self.sessionMeanWatts = sessionMeanWatts
        self.adapterRatedWatts = adapterRatedWatts
    }
}

/// 续航估算器。纯值类型、无 MainActor、无 IOKit——因此可以拿历史数据离线回测。
public struct RuntimeEstimator: Sendable {
    /// powerd 的饱和常数。实测在这台机器上无论电量怎么掉都返回 1200 分，
    /// 而同一时刻计量芯片给的是 110–176 分。这不是测量值，是上限。
    public static let systemSaturationMinutes = 1_200
    /// 计量芯片的「未知」哨兵。
    public static let gaugeSentinel = 65_535
    /// 显示值的绝对边界。
    public static let absoluteBounds = 1...1_080
    /// EMA 时间常数。
    public static let emaTau: TimeInterval = 90

    private var emaWatts: Double?
    private var lastSampleAt: Date?
    private var lastDisplayedMinutes: Int?
    private var lastDisplayedAt: Date?

    public init() {}

    /// 充放电切换、唤醒、长时间断档都要重置 EMA——跨越这些边界的平均没有意义。
    public mutating func reset() {
        emaWatts = nil
        lastSampleAt = nil
        lastDisplayedMinutes = nil
        lastDisplayedAt = nil
    }

    public mutating func update(_ input: RuntimeEstimatorInput, profile: DrainProfile) -> RuntimeEstimate {
        let magnitude = input.netPowerWatts.map(abs)
        updateEMA(watts: magnitude, now: input.now, sampleInterval: input.sampleInterval)

        let usablePercent = max(0, input.socFinePercent - input.reserveFloorPercent)
        let usableWattHours = input.isCharging
            ? max(0, 100 - input.socFinePercent) * input.wattHoursPerPercent
            : usablePercent * input.wattHoursPerPercent

        var estimate = RuntimeEstimate(systemEstimateMinutes: input.systemEstimateMinutes)

        // 系统值先过闸：命中饱和上限就直接拒绝，并记下来供界面解释。
        let systemAccepted = acceptSystemEstimate(input.systemEstimateMinutes)
        estimate.rejectedSystemEstimate = input.systemEstimateMinutes != nil && !systemAccepted

        guard usableWattHours > 0 else {
            estimate.confidence = .low
            return estimate
        }

        // —— 三个来源，全部先换算成瓦特再融合 ——
        //
        // 时间是速率的倒数，直接对分钟数取平均会过度加权最长的那个估计。
        var weightedWatts = 0.0
        var totalWeight = 0.0
        var candidates: [RuntimeBasis: Int] = [:]

        // 1. 当前负载
        if let instant = emaWatts, instant > 0.05 {
            let weight = instantWeight(profile: profile, input: input)
            weightedWatts += weight * instant
            totalWeight += weight
            candidates[.instant] = minutes(usableWattHours: usableWattHours, watts: instant)
        }

        // 2a. 充电：走分段模型而不是「瞬时功率 × 剩余能量」。
        //     80% 之后转恒压、电流衰减，用瞬时功率外推会严重低估最后那段时间。
        if input.isCharging {
            let observedWhPerMinute = emaWatts.map { $0 / 60 }
            if let banded = profile.chargeProfile.minutesToFull(
                fromSoc: input.socFinePercent,
                wattHoursPerPercent: input.wattHoursPerPercent,
                adapterRatedWatts: input.adapterRatedWatts,
                observedWattHoursPerMinute: observedWhPerMinute
            ) {
                weightedWatts += 1.0 * (usableWattHours * 60 / Double(banded))
                totalWeight += 1.0
                candidates[.learned] = banded
            }
        }

        // 2. 日常习惯
        let expectation = profile.expectedWatts(
            for: input.context,
            now: input.now,
            sessionMeanWatts: input.sessionMeanWatts
        )
        if !input.isCharging, let expectation, expectation.watts > 0.05 {
            let maturity = min(1, expectation.maturityMinutes / 120)
            var weight = maturity * 1.2
            if let instant = emaWatts, instant > 0 {
                // 负载抖动大时更信习惯，稳定时更信仪表。
                let volatility = abs(expectation.watts - instant) / max(expectation.watts, instant)
                if volatility > 0.40 { weight *= 1.5 }
            }
            weightedWatts += weight * expectation.watts
            totalWeight += weight
            candidates[.learned] = minutes(usableWattHours: usableWattHours, watts: expectation.watts)
        }

        // 3. 计量芯片
        if let gaugeMinutes = validGauge(input.gaugeMinutes), gaugeMinutes > 0 {
            let equivalentWatts = usableWattHours * 60 / Double(gaugeMinutes)
            if equivalentWatts > 0.05 {
                weightedWatts += 0.8 * equivalentWatts
                totalWeight += 0.8
                candidates[.gauge] = gaugeMinutes
            }
        }

        guard totalWeight > 0, weightedWatts > 0 else {
            estimate.candidates = candidates
            estimate.confidence = .low
            return estimate
        }

        let blendedWatts = weightedWatts / totalWeight
        var blended = minutes(usableWattHours: usableWattHours, watts: blendedWatts)

        // —— 钳制 ——
        blended = applyClamps(blended, input: input, profile: profile, usableWattHours: usableWattHours)
        blended = rateLimited(blended, now: input.now, isCharging: input.isCharging)

        estimate.minutes = blended
        estimate.candidates = candidates
        estimate.basis = dominantBasis(candidates: candidates, blended: blended)
        estimate.confidence = confidence(candidates: candidates, expectation: expectation)

        if estimate.confidence == .low {
            // 低置信度给区间而不是点值。宁可说「大概 2–3 小时」，
            // 也不要报一个看起来精确的假数字。
            let spread = max(0.2, expectation?.relativeSpread ?? 0.35)
            estimate.lowMinutes = max(RuntimeEstimator.absoluteBounds.lowerBound, Int(Double(blended) * (1 - min(0.5, spread))))
            estimate.highMinutes = min(RuntimeEstimator.absoluteBounds.upperBound, Int(Double(blended) * (1 + min(0.5, spread))))
        }

        lastDisplayedMinutes = blended
        lastDisplayedAt = input.now
        return estimate
    }

    // MARK: - 内部

    private mutating func updateEMA(watts: Double?, now: Date, sampleInterval: TimeInterval) {
        guard let watts, watts.isFinite else { return }
        defer { lastSampleAt = now }
        guard let last = lastSampleAt else {
            emaWatts = watts
            return
        }
        let dt = now.timeIntervalSince(last)
        // 断档超过 5 分钟：中间发生了什么无从得知，重新起步而不是硬平均。
        guard dt > 0, dt < 300 else {
            emaWatts = watts
            return
        }
        // dt 感知的 α：采样节奏在 2 秒和 10 秒之间切换，固定 α 会让时间常数漂移。
        let alpha = 1 - exp(-dt / Self.emaTau)
        emaWatts = (emaWatts ?? watts) + alpha * (watts - (emaWatts ?? watts))
    }

    private func instantWeight(profile: DrainProfile, input: RuntimeEstimatorInput) -> Double {
        guard let expectation = profile.expectedWatts(for: input.context, now: input.now),
              let instant = emaWatts, instant > 0, expectation.watts > 0
        else { return 1.0 }
        let volatility = abs(expectation.watts - instant) / max(expectation.watts, instant)
        // 负载稳定：信仪表。
        return volatility < 0.15 ? 1.5 : 1.0
    }

    private func validGauge(_ minutes: Int?) -> Int? {
        guard let minutes else { return nil }
        // 65535 是「未知」哨兵，不是 45 天。
        guard minutes != Self.gaugeSentinel, minutes > 0, minutes < Self.systemSaturationMinutes else { return nil }
        return minutes
    }

    private func acceptSystemEstimate(_ minutes: Int?) -> Bool {
        guard let minutes else { return false }
        return minutes > 0 && minutes < Self.systemSaturationMinutes
    }

    private func minutes(usableWattHours: Double, watts: Double) -> Int {
        let raw = usableWattHours * 60 / watts
        guard raw.isFinite else { return Self.absoluteBounds.upperBound }
        return Int(min(Double(Self.absoluteBounds.upperBound), max(Double(Self.absoluteBounds.lowerBound), raw)))
    }

    /// 四道钳制。**每一道都能独立干掉 20:00。**
    private func applyClamps(
        _ candidate: Int,
        input: RuntimeEstimatorInput,
        profile: DrainProfile,
        usableWattHours: Double
    ) -> Int {
        var value = candidate

        // ① 观测斜率一致性——最强也最诚实，纯观测、零模型。
        //    看本次放电段最近 15 分钟电量掉了多少，据此推出一个上限。
        //    实测 34% 每 6 分钟掉 1% → 推得约 186 分 → 上限 558 分。
        //    1200 在这一条就死了，哪怕没有下面那条上限规则。
        if !input.isCharging,
           let drop = input.recentSocDropPercent, drop > 0,
           let window = input.recentWindowMinutes, window > 0 {
            let implied = window * max(0, input.socFinePercent - input.reserveFloorPercent) / drop
            if implied.isFinite, implied > 0 {
                value = min(value, Int(implied * 3))
            }
        }

        // ② 物理下限：低于这个功耗在物理上不可能。
        let floorWatts = max(0.9, 0.6 * (profile.globalBucket.meanWatts * 0.5))
        let physicalCeiling = minutes(usableWattHours: usableWattHours, watts: floorWatts)
        value = min(value, physicalCeiling)

        // ③ 绝对边界。
        value = min(Self.absoluteBounds.upperBound, max(Self.absoluteBounds.lowerBound, value))
        return value
    }

    /// ④ 变化率限制：显示值每分钟移动不超过 ±25%，避免数字乱跳。
    ///    充放电状态切换时不限制——那是真实的突变。
    private func rateLimited(_ candidate: Int, now: Date, isCharging: Bool) -> Int {
        guard let previous = lastDisplayedMinutes, let previousAt = lastDisplayedAt else { return candidate }
        let elapsedMinutes = now.timeIntervalSince(previousAt) / 60
        guard elapsedMinutes > 0, elapsedMinutes < 10 else { return candidate }
        let maxChange = Double(previous) * 0.25 * max(elapsedMinutes, 0.05)
        let delta = Double(candidate - previous)
        guard abs(delta) > maxChange else { return candidate }
        return previous + Int(delta > 0 ? maxChange : -maxChange)
    }

    private func dominantBasis(candidates: [RuntimeBasis: Int], blended: Int) -> RuntimeBasis {
        candidates.count > 1 ? .blended : (candidates.keys.first ?? .blended)
    }

    private func confidence(candidates: [RuntimeBasis: Int], expectation: DrainProfile.Expectation?) -> RuntimeConfidence {
        let values = candidates.values.map(Double.init).filter { $0 > 0 }
        guard values.count >= 2, let low = values.min(), let high = values.max(), low > 0 else {
            return .low
        }
        let spread = high / low
        let bucketNoisy = (expectation?.relativeSpread ?? .infinity) > 0.35
        let mature = (expectation?.maturityMinutes ?? 0) >= DrainProfile.maturityMinutes

        if spread <= 1.25, mature, !bucketNoisy { return .high }
        if spread <= 1.80 { return .medium }
        return .low
    }
}
