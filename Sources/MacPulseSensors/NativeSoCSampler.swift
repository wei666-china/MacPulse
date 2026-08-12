import Foundation

// SoC 指标的原生采样指挥:IOReport(能耗/频率/占用)+ SMC(温度/整机功率)。
// 通道匹配规则、优先级与换算公式改编自 mactop(MIT)的 ioreport.m,
// 温度键位分组表同源;详见 THIRD_PARTY_NOTICES.md。

/// 一次采样窗口得到的全部 SoC 指标。字段语义与旧 mactop JSON 对齐
/// (totalPower = 封装总功耗,residual = 总减去具名轨的残差)。
public struct NativeSoCSample: Sendable {
    public var cpuPowerWatts: Double?
    public var gpuPowerWatts: Double?
    public var anePowerWatts: Double?
    public var dramPowerWatts: Double?
    public var gpuSRAMPowerWatts: Double?
    /// 封装总功耗 = max(SMC PSTR, 具名轨之和)。
    public var totalPowerWatts: Double?
    /// 电源输入功率(SMC PDTR,DC-In)。没插电或键不存在为 nil。
    public var dcInputPowerWatts: Double?
    /// 总功耗减去具名轨后的残差。语义陷阱继承自上游,别当整机功耗用。
    public var residualPowerWatts: Double?

    public var eClusterActivePercent: Double?
    public var eClusterFreqMHz: Double?
    public var pClusterActivePercent: Double?
    public var pClusterFreqMHz: Double?
    public var gpuActivePercent: Double?
    public var gpuFreqMHz: Double?

    public var cpuTemperature: Double?
    public var gpuTemperature: Double?
    public var temperatureGroups: [TemperatureGroup] = []

    /// DRAM 带宽(GB/s)。通道在本机不存在时为 nil,由上游判「本机型不提供」。
    public var dramReadGBs: Double?
    public var dramWriteGBs: Double?

    public init() {}
}

public struct TemperatureGroup: Sendable {
    public let name: String
    public let average: Double
    public let minimum: Double
    public let maximum: Double
    public let sensorCount: Int
}

public final class NativeSoCSampler: @unchecked Sendable {
    private let ioReport: IOReportSession?
    private let smc: SMCClient?
    private let tables: ClusterFrequencyTables
    /// SMC 温度键清单,启动时枚举一次(键集是机器常量)。
    private let temperatureKeys: [String]

    public init() {
        // Energy Model 必需;其余组缺了就少一类数据,不拦启动。
        // "Energy Counters" 是 macOS 27 起对 Energy Model 的接棒者,提前带上。
        // AMC Stats 里有部分机型的 DRAM 带宽字节计数,没有就没有。
        ioReport = IOReportSession(groups: [
            "Energy Model", "Energy Counters", "CPU Stats", "GPU Stats", "AMC Stats"
        ])
        smc = SMCClient()
        tables = ClusterFrequencyTables.load()
        temperatureKeys = smc?.allKeys().filter { $0.hasPrefix("T") } ?? []
    }

    /// 风扇个数(SMC FNum)。无风扇机型(MacBook Air)读 0 或读不到。
    public var fanCount: Int? {
        smc?.readDouble("FNum").map(Int.init)
    }

    /// GPU 频率表最高档,供理论算力推算。
    public var gpuMaxFrequencyMHz: Double? {
        tables.gpu.max()
    }

    /// 各集群频率表最高档。节流判定要拿它当分母。
    /// 三集群机型上 P 行显示的是中核(与采样端映射一致),表也跟着取 sCluster。
    public var eClusterMaxFrequencyMHz: Double? { tables.eCluster.max() }
    public var pClusterMaxFrequencyMHz: Double? {
        tables.sCluster.isEmpty ? tables.pCluster.max() : tables.sCluster.max()
    }

