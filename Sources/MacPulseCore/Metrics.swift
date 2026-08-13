import Foundation

public enum ChargeState: String, Codable, Sendable {
    case charging
    case discharging
    case pluggedDischarging
    case pluggedNotCharging
    case full
    case unknown

    public var title: String {
        switch self {
        case .charging: String(localized: "正在充电")
        case .discharging: String(localized: "正在使用电池")
        case .pluggedDischarging: String(localized: "已接电，电池仍在供电")
        case .pluggedNotCharging: String(localized: "已接入电源")
        case .full: String(localized: "电池已充满")
        case .unknown: String(localized: "状态未知")
        }
    }

    public var symbol: String {
        switch self {
        case .charging: "bolt.fill"
        case .discharging: "arrow.down.right"
        case .pluggedDischarging: "powerplug.fill"
        case .pluggedNotCharging: "powerplug.fill"
        case .full: "checkmark.circle.fill"
        case .unknown: "questionmark.circle"
        }
    }
}

public enum SystemPowerSource: String, Codable, Sendable {
    case battery
    case external
    case ups
    case unknown
}

public enum ThermalLevel: String, Codable, Sendable {
    case nominal
    case fair
    case serious
    case critical
    case unknown

    public var title: String {
        switch self {
        case .nominal: String(localized: "正常")
        case .fair: String(localized: "偏热")
        case .serious: String(localized: "较热")
        case .critical: String(localized: "严重")
        case .unknown: String(localized: "未知")
        }
    }
}

public enum CollectorParentPolicy {
    public static func shouldTerminate(
        configuredParentPID: Int32?,
        signalResult: Int32,
        errorCode: Int32
    ) -> Bool {
        guard let configuredParentPID, configuredParentPID > 1 else { return false }
        return signalResult != 0 && errorCode == ESRCH
    }
}

public struct BatteryMetrics: Codable, Sendable, Equatable {
    public var percentage: Double
    public var state: ChargeState
    public var powerSource: SystemPowerSource
    public var adapterAttached: Bool?
    public var isExternalPowerConnected: Bool
    public var voltageVolts: Double?
    public var currentAmps: Double?
    public var netPowerWatts: Double?
    public var adapterRatedWatts: Double?
    public var adapterWatts: Double?
    public var temperatureCelsius: Double?
    public var healthPercent: Double?
    public var cycleCount: Int?
    public var currentCapacityMAh: Int?
    public var maxCapacityMAh: Int?
    public var designCapacityMAh: Int?
    /// `IOPSGetTimeRemainingEstimate()` 的原始值。
    ///
    /// **只保留用于对照，绝不直接显示。** 实测这台机器上它被 powerd 钉死在
    /// 1200 分（20:00），电量掉了 1% 都不动，而同一时刻计量芯片给的是
    /// 110–176 分。它是上限常数，不是测量值。
    public var timeRemainingMinutes: Int?
    /// 计量芯片自己的放电到空估计（`AvgTimeToEmpty`），已滤掉 65535 哨兵。
    public var gaugeMinutesToEmpty: Int?
    /// 计量芯片的充满估计（`AvgTimeToFull`），已滤掉 65535 哨兵。
    public var gaugeMinutesToFull: Int?
    /// 细分电量 = `AppleRawCurrentCapacity / AppleRawMaxCapacity × 100`。
    ///
    /// 整数 `CurrentCapacity` 把能量量化成约 0.67Wh 一档（7W 下约 6 分钟），
    /// 直接用它会让续航估计出现肉眼可见的台阶跳动。
    public var socFinePercent: Double?

    public init(
        percentage: Double = 0,
        state: ChargeState = .unknown,
        powerSource: SystemPowerSource = .unknown,
        adapterAttached: Bool? = nil,
        isExternalPowerConnected: Bool = false,
        voltageVolts: Double? = nil,
        currentAmps: Double? = nil,
        netPowerWatts: Double? = nil,
        adapterRatedWatts: Double? = nil,
        adapterWatts: Double? = nil,
        temperatureCelsius: Double? = nil,
        healthPercent: Double? = nil,
        cycleCount: Int? = nil,
        currentCapacityMAh: Int? = nil,
        maxCapacityMAh: Int? = nil,
        designCapacityMAh: Int? = nil,
        timeRemainingMinutes: Int? = nil,
        gaugeMinutesToEmpty: Int? = nil,
        gaugeMinutesToFull: Int? = nil,
        socFinePercent: Double? = nil
    ) {
        self.percentage = percentage
        self.state = state
        self.powerSource = powerSource
        self.adapterAttached = adapterAttached
        self.isExternalPowerConnected = isExternalPowerConnected
        self.voltageVolts = voltageVolts
        self.currentAmps = currentAmps
        self.netPowerWatts = netPowerWatts
        self.adapterRatedWatts = adapterRatedWatts ?? adapterWatts
        self.adapterWatts = adapterWatts ?? adapterRatedWatts
        self.temperatureCelsius = temperatureCelsius
        self.healthPercent = healthPercent
        self.cycleCount = cycleCount
        self.currentCapacityMAh = currentCapacityMAh
        self.maxCapacityMAh = maxCapacityMAh
        self.designCapacityMAh = designCapacityMAh
        self.timeRemainingMinutes = timeRemainingMinutes
        self.gaugeMinutesToEmpty = gaugeMinutesToEmpty
        self.gaugeMinutesToFull = gaugeMinutesToFull
        self.socFinePercent = socFinePercent
    }
}

