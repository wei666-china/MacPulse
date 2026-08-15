import Foundation

/// 「为什么卡」取样窗口:每约 2 秒一拍的原始证据。
/// 速率型字段本身已是该拍区间内的均速。
public struct BottleneckProbeWindow: Sendable, Equatable {
    public struct Tick: Sendable, Equatable {
        public var timestamp: Date
        /// 全机制(全机=100%)。
        public var cpuUsagePercent: Double?
        /// 每核占用,硬件索引序(能效核在前);空 = 该拍读不到。
        public var perCoreUsage: [Double]
        /// 采集器供给,离线时 nil。
        public var gpuUsagePercent: Double?
        public var memoryRates: MemoryRates?
        public var memoryPressure: MemoryPressureLevel
        public var swapUsedBytes: UInt64?
        public var diskReadBytesPerSecond: Double?
        public var diskWriteBytesPerSecond: Double?
        public var hotspotTemperature: Double?
        public var thermalLevel: ThermalLevel
        public var collectorLive: Bool

        public init(
            timestamp: Date = .init(timeIntervalSince1970: 0),
            cpuUsagePercent: Double? = nil,
            perCoreUsage: [Double] = [],
            gpuUsagePercent: Double? = nil,
            memoryRates: MemoryRates? = nil,
            memoryPressure: MemoryPressureLevel = .unknown,
            swapUsedBytes: UInt64? = nil,
            diskReadBytesPerSecond: Double? = nil,
            diskWriteBytesPerSecond: Double? = nil,
            hotspotTemperature: Double? = nil,
            thermalLevel: ThermalLevel = .nominal,
            collectorLive: Bool = false
        ) {
            self.timestamp = timestamp
            self.cpuUsagePercent = cpuUsagePercent
            self.perCoreUsage = perCoreUsage
            self.gpuUsagePercent = gpuUsagePercent
            self.memoryRates = memoryRates
            self.memoryPressure = memoryPressure
            self.swapUsedBytes = swapUsedBytes
            self.diskReadBytesPerSecond = diskReadBytesPerSecond
            self.diskWriteBytesPerSecond = diskWriteBytesPerSecond
            self.hotspotTemperature = hotspotTemperature
            self.thermalLevel = thermalLevel
            self.collectorLive = collectorLive
        }
    }

    public var ticks: [Tick]
    /// 2 秒节奏下 3 拍 ≈ 4–6 秒窗口,文案统一说「约 5 秒」。
    public static let requiredTicks = 3
    public var isComplete: Bool { ticks.count >= Self.requiredTicks }

    public init(ticks: [Tick] = []) {
        self.ticks = ticks
    }
}

/// 进程候选:从 ProcessGroupSnapshot 折出的纯值。只带显示名,不带路径——
/// 诊断结论会进体检报告外发,隐私红线与报告一致。
public struct BottleneckProcessCandidate: Sendable, Equatable {
    public var name: String
    /// 单核=100% 制原值(与进程页同口径)。
    public var rawCPUPercent: Double?
    public var gpuNanosecondsPerSecond: Double?
    public var diskReadBytesPerSecond: Double?
    public var diskWriteBytesPerSecond: Double?
    public var memoryFootprintBytes: UInt64?

    public init(
        name: String,
        rawCPUPercent: Double? = nil,
        gpuNanosecondsPerSecond: Double? = nil,
        diskReadBytesPerSecond: Double? = nil,
        diskWriteBytesPerSecond: Double? = nil,
        memoryFootprintBytes: UInt64? = nil
    ) {
        self.name = name
        self.rawCPUPercent = rawCPUPercent
        self.gpuNanosecondsPerSecond = gpuNanosecondsPerSecond
        self.diskReadBytesPerSecond = diskReadBytesPerSecond
        self.diskWriteBytesPerSecond = diskWriteBytesPerSecond
        self.memoryFootprintBytes = memoryFootprintBytes
    }
}