    /// 阻塞采样一个窗口。IOReport 都拿不到时返回 nil(上游会走 degraded)。
    public func sample(windowSeconds: Double) -> NativeSoCSample? {
        guard let window = ioReport?.sample(windowSeconds: windowSeconds) else { return nil }
        var result = NativeSoCSample()

        let elapsedSeconds = Double(window.elapsedNanoseconds) / 1e9
        guard elapsedSeconds > 0 else { return nil }

        // —— 能耗轨 ——
        let rails = Self.resolveEnergyRails(readings: window.readings, elapsedSeconds: elapsedSeconds)
        result.cpuPowerWatts = rails.cpu
        result.gpuPowerWatts = rails.gpu
        result.anePowerWatts = rails.ane
        result.dramPowerWatts = rails.dram
        result.gpuSRAMPowerWatts = rails.gpuSRAM

        // —— 集群频率/活跃度 ——
        let clusters = Self.summarizeCPUClusters(readings: window.readings, tables: tables)
        result.eClusterActivePercent = clusters.e?.activePercent
        result.eClusterFreqMHz = clusters.e?.frequencyMHz
        result.pClusterActivePercent = clusters.p?.activePercent
        result.pClusterFreqMHz = clusters.p?.frequencyMHz

        let gpu = Self.summarizeGPU(readings: window.readings, table: tables.gpu)
        result.gpuActivePercent = gpu?.activePercent
        result.gpuFreqMHz = gpu?.frequencyMHz

        let dram = Self.resolveDRAMBandwidth(readings: window.readings, elapsedSeconds: elapsedSeconds)
        result.dramReadGBs = dram.readGBs
        result.dramWriteGBs = dram.writeGBs

        // —— SMC:整机功率归一化 + 温度 ——
        let componentSum = [rails.cpu, rails.gpu, rails.ane, rails.dram, rails.gpuSRAM]
            .compactMap { $0 }.reduce(0, +)
        let systemTotal = smc?.readDouble("PSTR")
        let normalized = Self.normalizePower(systemTotal: systemTotal, componentSum: componentSum)
        result.totalPowerWatts = normalized.total
        result.residualPowerWatts = normalized.residual
        // DC-In:插电时的电源输入功率;拔电时该键读 0 或消失,按 nil 处理。
        if let dcIn = smc?.readDouble("PDTR"), dcIn > 0.1 {
            result.dcInputPowerWatts = dcIn
        }

        if let smc {
            let temps = Self.readTemperatures(client: smc, keys: temperatureKeys)
            result.temperatureGroups = temps.groups
            result.cpuTemperature = temps.cpuAverage
            result.gpuTemperature = temps.gpuAverage
        }
        return result
    }

    // MARK: - 能耗轨归类(纯函数)

    struct EnergyRails {
        var cpu: Double?
        var gpu: Double?
        var ane: Double?
        var dram: Double?
        var gpuSRAM: Double?
    }

    /// 能量增量 → 瓦。单位标签缺失按 µJ(上游同一约定)。
    static func watts(delta: Int64, unit: String?, elapsedSeconds: Double) -> Double {
        let rate = Double(delta) / elapsedSeconds
        switch unit {
        case "mJ": return rate / 1e3
        case "nJ": return rate / 1e9
        default: return rate / 1e6
        }
    }

