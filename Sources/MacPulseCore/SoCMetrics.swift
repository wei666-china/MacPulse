import Foundation

/// SoC 各功耗轨。
///
/// 注意 `packageWatts` 与 `residualWatts` 的关系：上游把「各具名轨之和」从封装总功耗里
/// 减掉，剩下的残差放在 `system_power` 字段里。这个残差此前被当成「整机功耗」显示，
/// 实测 23.38W 的封装总功耗下，显示出来的却是 17.58W 的残差。
public struct SoCPowerMetrics: Codable, Sendable, Equatable {
    /// SoC 封装总功耗。等于各具名轨之和加上残差。
    public var packageWatts: Double?
    /// 封装总功耗减去 CPU/GPU/ANE/DRAM/GPU-SRAM 之后剩下的部分。
    ///
    /// 不要给它编一个「屏幕·SSD·外设」之类的名字——它来自 IOReport 能量模型内部，
    /// 无法断言构成。界面上就叫「其他（未细分）」。
    public var residualWatts: Double?
    public var gpuSRAMWatts: Double?

    public init(packageWatts: Double? = nil, residualWatts: Double? = nil, gpuSRAMWatts: Double? = nil) {
        self.packageWatts = packageWatts
        self.residualWatts = residualWatts
        self.gpuSRAMWatts = gpuSRAMWatts
    }

    public var hasAnyValue: Bool {
        packageWatts != nil || residualWatts != nil || gpuSRAMWatts != nil
    }
}

/// CPU 集群、GPU、神经引擎的活跃度与频率。
public struct SoCComputeMetrics: Codable, Sendable, Equatable {
    public var eClusterActivePercent: Double?
    public var eClusterFreqMHz: Int?
    public var pClusterActivePercent: Double?
    public var pClusterFreqMHz: Int?
    public var gpuFreqMHz: Int?
    /// 神经引擎活跃度。**0 表示空闲，是真读数**，不要当成缺失。
    public var aneActivePercent: Double?
    public var dramReadGBs: Double?
    public var dramWriteGBs: Double?
    public var aneReadGBs: Double?
    public var aneWriteGBs: Double?

    public init(
        eClusterActivePercent: Double? = nil,
        eClusterFreqMHz: Int? = nil,
        pClusterActivePercent: Double? = nil,
        pClusterFreqMHz: Int? = nil,
        gpuFreqMHz: Int? = nil,
        aneActivePercent: Double? = nil,
        dramReadGBs: Double? = nil,
        dramWriteGBs: Double? = nil,
        aneReadGBs: Double? = nil,
        aneWriteGBs: Double? = nil
    ) {
        self.eClusterActivePercent = eClusterActivePercent
        self.eClusterFreqMHz = eClusterFreqMHz
        self.pClusterActivePercent = pClusterActivePercent
        self.pClusterFreqMHz = pClusterFreqMHz
        self.gpuFreqMHz = gpuFreqMHz
        self.aneActivePercent = aneActivePercent
        self.dramReadGBs = dramReadGBs
        self.dramWriteGBs = dramWriteGBs
        self.aneReadGBs = aneReadGBs
        self.aneWriteGBs = aneWriteGBs
    }
}

/// 芯片身份与规格。
public struct ChipIdentity: Codable, Sendable, Equatable {
    public var name: String?
    public var coreCount: Int?
    public var eCoreCount: Int?
    public var pCoreCount: Int?
    public var gpuCoreCount: Int?
    /// 理论峰值算力，由核数 × 最高频率推算而来，**不是实测值**。
    /// 界面上必须标注「理论峰值」。
    public var tflopsFP32: Double?
    public var tflopsFP16: Double?

    public init(
        name: String? = nil,
        coreCount: Int? = nil,
        eCoreCount: Int? = nil,
        pCoreCount: Int? = nil,
        gpuCoreCount: Int? = nil,
        tflopsFP32: Double? = nil,
        tflopsFP16: Double? = nil
    ) {
        self.name = name
        self.coreCount = coreCount
        self.eCoreCount = eCoreCount
        self.pCoreCount = pCoreCount
        self.gpuCoreCount = gpuCoreCount
        self.tflopsFP32 = tflopsFP32
        self.tflopsFP16 = tflopsFP16
    }

