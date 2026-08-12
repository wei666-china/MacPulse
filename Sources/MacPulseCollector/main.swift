import Foundation
import MacPulseCore
import MacPulseSensors

// MacPulseCollector:SoC 深层指标的专职采集进程。
//
// v3 起不再捆绑 mactop 子进程——功耗/频率/温度全部由 MacPulseSensors
// 原生读取(IOReport + SMC),对外的 NDJSON 契约(CollectorFrameV2,
// schemaVersion 2)保持不变,App 侧无感。
//
// 仍然独立成进程而不是并进 App,理由没变:IOReport 是无文档接口,
// 万一哪代系统上崩了,死的是采集器(App 显示「采集器重连中」),不是整个 App。

/// 区分「本机型没有这个传感器」和「这个传感器读数确实是 0」。
///
/// 判据分两类，绝不混用：
///
/// 1. **结构性缺失** —— 风扇个数(SMC FNum)读 0 或读不到,一次就能判定。
///    无风扇的 MacBook Air 就是这种。
/// 2. **持续精确零，且仅限带宽计数器** —— 一台运行中的机器不可能连续 30 帧
///    DRAM 读写带宽都精确等于 `0.0`，同时 DRAM 又在耗电。这个组合只能说明
///    IOReport 通道在这颗芯片上不存在。一旦出现非零值就永久解除标记——
///    芯片不会中途丢掉一个传感器。
///
/// 功率和活跃度**永远不套用零规则**：`ane_power == 0` 就是空闲，空闲是真读数。
private struct UnsupportedDetector {
    private static let zeroRunThreshold = 30

    private var dramBandwidthZeroRun = 0
    private var aneBandwidthZeroRun = 0
    private var dramBandwidthConfirmedPresent = false
    private var aneBandwidthConfirmedPresent = false
    private var fansAbsent = false

    private(set) var unsupportedKeys: [String] = []

    func isUnsupported(_ key: String) -> Bool {
        unsupportedKeys.contains(key)
    }

    mutating func observe(
        fanCount: Int?,
        dramReadGBs: Double?,
        dramWriteGBs: Double?,
        dramPowerWatts: Double?
    ) {
        // 结构性缺失：一次即判。
        if (fanCount ?? 0) <= 0 {
            fansAbsent = true
        }

        // DRAM 带宽：只有在 DRAM 确实通着电时，「零流量/无通道」才是可疑的。
        let dramPowered = (dramPowerWatts ?? 0) > 0
        evaluateBandwidth(
            values: [dramReadGBs, dramWriteGBs],
            channelMissing: dramReadGBs == nil && dramWriteGBs == nil,
            powered: dramPowered,
            run: &dramBandwidthZeroRun,
            confirmedPresent: &dramBandwidthConfirmedPresent
        )
        // 神经引擎带宽:原生路径本期不提供该通道(上游靠 PMP 直方图推算,
        // 复杂度与泄漏风险都在那条路上),按「无通道」走判定,
        // 30 帧后如实标注「本机型不提供」。界面本来也没有消费它。
        evaluateBandwidth(
            values: [nil, nil],
            channelMissing: true,
            powered: dramPowered,
            run: &aneBandwidthZeroRun,
            confirmedPresent: &aneBandwidthConfirmedPresent
        )

        var keys: [String] = []
        if fansAbsent { keys.append(SensorAvailabilityKey.fans) }
        if !dramBandwidthConfirmedPresent, dramBandwidthZeroRun >= Self.zeroRunThreshold {
            keys.append(SensorAvailabilityKey.dramBandwidth)
        }
        if !aneBandwidthConfirmedPresent, aneBandwidthZeroRun >= Self.zeroRunThreshold {
            keys.append(SensorAvailabilityKey.aneBandwidth)
        }
        unsupportedKeys = keys
    }

    private func evaluateBandwidth(
        values: [Double?],
        channelMissing: Bool,
        powered: Bool,
        run: inout Int,
        confirmedPresent: inout Bool
    ) {
        guard !confirmedPresent else { return }
        let present = values.compactMap { $0 }
        if present.contains(where: { $0 > 0 }) {
            confirmedPresent = true
            run = 0
            return
        }
        guard powered else { return }
        if channelMissing || !present.isEmpty {
            run += 1
        }
    }
}