    /// 通道名 → 轨,规则改编自 mactop(逐代通道命名都踩过):
    /// 同一轨在不同代际有「总量通道」与「分核通道」两套,**取其一,绝不相加**,
    /// 否则新代际上会双倍计数。
    static func resolveEnergyRails(readings: [IOReportReading], elapsedSeconds: Double) -> EnergyRails {
        var cpuTotal = 0.0, cpuTyped = 0.0
        var gpuNamed = 0.0, gpuAlias = 0.0, gpuSRAM = 0.0
        var aneNamed = 0.0, aneBlock = 0.0
        var dramNamed = 0.0, dramBlock = 0.0
        var sawEnergyChannel = false

        for reading in readings where reading.group == "Energy Model" || reading.group == "Energy Counters" {
            guard let delta = reading.simpleValue else { continue }
            let name = reading.channel
            let w = watts(delta: delta, unit: reading.unit, elapsedSeconds: elapsedSeconds)
            guard w >= 0 else { continue }
            sawEnergyChannel = true

            if name.contains("ECPU Energy") || name.contains("PCPU Energy") || name.contains("MCPU Energy")
                || name.contains("eCPUs Energy") || name.contains("pCPUs Energy") || name.contains("mCPUs Energy") {
                cpuTyped += w
            } else if name.contains("CPU Energy") {
                cpuTotal += w
            } else if name == "GPU Energy" {
                gpuNamed += w
            } else if name == "GPU" {
                gpuAlias += w
            } else if name.hasPrefix("GPU SRAM") {
                gpuSRAM += w
            } else if name.contains("ANE") || name.contains("NPU") || name.contains("Neural") || name.contains("ane") {
                if name.contains("Energy") { aneNamed += w } else { aneBlock += w }
            } else if name.hasPrefix("DRAM") {
                dramNamed += w
            }
            // DRAM 分块通道(DRAM0_0 等)带 DRAM 前缀,已被上一分支收进 named;
            // mactop 的 block/named 区分在 M 系至今等价,保留 named 单桶即可。
            _ = dramBlock
        }
        guard sawEnergyChannel else { return EnergyRails() }

        var rails = EnergyRails()
        rails.cpu = cpuTotal > 0 ? cpuTotal : (cpuTyped > 0 ? cpuTyped : nil)
        rails.gpu = gpuNamed > 0 ? gpuNamed : (gpuAlias > 0 ? gpuAlias : nil)
        rails.ane = aneBlock > 0 ? aneBlock : (aneNamed >= 0 ? aneNamed : nil)
        rails.dram = dramNamed > 0 ? dramNamed : nil
        rails.gpuSRAM = gpuSRAM > 0 ? gpuSRAM : nil
        // ANE 空闲时能量增量就是 0,0 是真读数(空闲),不折叠成 nil。
        if rails.ane == nil { rails.ane = 0 }
        return rails
    }

    // MARK: - 集群驻留(纯函数)

    public struct ClusterSummary: Sendable {
        public let activePercent: Double
        public let frequencyMHz: Double?
    }

    /// 驻留 → 活跃度与加权频率。OFF/IDLE 计入总时长但不计活跃;
    /// 平均频率只在活跃时间上加权,否则深度空闲的机器会显示一个没意义的超低频。
    ///
    /// 频率表对位分两级:CPU 状态名自带档位序号(M5 实测 "V0P7"…"V18P0"),
    /// 有 V 序号就按序号对表——状态稀疏或乱序也不会错位;没有(GPU 的
    /// "P1"…"P15")退回活跃状态计数器,与上游一致。
    static func summarizeResidency(
        states: [(name: String, residency: Int64)],
        table: [Double],
        idleNames: Set<String>
    ) -> ClusterSummary? {
        var total = 0.0
        var active = 0.0
        var weighted = 0.0
        var activeStateIndex = 0
        for (name, residency) in states {
            let time = Double(residency)
            guard time >= 0 else { continue }
            total += time
            if idleNames.contains(name.uppercased()) { continue }
            let tableIndex = Self.stateIndex(from: name) ?? activeStateIndex
            if tableIndex < table.count {
                weighted += table[tableIndex] * time
            }
            active += time
            activeStateIndex += 1
        }
        guard total > 0 else { return nil }
        let percent = active / total * 100
        let freq = active > 0 && weighted > 0 ? weighted / active : nil
        return ClusterSummary(activePercent: percent, frequencyMHz: freq)
    }

    /// "V12P6" → 12;"V3" → 3;无 V 前缀返回 nil。
    static func stateIndex(from name: String) -> Int? {
        guard name.hasPrefix("V") else { return nil }
        let digits = name.dropFirst().prefix(while: \.isNumber)
        guard !digits.isEmpty else { return nil }
        return Int(digits)
    }

    struct CPUClusters {
        var e: ClusterSummary?
        var p: ClusterSummary?
    }