public enum PowerStateResolver {
    public static func resolve(
        isCharging: Bool,
        fullyCharged: Bool,
        powerSource: SystemPowerSource,
        adapterAttached: Bool?,
        netBatteryPowerWatts: Double?,
        powerDeadbandWatts: Double = 0.5
    ) -> ChargeState {
        if isCharging {
            return .charging
        }

        let hasExternalPower = powerSource == .external || powerSource == .ups || adapterAttached == true
        if hasExternalPower {
            if let netBatteryPowerWatts, netBatteryPowerWatts < -powerDeadbandWatts {
                return .pluggedDischarging
            }
            if fullyCharged {
                return .full
            }
            return .pluggedNotCharging
        }

        if powerSource == .battery
            || (netBatteryPowerWatts.map { $0 < -powerDeadbandWatts } ?? false) {
            return .discharging
        }

        return fullyCharged ? .full : .unknown
    }
}

public struct DeepMetrics: Codable, Sendable, Equatable {
    public var cpuUsagePercent: Double?
    public var gpuUsagePercent: Double?
    public var memoryUsedBytes: UInt64?
    public var memoryTotalBytes: UInt64?
    public var swapUsedBytes: UInt64?
    public var cpuTemperature: Double?
    public var gpuTemperature: Double?
    public var hotspotTemperature: Double?
    public var cpuPowerWatts: Double?
    public var gpuPowerWatts: Double?
    public var anePowerWatts: Double?
    public var dramPowerWatts: Double?
    public var systemPowerWatts: Double?
    /// 电源输入功率(SMC PDTR,DC-In)。插电且不充电时约等于整机功耗;
    /// 充电时含充入电池的部分,不能当整机消耗用。
    public var dcInputWatts: Double?
    /// 系统低电量模式开关状态。节流判定要靠它区分「用户主动省电」与「被迫降频」。
    public var lowPowerModeEnabled: Bool?
    public var diskReadBytesPerSecond: Double?
    public var diskWriteBytesPerSecond: Double?
    public var networkInBytesPerSecond: Double?
    public var networkOutBytesPerSecond: Double?
    public var socPower: SoCPowerMetrics?
    public var socCompute: SoCComputeMetrics?
    public var chip: ChipIdentity?
    public var thermalGroups: [ThermalGroup]?
    /// 当前链路的协商信息。零流量读数，不含 SSID/RSSI。
    public var networkLink: NetworkLinkInfo?
    /// 本机型不提供的传感器键。见 `SensorAvailabilityKey`。
    public var unsupported: [String]
    public var thermalLevel: ThermalLevel
    public var collectorAvailable: Bool

    public func isUnsupported(_ key: String) -> Bool {
        unsupported.contains(key)
    }

