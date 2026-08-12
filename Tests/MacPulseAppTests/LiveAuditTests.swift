import XCTest
@testable import MacPulse
@testable import MacPulseCore

/// 真机对账：每个读数都拿一个**独立的系统工具**当真值。
///
/// 原则：不许自己对自己。MemoryBreakdown 对 `vm_stat`，每核 CPU 对聚合值，
/// 背光对 `ioreg`，ANE 持有者对 `ioreg`。实现和真值走不同代码路径，
/// 对上了才说明实现是对的。
final class LiveAuditTests: XCTestCase {
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

    // MARK: - 内存 vs vm_stat

    /// 我们的内存分项和手工解析 `vm_stat` 必须给出同样的结果。
    /// 两次读取相隔几十毫秒，内存在动，给 3% 容差。
    func testMemoryBreakdownAgreesWithVmStat() throws {
        let reader = SystemFallbackReader()
        guard let breakdown = reader.memoryBreakdown() else {
            throw XCTSkip("本机读不到 vm 统计")
        }
        let vmstat = shell("vm_stat")

        func pages(_ label: String) -> UInt64? {
            for line in vmstat.split(separator: "\n") where line.contains(label) {
                let digits = line.split(separator: ":").last?
                    .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
                return digits.flatMap { UInt64($0) }
            }
            return nil
        }

        let page: UInt64 = 16_384
        let anonymous = try XCTUnwrap(pages("Anonymous pages"))
        let purgeable = try XCTUnwrap(pages("Pages purgeable"))
        let wired = try XCTUnwrap(pages("Pages wired down"))
        let compressed = try XCTUnwrap(pages("Pages occupied by compressor"))
        let fileBacked = try XCTUnwrap(pages("File-backed pages"))

        let expectedApp = (anonymous - min(anonymous, purgeable)) * page
        let expectedUsed = expectedApp + wired * page + compressed * page
        let expectedCached = (fileBacked + purgeable) * page

        func assertClose(_ actual: UInt64, _ expected: UInt64, _ label: String) {
            let tolerance = Double(max(expected, 1)) * 0.03 + 64 * 1_048_576
            XCTAssertEqual(
                Double(actual), Double(expected), accuracy: tolerance,
                "\(label): 实现 \(actual / 1_048_576)MB vs vm_stat \(expected / 1_048_576)MB"
            )
        }
        assertClose(breakdown.appBytes, expectedApp, "应用内存")
        assertClose(breakdown.usedBytes, expectedUsed, "已使用")
        assertClose(breakdown.cachedFilesBytes, expectedCached, "缓存文件")

        // 压力等级要与 sysctl 一致（同一瞬间读，等级不会抖）。
        let sysctlLevel = shell("sysctl -n kern.memorystatus_vm_pressure_level").trimmingCharacters(in: .whitespacesAndNewlines)
        if let level = Int(sysctlLevel) {
            XCTAssertEqual(breakdown.pressureLevel.rawValue, level)
        }
    }

    // MARK: - 每核 CPU vs 聚合值

    /// 各核占用的平均值必须与聚合 CPU 占用一致——两者来自内核的同一套
    /// tick 计数，只是分组不同。对不上说明每核解析在胡说。
    func testPerCoreAverageMatchesAggregateCPU() async throws {
        let reader = SystemFallbackReader()
        // 第一次调用建基线
        _ = reader.read()
        _ = reader.perCoreUsage()
        try await Task.sleep(for: .seconds(2))

        let aggregate = reader.read().cpuUsagePercent
        guard let perCore = reader.perCoreUsage(), !perCore.isEmpty else {
            throw XCTSkip("本机读不到每核数据")
        }
        let mean = perCore.reduce(0, +) / Double(perCore.count)

        let total = try XCTUnwrap(aggregate)
        XCTAssertEqual(mean, total, accuracy: max(5, total * 0.35),
                       "每核平均 \(mean) vs 聚合 \(total)：分组不同但总量必须一致")
        // 核数要和硬件一致。
        let coreCount = Int(shell("sysctl -n hw.ncpu").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        XCTAssertEqual(perCore.count, coreCount)
        // 每核值必须在 0–100。
        for value in perCore {
            XCTAssertGreaterThanOrEqual(value, 0)
            XCTAssertLessThanOrEqual(value, 100.5)
        }
    }

    // MARK: - 背光 vs ioreg

    func testBacklightAgreesWithIORegistry() throws {
        let reader = DisplayBacklightReader()
        guard let sample = reader.read() else {
            throw XCTSkip("本机读不到背光")
        }
        let raw = shell(#"ioreg -c AppleARMBacklight -r -d1 -w0 | grep -oE '"brightness"=\{[^}]*\}'"#)
        guard let valueRange = raw.range(of: #""value"=(\d+)"#, options: .regularExpression),
              let maxRange = raw.range(of: #""max"=(\d+)"#, options: .regularExpression)
        else { throw XCTSkip("ioreg 输出格式变了") }

        let value = Double(raw[valueRange].split(separator: "=").last ?? "0") ?? 0
        let maximum = Double(raw[maxRange].split(separator: "=").last ?? "1") ?? 1
        let expected = value / maximum

        let actual = try XCTUnwrap(sample.brightnessFraction)
        // 用户可能在两次读取之间调亮度，容差放宽到 10 个百分点。
        XCTAssertEqual(actual, expected, accuracy: 0.10,
                       "背光比例：实现 \(actual) vs ioreg \(expected)")

        if let microAmps = sample.microAmps {
            XCTAssertGreaterThan(microAmps, 0)
            XCTAssertLessThan(microAmps, 100_000, "背光电流超过 100mA 说明单位解析错了")
        }
    }

    // MARK: - ANE 持有者 vs ioreg

    func testANEHoldersMatchIORegistryListing() throws {
        let reader = ANEClientReader()
        guard let pids = reader.activeClientPIDs() else {
            throw XCTSkip("本机读不到 ANE 驱动")
        }
        let listing = shell(#"ioreg -rc H1xANELoadBalancerDirectPathClient -w0 | grep -oE 'pid [0-9]+'"#)
        let expected = Set(
            listing.split(separator: "\n")
                .compactMap { Int32($0.dropFirst(4)) }
        )
        // 两次枚举之间可能有 App 打开/关闭会话，允许一个成员的差异。
        let difference = pids.symmetricDifference(expected)
        XCTAssertLessThanOrEqual(difference.count, 1,
                                 "实现 \(pids.sorted()) vs ioreg \(expected.sorted())")
    }
}
