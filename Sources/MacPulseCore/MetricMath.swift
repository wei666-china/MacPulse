import Foundation

public enum MetricMath {
    public static func signedInt64(from number: NSNumber?) -> Int64? {
        number?.int64Value
    }

    public static func batteryPowerWatts(voltageMillivolts: NSNumber?, currentMilliamps: NSNumber?) -> Double? {
        guard
            let voltage = voltageMillivolts?.doubleValue,
            let currentNumber = currentMilliamps,
            voltage > 0
        else {
            return nil
        }
        return voltage * Double(currentNumber.int64Value) / 1_000_000
    }

    public static func healthPercent(maxCapacity: NSNumber?, designCapacity: NSNumber?) -> Double? {
        guard
            let max = maxCapacity?.doubleValue,
            let design = designCapacity?.doubleValue,
            max > 0,
            design > 0
        else {
            return nil
        }
        return min(100, max / design * 100)
    }

    public static func validTemperature(_ value: Double?) -> Double? {
        guard let value, value >= 0, value < 150 else { return nil }
        return value
    }

    public static func nonZero(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    public static func nonNegative(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    public static func mean(_ values: [Double?]) -> Double? {
        let valid = values.compactMap { $0 }.filter(\.isFinite)
        guard !valid.isEmpty else { return nil }
        return valid.reduce(0, +) / Double(valid.count)
    }

    public static func cpuUsagePercent(
        previous: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32),
        current: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)
    ) -> Double? {
        let user = UInt64(current.user &- previous.user)
        let system = UInt64(current.system &- previous.system)
        let idle = UInt64(current.idle &- previous.idle)
        let nice = UInt64(current.nice &- previous.nice)
        let total = user + system + idle + nice
        guard total > 0 else { return nil }
        return Double(user + system + nice) / Double(total) * 100
    }
}

public struct AlertEvaluator: Sendable {
    public var hotSince: Date?
    public var lastSent: [String: Date] = [:]

    public init(hotSince: Date? = nil, lastSent: [String: Date] = [:]) {
        self.hotSince = hotSince
        self.lastSent = lastSent
    }

    public mutating func evaluate(
        snapshot: MetricSnapshot,
        now: Date,
        temperatureThreshold: Double,
        requiredDuration: TimeInterval = 120,
        cooldown: TimeInterval = 3_600,
        resetMargin: Double = 1,
        temperatureEnabled: Bool = true,
        thermalEnabled: Bool = true,
        healthEnabled: Bool = true,
        healthThreshold: Double = 80
    ) -> [String] {
        var alerts: [String] = []

        if temperatureEnabled,
           let temperature = snapshot.battery.temperatureCelsius,
           temperature >= temperatureThreshold {
            hotSince = hotSince ?? now
            if let hotSince, now.timeIntervalSince(hotSince) >= requiredDuration,
               canSend("temperature", now: now, cooldown: cooldown) {
                alerts.append("temperature")
                lastSent["temperature"] = now
            }
        } else if snapshot.battery.temperatureCelsius.map({
            $0 < temperatureThreshold - resetMargin
        }) ?? true {
            hotSince = nil
        }

        if thermalEnabled,
           [.serious, .critical].contains(snapshot.deep.thermalLevel),
           canSend("thermal", now: now, cooldown: cooldown) {
            alerts.append("thermal")
            lastSent["thermal"] = now
        }

        if healthEnabled,
           let health = snapshot.battery.healthPercent,
           health < healthThreshold,
           // 冷却用同一把用户设的滑杆,但健康度天级变化,给它兜个 24h 下限:
           // 用户设 15 分钟不该被同一条健康提醒轰炸,可高温提醒仍按 15 分钟走。
           canSend("health", now: now, cooldown: max(cooldown, 86_400)) {
            alerts.append("health")
            lastSent["health"] = now
        }

        return alerts
    }

    private func canSend(_ key: String, now: Date, cooldown: TimeInterval) -> Bool {
        guard let last = lastSent[key] else { return true }
        return now.timeIntervalSince(last) >= cooldown
    }
}

public struct MinuteAggregator: Sendable {
    private var snapshots: [MetricSnapshot] = []
    private var bucketStart: Date?
    public init() {}

    @discardableResult
    public mutating func append(
        _ snapshot: MetricSnapshot,
        calendar: Calendar = .current
    ) -> HistoryPoint? {
        let incomingBucket = calendar.dateInterval(of: .minute, for: snapshot.timestamp)?.start
            ?? snapshot.timestamp

        if let bucketStart, bucketStart != incomingBucket {
            let completed = flush()
            self.bucketStart = incomingBucket
            snapshots.append(snapshot)
            return completed
        }

        bucketStart = incomingBucket
        snapshots.append(snapshot)
        return nil
    }

    public mutating func flush() -> HistoryPoint? {
        guard let last = snapshots.last else { return nil }
        var point = HistoryPoint(snapshot: last)
        point.batteryPercent = MetricMath.mean(snapshots.map { $0.battery.percentage }) ?? last.battery.percentage
        point.batteryPowerWatts = MetricMath.mean(snapshots.map { $0.battery.netPowerWatts })
        point.batteryTemperature = MetricMath.mean(snapshots.map { $0.battery.temperatureCelsius })
        point.hotspotTemperature = MetricMath.mean(snapshots.map { $0.deep.hotspotTemperature })
        point.systemPowerWatts = MetricMath.mean(snapshots.map { $0.deep.systemPowerWatts })
        point.cpuUsagePercent = MetricMath.mean(snapshots.map { $0.deep.cpuUsagePercent })
        snapshots.removeAll(keepingCapacity: true)
        bucketStart = nil
        return point
    }
}