/// 「为什么卡」的判定结果。把散在各页的诊断零件焊成一个入口:
/// 小白看 summary 一句话,高手展开 findings 看逐条证据。
///
/// 诚实红线(违反任何一条都是 bug,测试有断言盯着):
/// - 进程 GPU 只报「提交了 x ms/s 的 GPU 命令」,绝不换算成「占 GPU x%」
///   ——各进程 Metal 时间之和不等于系统 GPU 占用率
/// - 磁盘只说「吞吐高」,不说「是卡的原因」——没有延迟/队列深度证据
/// - 看不到的证据(采集器离线)列进 unobserved 明说,绝不因为看不到就说没有
/// - 「没瓶颈」是有内容的结论:给各子系统的余量数字
public struct BottleneckDiagnosis: Sendable, Equatable {
    public enum Kind: String, Sendable {
        /// 各子系统都有余量,系统资源不是卡的原因。
        case noBottleneck
        /// 旗舰组合:GPU 饱和 + 内存换页同时成立(本地跑大模型的典型形状)。
        case gpuSaturatedMemoryThrash
        /// 内存装不下,正在双向换页——全局都会卡,连光标都受影响。
        case memoryThrash
        /// GPU 无余量;拖累的是 GPU 客户(界面合成、渲染、推理)。
        case gpuSaturated
        /// 硬件在热保护性降频,什么都慢。
        case thermalThrottle
        /// CPU 接近满载,调度在排队。
        case cpuSaturated
        /// 一个核被钉死而整机很闲:是那个 App 自己卡,不是资源不够。
        case singleCoreBound
        /// 低电量模式压着性能上限,且确有需求被压着。
        case lowPowerCapped
        /// 磁盘吞吐很高。证据最弱:没有延迟数据,不敢断言因果。
        case diskBusy
        /// 可见证据无异常,但关键证据(GPU/磁盘/温度)本次没看到。
        case insufficientEvidence
    }

    public enum Subsystem: String, Sendable {
        case cpu, gpu, memory, disk, thermal, power
    }

    public struct Finding: Sendable, Equatable {
        public var subsystem: Subsystem
        /// 只用原子 case;组合 case 只存在于总体 kind。
        public var kind: Kind
        public var summary: String
        /// 逐条数字证据,给高手展开看。
        public var evidence: [String]
        /// 责任进程显示名;证据不足不点名。
        public var culpritName: String?
        public var isWarning: Bool

        public init(
            subsystem: Subsystem, kind: Kind, summary: String,
            evidence: [String], culpritName: String? = nil, isWarning: Bool
        ) {
            self.subsystem = subsystem
            self.kind = kind
            self.summary = summary
            self.evidence = evidence
            self.culpritName = culpritName
            self.isWarning = isWarning
        }
    }

    public var kind: Kind
    public var summary: String
    public var detail: String
    public var findings: [Finding]
    /// 本次没看到的证据(显示名)。
    public var unobserved: [String]
    /// 实际取样时长(秒)。
    public var windowSeconds: Double

    /// 警告只留给「硬件在保护自己」和「全局都被拖慢」:
    /// GPU/CPU 被自己选的重活跑满不是故障,是解释(与节流诊断对
    /// 低电量模式「用户主动省电不是警告」同一哲学)。
    public var isWarning: Bool {
        switch kind {
        case .thermalThrottle, .memoryThrash, .gpuSaturatedMemoryThrash: true
        default: false
        }
    }

    // MARK: - 阈值(全部为初值,阶段 3 用 LM Studio 实测校准;出处见各注释)