@main
private enum MacPulseCollector {
    static func main() {
        let intervalSeconds = Double(sampleIntervalMilliseconds()) / 1000

        let sampler = NativeSoCSampler()
        let throughput = ThroughputReader()
        let chip = ChipInfoReader.read(gpuMaxFrequencyMHz: sampler.gpuMaxFrequencyMHz)
        let fanCount = sampler.fanCount

        let configuredParentPID = ProcessInfo.processInfo.environment["MACPULSE_PARENT_PID"]
            .flatMap(Int32.init)

        func parentIsUnavailable() -> Bool {
            errno = 0
            let signalResult = configuredParentPID.map { kill($0, 0) } ?? 0
            return CollectorParentPolicy.shouldTerminate(
                configuredParentPID: configuredParentPID,
                signalResult: signalResult,
                errorCode: errno
            )
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        var sequence: UInt64 = 0
        var consecutiveSampleFailures = 0
        var unsupportedDetector = UnsupportedDetector()

        while true {
            if parentIsUnavailable() { break }

            // 采样本身阻塞满整个窗口(节奏与旧路径一致:窗口即间隔)。
            guard let soc = sampler.sample(windowSeconds: intervalSeconds) else {
                consecutiveSampleFailures += 1
                if consecutiveSampleFailures == 1 || consecutiveSampleFailures.isMultiple(of: 20) {
                    FileHandle.standardError.write(
                        Data("native_sample_failed=\(consecutiveSampleFailures)\n".utf8)
                    )
                }
                // IOReport 起不来(极端情况)也别忙轮询烧 CPU。
                Thread.sleep(forTimeInterval: intervalSeconds)
                continue
            }
            consecutiveSampleFailures = 0
            let rates = throughput.sample()

            unsupportedDetector.observe(
                fanCount: fanCount,
                dramReadGBs: soc.dramReadGBs,
                dramWriteGBs: soc.dramWriteGBs,
                dramPowerWatts: soc.dramPowerWatts
            )

            // 「芯片热点」覆盖 CPU/SoC/GPU 全部芯片区组:旧版漏了 GPU,
            // 渲染时会出现热点 52° 而正下方 GPU 组 61° 的倒挂。
            let hotspot = soc.temperatureGroups
                .filter { $0.name.localizedCaseInsensitiveContains("CPU")
                    || $0.name.localizedCaseInsensitiveContains("SoC")
                    || $0.name.localizedCaseInsensitiveContains("GPU") }
                .map(\.maximum)
                .max()
            let fallbackHotspot = [soc.cpuTemperature, soc.gpuTemperature].compactMap { $0 }.max()

            let deep = DeepMetrics(
                gpuUsagePercent: validPercent(soc.gpuActivePercent),
                cpuTemperature: MetricMath.validTemperature(soc.cpuTemperature),
                gpuTemperature: MetricMath.validTemperature(soc.gpuTemperature),
                hotspotTemperature: MetricMath.validTemperature(hotspot ?? fallbackHotspot),
                cpuPowerWatts: MetricMath.nonNegative(soc.cpuPowerWatts),
                gpuPowerWatts: MetricMath.nonNegative(soc.gpuPowerWatts),
                anePowerWatts: MetricMath.nonNegative(soc.anePowerWatts),
                dramPowerWatts: MetricMath.nonNegative(soc.dramPowerWatts),
                systemPowerWatts: MetricMath.nonNegative(soc.totalPowerWatts),
                dcInputWatts: MetricMath.nonNegative(soc.dcInputPowerWatts),
                diskReadBytesPerSecond: MetricMath.nonNegative(rates.diskReadBytesPerSecond),
                diskWriteBytesPerSecond: MetricMath.nonNegative(rates.diskWriteBytesPerSecond),
                networkInBytesPerSecond: MetricMath.nonNegative(rates.networkInBytesPerSecond),
                networkOutBytesPerSecond: MetricMath.nonNegative(rates.networkOutBytesPerSecond),
                socPower: SoCPowerMetrics(
                    packageWatts: MetricMath.nonNegative(soc.totalPowerWatts),
                    residualWatts: MetricMath.nonNegative(soc.residualPowerWatts),
                    gpuSRAMWatts: MetricMath.nonNegative(soc.gpuSRAMPowerWatts)
                ),
                socCompute: SoCComputeMetrics(
                    eClusterActivePercent: validPercent(soc.eClusterActivePercent),
                    eClusterFreqMHz: positiveInt(soc.eClusterFreqMHz.map { Int($0.rounded()) }),
                    pClusterActivePercent: validPercent(soc.pClusterActivePercent),
                    pClusterFreqMHz: positiveInt(soc.pClusterFreqMHz.map { Int($0.rounded()) }),
                    gpuFreqMHz: positiveInt(soc.gpuFreqMHz.map { Int($0.rounded()) }),
                    // 神经引擎活跃度:原生路径暂无可靠来源(上游取自 PMP 驻留,
                    // 本期不订阅),nil = 界面显示「不可用」。功率照常提供。
                    aneActivePercent: nil,
                    dramReadGBs: bandwidth(
                        soc.dramReadGBs,
                        unsupported: unsupportedDetector.isUnsupported(SensorAvailabilityKey.dramBandwidth)
                    ),
                    dramWriteGBs: bandwidth(
                        soc.dramWriteGBs,
                        unsupported: unsupportedDetector.isUnsupported(SensorAvailabilityKey.dramBandwidth)
                    ),
                    aneReadGBs: nil,
                    aneWriteGBs: nil
                ),
                chip: chip,
                thermalGroups: soc.temperatureGroups.map { group in
                    ThermalGroup(
                        rawName: group.name,
                        averageCelsius: MetricMath.validTemperature(group.average),
                        minimumCelsius: MetricMath.validTemperature(group.minimum),
                        maximumCelsius: MetricMath.validTemperature(group.maximum),
                        sensorCount: positiveInt(group.sensorCount)
                    )
                },
                networkLink: NetworkLinkReader.read(),
                unsupported: unsupportedDetector.unsupportedKeys,
                collectorAvailable: true
            )

            let warningList = warnings(for: deep)
            guard hasAnyMetric(deep) else {
                FileHandle.standardError.write(Data("collector_empty_sample\n".utf8))
                continue
            }

            sequence &+= 1
            let frame = CollectorFrameV2(
                sequence: sequence,
                timestamp: .now,
                metrics: deep,
                warnings: warningList
            )
            guard let encoded = try? encoder.encode(frame) else { continue }
            FileHandle.standardOutput.write(encoded)
            FileHandle.standardOutput.write(Data([0x0A]))
        }
    }

    private static func sampleIntervalMilliseconds() -> Int {
        let raw = ProcessInfo.processInfo.environment["MACPULSE_INTERVAL_MS"]
            .flatMap(Int.init)
            ?? 2_000
        return min(30_000, max(1_000, raw))
    }

    private static func validPercent(_ value: Double?) -> Double? {
        guard let value, value.isFinite, (0...100).contains(value) else { return nil }
        return value
    }

    private static func positiveInt(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }

    /// 带宽读数：本机型不提供时返回 nil，让界面显示「本机型不提供」而不是 0。
    private static func bandwidth(_ value: Double?, unsupported: Bool) -> Double? {
        guard !unsupported else { return nil }
        return MetricMath.nonNegative(value)
    }

    private static func warnings(for metrics: DeepMetrics) -> [String] {
        var result: [String] = []
        if metrics.cpuTemperature == nil { result.append("cpu_temperature_missing") }
        if metrics.gpuTemperature == nil { result.append("gpu_temperature_missing") }
        if metrics.gpuUsagePercent == nil { result.append("gpu_usage_missing") }
        if metrics.systemPowerWatts == nil { result.append("system_power_missing") }
        return result
    }

    /// 判空只看深层指标本身；内存/CPU 占用由 App 原生读取，不在此列。
    private static func hasAnyMetric(_ metrics: DeepMetrics) -> Bool {
        metrics.gpuUsagePercent != nil
            || metrics.hotspotTemperature != nil
            || metrics.systemPowerWatts != nil
            || metrics.cpuPowerWatts != nil
            || metrics.socPower?.hasAnyValue == true
            || metrics.thermalGroups?.isEmpty == false
    }
}