    public init(
        cpuUsagePercent: Double? = nil,
        gpuUsagePercent: Double? = nil,
        memoryUsedBytes: UInt64? = nil,
        memoryTotalBytes: UInt64? = nil,
        swapUsedBytes: UInt64? = nil,
        cpuTemperature: Double? = nil,
        gpuTemperature: Double? = nil,
        hotspotTemperature: Double? = nil,
        cpuPowerWatts: Double? = nil,
        gpuPowerWatts: Double? = nil,
        anePowerWatts: Double? = nil,
        dramPowerWatts: Double? = nil,
        systemPowerWatts: Double? = nil,
        dcInputWatts: Double? = nil,
        lowPowerModeEnabled: Bool? = nil,
        diskReadBytesPerSecond: Double? = nil,
        diskWriteBytesPerSecond: Double? = nil,
        networkInBytesPerSecond: Double? = nil,
        networkOutBytesPerSecond: Double? = nil,
        socPower: SoCPowerMetrics? = nil,
        socCompute: SoCComputeMetrics? = nil,
        chip: ChipIdentity? = nil,
        thermalGroups: [ThermalGroup]? = nil,
        networkLink: NetworkLinkInfo? = nil,
        unsupported: [String] = [],
        thermalLevel: ThermalLevel = .unknown,
        collectorAvailable: Bool = false
    ) {
        self.cpuUsagePercent = cpuUsagePercent
        self.gpuUsagePercent = gpuUsagePercent
        self.memoryUsedBytes = memoryUsedBytes
        self.memoryTotalBytes = memoryTotalBytes
        self.swapUsedBytes = swapUsedBytes
        self.cpuTemperature = cpuTemperature
        self.gpuTemperature = gpuTemperature
        self.hotspotTemperature = hotspotTemperature
        self.cpuPowerWatts = cpuPowerWatts
        self.gpuPowerWatts = gpuPowerWatts
        self.anePowerWatts = anePowerWatts
        self.dramPowerWatts = dramPowerWatts
        self.systemPowerWatts = systemPowerWatts
        self.dcInputWatts = dcInputWatts
        self.lowPowerModeEnabled = lowPowerModeEnabled
        self.diskReadBytesPerSecond = diskReadBytesPerSecond
        self.diskWriteBytesPerSecond = diskWriteBytesPerSecond
        self.networkInBytesPerSecond = networkInBytesPerSecond
        self.networkOutBytesPerSecond = networkOutBytesPerSecond
        self.socPower = socPower
        self.socCompute = socCompute
        self.chip = chip
        self.thermalGroups = thermalGroups
        self.networkLink = networkLink
        self.unsupported = unsupported
        self.thermalLevel = thermalLevel
        self.collectorAvailable = collectorAvailable
    }

    private enum CodingKeys: String, CodingKey {
        case cpuUsagePercent
        case gpuUsagePercent
        case memoryUsedBytes
        case memoryTotalBytes
        case swapUsedBytes
        case cpuTemperature
        case gpuTemperature
        case hotspotTemperature
        case cpuPowerWatts
        case gpuPowerWatts
        case anePowerWatts
        case dramPowerWatts
        case systemPowerWatts
        case dcInputWatts
        case lowPowerModeEnabled
        case diskReadBytesPerSecond
        case diskWriteBytesPerSecond
        case networkInBytesPerSecond
        case networkOutBytesPerSecond
        case socPower
        case socCompute
        case chip
        case thermalGroups
        case networkLink
        case unsupported
        case thermalLevel
        case collectorAvailable
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        cpuUsagePercent = try values.decodeIfPresent(Double.self, forKey: .cpuUsagePercent)
        gpuUsagePercent = try values.decodeIfPresent(Double.self, forKey: .gpuUsagePercent)
        memoryUsedBytes = try values.decodeIfPresent(UInt64.self, forKey: .memoryUsedBytes)
        memoryTotalBytes = try values.decodeIfPresent(UInt64.self, forKey: .memoryTotalBytes)
        swapUsedBytes = try values.decodeIfPresent(UInt64.self, forKey: .swapUsedBytes)
        cpuTemperature = try values.decodeIfPresent(Double.self, forKey: .cpuTemperature)
        gpuTemperature = try values.decodeIfPresent(Double.self, forKey: .gpuTemperature)
        hotspotTemperature = try values.decodeIfPresent(Double.self, forKey: .hotspotTemperature)
        cpuPowerWatts = try values.decodeIfPresent(Double.self, forKey: .cpuPowerWatts)
        gpuPowerWatts = try values.decodeIfPresent(Double.self, forKey: .gpuPowerWatts)
        anePowerWatts = try values.decodeIfPresent(Double.self, forKey: .anePowerWatts)
        dramPowerWatts = try values.decodeIfPresent(Double.self, forKey: .dramPowerWatts)
        systemPowerWatts = try values.decodeIfPresent(Double.self, forKey: .systemPowerWatts)
        dcInputWatts = try values.decodeIfPresent(Double.self, forKey: .dcInputWatts)
        lowPowerModeEnabled = try values.decodeIfPresent(Bool.self, forKey: .lowPowerModeEnabled)
        diskReadBytesPerSecond = try values.decodeIfPresent(Double.self, forKey: .diskReadBytesPerSecond)
        diskWriteBytesPerSecond = try values.decodeIfPresent(Double.self, forKey: .diskWriteBytesPerSecond)
        networkInBytesPerSecond = try values.decodeIfPresent(Double.self, forKey: .networkInBytesPerSecond)
        networkOutBytesPerSecond = try values.decodeIfPresent(Double.self, forKey: .networkOutBytesPerSecond)
        // 全部 decodeIfPresent：新版 App 读旧版采集器的帧时，这些键不存在即为 nil，
        // 界面显示「不可用」而不是解码失败。schemaVersion 因此不必上调。
        socPower = try values.decodeIfPresent(SoCPowerMetrics.self, forKey: .socPower)
        socCompute = try values.decodeIfPresent(SoCComputeMetrics.self, forKey: .socCompute)
        chip = try values.decodeIfPresent(ChipIdentity.self, forKey: .chip)
        thermalGroups = try values.decodeIfPresent([ThermalGroup].self, forKey: .thermalGroups)
        networkLink = try values.decodeIfPresent(NetworkLinkInfo.self, forKey: .networkLink)
        unsupported = try values.decodeIfPresent([String].self, forKey: .unsupported) ?? []
        thermalLevel = try values.decodeIfPresent(ThermalLevel.self, forKey: .thermalLevel) ?? .unknown
        collectorAvailable = try values.decodeIfPresent(Bool.self, forKey: .collectorAvailable) ?? false
    }
}