    /// GPU 饱和:窗口均值 ≥90 且每拍 ≥80。均值防单拍抖动,每拍下限防
    /// 「一拍 100 + 两拍 60」被均值放行。UI 合成的瞬时尖峰不会持续 4–6 秒。
    public static let gpuSaturatedMeanPercent: Double = 90
    public static let gpuSaturatedTickFloorPercent: Double = 80
    /// GPU 点名线:200 ms/s。窗口合成(WindowServer)通常 <100 ms/s,
    /// 200 起步才是计算型提交。
    public static let gpuCulpritNanoseconds: Double = 2e8
    /// 换页 thrash:双向合计 ≥32 MB/s(16KB 页 ×2000 页/秒,肉眼可感的持续倒腾)。
    public static let thrashSwapBytesPerSecond: Double = 32 * 1_048_576
    /// 且换入换出**各自** ≥4 MB/s——双向才是 thrash:一边驱逐一边把刚换走的
    /// 页错页拿回来,说明工作集真装不下;单向大换出只是驱逐,不足以定罪。
    public static let thrashBidirectionalFloor: Double = 4 * 1_048_576
    /// 第二证据链:压缩器双向流量 ≥125 MB/s 且系统压力已到 critical
    /// (关掉了 swap 的机器也能命中)。
    public static let thrashCompressionBytesPerSecond: Double = 125 * 1_048_576
    /// 换页点名线:单进程占物理内存 ≥1/4。换页是全局现象,点名要比 GPU 谨慎。
    public static let memoryCulpritFootprintRatio: Double = 0.25
    /// CPU 饱和:全机制均值 ≥85,调度开始排队。
    public static let cpuSaturatedMeanPercent: Double = 85
    /// CPU 点名线:单进程换算成全机制后 ≥25%。
    public static let cpuCulpritShareOfMachine: Double = 25
    /// 单核钉死:各拍 max(perCore) 的均值 ≥95(不取 100,给 timer 抖动留量)。
    public static let singleCoreBusyPercent: Double = 95
    /// 且总负载 <50——总负载也高时它只是并行重活的一部分,归 cpuSaturated。
    public static let singleCoreTotalCeilingPercent: Double = 50
    /// 单核点名线:进程 raw(单核制)≥90,正是「主线程跑满一个核」的形状。
    public static let singleCoreCulpritRawPercent: Double = 90
    /// 磁盘忙:读写合计均值 ≥400 MB/s。只说明「有重 IO 在跑」,不断言因果。
    public static let diskBusyBytesPerSecond: Double = 400 * 1_048_576
    /// 低电量模式只在「有需求被压着」时才是卡的解释:CPU 或 GPU 均值 ≥60。
    public static let lowPowerDemandPercent: Double = 60
    /// ANE 活跃线:功率 ≥0.5W 且持有者非空,作为 GPU 类 finding 的附加证据。
    public static let aneActiveWatts: Double = 0.5

    public struct Input: Sendable {
        public var window: BottleneckProbeWindow
        public var processes: [BottleneckProcessCandidate]
        public var activeProcessorCount: Int
        public var physicalMemoryBytes: UInt64
        /// 直读 ProcessInfo,不走采集器——采集器掉线时这个证据不能跟着消失。
        public var lowPowerModeEnabled: Bool
        /// nil = 读不到;[] = 确实没人在用。
        public var aneHolderNames: [String]?
        public var anePowerWatts: Double?
        /// 由调用方用窗口均值喂现有 ThrottleDiagnosis 算好传入,判定逻辑不重写。
        public var throttle: ThrottleDiagnosis?

        public init(
            window: BottleneckProbeWindow,
            processes: [BottleneckProcessCandidate] = [],
            activeProcessorCount: Int,
            physicalMemoryBytes: UInt64,
            lowPowerModeEnabled: Bool = false,
            aneHolderNames: [String]? = nil,
            anePowerWatts: Double? = nil,
            throttle: ThrottleDiagnosis? = nil
        ) {
            self.window = window
            self.processes = processes
            self.activeProcessorCount = activeProcessorCount
            self.physicalMemoryBytes = physicalMemoryBytes
            self.lowPowerModeEnabled = lowPowerModeEnabled
            self.aneHolderNames = aneHolderNames
            self.anePowerWatts = anePowerWatts
            self.throttle = throttle
        }
    }

    // MARK: - 判定

