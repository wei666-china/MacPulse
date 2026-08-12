import XCTest
@testable import MacPulseSensors

/// 原生传感器纯逻辑测试。样本全部来自本机(M5 MacBook Air)实抓:
/// pmgr voltage-states5-sram 原始字节、IOReport 状态名("V0P7"…)、
/// SMC 类型编码。
final class NativeSensorMathTests: XCTestCase {

    // MARK: - 频率表解析

    func testParsesRealM5FrequencyTable() {
        // voltage-states5-sram 前三条记录(8 字节一条,前 4 字节小端 kHz)。
        let hex: [UInt8] = [
            0x60, 0xF5, 0x13, 0x00, 0x16, 0x03, 0x00, 0x00,  // 1_308_000 kHz
            0x40, 0x89, 0x18, 0x00, 0x16, 0x03, 0x00, 0x00,  // 1_608_000 kHz
            0xE0, 0x7A, 0x1D, 0x00, 0x2A, 0x03, 0x00, 0x00   // 1_932_000 kHz
        ]
        let parsed = ClusterFrequencyTables.parseFrequencies(Data(hex))
        XCTAssertEqual(parsed, [1308, 1608, 1932], "M5 起频率表按 kHz 记")
    }

    func testParsesLegacyHertzTable() {
        // M1–M4 时代按 Hz 记:1_308_000_000 Hz = 0x4DF71300。
        var data = Data()
        for freq: UInt32 in [1_308_000_000, 2_000_000_000] {
            withUnsafeBytes(of: freq.littleEndian) { data.append(contentsOf: $0) }
            data.append(contentsOf: [0, 0, 0, 0])
        }
        XCTAssertEqual(ClusterFrequencyTables.parseFrequencies(data), [1308, 2000])
    }

