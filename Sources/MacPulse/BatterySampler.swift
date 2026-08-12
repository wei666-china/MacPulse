import Foundation
import IOKit
import IOKit.ps
import MacPulseCore

/// 电池采样。把 IORegistry 读取从主线程挪走，并拆成快慢两档。
///
/// 之前的做法是每 2 秒在 MainActor 上跑一次
/// `IORegistryEntryCreateCFProperties(AppleSmartBattery)` —— 那会把**整棵树**
/// 物化出来：`AdapterDetails`、`BatteryData`、`CellVoltage`、`TemperatureSamples`、
/// `LifetimeData`，几百个键带嵌套数组，全部桥接成 `[String: Any]`，
/// 再加上 `IOPSCopyPowerSourcesInfo` 的第二份完整拷贝。
///
/// 现在：
/// - 快档按键单独读（`IORegistryEntryCreateCFProperty` 单数版），**永不物化嵌套子树**
/// - 慢档 60 秒一次，设计容量、循环次数、适配器详情这些几天都不变的值缓存起来
/// - 全程在 actor 上，主线程不再被 IOKit 阻塞
actor BatterySampler {
    /// 每次采样都要读的键。只有这 11 个。
    private static let fastKeys = [
        "CurrentCapacity",
        "AppleRawCurrentCapacity",
        "Voltage",
        "InstantAmperage",
        "Amperage",
        "IsCharging",
        "ExternalConnected",
        "FullyCharged",
        "Temperature",
        "AvgTimeToEmpty",
        "AvgTimeToFull"
    ]

    /// 几天都不变的值。实测 CycleCount 隔了好几天两次读都是 15。
    private struct SlowValues: Sendable {
        var rawMaxCapacity: Int?
        /// 苹果算「最大容量」用的标称值。健康度必须用它,
        /// 用 AppleRawMaxCapacity 会比系统设置低一两个点(见 BatteryReader 注释)。
        var nominalMaxCapacity: Int?
        var designCapacity: Int?
        var cycleCount: Int?
        var adapterRatedWatts: Double?
        var readAt: Date
    }

    private var service: io_service_t = IO_OBJECT_NULL
    private var slowValues: SlowValues?
    private var lastExternalConnected: Bool?

    private static let slowRefreshInterval: TimeInterval = 60

    deinit {
        if service != IO_OBJECT_NULL {
            IOObjectRelease(service)
        }
    }

    func sample() -> BatteryMetrics? {
        guard let service = resolveService() else { return nil }

        var fast: [String: Any] = [:]
        for key in Self.fastKeys {
            guard let value = IORegistryEntryCreateCFProperty(
                service,
                key as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() else { continue }
            fast[key] = value
        }
        guard !fast.isEmpty else { return nil }

        let external = boolValue(fast["ExternalConnected"])
        // 插拔适配器时立刻刷新慢档：额定功率会跟着变。
        let adapterChanged = external != lastExternalConnected
        lastExternalConnected = external

        let slow = refreshSlowValuesIfNeeded(service: service, force: adapterChanged)

        let voltageMV = numberValue(fast["Voltage"])
        let currentMA = numberValue(fast["InstantAmperage"]) ?? numberValue(fast["Amperage"])
        let charging = boolValue(fast["IsCharging"])
        let full = boolValue(fast["FullyCharged"])

        let netPowerWatts = MetricMath.batteryPowerWatts(
            voltageMillivolts: voltageMV,
            currentMilliamps: currentMA
        )
        let percentage = numberValue(fast["CurrentCapacity"])?.doubleValue ?? 0
        let rawCurrent = numberValue(fast["AppleRawCurrentCapacity"])

        let state = PowerStateResolver.resolve(
            isCharging: charging,
            fullyCharged: full,
            powerSource: external ? .external : .battery,
            adapterAttached: external,
            netBatteryPowerWatts: netPowerWatts
        )

        return BatteryMetrics(
            percentage: min(100, max(0, percentage)),
            state: state,
            powerSource: external ? .external : .battery,
            adapterAttached: external,
            isExternalPowerConnected: external,
            voltageVolts: voltageMV.map { $0.doubleValue / 1_000 },
            currentAmps: currentMA.map { Double($0.int64Value) / 1_000 },
            netPowerWatts: netPowerWatts,
            adapterRatedWatts: slow?.adapterRatedWatts,
            temperatureCelsius: MetricMath.validTemperature(
                numberValue(fast["Temperature"]).map { $0.doubleValue / 100 }
            ),
            healthPercent: MetricMath.healthPercent(
                maxCapacity: (slow?.nominalMaxCapacity ?? slow?.rawMaxCapacity).map(NSNumber.init(value:)),
                designCapacity: slow?.designCapacity.map(NSNumber.init(value:))
            ),
            cycleCount: slow?.cycleCount,
            currentCapacityMAh: rawCurrent?.intValue,
            maxCapacityMAh: slow?.nominalMaxCapacity ?? slow?.rawMaxCapacity,
            designCapacityMAh: slow?.designCapacity,
            // 只作对照，绝不直接显示。`IOPSGetTimeRemainingEstimate` 本身是单次
            // 调用，不像 `IOPSCopyPowerSourcesInfo` 那样拷贝整份字典，放在快档
            // 不构成负担。
            timeRemainingMinutes: systemEstimateMinutes(),
            gaugeMinutesToEmpty: gaugeMinutes(fast["AvgTimeToEmpty"]),
            gaugeMinutesToFull: gaugeMinutes(fast["AvgTimeToFull"]),
            socFinePercent: socFine(current: rawCurrent, max: slow?.rawMaxCapacity)
        )
    }

    // MARK: - 慢档

    private func refreshSlowValuesIfNeeded(service: io_service_t, force: Bool) -> SlowValues? {
        if !force,
           let slowValues,
           Date().timeIntervalSince(slowValues.readAt) < Self.slowRefreshInterval {
            return slowValues
        }

        let rawMax = property(service, "AppleRawMaxCapacity") ?? property(service, "MaxCapacity")
        let nominalMax = property(service, "NominalChargeCapacity")
        let design = property(service, "DesignCapacity")
        let cycles = property(service, "CycleCount")

        // AdapterDetails 是嵌套字典，只在慢档读。
        var adapterWatts: Double?
        if let details = IORegistryEntryCreateCFProperty(
            service,
            "AdapterDetails" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? [String: Any] {
            let watts = (details["Watts"] as? NSNumber) ?? (details["AdapterWattage"] as? NSNumber)
            // 0 不是「0 瓦适配器」，是「没读到」。
            if let value = watts?.doubleValue, value > 0 {
                adapterWatts = value
            }
        }

        let values = SlowValues(
            // Apple Silicon 上 MaxCapacity 是常数 100（百分比），拿它当 mAh
            // 会把健康度算成 1.7%。只接受看起来像 mAh 的值。
            rawMaxCapacity: rawMax.flatMap { $0.intValue > 200 ? $0.intValue : nil },
            nominalMaxCapacity: nominalMax.flatMap { $0.intValue > 200 ? $0.intValue : nil },
            designCapacity: design?.intValue,
            cycleCount: cycles?.intValue,
            adapterRatedWatts: adapterWatts,
            readAt: Date()
        )
        slowValues = values
        return values
    }

    // MARK: - 工具

    private func resolveService() -> io_service_t? {
        if service != IO_OBJECT_NULL { return service }
        let matched = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard matched != IO_OBJECT_NULL else { return nil }
        service = matched
        return matched
    }

    private func property(_ service: io_service_t, _ key: String) -> NSNumber? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber
    }

    /// 文档里 abstract 写的是「分钟」，但讨论段与 `@result` 写的是**秒**，
    /// 后者才是对的。这是 Apple 文档里一个长期存在的笔误。
    private func systemEstimateMinutes() -> Int? {
        let seconds = IOPSGetTimeRemainingEstimate()
        guard seconds.isFinite, seconds > 0 else { return nil }
        return Int(seconds / 60)
    }

    private func numberValue(_ value: Any?) -> NSNumber? { value as? NSNumber }

    private func boolValue(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        return false
    }

    /// 65535 是「未知」哨兵，不是 45 天。
    private func gaugeMinutes(_ value: Any?) -> Int? {
        guard let minutes = numberValue(value)?.intValue, minutes > 0, minutes != 65_535 else { return nil }
        return minutes
    }

    private func socFine(current: NSNumber?, max: Int?) -> Double? {
        guard let current = current?.doubleValue, let max, max > 200 else { return nil }
        return min(100, Swift.max(0, current / Double(max) * 100))
    }
}