    /// 返回 nil 的唯一条件:窗口为空,或所有拍的 CPU 都读不到——
    /// CPU 是唯一无条件可得的信号,连它都没有就什么都别说。
    /// GPU/磁盘/温度缺失不导致 nil,走降级路径(unobserved 明说)。
    public static func diagnose(_ input: Input) -> BottleneckDiagnosis? {
        let ticks = input.window.ticks
        guard !ticks.isEmpty else { return nil }

        // ---- 窗口聚合。信号「被观测到」= ≥2 拍有非 nil 读数(单拍不算数,
        // 防采集器中途上线的一拍数据撑起一个结论)。窗口只有 1 拍时放宽为 1。
        let observedFloor = min(2, ticks.count)

        func series(_ values: [Double?]) -> (mean: Double, peak: Double, min: Double)? {
            let present = values.compactMap { $0 }
            guard present.count >= observedFloor else { return nil }
            return (present.reduce(0, +) / Double(present.count), present.max() ?? 0, present.min() ?? 0)
        }

        let cpu = series(ticks.map(\.cpuUsagePercent))
        guard cpu != nil else { return nil }
        let gpu = series(ticks.map(\.gpuUsagePercent))
        let diskTotal = series(ticks.map { tick -> Double? in
            guard let r = tick.diskReadBytesPerSecond, let w = tick.diskWriteBytesPerSecond else { return nil }
            return r + w
        })
        let swapBi = series(ticks.map { $0.memoryRates.map(\.swapBidirectionalBytesPerSecond) })
        let swapIn = series(ticks.map { $0.memoryRates.map(\.swapinBytesPerSecond) })
        let swapOut = series(ticks.map { $0.memoryRates.map(\.swapoutBytesPerSecond) })
        let compression = series(ticks.map { tick -> Double? in
            guard let r = tick.memoryRates else { return nil }
            return r.compressionBytesPerSecond + r.decompressionBytesPerSecond
        })
        let maxCore = series(ticks.map { $0.perCoreUsage.max() })
        let worstPressure = ticks.map(\.memoryPressure.rawValue).max() ?? 0

        var windowSeconds: Double = Double(ticks.count) * 2
        if let first = ticks.first?.timestamp, let last = ticks.last?.timestamp, last > first {
            windowSeconds = last.timeIntervalSince(first) + 2
        }

        // ---- 未观测清单(采集器离线的诚实声明)。
        // 「关键证据」只算采集器供给的三样(GPU/磁盘/温度):它们看不到时,
        // 「没发现瓶颈」这句话撑不住。每核占用是精修信号,缺席照记但不翻案。
        var criticalUnobserved: [String] = []
        if gpu == nil { criticalUnobserved.append(String(localized: "GPU 占用")) }
        if diskTotal == nil { criticalUnobserved.append(String(localized: "磁盘吞吐")) }
        if series(ticks.map(\.hotspotTemperature)) == nil, input.throttle == nil {
            criticalUnobserved.append(String(localized: "芯片温度"))
        }
        var unobserved = criticalUnobserved
        if maxCore == nil { unobserved.append(String(localized: "每核占用")) }

        let coreCount = max(1, input.activeProcessorCount)
        func machinePercent(_ raw: Double) -> Double {
            // 单核制 → 全机制,与总览「谁在耗电」同一把尺(Pages.swift 同款换算)。
            raw / Double(coreCount)
        }
        func mb(_ bytesPerSecond: Double) -> String {
            String(format: "%.0f", bytesPerSecond / 1_048_576)
        }
        func pct(_ value: Double) -> String {
            String(format: "%.0f", value)
        }

        var findings: [Finding] = []

        // ---- 热降频(现成判定,不重写)。
        if let throttle = input.throttle, throttle.kind == .thermal {
            findings.append(Finding(
                subsystem: .thermal,
                kind: .thermalThrottle,
                summary: String(localized: "正在热降频,整机都会慢"),
                evidence: [throttle.detail],
                isWarning: true
            ))
        }

        // ---- GPU 饱和。
        var gpuFinding: Finding?
        if let gpu, gpu.mean >= gpuSaturatedMeanPercent, gpu.min >= gpuSaturatedTickFloorPercent {
            var evidence = [String(
                format: String(localized: "系统 GPU 占用均值 %@%%(峰值 %@%%)"),
                pct(gpu.mean), pct(gpu.peak)
            )]
            let culprit = input.processes
                .filter { ($0.gpuNanosecondsPerSecond ?? 0) >= gpuCulpritNanoseconds }
                .max { ($0.gpuNanosecondsPerSecond ?? 0) < ($1.gpuNanosecondsPerSecond ?? 0) }
            if let culprit, let ns = culprit.gpuNanosecondsPerSecond {
                // 铁律:只报提交量 ms/s,绝不说「它占 GPU x%」。
                evidence.append(String(
                    format: String(localized: "%@ 提交了 %@ ms/s 的 GPU 命令"),
                    culprit.name, String(format: "%.0f", ns / 1_000_000)
                ))
            }
            if let watts = input.anePowerWatts, watts >= aneActiveWatts,
               let holders = input.aneHolderNames, !holders.isEmpty {
                evidence.append(String(
                    format: String(localized: "神经引擎也在活跃(%@ W),持有会话:%@"),
                    String(format: "%.1f", watts), holders.joined(separator: String(localized: "、"))
                ))
            }
            gpuFinding = Finding(
                subsystem: .gpu,
                kind: .gpuSaturated,
                summary: String(localized: "GPU 已被吃满"),
                evidence: evidence,
                culpritName: culprit?.name,
                isWarning: false
            )
            findings.append(gpuFinding!)
        }

        // ---- 内存 thrash:双向换页,或压缩器高流量 + critical 压力。
        var thrashFinding: Finding?
        let swapHit = {
            guard let swapBi, let swapIn, let swapOut else { return false }
            return swapBi.mean >= thrashSwapBytesPerSecond
                && swapIn.mean >= thrashBidirectionalFloor
                && swapOut.mean >= thrashBidirectionalFloor
        }()
        let compressionHit = {
            guard let compression else { return false }
            return compression.mean >= thrashCompressionBytesPerSecond
                && worstPressure >= MemoryPressureLevel.critical.rawValue
        }()
        if swapHit || compressionHit {
            var evidence: [String] = []
            if swapHit, let swapIn, let swapOut {
                evidence.append(String(
                    format: String(localized: "换出 %@ MB/s、换回 %@ MB/s——双向都在动,说明工作集真的装不下"),
                    mb(swapOut.mean), mb(swapIn.mean)
                ))
            }
            if compressionHit, let compression {
                evidence.append(String(
                    format: String(localized: "内存压缩器流量 %@ MB/s,且系统压力已到紧急档"),
                    mb(compression.mean)
                ))
            }
            let culprit = input.processes
                .filter {
                    guard let footprint = $0.memoryFootprintBytes, input.physicalMemoryBytes > 0 else { return false }
                    return Double(footprint) / Double(input.physicalMemoryBytes) >= memoryCulpritFootprintRatio
                }
                .max { ($0.memoryFootprintBytes ?? 0) < ($1.memoryFootprintBytes ?? 0) }
            if let culprit, let footprint = culprit.memoryFootprintBytes {
                evidence.append(String(
                    format: String(localized: "%@ 占了 %@ GB 内存(物理内存共 %@ GB)"),
                    culprit.name,
                    String(format: "%.1f", Double(footprint) / 1_073_741_824),
                    String(format: "%.0f", Double(input.physicalMemoryBytes) / 1_073_741_824)
                ))
            }
            thrashFinding = Finding(
                subsystem: .memory,
                kind: .memoryThrash,
                summary: String(localized: "内存装不下,正在疯狂换页"),
                evidence: evidence,
                culpritName: culprit?.name,
                isWarning: true
            )
            findings.append(thrashFinding!)
        }

        // ---- CPU 饱和 / 单核钉死(互斥:单核判据要求总负载低)。
        if let cpu = cpu {
            if cpu.mean >= cpuSaturatedMeanPercent {
                var evidence = [String(
                    format: String(localized: "CPU 总负载均值 %@%%(全机=100%% 口径)"),
                    pct(cpu.mean)
                )]
                let culprit = input.processes
                    .filter { machinePercent($0.rawCPUPercent ?? 0) >= cpuCulpritShareOfMachine }
                    .max { ($0.rawCPUPercent ?? 0) < ($1.rawCPUPercent ?? 0) }
                if let culprit, let raw = culprit.rawCPUPercent {
                    evidence.append(String(
                        format: String(localized: "%@ 占整机算力约 %@%%"),
                        culprit.name, pct(machinePercent(raw))
                    ))
                }
                findings.append(Finding(
                    subsystem: .cpu,
                    kind: .cpuSaturated,
                    summary: String(localized: "CPU 已接近满载"),
                    evidence: evidence,
                    culpritName: culprit?.name,
                    isWarning: false
                ))
            } else if let maxCore, maxCore.mean >= singleCoreBusyPercent,
                      cpu.mean < singleCoreTotalCeilingPercent {
                var evidence = [String(
                    format: String(localized: "最忙的一个核平均 %@%%,而整机只有 %@%%"),
                    pct(maxCore.mean), pct(cpu.mean)
                )]
                let culprit = input.processes
                    .filter { ($0.rawCPUPercent ?? 0) >= singleCoreCulpritRawPercent }
                    .max { ($0.rawCPUPercent ?? 0) < ($1.rawCPUPercent ?? 0) }
                if let culprit {
                    evidence.append(String(
                        format: String(localized: "%@ 恰好吃满一个核——典型的主线程跑满形状"),
                        culprit.name
                    ))
                }
                findings.append(Finding(
                    subsystem: .cpu,
                    kind: .singleCoreBound,
                    summary: String(localized: "一个核被跑满,其余大多空闲"),
                    evidence: evidence,
                    culpritName: culprit?.name,
                    isWarning: false
                ))
            }
        }

        // ---- 低电量模式:只在有需求被压着时才是解释。
        let demandPresent = (cpu?.mean ?? 0) >= lowPowerDemandPercent
            || (gpu?.mean ?? 0) >= lowPowerDemandPercent
        if input.lowPowerModeEnabled, demandPresent {
            findings.append(Finding(
                subsystem: .power,
                kind: .lowPowerCapped,
                summary: String(localized: "低电量模式压着性能上限"),
                evidence: [String(localized: "低电量模式开着,系统按设定压低频率上限;关掉它即可恢复满速")],
                isWarning: false
            ))
        }

        // ---- 磁盘忙:证据最弱,永远最后,措辞必须含「不一定」。
        if let diskTotal, diskTotal.mean >= diskBusyBytesPerSecond {
            var evidence = [String(
                format: String(localized: "磁盘读写合计 %@ MB/s(峰值 %@ MB/s)。没有延迟数据,吞吐高不一定就是卡的原因"),
                mb(diskTotal.mean), mb(diskTotal.peak)
            )]
            let culprit = input.processes
                .max {
                    (($0.diskReadBytesPerSecond ?? 0) + ($0.diskWriteBytesPerSecond ?? 0))
                        < (($1.diskReadBytesPerSecond ?? 0) + ($1.diskWriteBytesPerSecond ?? 0))
                }
            if let culprit {
                let total = (culprit.diskReadBytesPerSecond ?? 0) + (culprit.diskWriteBytesPerSecond ?? 0)
                if total >= diskBusyBytesPerSecond / 4 {
                    evidence.append(String(
                        format: String(localized: "%@ 正在读写 %@ MB/s"),
                        culprit.name, mb(total)
                    ))
                }
            }
            findings.append(Finding(
                subsystem: .disk,
                kind: .diskBusy,
                summary: String(localized: "磁盘吞吐很高,但这不一定是卡的原因"),
                evidence: evidence,
                isWarning: false
            ))
        }

        // ---- 头条裁决(优先级见方案;findings 全保留,不吞)。
        let kind = headline(findings: findings, criticalUnobserved: criticalUnobserved)
        let (summary, detail) = compose(
            kind: kind, findings: findings, unobserved: unobserved,
            gpuFinding: gpuFinding, thrashFinding: thrashFinding,
            cpu: cpu, gpu: gpu, swapBi: swapBi, diskTotal: diskTotal,
            hotspot: series(ticks.map(\.hotspotTemperature)),
            maxCorePresent: maxCore != nil,
            singleCoreTriggered: findings.contains { $0.kind == .singleCoreBound }
        )

        return BottleneckDiagnosis(
            kind: kind, summary: summary, detail: detail,
            findings: findings, unobserved: unobserved, windowSeconds: windowSeconds
        )
    }

