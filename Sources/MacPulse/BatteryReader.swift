import Foundation
import IOKit
import IOKit.ps
import MacPulseCore

enum BatteryReader {
    static func read() -> BatteryMetrics {
        let powerSources = readPowerSources()
        guard let matching = IOServiceMatching("AppleSmartBattery") else {
            return fallbackFromPowerSources(powerSources)
        }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else {
            return fallbackFromPowerSources(powerSources)
        }
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = properties?.takeRetainedValue() as? [String: Any] else {
            return fallbackFromPowerSources(powerSources)
        }

        let registryExternal = bool(dictionary["ExternalConnected"])
        let charging = bool(dictionary["IsCharging"])
        let full = bool(dictionary["FullyCharged"])
        let percentage = number(dictionary["CurrentCapacity"])?.doubleValue
            ?? powerSources.percentage
            ?? 0

        // 电压 0/负值是坏读数:净功率算法有 >0 防护,显示行也得有,
        // 否则「实时电压 0.00 V」旁边挂着非零电流,三行自相矛盾。
        let voltageMV = number(dictionary["Voltage"]).flatMap { $0.doubleValue > 0 ? $0 : nil }
        let currentMA = number(dictionary["InstantAmperage"]) ?? number(dictionary["Amperage"])
        let netPowerWatts = MetricMath.batteryPowerWatts(
            voltageMillivolts: voltageMV,
            currentMilliamps: currentMA
        )
        // Apple Silicon 上 MaxCapacity 是常数 100(百分比)。这个哨兵在
        // 本文件下方和模型层都防了,唯独用户直接看的这条路没防——
        // 会渲染出「健康度 1%、最大容量 100 mAh」。≤200 一律不当 mAh 用。
        let rawMax = (number(dictionary["AppleRawMaxCapacity"]) ?? number(dictionary["MaxCapacity"]))
            .flatMap { $0.doubleValue > 200 ? $0 : nil }
        // 健康度的分子必须用 NominalChargeCapacity,不能用 AppleRawMaxCapacity。
        // 后者是电量计的**瞬时原始估计**,随温度与最近充放电波动;前者是苹果
        // 自己算「最大容量」用的标称值。实测本机(20 次循环、几乎全新):
        // raw 5711/5760 = 99% ,而系统设置里明明写着 100% ——
        // 我们的数字和用户能自查的权威来源打架,这种账必须对上。
        let nominalMax = number(dictionary["NominalChargeCapacity"])
            .flatMap { $0.doubleValue > 200 ? $0 : nil } ?? rawMax
        let rawCurrent = number(dictionary["AppleRawCurrentCapacity"])
        let design = number(dictionary["DesignCapacity"])
        let temperatureRaw = number(dictionary["Temperature"])?.doubleValue
        let adapterDetails = readAdapterDetails()
        let adapterRatedWatts = adapterDetails.watts ?? readAdapterWatts(dictionary)
        let adapterAttached: Bool? = {
            if adapterDetails.attached { return true }
            if powerSources.powerSource == .battery { return false }
            if registryExternal { return true }
            return nil
        }()
        let state = PowerStateResolver.resolve(
            isCharging: charging || powerSources.isCharging,
            fullyCharged: full,
            powerSource: powerSources.powerSource,
            adapterAttached: adapterAttached ?? registryExternal,
            netBatteryPowerWatts: netPowerWatts
        )
        let external = powerSources.powerSource == .external
            || powerSources.powerSource == .ups
            || registryExternal

        return BatteryMetrics(
            percentage: min(100, max(0, percentage)),
            state: state,
            powerSource: powerSources.powerSource,
            adapterAttached: adapterAttached,
            isExternalPowerConnected: external,
            voltageVolts: voltageMV.map { $0.doubleValue / 1_000 },
            currentAmps: currentMA.map { Double($0.int64Value) / 1_000 },
            netPowerWatts: netPowerWatts,
            adapterRatedWatts: adapterRatedWatts,
            temperatureCelsius: MetricMath.validTemperature(temperatureRaw.map { $0 / 100 }),
            healthPercent: MetricMath.healthPercent(maxCapacity: nominalMax, designCapacity: design),
            cycleCount: number(dictionary["CycleCount"])?.intValue,
            currentCapacityMAh: rawCurrent?.intValue,
            maxCapacityMAh: nominalMax?.intValue,
            designCapacityMAh: design?.intValue,
            timeRemainingMinutes: powerSources.timeRemainingMinutes,
            // 计量芯片自己的估计，就躺在同一个字典里，此前从未被读过。
            // 实测它给 110–176 分，而 powerd 给 1200 分。
            gaugeMinutesToEmpty: gaugeMinutes(dictionary["AvgTimeToEmpty"])
                ?? gaugeMinutes(dictionary["TimeRemaining"]),
            gaugeMinutesToFull: gaugeMinutes(dictionary["AvgTimeToFull"]),
            socFinePercent: socFine(rawCurrent: rawCurrent, rawMax: rawMax)
        )
    }

