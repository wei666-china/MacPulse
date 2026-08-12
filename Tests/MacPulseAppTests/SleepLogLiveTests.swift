import XCTest
@testable import MacPulse
@testable import MacPulseCore

/// 睡眠日志真机对账。解析规则的单元测试在 Core 里用固定样本跑;
/// 这里验的是**在这台机器的真实日志上**解出来的东西是否自洽——
/// 格式一旦随系统版本变化,这条会先炸。
final class SleepLogLiveTests: XCTestCase {

    func testRealLogYieldsPlausibleSessions() async throws {
        let sessions = await SleepLogReader().sessions()
        guard !sessions.isEmpty else {
            throw XCTSkip("本机近 14 天没有满 30 分钟的睡眠记录")
        }

        for session in sessions {
            XCTAssertTrue((0...100).contains(session.startPercent), "入睡电量越界:\(session.startPercent)")
            XCTAssertTrue((0...100).contains(session.endPercent), "醒来电量越界:\(session.endPercent)")
            XCTAssertGreaterThan(session.hours, 0.49, "不足 30 分钟的段不该入账")
            XCTAssertGreaterThan(session.end, session.start, "醒来必须晚于入睡")
            if session.onBattery {
                // 电池上睡觉不可能越睡越满。允许 1% 的电量计回弹。
                XCTAssertGreaterThanOrEqual(
                    session.droppedPercent, -1,
                    "电池睡眠不该涨电:\(session.startPercent)% → \(session.endPercent)%"
                )
                // 一小时掉 40% 以上不是待机,是没睡着——那说明解析配错了对。
                XCTAssertLessThan(session.drainPerHour, 40, "掉电率离谱,疑似配错了睡眠/唤醒对")
            }
            XCTAssertGreaterThanOrEqual(session.darkWakeCount, 0)
            XCTAssertEqual(
                session.wakeReasons.values.reduce(0, +), session.darkWakeCount,
                "唤醒原因计数之和必须等于唤醒总次数"
            )
        }
    }

    /// 判定不能对真实数据崩,且每段都要给得出一句结论。
    func testEveryRealSessionGetsAVerdict() async throws {
        let sessions = await SleepLogReader().sessions()
        guard !sessions.isEmpty else { throw XCTSkip("无睡眠记录") }
        for session in sessions {
            let verdict = SleepDiagnosis.diagnose(session)
            XCTAssertFalse(verdict.summary.isEmpty)
            XCTAssertFalse(verdict.detail.isEmpty)
            if !session.onBattery {
                XCTAssertEqual(verdict.kind, .onPower, "接电睡眠一律不作掉电结论")
            }
        }
    }
}
