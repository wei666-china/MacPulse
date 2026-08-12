import Foundation
import XCTest
@testable import MacPulseCore

/// 热节流判据。数字取自本机 M5:性能集群最高 3808 MHz(pmgr voltage-states5-sram)。
final class ThrottleDiagnosisTests: XCTestCase {

    private func input(
        active: Double? = 80,
        freq: Int? = 3800,
        maxFreq: Int? = 3808,
        temp: Double? = 60,
        thermal: ThermalLevel = .nominal,
        lowPower: Bool = false,
        onBattery: Bool = false
    ) -> ThrottleDiagnosis.Input {
        .init(
            clusterActivePercent: active,
            clusterFreqMHz: freq,
            clusterMaxFreqMHz: maxFreq,
            hotspotTemperature: temp,
            thermalLevel: thermal,
            lowPowerModeEnabled: lowPower,
            onBattery: onBattery
        )
    }

    func testMissingInputsYieldNoVerdict() {
        XCTAssertNil(ThrottleDiagnosis.diagnose(input(active: nil)), "读不到活跃度就不下结论")
        XCTAssertNil(ThrottleDiagnosis.diagnose(input(freq: nil)))
        XCTAssertNil(ThrottleDiagnosis.diagnose(input(maxFreq: nil)))
        XCTAssertNil(ThrottleDiagnosis.diagnose(input(maxFreq: 0)), "最高频为 0 时比例无意义")
    }

    /// 回归:本机实测样本(编译中,P 集群 73% 活跃 / 3082 MHz / 上限 4464 / 61°C)。
    /// 初版阈值把这判成「功耗墙限速」——纯误报,突发负载的平均频率天然偏低。
    func testRealCompileLoadIsNotThrottling() throws {
        let verdict = try XCTUnwrap(ThrottleDiagnosis.diagnose(
            input(active: 73, freq: 3082, maxFreq: 4464, temp: 61.9)
        ))
        XCTAssertEqual(verdict.kind, .fullSpeed, "普通编译负载不能报成被限速")
        XCTAssertFalse(verdict.isWarning)
    }

    func testIdleIsNotThrottling() throws {
        // 空闲时低频是省电,不是被限制——这是最容易误报的一类。
        let verdict = try XCTUnwrap(ThrottleDiagnosis.diagnose(input(active: 8, freq: 1200)))
        XCTAssertEqual(verdict.kind, .idle)
        XCTAssertFalse(verdict.isWarning)
    }

    func testFullSpeedUnderLoad() throws {
        let verdict = try XCTUnwrap(ThrottleDiagnosis.diagnose(input(active: 95, freq: 3800)))
        XCTAssertEqual(verdict.kind, .fullSpeed)
        XCTAssertFalse(verdict.isWarning)
    }

    func testThermalThrottleWhenHot() throws {
        // 满载 + 频率掉到六成 + 96°C = 热降频。
        let verdict = try XCTUnwrap(ThrottleDiagnosis.diagnose(
            input(active: 92, freq: 2280, temp: 96)
        ))
        XCTAssertEqual(verdict.kind, .thermal)
        XCTAssertTrue(verdict.isWarning)
        XCTAssertEqual(try XCTUnwrap(verdict.frequencyHeadroomPercent), 59.9, accuracy: 0.5)
    }

    func testThermalLevelAloneTriggersThermal() throws {
        // 温度读不到但系统报了热压力,同样算热降频。
        let verdict = try XCTUnwrap(ThrottleDiagnosis.diagnose(
            input(active: 90, freq: 2000, temp: nil, thermal: .serious)
        ))
        XCTAssertEqual(verdict.kind, .thermal)
    }

    func testLowPowerModeBeatsPowerLimit() throws {
        // 不热但开着低电量模式:是用户自己选的,不该报成故障。
        let verdict = try XCTUnwrap(ThrottleDiagnosis.diagnose(
            input(active: 90, freq: 1800, temp: 55, lowPower: true)
        ))
        XCTAssertEqual(verdict.kind, .lowPowerMode)
        XCTAssertFalse(verdict.isWarning, "用户主动省电不是警告")
    }

    /// 功耗墙要「又满载又跑不动」才成立:90% 活跃 + 47% 频率。
    func testPowerLimitNeedsExtremeEvidence() throws {
        let verdict = try XCTUnwrap(ThrottleDiagnosis.diagnose(
            input(active: 90, freq: 1800, temp: 55, onBattery: true)
        ))
        XCTAssertEqual(verdict.kind, .powerLimit)
        XCTAssertTrue(verdict.isWarning)
        XCTAssertTrue(verdict.detail.contains("电池"), "电池供电时应点明插电可缓解")
    }

    func testBusyThresholdBoundary() throws {
        // 70% 是忙线门槛:门槛下一律按空闲,不参与受限判定。
        let below = try XCTUnwrap(ThrottleDiagnosis.diagnose(input(active: 69, freq: 1500, temp: 95)))
        XCTAssertEqual(below.kind, .idle, "没在忙就不能说被限速,哪怕机器热")
        let above = try XCTUnwrap(ThrottleDiagnosis.diagnose(input(active: 71, freq: 1500, temp: 95)))
        XCTAssertEqual(above.kind, .thermal)
    }

    func testFullSpeedRatioBoundary() throws {
        // 70% 是满速门槛,给加权平均的天然折损留足余量。
        let at72 = try XCTUnwrap(ThrottleDiagnosis.diagnose(input(active: 90, freq: 2750)))
        XCTAssertEqual(at72.kind, .fullSpeed, "2750/3808 = 72%,算跑满")
        let at60 = try XCTUnwrap(ThrottleDiagnosis.diagnose(input(active: 90, freq: 2285, temp: 95)))
        XCTAssertEqual(at60.kind, .thermal, "热证据独立成立")
    }

    /// 没有热证据、也没到极端:一律不下「被限速」的结论。
    func testNoEvidenceMeansNoAccusation() throws {
        let verdict = try XCTUnwrap(ThrottleDiagnosis.diagnose(
            input(active: 75, freq: 2400, temp: 60)
        ))
        XCTAssertEqual(verdict.kind, .fullSpeed, "63% 频率但只有 75% 负载,证据不足以指控")
        XCTAssertFalse(verdict.isWarning)
    }
}

/// 启动项名称推断(纯字符串逻辑)。
final class LoginItemNamingTests: XCTestCase {
    func testFriendlyNameFromLabel() {
        // 反射式验证放在 App 测试里;这里只固定规则本身的期望,
        // 与 LoginItemsReader.friendlyName 的实现保持同一约定。
        func friendly(_ label: String) -> String {
            let parts = label.split(separator: ".")
            guard parts.count >= 3 else { return label }
            let tail = parts.dropFirst(2)
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
            return tail.isEmpty ? label : tail
        }
        XCTAssertEqual(friendly("com.microsoft.teams2.agent"), "Teams2 Agent")
        XCTAssertEqual(friendly("com.deskin.session"), "Session")
        XCTAssertEqual(friendly("shortlabel"), "shortlabel", "推不出好名字就用原标签")
    }
}