    /// CPU 集群汇总。M5 起的三集群芯片上,MCPU(中核)对外映射为 P 集群、
    /// PCPU(超大核)映射为 S 集群——本期界面只有 E/P 两行,基础款 M5
    /// 没有 MCPU,直接 ECPU→E、PCPU→P;带 MCPU 的机型按上游规则取 MCPU 当 P。
    static func summarizeCPUClusters(
        readings: [IOReportReading],
        tables: ClusterFrequencyTables
    ) -> CPUClusters {
        let idle: Set<String> = ["OFF", "IDLE"]
        var eSummaries: [ClusterSummary] = []
        var pSummaries: [ClusterSummary] = []
        var mSummaries: [ClusterSummary] = []

        for reading in readings
        where reading.group == "CPU Stats" && reading.subgroup == "CPU Complex Performance States" {
            guard let states = reading.states else { continue }
            let name = reading.channel
            if name.hasPrefix("ECPU") {
                if let s = summarizeResidency(states: states, table: tables.eCluster, idleNames: idle) {
                    eSummaries.append(s)
                }
            } else if name.hasPrefix("PCPU") {
                if let s = summarizeResidency(states: states, table: tables.pCluster, idleNames: idle) {
                    pSummaries.append(s)
                }
            } else if name.hasPrefix("MCPU") {
                if let s = summarizeResidency(states: states, table: tables.sCluster, idleNames: idle) {
                    mSummaries.append(s)
                }
            }
        }

        func best(_ list: [ClusterSummary]) -> ClusterSummary? {
            // 多 die(Ultra)取最忙的一个,与上游一致。
            list.max { $0.activePercent < $1.activePercent }
        }

        var result = CPUClusters()
        result.e = best(eSummaries)
        if !mSummaries.isEmpty {
            result.p = best(mSummaries)
        } else {
            result.p = best(pSummaries)
        }
        return result
    }

    static func summarizeGPU(readings: [IOReportReading], table: [Double]) -> ClusterSummary? {
        let idle: Set<String> = ["OFF", "IDLE", "DOWN"]
        for reading in readings
        where reading.group == "GPU Stats"
            && reading.subgroup == "GPU Performance States"
            && reading.channel == "GPUPH" {
            guard let states = reading.states else { continue }
            return summarizeResidency(states: states, table: table, idleNames: idle)
        }
        return nil
    }

    // MARK: - DRAM 带宽(纯函数)

    struct DRAMBandwidth {
        var readGBs: Double?
        var writeGBs: Double?
    }

    /// AMC Stats 的 DCS 字节计数 → GB/s(十进制 GB)。通道命名分三档,
    /// 只取最准的一档,优先级与上游一致:
    /// 精确聚合("DCS"/"DCS RD"/"DCS WR")> 分区("DCS_x"/"DCS0…")> 挂名(" DCS ")。
    /// 方向后缀:RD 读、WR 写、RD+WR/RW 合计(五五开拆)。全都没有 → nil。
    static func resolveDRAMBandwidth(readings: [IOReportReading], elapsedSeconds: Double) -> DRAMBandwidth {
        var exactRead = 0.0, exactWrite = 0.0, exactCombined = 0.0
        var partRead = 0.0, partWrite = 0.0, partCombined = 0.0
        var sawAny = false

        for reading in readings where reading.group == "AMC Stats" {
            guard let delta = reading.simpleValue, delta >= 0 else { continue }
            let name = reading.channel
            guard name.contains("DCS") else { continue }

            enum Direction { case read, write, combined }
            let direction: Direction
            if name.contains("RD+WR") || name.hasSuffix("RW") {
                direction = .combined
            } else if name.contains("RD") {
                direction = .read
            } else if name.contains("WR") {
                direction = .write
            } else if name == "DCS" {
                direction = .combined
            } else {
                continue
            }

            let isExact = name == "DCS" || name == "DCS RD" || name == "DCS WR" || name == "DCS RD+WR"
            let isPartition = !isExact
                && (name.hasPrefix("DCS_") || (name.hasPrefix("DCS") && name.dropFirst(3).first?.isNumber == true))
            guard isExact || isPartition else { continue }
            sawAny = true

            let bytes = Double(delta)
            switch (isExact, direction) {
            case (true, .read): exactRead += bytes
            case (true, .write): exactWrite += bytes
            case (true, .combined): exactCombined += bytes
            case (false, .read): partRead += bytes
            case (false, .write): partWrite += bytes
            case (false, .combined): partCombined += bytes
            }
        }
        guard sawAny, elapsedSeconds > 0 else { return DRAMBandwidth() }

        func gbs(_ bytes: Double) -> Double { bytes / elapsedSeconds / 1e9 }
        if exactRead > 0 || exactWrite > 0 {
            return DRAMBandwidth(readGBs: gbs(exactRead), writeGBs: gbs(exactWrite))
        }
        if exactCombined > 0 {
            return DRAMBandwidth(readGBs: gbs(exactCombined / 2), writeGBs: gbs(exactCombined / 2))
        }
        if partRead > 0 || partWrite > 0 {
            return DRAMBandwidth(readGBs: gbs(partRead), writeGBs: gbs(partWrite))
        }
        if partCombined > 0 {
            return DRAMBandwidth(readGBs: gbs(partCombined / 2), writeGBs: gbs(partCombined / 2))
        }
        // 有 DCS 通道但这窗口全为零:零是真读数(内存没流量不至于,但语义上如实报 0)。
        return DRAMBandwidth(readGBs: 0, writeGBs: 0)
    }