    private static func headline(findings: [Finding], criticalUnobserved: [String]) -> Kind {
        let kinds = Set(findings.map(\.kind))
        if kinds.contains(.thermalThrottle) { return .thermalThrottle }
        if kinds.contains(.gpuSaturated), kinds.contains(.memoryThrash) { return .gpuSaturatedMemoryThrash }
        if kinds.contains(.memoryThrash) { return .memoryThrash }
        if kinds.contains(.gpuSaturated) { return .gpuSaturated }
        if kinds.contains(.cpuSaturated) { return .cpuSaturated }
        if kinds.contains(.singleCoreBound) { return .singleCoreBound }
        if kinds.contains(.lowPowerCapped) { return .lowPowerCapped }
        if kinds.contains(.diskBusy) { return .diskBusy }
        return criticalUnobserved.isEmpty ? .noBottleneck : .insufficientEvidence
    }

    // 头条与 detail 的排版。组合 case 用专用配对模板一句话讲完因果链。
    private static func compose(
        kind: Kind, findings: [Finding], unobserved: [String],
        gpuFinding: Finding?, thrashFinding: Finding?,
        cpu: (mean: Double, peak: Double, min: Double)?,
        gpu: (mean: Double, peak: Double, min: Double)?,
        swapBi: (mean: Double, peak: Double, min: Double)?,
        diskTotal: (mean: Double, peak: Double, min: Double)?,
        hotspot: (mean: Double, peak: Double, min: Double)?,
        maxCorePresent: Bool,
        singleCoreTriggered: Bool
    ) -> (summary: String, detail: String) {
        func pct(_ value: Double) -> String { String(format: "%.0f", value) }
        func mb(_ value: Double) -> String { String(format: "%.0f", value / 1_048_576) }

        var detailLines: [String] = []

        let summary: String
        switch kind {
        case .gpuSaturatedMemoryThrash:
            if let culprit = gpuFinding?.culpritName {
                summary = String(
                    format: String(localized: "%@ 把 GPU 吃满了,同时内存装不下、正在疯狂换页——这就是卡的原因"),
                    culprit
                )
            } else {
                summary = String(localized: "GPU 被吃满,同时内存在疯狂换页——这就是卡的原因")
            }
        case .noBottleneck:
            summary = String(localized: "没发现系统级瓶颈")
        case .insufficientEvidence:
            summary = String(localized: "可见证据里没发现瓶颈,但关键证据这次没看到")
        default:
            // 单一头条:直接用该 finding 的 summary。
            summary = findings.first { $0.kind == kind }?.summary
                ?? String(localized: "没发现系统级瓶颈")
        }

        switch kind {
        case .noBottleneck, .insufficientEvidence:
            // 「没瓶颈」必须是有内容的结论:给余量数字。
            var margins: [String] = []
            if let cpu { margins.append(String(format: String(localized: "CPU 还有 %@%% 余量"), pct(100 - cpu.mean))) }
            if let gpu { margins.append(String(format: String(localized: "GPU 占 %@%%"), pct(gpu.mean))) }
            if let swapBi { margins.append(String(format: String(localized: "换页 %@ MB/s"), mb(swapBi.mean))) }
            if let diskTotal { margins.append(String(format: String(localized: "磁盘 %@ MB/s"), mb(diskTotal.mean))) }
            if let hotspot { margins.append(String(format: String(localized: "芯片 %@°C"), pct(hotspot.mean))) }
            if !margins.isEmpty {
                detailLines.append(margins.joined(separator: String(localized: "、")) + String(localized: "。"))
            }
            // 只有在每核数据在场且单核判据没触发时,才敢把矛头指向 App 自身。
            if maxCorePresent, !singleCoreTriggered, kind == .noBottleneck {
                detailLines.append(String(localized: "若某个 App 仍然卡,更可能是它自己的主线程卡住了(在等网络、等磁盘或死锁),不是系统资源不够——去「性能 → 进程」页看它。"))
            }
        default:
            // 有头条时,detail 先给次要发现的一句话,再接未观测清单。
            let secondary = findings.filter { $0.kind != kind }
            if kind == .gpuSaturatedMemoryThrash {
                // 组合头条的两个成员不算次要发现。
                let rest = secondary.filter { $0.kind != .gpuSaturated && $0.kind != .memoryThrash }
                if !rest.isEmpty {
                    detailLines.append(String(
                        format: String(localized: "同时注意到:%@。"),
                        rest.map(\.summary).joined(separator: String(localized: "、"))
                    ))
                }
            } else if !secondary.isEmpty {
                detailLines.append(String(
                    format: String(localized: "同时注意到:%@。"),
                    secondary.map(\.summary).joined(separator: String(localized: "、"))
                ))
            }
        }

        if !unobserved.isEmpty {
            detailLines.append(String(
                format: String(localized: "以下证据本次没看到:%@——原因也可能藏在里面。"),
                unobserved.joined(separator: String(localized: "、"))
            ))
        }

        return (summary, detailLines.joined(separator: "\n"))
    }
}
