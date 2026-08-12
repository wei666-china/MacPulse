import Foundation

/// 「机器怎么突然变慢了」的答案。
///
/// Apple Silicon 上没有一个「我正在节流」的直接读数(苹果不发布这个通道),
/// 但可以从一组事实推断出来,判据的核心是**满载却跑不到最高频**:
/// 芯片在忙、频率却上不去,一定有东西在限制它;剩下的就是分辨限制来自哪。
///
/// 三条铁律照旧:任何一项原料缺失就返回 nil(不猜),阈值全部写在这里可复核,
/// 结论用大白话说清「谁在限速、能不能改善」。
public struct ThrottleDiagnosis: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// 满载且频率跑满,一切正常。
        case fullSpeed
        /// 芯片太热,系统主动降频保护。
        case thermal
        /// 低电量模式限制(用户自己开的)。
        case lowPowerMode
        /// 频率受限但机器不热、也没开省电——多半是功耗墙或供电不足。
        case powerLimit
        /// 机器没在忙,频率低是省电,不是被限制。
        case idle
    }

    public var kind: Kind
    /// 一句话结论,直接上卡片。
    public var summary: String
    /// 展开说明:为什么这么判、能做什么。
    public var detail: String
    /// 当前频率占最高频的百分比(0-100)。
    public var frequencyHeadroomPercent: Double?

    public var isWarning: Bool { kind == .thermal || kind == .powerLimit }

    public init(kind: Kind, summary: String, detail: String, frequencyHeadroomPercent: Double? = nil) {
        self.kind = kind
        self.summary = summary
        self.detail = detail
        self.frequencyHeadroomPercent = frequencyHeadroomPercent
    }

    /// 判定输入。全部来自已有读数,不新增任何权限。
    public struct Input: Sendable {
        public var clusterActivePercent: Double?
        public var clusterFreqMHz: Int?
        public var clusterMaxFreqMHz: Int?
        public var hotspotTemperature: Double?
        public var thermalLevel: ThermalLevel
        public var lowPowerModeEnabled: Bool
        public var onBattery: Bool

        public init(
            clusterActivePercent: Double? = nil,
            clusterFreqMHz: Int? = nil,
            clusterMaxFreqMHz: Int? = nil,
            hotspotTemperature: Double? = nil,
            thermalLevel: ThermalLevel = .unknown,
            lowPowerModeEnabled: Bool = false,
            onBattery: Bool = false
        ) {
            self.clusterActivePercent = clusterActivePercent
            self.clusterFreqMHz = clusterFreqMHz
            self.clusterMaxFreqMHz = clusterMaxFreqMHz
            self.hotspotTemperature = hotspotTemperature
            self.thermalLevel = thermalLevel
            self.lowPowerModeEnabled = lowPowerModeEnabled
            self.onBattery = onBattery
        }
    }

    /// 判据阈值。这套数字是拿本机实测调过的,别凭直觉改——
    /// 初版用「忙 35% + 频率低于 85%」,结果一次普通编译(73% 活跃、
    /// 频率 69%、温度 61°C)就被判成「功耗墙限速」,纯属误报:
    /// **突发负载下加权平均频率天然低于峰值**,采样窗口里混着状态切换与短暂空隙,
    /// 光凭频率低根本证明不了「被限制」。
    ///
    /// 所以判据改成:热证据独立成立(温度/热压力够硬,自己就能定案),
    /// 而没有热证据时,必须**又忙又慢到极端**才敢提功耗墙,宁可放过不可错杀。
    /// - 忙线门槛 70%:低于此一律按空闲/正常处理。
    /// - 满速门槛 70%:达到最高档七成就算跑满(留足平均值的天然折损)。
    /// - 功耗墙门槛:活跃 ≥85% 且频率 <55%——只有真的又满载又跑不动才算。
    /// - 热判据 90°C:与界面警示条、量表变红线同一条线,全 App 一个刻度。
    public static let busyThreshold: Double = 70
    public static let fullSpeedRatio: Double = 0.70
    public static let powerLimitBusyThreshold: Double = 85
    public static let powerLimitRatio: Double = 0.55
    public static let hotThreshold: Double = 90

    public static func diagnose(_ input: Input) -> ThrottleDiagnosis? {
        guard let active = input.clusterActivePercent,
              let freq = input.clusterFreqMHz,
              let maxFreq = input.clusterMaxFreqMHz, maxFreq > 0
        else { return nil }

        let ratio = Double(freq) / Double(maxFreq)
        let headroom = min(100, ratio * 100)

        guard active >= busyThreshold else {
            return ThrottleDiagnosis(
                kind: .idle,
                summary: "性能未受限",
                detail: "当前负载不高,频率随需求浮动是正常省电行为。要看是否被限速,请在高负载时查看。",
                frequencyHeadroomPercent: headroom
            )
        }

        guard ratio < fullSpeedRatio else {
            return ThrottleDiagnosis(
                kind: .fullSpeed,
                summary: "满速运行",
                detail: "芯片在满负载下跑到了 \(freq) MHz(最高 \(maxFreq) MHz),没有受到限制。",
                frequencyHeadroomPercent: headroom
            )
        }

        // 到这里已确认:在忙,但频率明显上不去。分辨是谁在限制。
        // 热证据是独立可信的:温度/热压力到线就能定案,不需要频率配合到极端。
        let hot = (input.hotspotTemperature ?? 0) >= hotThreshold
            || input.thermalLevel == .serious || input.thermalLevel == .critical

        if hot {
            let tempText = input.hotspotTemperature.map { String(format: "%.0f°C", $0) } ?? "偏高"
            return ThrottleDiagnosis(
                kind: .thermal,
                summary: "正在热降频",
                detail: "芯片温度 \(tempText),系统主动把频率压到最高档的 \(Int(headroom))% 以保护硬件。改善散热(垫高、清灰、离开高温环境)可以恢复性能。",
                frequencyHeadroomPercent: headroom
            )
        }

        if input.lowPowerModeEnabled {
            return ThrottleDiagnosis(
                kind: .lowPowerMode,
                summary: "低电量模式限速中",
                detail: "你开着低电量模式,系统按设定压低了频率(当前为最高档的 \(Int(headroom))%)。关掉它即可恢复满速。",
                frequencyHeadroomPercent: headroom
            )
        }

        // 没有热证据时,门槛拉到极端才敢说「被功耗墙限住」:
        // 又满载(≥85%)又跑不动(<55%)才算,否则只是普通的突发负载。
        if active >= powerLimitBusyThreshold, ratio < powerLimitRatio {
            return ThrottleDiagnosis(
                kind: .powerLimit,
                summary: "频率受限,但机器不热",
                detail: "芯片持续满载却只跑到最高档的 \(Int(headroom))%,温度也不高——通常是功耗上限所致\(input.onBattery ? "(电池供电时上限更低,插电可缓解)" : ",也可能是充电器供电不足")。",
                frequencyHeadroomPercent: headroom
            )
        }

        return ThrottleDiagnosis(
            kind: .fullSpeed,
            summary: "性能未受限",
            detail: "当前负载下频率随需求浮动(最高档的 \(Int(headroom))%)。突发型任务的平均频率天然低于峰值,这不代表被限速。",
            frequencyHeadroomPercent: headroom
        )
    }
}