    /// 「10 核（6 能效 + 4 性能）」。缺项时自动降级，不硬凑。
    public var coreLayoutDescription: String? {
        guard let coreCount else { return nil }
        if let eCoreCount, let pCoreCount, eCoreCount + pCoreCount <= coreCount {
            return "\(coreCount) 核（\(eCoreCount) 能效 + \(pCoreCount) 性能）"
        }
        return "\(coreCount) 核"
    }
}

/// 温度传感器分组。
public struct ThermalGroup: Codable, Sendable, Equatable, Identifiable {
    public var kind: ThermalGroupKind
    /// 上游给出的原始组名。未识别的组会原样显示，不丢弃。
    public var rawName: String
    public var averageCelsius: Double?
    public var minimumCelsius: Double?
    public var maximumCelsius: Double?
    public var sensorCount: Int?

    public var id: String { rawName }

    public init(
        rawName: String,
        averageCelsius: Double? = nil,
        minimumCelsius: Double? = nil,
        maximumCelsius: Double? = nil,
        sensorCount: Int? = nil
    ) {
        self.rawName = rawName
        self.kind = ThermalGroupKind(rawName: rawName)
        self.averageCelsius = averageCelsius
        self.minimumCelsius = minimumCelsius
        self.maximumCelsius = maximumCelsius
        self.sensorCount = sensorCount
    }

    /// 实测出现过 `VRM min 1.0°C` 这种明显失灵的读数。区间条只在最小值可信时才画，
    /// 平均值和最高值照常显示——丢一个坏传感器，不丢整组数据。
    public var trustworthyMinimumCelsius: Double? {
        guard let minimumCelsius, minimumCelsius >= 5 else { return nil }
        return minimumCelsius
    }
}

public enum ThermalGroupKind: String, Codable, Sendable, Equatable, CaseIterable {
    case cpuECore, cpuPCore, cpuDie, gpu, socPackage
    case memory, ssd, nand, nvme
    case ambient, vrm, board, thunderbolt, wireless, display
    case other

    public init(rawName: String) {
        switch rawName {
        case "CPU E-Core": self = .cpuECore
        case "CPU P-Core": self = .cpuPCore
        case "CPU Die": self = .cpuDie
        case "GPU": self = .gpu
        case "SoC Package": self = .socPackage
        case "Memory": self = .memory
        case "SSD": self = .ssd
        case "NAND": self = .nand
        case "NVMe": self = .nvme
        case "Ambient": self = .ambient
        case "VRM": self = .vrm
        case "Board": self = .board
        case "Thunderbolt": self = .thunderbolt
        case "Wireless": self = .wireless
        case "Display": self = .display
        default: self = .other
        }
    }

    public var title: String {
        switch self {
        case .cpuECore: "CPU 能效核"
        case .cpuPCore: "CPU 性能核"
        case .cpuDie: "CPU 裸片"
        case .gpu: "GPU"
        case .socPackage: "SoC 封装"
        case .memory: "内存"
        case .ssd: "固态硬盘"
        case .nand: "闪存颗粒"
        case .nvme: "NVMe 控制器"
        case .ambient: "机内环境"
        case .vrm: "供电模块"
        case .board: "主板"
        case .thunderbolt: "雷雳"
        case .wireless: "无线模块"
        case .display: "屏幕"
        case .other: "其他"
        }
    }

    /// 界面分区。16 组一次铺开会淹没信息，按这三档折叠。
    public enum Section: String, CaseIterable, Sendable {
        case chip = "芯片"
        case storage = "存储与内存"
        case chassis = "机身"
    }

    public var section: Section {
        switch self {
        case .cpuECore, .cpuPCore, .cpuDie, .gpu, .socPackage: .chip
        case .memory, .ssd, .nand, .nvme: .storage
        case .ambient, .vrm, .board, .thunderbolt, .wireless, .display, .other: .chassis
        }
    }
}

/// 「本机型不提供」的标记键。
///
/// 与「读数为 0」严格区分：`ane_power == 0` 是空闲（真读数），而 DRAM 带宽计数器
/// 在一台运行中的机器上永远不可能精确为 0 —— 持续为 0 只能说明这颗芯片没有这个
/// IOReport 通道。前者要显示 0，后者要显示「本机型不提供」。
public enum SensorAvailabilityKey {
    public static let dramBandwidth = "dram_bandwidth"
    public static let aneBandwidth = "ane_bandwidth"
    public static let fans = "fans"

    public static func title(for key: String) -> String {
        switch key {
        case dramBandwidth: "内存带宽"
        case aneBandwidth: "神经引擎带宽"
        case fans: "风扇"
        default: key
        }
    }
}