public struct MetricSnapshot: Codable, Sendable, Equatable, Identifiable {
    public var id: Date { timestamp }
    public let schemaVersion: Int
    public var timestamp: Date
    public var battery: BatteryMetrics
    public var deep: DeepMetrics

    public init(
        schemaVersion: Int = 1,
        timestamp: Date = .now,
        battery: BatteryMetrics = .init(),
        deep: DeepMetrics = .init()
    ) {
        self.schemaVersion = schemaVersion
        self.timestamp = timestamp
        self.battery = battery
        self.deep = deep
    }
}

public struct CollectorFrameV2: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public var sequence: UInt64
    public var timestamp: Date
    public var metrics: DeepMetrics
    public var warnings: [String]

    public init(
        schemaVersion: Int = 2,
        sequence: UInt64,
        timestamp: Date = .now,
        metrics: DeepMetrics,
        warnings: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.sequence = sequence
        self.timestamp = timestamp
        self.metrics = metrics
        self.warnings = warnings
    }
}

public enum CollectorPhase: String, Codable, Sendable {
    case starting
    case live
    case degraded
    case reconnecting
    case unavailable
    case sleeping
}

public struct CollectorStatus: Codable, Sendable, Equatable {
    public var phase: CollectorPhase
    public var lastSampleAt: Date?
    public var lastErrorCode: String?
    public var warnings: [String]

    public init(
        phase: CollectorPhase = .starting,
        lastSampleAt: Date? = nil,
        lastErrorCode: String? = nil,
        warnings: [String] = []
    ) {
        self.phase = phase
        self.lastSampleAt = lastSampleAt
        self.lastErrorCode = lastErrorCode
        self.warnings = warnings
    }
}

public struct CollectorIntervalChangePlan: Sendable, Equatable {
    public var terminateRunningProcess: Bool
    public var launchImmediately: Bool
    public var retainLastMetrics: Bool

    public init(
        terminateRunningProcess: Bool,
        launchImmediately: Bool,
        retainLastMetrics: Bool
    ) {
        self.terminateRunningProcess = terminateRunningProcess
        self.launchImmediately = launchImmediately
        self.retainLastMetrics = retainLastMetrics
    }
}

public enum CollectorLifecyclePolicy {
    public static func intervalChange(
        processIsRunning: Bool
    ) -> CollectorIntervalChangePlan {
        CollectorIntervalChangePlan(
            terminateRunningProcess: processIsRunning,
            launchImmediately: !processIsRunning,
            retainLastMetrics: true
        )
    }
}

public struct HistoryPoint: Codable, Sendable, Equatable, Identifiable {
    public var id: Date { timestamp }
    public var timestamp: Date
    public var batteryPercent: Double
    public var batteryPowerWatts: Double?
    public var batteryTemperature: Double?
    public var hotspotTemperature: Double?
    public var systemPowerWatts: Double?
    public var cpuUsagePercent: Double?

    public init(snapshot: MetricSnapshot) {
        timestamp = snapshot.timestamp
        batteryPercent = snapshot.battery.percentage
        batteryPowerWatts = snapshot.battery.netPowerWatts
        batteryTemperature = snapshot.battery.temperatureCelsius
        hotspotTemperature = snapshot.deep.hotspotTemperature
        systemPowerWatts = snapshot.deep.systemPowerWatts
        cpuUsagePercent = snapshot.deep.cpuUsagePercent
    }
}