    func testFrequencyTableDropsSentinels() {
        // 全零/超小值是占位,宁可短表不放垃圾档。
        let data = Data([0, 0, 0, 0, 0, 0, 0, 0, 0x10, 0x27, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(ClusterFrequencyTables.parseFrequencies(data), [], "0 与 10000(<1e5)都不入表")
    }

    // MARK: - 状态名与驻留

    func testStateIndexParsing() {
        XCTAssertEqual(NativeSoCSampler.stateIndex(from: "V12P6"), 12)
        XCTAssertEqual(NativeSoCSampler.stateIndex(from: "V0P7"), 0)
        XCTAssertEqual(NativeSoCSampler.stateIndex(from: "V3"), 3)
        XCTAssertNil(NativeSoCSampler.stateIndex(from: "P5"), "GPU 的 P 状态没有 V 序号")
        XCTAssertNil(NativeSoCSampler.stateIndex(from: "IDLE"))
    }

    func testResidencySummaryWeightsActiveStatesOnly() throws {
        // M5 真实命名:IDLE + V<idx>P<n>。空闲 50%,两档活跃各 25%。
        let summary = try XCTUnwrap(NativeSoCSampler.summarizeResidency(
            states: [("IDLE", 50), ("V0P1", 25), ("V1P0", 25)],
            table: [1000, 2000],
            idleNames: ["OFF", "IDLE"]
        ))
        XCTAssertEqual(summary.activePercent, 50, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(summary.frequencyMHz), 1500, accuracy: 0.001,
                       "平均频率只在活跃时间上加权")
    }

    func testResidencySummaryHonorsSparseStateIndex() throws {
        // 状态稀疏时必须按 V 序号对表,计数器法会错位到 1000。
        let summary = try XCTUnwrap(NativeSoCSampler.summarizeResidency(
            states: [("IDLE", 90), ("V2P0", 10)],
            table: [1000, 1500, 2200],
            idleNames: ["IDLE"]
        ))
        XCTAssertEqual(try XCTUnwrap(summary.frequencyMHz), 2200, accuracy: 0.001)
    }

    // MARK: - 能耗轨

    private func energyReading(_ channel: String, _ delta: Int64, unit: String = "mJ") -> IOReportReading {
        IOReportReading(group: "Energy Model", subgroup: "", channel: channel,
                        unit: unit, simpleValue: delta, states: nil)
    }

    func testEnergyUnitConversion() {
        XCTAssertEqual(NativeSoCSampler.watts(delta: 2000, unit: "mJ", elapsedSeconds: 2), 1)
        XCTAssertEqual(NativeSoCSampler.watts(delta: 2_000_000, unit: "uJ", elapsedSeconds: 2), 1)
        XCTAssertEqual(NativeSoCSampler.watts(delta: 2_000_000_000, unit: "nJ", elapsedSeconds: 2), 1)
        XCTAssertEqual(NativeSoCSampler.watts(delta: 2_000_000, unit: nil, elapsedSeconds: 2), 1,
                       "无单位按 µJ,上游同一约定")
    }

    func testEnergyRailsPreferTotalOverTyped() {
        // 同代芯片会同时给总量通道与分核通道,取其一,绝不相加。
        let rails = NativeSoCSampler.resolveEnergyRails(
            readings: [
                energyReading("CPU Energy", 4000),
                energyReading("ECPU Energy", 1000),
                energyReading("PCPU Energy", 2000)
            ],
            elapsedSeconds: 2
        )
        XCTAssertEqual(try XCTUnwrap(rails.cpu), 2.0, accuracy: 0.001, "总量通道优先,不叠加分核")
    }

    func testEnergyRailsFallBackToTypedChannels() {
        let rails = NativeSoCSampler.resolveEnergyRails(
            readings: [
                energyReading("ECPU Energy", 1000),
                energyReading("PCPU Energy", 2000)
            ],
            elapsedSeconds: 2
        )
        XCTAssertEqual(try XCTUnwrap(rails.cpu), 1.5, accuracy: 0.001)
    }

    func testIdleANEReportsZeroNotNil() {
        // ANE 空闲时能量增量为 0:0 是真读数(空闲),不折叠成「不可用」。
        let rails = NativeSoCSampler.resolveEnergyRails(
            readings: [energyReading("CPU Energy", 1000), energyReading("ANE", 0)],
            elapsedSeconds: 2
        )
        XCTAssertEqual(rails.ane, 0)
    }

    func testGPUAliasChannel() {
        let rails = NativeSoCSampler.resolveEnergyRails(
            readings: [energyReading("GPU", 3000)],
            elapsedSeconds: 3
        )
        XCTAssertEqual(try XCTUnwrap(rails.gpu), 1.0, accuracy: 0.001)
    }

    // MARK: - 功率归一化

    func testPowerNormalization() {
        let normal = NativeSoCSampler.normalizePower(systemTotal: 5, componentSum: 3)
        XCTAssertEqual(normal.total, 5)
        XCTAssertEqual(try XCTUnwrap(normal.residual), 2, accuracy: 0.001)

        let inverted = NativeSoCSampler.normalizePower(systemTotal: 2, componentSum: 3)
        XCTAssertEqual(inverted.total, 3, "总功耗至少是具名轨之和")
        XCTAssertEqual(inverted.residual, 0)

        let missing = NativeSoCSampler.normalizePower(systemTotal: nil, componentSum: 3)
        XCTAssertEqual(missing.total, 3)
        XCTAssertNil(missing.residual, "PSTR 读不到就没有「其他」的依据,不硬造")
    }

    // MARK: - 温度键分组

    func testTemperatureKeyClassification() {
        XCTAssertEqual(NativeSoCSampler.classifyTemperatureKey("Tp0X"), "CPU P-Core")
        XCTAssertEqual(NativeSoCSampler.classifyTemperatureKey("Te05"), "CPU E-Core")
        XCTAssertEqual(NativeSoCSampler.classifyTemperatureKey("Tg0j"), "GPU")
        XCTAssertEqual(NativeSoCSampler.classifyTemperatureKey("TPD1"), "SoC Package")
        XCTAssertEqual(NativeSoCSampler.classifyTemperatureKey("Ts0P"), "SSD", "无 S 核机型上 Ts 归 SSD")
        XCTAssertEqual(NativeSoCSampler.classifyTemperatureKey("Ts0P", hasSCores: true), "CPU S-Core")
        XCTAssertEqual(NativeSoCSampler.classifyTemperatureKey("TW0P"), "Wireless")
        XCTAssertNil(NativeSoCSampler.classifyTemperatureKey("Tx99"), "认不出的前缀不硬归组")
        XCTAssertNil(NativeSoCSampler.classifyTemperatureKey("PSTR"))
    }

    // MARK: - SMC 解码

    func testSMCDecodesNegativeFixedPoint() {
        // sp78 是有符号 7.8 定点:0xC000 = -16384/256 = -64℃。
        // 上游按无符号解会得到 +192,负温度全是鬼值——这里必须是负数。
        let value = SMCValue(key: "TEST", type: "sp78", bytes: [0xC0, 0x00])
        XCTAssertEqual(try XCTUnwrap(value.doubleValue), -64, accuracy: 0.001)

        let positive = SMCValue(key: "TEST", type: "sp78", bytes: [0x30, 0x80])
        XCTAssertEqual(try XCTUnwrap(positive.doubleValue), 48.5, accuracy: 0.001)
    }

    func testSMCDecodesLittleEndianFloat() {
        // flt 是小端 IEEE754:50.0 = 0x42480000,小端字节序 00 00 48 42。
        let value = SMCValue(key: "TEST", type: "flt ", bytes: [0x00, 0x00, 0x48, 0x42])
        XCTAssertEqual(try XCTUnwrap(value.doubleValue), 50, accuracy: 0.001)
    }

    func testSMCDecodesFanRPM() {
        // fpe2:3000 RPM = (0x2E << 6) + (0xE0 >> 2)。
        let value = SMCValue(key: "F0Ac", type: "fpe2", bytes: [0x2E, 0xE0])
        XCTAssertEqual(value.doubleValue, 3000)
    }

    func testSMCUnknownTypeReturnsNil() {
        XCTAssertNil(SMCValue(key: "TEST", type: "ch8*", bytes: [1, 2]).doubleValue, "未知类型不猜")
    }

    // MARK: - DRAM 带宽

    private func amcReading(_ channel: String, _ delta: Int64) -> IOReportReading {
        IOReportReading(group: "AMC Stats", subgroup: "Perf Counters", channel: channel,
                        unit: nil, simpleValue: delta, states: nil)
    }

    func testDRAMBandwidthPrefersExactDirectional() {
        let bw = NativeSoCSampler.resolveDRAMBandwidth(
            readings: [
                amcReading("DCS RD", 2_000_000_000),
                amcReading("DCS WR", 1_000_000_000),
                amcReading("DCS_0 RD", 999)
            ],
            elapsedSeconds: 2
        )
        XCTAssertEqual(try XCTUnwrap(bw.readGBs), 1.0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(bw.writeGBs), 0.5, accuracy: 0.001)
    }

    func testDRAMBandwidthSplitsCombined() {
        let bw = NativeSoCSampler.resolveDRAMBandwidth(
            readings: [amcReading("DCS RD+WR", 4_000_000_000)],
            elapsedSeconds: 2
        )
        XCTAssertEqual(try XCTUnwrap(bw.readGBs), 1.0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(bw.writeGBs), 1.0, accuracy: 0.001)
    }

    func testDRAMBandwidthNilWhenNoChannels() {
        let bw = NativeSoCSampler.resolveDRAMBandwidth(
            readings: [energyReading("CPU Energy", 100)],
            elapsedSeconds: 2
        )
        XCTAssertNil(bw.readGBs, "没有 DCS 通道就是 nil,交给上游判「本机型不提供」")
        XCTAssertNil(bw.writeGBs)
    }
}

/// 真机对账:采样器读数对独立来源(ioreg 文本、物理边界)。
/// 原则不变:不许自己对自己。
final class NativeSensorLiveTests: XCTestCase {
    private func shell(_ command: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    func testLiveSampleHasCoherentPower() throws {
        let sampler = NativeSoCSampler()
        guard let sample = sampler.sample(windowSeconds: 1.0) else {
            throw XCTSkip("本机拿不到 IOReport 会话")
        }
        let rails = [sample.cpuPowerWatts, sample.gpuPowerWatts,
                     sample.anePowerWatts, sample.dramPowerWatts]
            .compactMap { $0 }.reduce(0, +)
        XCTAssertGreaterThan(rails, 0, "运行中的机器 CPU 轨不可能是 0")
        if let total = sample.totalPowerWatts {
            XCTAssertGreaterThanOrEqual(total + 0.001, rails, "封装总功耗不能小于具名轨之和")
            XCTAssertLessThan(total, 300, "笔记本功耗不可能到 300W,超出必是解码错误")
        }
    }

    func testLiveClusterFrequencyWithinIoregTableBounds() throws {
        let sampler = NativeSoCSampler()
        guard let sample = sampler.sample(windowSeconds: 1.0),
              let eFreq = sample.eClusterFreqMHz else {
            throw XCTSkip("本机拿不到集群频率")
        }
        // 独立真值:直接从 ioreg 文本抠 voltage-states1-sram 的十六进制,
        // 与实现走完全不同的解析路径(文本 vs CFData)。
        let text = shell("ioreg -c AppleARMIODevice -r -d 1 | grep 'voltage-states1-sram'")
        guard let start = text.firstIndex(of: "<"), let end = text.firstIndex(of: ">") else {
            throw XCTSkip("ioreg 里找不到 voltage-states1-sram")
        }
        let hex = text[text.index(after: start)..<end]
        var freqs: [Double] = []
        var cursor = hex.startIndex
        while let next = hex.index(cursor, offsetBy: 16, limitedBy: hex.endIndex) {
            let record = hex[cursor..<next]
            let freqHex = String(record.prefix(8))
            // 小端十六进制 → 数值:两两倒序。
            let bytes = stride(from: 0, to: 8, by: 2).compactMap {
                UInt32(freqHex.dropFirst($0).prefix(2), radix: 16)
            }
            guard bytes.count == 4 else { break }
            let raw = bytes[0] | bytes[1] << 8 | bytes[2] << 16 | bytes[3] << 24
            let value = Double(raw)
            if value >= 1e8 { freqs.append(value / 1e6) } else if value >= 1e5 { freqs.append(value / 1e3) }
            cursor = next
        }
        guard let minFreq = freqs.min(), let maxFreq = freqs.max() else {
            throw XCTSkip("ioreg 频率表解析为空")
        }
        XCTAssertGreaterThanOrEqual(eFreq, minFreq * 0.99, "E 集群频率低于表底")
        XCTAssertLessThanOrEqual(eFreq, maxFreq * 1.01, "E 集群频率高于表顶")
    }

    func testLiveTemperaturesArePlausible() throws {
        let sampler = NativeSoCSampler()
        guard let sample = sampler.sample(windowSeconds: 0.3),
              !sample.temperatureGroups.isEmpty else {
            throw XCTSkip("本机拿不到 SMC 温度")
        }
        for group in sample.temperatureGroups {
            XCTAssertGreaterThan(group.average, 1, "\(group.name) 平均温度不可信")
            XCTAssertLessThan(group.average, 120, "\(group.name) 平均温度不可信")
            XCTAssertGreaterThanOrEqual(group.maximum + 0.001, group.minimum, "\(group.name) 区间倒挂")
        }
    }
}