    // MARK: - 功率归一化(纯函数)

    /// totalPower/residual 语义与上游一致:总功耗至少是具名轨之和;
    /// PSTR 读不到时 residual 为 nil(没有依据凭空造一个「其他」)。
    static func normalizePower(systemTotal: Double?, componentSum: Double)
        -> (total: Double?, residual: Double?) {
        guard let systemTotal, systemTotal > 0 else {
            return (componentSum > 0 ? componentSum : nil, nil)
        }
        let total = max(systemTotal, componentSum)
        return (total, max(0, total - componentSum))
    }

    // MARK: - 温度分组

    /// SMC 键前缀 → 分组名。表改编自 mactop,分组名必须与 App 侧
    /// ThermalGroupKind(rawName:) 的 16 个规范英文名严格一致,变一个字母
    /// 界面就归不进组。
    static func classifyTemperatureKey(_ key: String, hasSCores: Bool = false) -> String? {
        guard key.hasPrefix("T"), key.count == 4 else { return nil }
        // 三字符前缀优先(更具体)。
        let p3 = String(key.prefix(3))
        switch p3 {
        case "TPD", "TPM", "TPS": return "SoC Package"
        case "TRD": return "GPU"
        case "TCM", "TCD": return "CPU Die"
        default: break
        }
        let p2 = String(key.prefix(2))
        switch p2 {
        case "Tp", "Tf": return "CPU P-Core"
        case "Te": return "CPU E-Core"
        case "Tg": return "GPU"
        case "Tm", "TM": return "Memory"
        case "Ts": return hasSCores ? "CPU S-Core" : "SSD"
        case "TS": return "SSD"
        case "TH", "TN": return "NAND"
        case "Ta", "TA", "TF": return "Ambient"
        case "TB", "Tb": return "Board"
        case "TV": return "VRM"
        case "TT", "TI": return "Thunderbolt"
        case "Tw", "TW": return "Wireless"
        case "TD", "Td", "TL": return "Display"
        default: return nil
        }
    }

    struct TemperatureSummary {
        var groups: [TemperatureGroup]
        var cpuAverage: Double?
        var gpuAverage: Double?
    }

    static func readTemperatures(client: SMCClient, keys: [String]) -> TemperatureSummary {
        var buckets: [String: [Double]] = [:]
        for key in keys {
            guard let group = classifyTemperatureKey(key) else { continue }
            guard let value = client.readDouble(key), value > 1, value < 120 else { continue }
            buckets[group, default: []].append(value)
        }

        // 组顺序沿用上游的展示优先级,App 侧按 kind 再归三大区。
        let order = ["CPU E-Core", "CPU P-Core", "CPU S-Core", "CPU Die", "GPU", "SoC Package",
                     "Memory", "SSD", "NAND", "Ambient", "VRM", "Board",
                     "Thunderbolt", "Wireless", "Display"]
        var groups: [TemperatureGroup] = []
        for name in order {
            guard let values = buckets[name], !values.isEmpty else { continue }
            groups.append(TemperatureGroup(
                name: name,
                average: (values.reduce(0, +) / Double(values.count) * 10).rounded() / 10,
                minimum: values.min() ?? 0,
                maximum: values.max() ?? 0,
                sensorCount: values.count
            ))
        }

        func average(of names: [String]) -> Double? {
            let all = names.flatMap { buckets[$0] ?? [] }
            guard !all.isEmpty else { return nil }
            return all.reduce(0, +) / Double(all.count)
        }
        return TemperatureSummary(
            groups: groups,
            cpuAverage: average(of: ["CPU P-Core", "CPU E-Core", "CPU S-Core"]),
            gpuAverage: average(of: ["GPU"])
        )
    }
}