    /// 65535 是「未知」哨兵，不是 45 天。实测放电时 `AvgTimeToFull` 就是这个值。
    private static func gaugeMinutes(_ value: Any?) -> Int? {
        guard let minutes = number(value)?.intValue,
              minutes > 0,
              minutes != 65_535
        else { return nil }
        return minutes
    }

    /// 细分电量。整数 `CurrentCapacity` 的量化台阶在 7W 下约合 6 分钟，
    /// 直接拿它算续航会让数字一跳一跳。
    private static func socFine(rawCurrent: NSNumber?, rawMax: NSNumber?) -> Double? {
        guard let current = rawCurrent?.doubleValue,
              let max = rawMax?.doubleValue,
              max > 0,
              // Apple Silicon 上 MaxCapacity 是常数 100（百分比），
              // 拿它当 mAh 会算出 1.7% 这种荒谬值。
              max > 200
        else { return nil }
        return min(100, Swift.max(0, current / max * 100))
    }

    private static func fallbackFromPowerSources(_ snapshot: PowerSourcesSnapshot) -> BatteryMetrics {
        let adapterDetails = readAdapterDetails()
        let attached = adapterDetails.attached
            ? true
            : (snapshot.powerSource == .battery ? false : nil)
        let state = PowerStateResolver.resolve(
            isCharging: snapshot.isCharging,
            fullyCharged: false,
            powerSource: snapshot.powerSource,
            adapterAttached: attached,
            netBatteryPowerWatts: nil
        )
        return BatteryMetrics(
            percentage: snapshot.percentage ?? 0,
            state: state,
            powerSource: snapshot.powerSource,
            adapterAttached: attached,
            isExternalPowerConnected: snapshot.powerSource == .external || snapshot.powerSource == .ups,
            adapterRatedWatts: adapterDetails.watts,
            timeRemainingMinutes: snapshot.timeRemainingMinutes
        )
    }

    private struct PowerSourcesSnapshot {
        var percentage: Double?
        var isCharging = false
        var powerSource: SystemPowerSource = .unknown
        var timeRemainingMinutes: Int?
    }

    private static func readPowerSources() -> PowerSourcesSnapshot {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return .init()
        }

        let powerSource: SystemPowerSource = {
            let raw = IOPSGetProvidingPowerSourceType(blob).takeUnretainedValue() as String
            switch raw {
            case kIOPSACPowerValue: return .external
            case kIOPSBatteryPowerValue: return .battery
            case "UPS Power": return .ups
            default: return .unknown
            }
        }()

        guard
            let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef],
            let source = sources.first(where: { source in
                guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue()
                    as? [String: Any] else { return false }
                return (description[kIOPSTypeKey as String] as? String) == (kIOPSInternalBatteryType as String)
            }),
            let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue()
                as? [String: Any]
        else {
            return PowerSourcesSnapshot(
                powerSource: powerSource,
                timeRemainingMinutes: timeRemainingMinutes()
            )
        }

        let current = number(description[kIOPSCurrentCapacityKey as String])?.doubleValue
        let maximum = number(description[kIOPSMaxCapacityKey as String])?.doubleValue
        let percentage: Double? = {
            guard let current, let maximum, maximum > 0 else { return nil }
            return current / maximum * 100
        }()
        return PowerSourcesSnapshot(
            percentage: percentage,
            isCharging: bool(description[kIOPSIsChargingKey as String]),
            powerSource: powerSource,
            timeRemainingMinutes: timeRemainingMinutes()
        )
    }

    private static func readAdapterDetails() -> (attached: Bool, watts: Double?) {
        guard let unmanaged = IOPSCopyExternalPowerAdapterDetails() else {
            return (false, nil)
        }
        let details = unmanaged.takeRetainedValue() as NSDictionary
        return (
            true,
            number(details[kIOPSPowerAdapterWattsKey as String])?.doubleValue
        )
    }

    private static func readAdapterWatts(_ dictionary: [String: Any]) -> Double? {
        if let details = dictionary["AdapterDetails"] as? [String: Any] {
            if let watts = number(details["Watts"])?.doubleValue, watts > 0 { return watts }
            if let watts = number(details["AdapterWattage"])?.doubleValue, watts > 0 { return watts }
        }
        if let data = dictionary["BatteryData"] as? [String: Any],
           let watts = number(data["AdapterPower"])?.doubleValue,
           watts > 0 {
            return watts
        }
        return nil
    }

    private static func timeRemainingMinutes() -> Int? {
        let estimate = IOPSGetTimeRemainingEstimate()
        guard estimate.isFinite, estimate > 0 else { return nil }
        return Int(estimate / 60)
    }

    private static func number(_ value: Any?) -> NSNumber? {
        if let number = value as? NSNumber { return number }
        return nil
    }

    private static func bool(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        return (value as? NSNumber)?.boolValue ?? false
    }
}
