import XCTest
@testable import MacPulse
@testable import MacPulseCore

/// 真机验证快慢档采样器。读不到电池的机器上跳过。
final class BatterySamplerTests: XCTestCase {
    func testFastPathReturnsCoherentReading() async throws {
        let sampler = BatterySampler()
        guard let metrics = await sampler.sample() else {
            throw XCTSkip("本机读不到 AppleSmartBattery")
        }

        XCTAssertGreaterThan(metrics.percentage, 0)
        XCTAssertLessThanOrEqual(metrics.percentage, 100)

        // socFinePercent 只是原始容量比，**不等于系统显示的百分比**——
        // 实测 98% 对 93.18%、40% 对 36.6%，既非固定偏移也非固定比例。
        // 这一条曾经断言两者接近，被真机跑挂了，那是个真发现：
        // 续航估算因此一度把两把尺子混用。现在只验证它在合理范围内，
        // 且能量模型已改用显示百分比。
        if let fine = metrics.socFinePercent {
            XCTAssertGreaterThan(fine, 0)
            XCTAssertLessThanOrEqual(fine, 100)
            XCTAssertLessThan(abs(fine - metrics.percentage), 15, "偏差过大说明分母取错了")
        }

        // 电压电流应当在合理量级。
        if let volts = metrics.voltageVolts {
            XCTAssertGreaterThan(volts, 5)
            XCTAssertLessThan(volts, 20)
        }
        if let watts = metrics.netPowerWatts {
            XCTAssertLessThan(abs(watts), 200)
        }

        // 健康度不能算成 1.7% —— 那是把 MaxCapacity(=100) 当 mAh 的典型症状。
        if let health = metrics.healthPercent {
            XCTAssertGreaterThan(health, 50, "健康度过低通常意味着分母取错了")
            XCTAssertLessThanOrEqual(health, 100)
        }

        // 计量芯片读数要么缺失、要么合理，绝不能是 65535。
        for gauge in [metrics.gaugeMinutesToEmpty, metrics.gaugeMinutesToFull].compactMap({ $0 }) {
            XCTAssertNotEqual(gauge, 65_535, "哨兵值必须被滤掉")
            XCTAssertGreaterThan(gauge, 0)
            XCTAssertLessThan(gauge, 3_000)
        }
    }

    /// 慢档缓存要生效：连读多次不应当每次都去翻 AdapterDetails 那棵子树。
    /// 这里只验证结果稳定——数值不该在几毫秒内跳变。
    func testSlowValuesStayStableAcrossRapidSamples() async throws {
        let sampler = BatterySampler()
        guard let first = await sampler.sample() else {
            throw XCTSkip("本机读不到 AppleSmartBattery")
        }
        let second = await sampler.sample()
        let third = await sampler.sample()

        XCTAssertEqual(first.cycleCount, second?.cycleCount)
        XCTAssertEqual(first.designCapacityMAh, third?.designCapacityMAh)
        XCTAssertEqual(first.maxCapacityMAh, third?.maxCapacityMAh)
    }

    /// 与旧的整树读法交叉验证：两条路径读的是同一块电池，
    /// 关键字段必须一致，否则说明按键读取漏了什么。
    func testAgreesWithFullTreeReader() async throws {
        let sampler = BatterySampler()
        guard let fast = await sampler.sample() else {
            throw XCTSkip("本机读不到 AppleSmartBattery")
        }
        let full = BatteryReader.read()

        XCTAssertEqual(fast.percentage, full.percentage, accuracy: 2)
        XCTAssertEqual(fast.cycleCount, full.cycleCount)
        XCTAssertEqual(fast.designCapacityMAh, full.designCapacityMAh)
        if let a = fast.netPowerWatts, let b = full.netPowerWatts {
            // 两次读取相隔几毫秒，功率会小幅变化，但不该差一个数量级。
            XCTAssertEqual(a, b, accuracy: max(3, abs(b) * 0.5))
        }
        XCTAssertEqual(fast.isExternalPowerConnected, full.isExternalPowerConnected)
    }

    func testRepeatedSamplingDoesNotLeakServiceHandles() async throws {
        let sampler = BatterySampler()
        guard await sampler.sample() != nil else {
            throw XCTSkip("本机读不到 AppleSmartBattery")
        }
        for _ in 0..<300 {
            _ = await sampler.sample()
        }
        let final = await sampler.sample()
        XCTAssertNotNil(final, "300 轮之后仍应可读")
    }
}

/// 电池健康度真值对账。这项一直没对过账,结果读错了字段:
/// 用 AppleRawMaxCapacity(电量计瞬时估计)算出 99%,而系统设置里写着 100%。
/// 我们的数字必须和用户能自己查到的权威来源对得上。
final class BatteryHealthAuditTests: XCTestCase {
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

    func testHealthMatchesSystemProfiler() async throws {
        let metrics = await BatterySampler().sample() ?? BatteryReader.read()
        guard let health = metrics.healthPercent else {
            throw XCTSkip("本机读不到电池健康度")
        }
        // 真值:system_profiler 的 Maximum Capacity(与系统设置同一个数)。
        let output = shell("system_profiler SPPowerDataType | grep -A 4 'Health Information' | grep 'Maximum Capacity'")
        guard let range = output.range(of: #"\d+"#, options: .regularExpression),
              let systemValue = Double(output[range]) else {
            throw XCTSkip("system_profiler 没给出最大容量")
        }
        // 苹果自己也是取整显示,允许 1 个百分点的取整差。
        XCTAssertEqual(
            health.rounded(), systemValue, accuracy: 1,
            "健康度 \(health)% 与系统设置的 \(systemValue)% 对不上——多半又拿错了分子字段"
        )
    }
}
