import Foundation
import XCTest
@testable import MacPulseCore

/// 睡眠日志解析与判定。样本行的格式**逐字**照抄本机 `pmset -g log`:
/// 时间戳 + 时区 + 定宽事件类型列 + 制表符 + 描述。
/// 初版解析器就栽在这个定宽列上(以为类型在制表符之后),0 段都还原不出来。
final class SleepLogParserTests: XCTestCase {

    /// 真实格式:注意 "Sleep" 后面是空格补位再接制表符。
    private func line(_ time: String, _ type: String, _ desc: String) -> String {
        let padded = type.padding(toLength: max(type.count, 20), withPad: " ", startingAt: 0)
        return "\(time) +1000 \(padded)\t\(desc)"
    }

    func testParsesRealFormatSession() throws {
        let lines = [
            line("2026-08-12 01:00:00", "Sleep", "Entering Sleep state due to 'Clamshell Sleep':TCPKeepAlive=active Using Batt (Charge:90%) 12 secs"),
            line("2026-08-12 02:00:00", "DarkWake", "DarkWake from Deep Idle [CDNP] : due to smc.sysState.Wake(0x70070000) wifibt SMC.OutboxNotEmpty"),
            line("2026-08-12 03:00:00", "DarkWake", "DarkWake from Deep Idle [CDNP] : due to smc.sysState.Wake(0x70070000) wifibt SMC.OutboxNotEmpty"),
            line("2026-08-12 09:00:00", "Wake", "DarkWake to FullWake from Deep Idle [CDNVA] : due to HID Activity Using Batt (Charge:62%)")
        ]
        let sessions = SleepLogParser.parse(lines: lines)
        let session = try XCTUnwrap(sessions.first, "定宽事件类型列必须解析得出")
        XCTAssertEqual(session.startPercent, 90)
        XCTAssertEqual(session.endPercent, 62)
        XCTAssertEqual(session.droppedPercent, 28)
        XCTAssertEqual(session.hours, 8, accuracy: 0.01)
        XCTAssertEqual(session.darkWakeCount, 2)
        XCTAssertTrue(session.onBattery)
        XCTAssertEqual(session.wakeReasons["网络与蓝牙"], 2, "唤醒原因要归成人话")
        XCTAssertEqual(session.drainPerHour, 3.5, accuracy: 0.01)
    }

    func testShortNapsAreIgnored() {
        let lines = [
            line("2026-08-12 01:00:00", "Sleep", "Entering Sleep state due to 'Maintenance Sleep':TCPKeepAlive=active Using Batt (Charge:90%) 12 secs"),
            line("2026-08-12 01:10:00", "Wake", "Wake from Deep Idle : due to HID Activity Using Batt (Charge:89%)")
        ]
        XCTAssertTrue(SleepLogParser.parse(lines: lines).isEmpty, "十分钟小憩的掉电噪声太大,不入账")
    }

    func testSessionWithoutChargeIsDropped() {
        let lines = [
            line("2026-08-12 01:00:00", "Sleep", "Entering Sleep state due to 'Clamshell Sleep' Using Batt"),
            line("2026-08-12 09:00:00", "Wake", "Wake : due to HID Activity Using Batt (Charge:62%)")
        ]
        XCTAssertTrue(SleepLogParser.parse(lines: lines).isEmpty, "读不到入睡电量就不能算掉电")
    }

    func testReasonClassification() {
        XCTAssertEqual(SleepLogParser.classifyReason("due to HID Activity"), "你的操作")
        XCTAssertEqual(SleepLogParser.classifyReason("due to smc.sysState.Wake(0x1) wifibt SMC.Outbox"), "网络与蓝牙")
        XCTAssertEqual(SleepLogParser.classifyReason("due to smc.sysState.Wake(0x1) USB-C_plug"), "USB-C 插拔")
        XCTAssertEqual(SleepLogParser.classifyReason("due to something.unknown"), "其他", "认不出就说其他,不硬归类")
    }

    func testPercentExtraction() {
        XCTAssertEqual(SleepLogParser.percentValue(in: "Using Batt (Charge:93%)"), 93)
        XCTAssertEqual(SleepLogParser.percentValue(in: "Charge: 7%"), 7)
        XCTAssertNil(SleepLogParser.percentValue(in: "no charge here"))
    }
}

final class SleepDiagnosisTests: XCTestCase {

    private func session(
        hours: Double, dropped: Int, wakes: Int,
        onBattery: Bool = true, reasons: [String: Int] = ["网络与蓝牙": 1]
    ) -> SleepSession {
        let start = Date(timeIntervalSince1970: 1_000_000)
        return SleepSession(
            start: start,
            end: start.addingTimeInterval(hours * 3600),
            startPercent: 90,
            endPercent: 90 - dropped,
            darkWakeCount: wakes,
            wakeReasons: reasons,
            onBattery: onBattery
        )
    }

    func testHealthyOvernight() {
        // 睡 8 小时掉 8%(1%/h)= 正常待机。
        let verdict = SleepDiagnosis.diagnose(session(hours: 8, dropped: 8, wakes: 10))
        XCTAssertEqual(verdict.kind, .healthy)
        XCTAssertFalse(verdict.isWarning)
    }

    func testTooManyWakesNeedsBothSignals() {
        // 掉电快 + 唤醒多 → 归因到唤醒,并点名最大来源。
        let verdict = SleepDiagnosis.diagnose(
            session(hours: 8, dropped: 32, wakes: 400, reasons: ["网络与蓝牙": 380, "定时唤醒": 20])
        )
        XCTAssertEqual(verdict.kind, .tooManyWakes)
        XCTAssertTrue(verdict.isWarning)
        XCTAssertTrue(verdict.detail.contains("网络与蓝牙"), "要点名最大来源")
    }

    func testFastDrainWithFewWakesIsNotBlamedOnWakes() {
        // 掉电快但没怎么被吵醒:不能赖唤醒,如实说耗电在别处。
        let verdict = SleepDiagnosis.diagnose(session(hours: 8, dropped: 32, wakes: 3))
        XCTAssertEqual(verdict.kind, .fastDrain)
        XCTAssertTrue(verdict.detail.contains("不在唤醒上"))
    }

    func testOnPowerSessionIsMeaningless() {
        let verdict = SleepDiagnosis.diagnose(session(hours: 8, dropped: 0, wakes: 500, onBattery: false))
        XCTAssertEqual(verdict.kind, .onPower)
        XCTAssertFalse(verdict.isWarning, "接电睡眠不是故障")
    }

    func testDrainThresholdBoundary() {
        // 1.5%/h 是健康线。
        let ok = SleepDiagnosis.diagnose(session(hours: 10, dropped: 15, wakes: 5))
        XCTAssertEqual(ok.kind, .healthy, "正好 1.5%/h 算正常")
        let bad = SleepDiagnosis.diagnose(session(hours: 10, dropped: 20, wakes: 5))
        XCTAssertEqual(bad.kind, .fastDrain, "2%/h 超线")
    }
}
