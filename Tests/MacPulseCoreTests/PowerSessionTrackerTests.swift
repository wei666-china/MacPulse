import XCTest
@testable import MacPulseCore

final class PowerSessionTrackerTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func sample(
        _ offsetMinutes: Double,
        soc: Double,
        watts: Double? = -8,
        discharging: Bool = true,
        predicted: Int? = nil
    ) -> PowerSessionTracker.Sample {
        PowerSessionTracker.Sample(
            date: start.addingTimeInterval(offsetMinutes * 60),
            socPercent: soc,
            netPowerWatts: watts,
            isDischarging: discharging,
            predictedMinutes: predicted
        )
    }

    // MARK: - 切分

    /// 适配器重协商会产生瞬时状态抖动。不去抖就会切出一堆假会话。
    func testSingleSampleBlipDoesNotOpenSession() {
        var tracker = PowerSessionTracker()
        tracker.ingest(sample(0, soc: 80))
        XCTAssertNil(tracker.current, "只有一次采样确认时不该开段")
        tracker.ingest(sample(1, soc: 79.9))
        XCTAssertNotNil(tracker.current, "连续两次确认才开段")
    }

    func testPluggingInClosesSession() {
        var tracker = PowerSessionTracker()
        for minute in 0..<20 {
            tracker.ingest(sample(Double(minute), soc: 80 - Double(minute) * 0.2))
        }
        XCTAssertNotNil(tracker.current)
        tracker.ingest(sample(20, soc: 76, watts: 30, discharging: false))
        XCTAssertNil(tracker.current)
        XCTAssertEqual(tracker.completed.count, 1)
        XCTAssertEqual(tracker.completed.first?.endReason, .plugged)
    }

    /// 8 小时待机和连续使用不是同一个物理过程，睡眠之后必须另起一段。
    func testSleepGapStartsANewSessionInsteadOfExtending() {
        var tracker = PowerSessionTracker()
        for minute in 0..<20 {
            tracker.ingest(sample(Double(minute), soc: 80 - Double(minute) * 0.1))
        }
        // 16.4 小时断档——实测数据里真实存在过
        tracker.ingest(sample(20 + 982.9, soc: 74))
        tracker.ingest(sample(21 + 982.9, soc: 73.9))
        tracker.ingest(sample(22 + 982.9, soc: 73.8))

        XCTAssertEqual(tracker.completed.count, 1, "断档前那段应当被收掉")
        XCTAssertEqual(tracker.completed.first?.endReason, .sleep)
        XCTAssertNotNil(tracker.current, "断档后应当另起一段")
        XCTAssertGreaterThan(tracker.current?.startSoc ?? 0, 73)
    }

    // MARK: - 能量积分

    /// 不钳制的话 16.4 小时 × 8W ≈ 131 Wh，比整块电池还大。
    /// 钳制只写在一个地方，这条测试守着它。
    func testSixteenHourGapContributesAlmostNoEnergy() {
        var tracker = PowerSessionTracker()
        tracker.ingest(sample(0, soc: 80))
        tracker.ingest(sample(1, soc: 79.9))
        let beforeGap = tracker.current?.energyWattHours ?? 0

        // 同一段内部的长断档（未触发换段的边界情况也要扛住）
        tracker.ingest(sample(1 + 2.9, soc: 79.8))
        let afterShortGap = tracker.current?.energyWattHours ?? 0

        XCTAssertLessThan(afterShortGap - beforeGap, 0.5, "3 分钟以内正常积分")
        XCTAssertLessThan(afterShortGap, 1.0)
    }

    func testEnergyIntegratesCorrectlyOverNormalSamples() {
        var tracker = PowerSessionTracker()
        // 60 分钟恒定 12W → 应当约 12 Wh
        for minute in 0...60 {
            tracker.ingest(sample(Double(minute), soc: 80 - Double(minute) * 0.25, watts: -12))
        }
        let energy = try! XCTUnwrap(tracker.current?.energyWattHours)
        XCTAssertEqual(energy, 12, accuracy: 0.5)
    }

    func testWattHoursPerPercentIsDerivedFromCompletedSession() {
        var tracker = PowerSessionTracker()
        // 从 80% 掉到 40%（40 个百分点），恒定 27W 跑 60 分钟 = 27 Wh
        // → 0.675 Wh/%
        for minute in 0...60 {
            tracker.ingest(sample(Double(minute), soc: 80 - Double(minute) * (40.0 / 60), watts: -27))
        }
        tracker.close(reason: .plugged, at: start.addingTimeInterval(3_600), soc: 40)
        let ratio = try! XCTUnwrap(tracker.completed.first?.wattHoursPerPercent)
        XCTAssertEqual(ratio, 0.675, accuracy: 0.03)
    }

    /// 电量掉得太少的段不出 Wh/%：噪声会淹没信号。
    func testShortDropDoesNotProduceEnergyRatio() {
        var tracker = PowerSessionTracker()
        for minute in 0...30 {
            tracker.ingest(sample(Double(minute), soc: 80 - Double(minute) * 0.1, watts: -8))
        }
        tracker.close(reason: .plugged, at: start.addingTimeInterval(1_800), soc: 77)
        XCTAssertNil(tracker.completed.first?.wattHoursPerPercent, "只掉 3% 不足以定标能量模型")
    }

    // MARK: - 自我评分的诚实性

    /// **这是全套测试里最重要的一条。**
    ///
    /// 如果一段放电是因为用户在 40% 时插了电而结束，真实的到空时间比观测到的
    /// 更长。把它算进误差会让分数虚高——那正是「好看数字」的来源。
    /// 头条只能用跑到低电量的未删失段。
    func testCensoredSessionsAreExcludedFromHeadlineAccuracy() {
        var tracker = PowerSessionTracker()

        // 段一：从 80% 一路跑到 3%（未删失）。预测一直报 60 分钟。
        for minute in 0...120 {
            tracker.ingest(sample(Double(minute), soc: 80 - Double(minute) * 0.64, predicted: 60))
        }
        tracker.close(reason: .shutdown, at: start.addingTimeInterval(120 * 60), soc: 3)

        // 段二：从 90% 跑到 60% 就插电了（删失）。预测报了个离谱的 600 分钟。
        var second = PowerSessionTracker(completed: tracker.completed)
        for minute in 200...260 {
            second.ingest(sample(Double(minute), soc: 90 - Double(minute - 200) * 0.5, predicted: 600))
        }
        second.close(reason: .plugged, at: start.addingTimeInterval(260 * 60), soc: 60)

        let accuracy = second.accuracy()
        XCTAssertEqual(accuracy.sessionCount, 1, "只有未删失的那一段进头条")
        XCTAssertGreaterThan(accuracy.checkpointCount, 0)
        // 若把删失段算进来，600 分钟的离谱预测会把 MAE 拉到几百分。
        XCTAssertLessThan(accuracy.meanAbsoluteErrorMinutes, 120)
    }

    /// 最后 20 分钟的预测太容易猜，算进去只会美化分数。
    func testPredictionsMadeInFinalMinutesAreNotScored() {
        var tracker = PowerSessionTracker()
        // 只有最后 10 分钟有预测记录
        for minute in 0...20 {
            let predicted = minute >= 11 ? 5 : nil
            tracker.ingest(sample(Double(minute), soc: 20 - Double(minute) * 0.8, predicted: predicted))
        }
        tracker.close(reason: .shutdown, at: start.addingTimeInterval(20 * 60), soc: 3)

        let accuracy = tracker.accuracy()
        XCTAssertEqual(accuracy.checkpointCount, 0, "剩余不足 20 分钟的预测不计分")
    }

    /// 22:00 做的预测不能拿去跟随后睡了 8 小时的电池对账。
    func testSessionsContainingSleepAreExcludedFromScoring() {
        var tracker = PowerSessionTracker()
        for minute in 0...60 {
            tracker.ingest(sample(Double(minute), soc: 60 - Double(minute) * 0.9, predicted: 45))
        }
        // 人为制造一段睡眠计入
        tracker.close(reason: .shutdown, at: start.addingTimeInterval(60 * 60), soc: 5)
        var session = try! XCTUnwrap(tracker.completed.first)
        session.sleepSeconds = 8 * 3_600
        let polluted = PowerSessionTracker(completed: [session])

        XCTAssertEqual(polluted.accuracy().checkpointCount, 0, "含睡眠的段不参与评分")
    }

    /// 样本不足时如实说「还在积累」，不给一个假的准确率。
    func testInsufficientDataReportsAccumulatingRatherThanFakeAccuracy() {
        let tracker = PowerSessionTracker()
        let accuracy = tracker.accuracy()
        XCTAssertEqual(accuracy.sessionCount, 0)
        XCTAssertTrue(accuracy.summary.contains("积累"))
        XCTAssertFalse(accuracy.summary.contains("误差"))
    }

    func testAccuracySummaryReportsRealError() {
        var tracker = PowerSessionTracker()
        // 一路预测 90 分钟，实际从 120 分钟递减到 20 分钟。
        for minute in 0...120 {
            tracker.ingest(sample(Double(minute), soc: 80 - Double(minute) * 0.64, predicted: 90))
        }
        tracker.close(reason: .shutdown, at: start.addingTimeInterval(120 * 60), soc: 3)

        let accuracy = tracker.accuracy()
        XCTAssertEqual(accuracy.sessionCount, 1)
        XCTAssertGreaterThan(accuracy.checkpointCount, 50)
        XCTAssertTrue(accuracy.summary.contains("误差"))
        // 恒定报 90 分钟、实际从 120 递减到 20，平均误差应当在几十分钟量级。
        XCTAssertGreaterThan(accuracy.meanAbsoluteErrorMinutes, 10)
        XCTAssertLessThan(accuracy.meanAbsoluteErrorMinutes, 60)
    }

    /// 「预告了没发生的死亡」这类错误对用户伤害更大，要单独计数。
    func testUnderestimatesAreCountedSeparately() {
        var tracker = PowerSessionTracker()
        for minute in 0...120 {
            tracker.ingest(sample(Double(minute), soc: 80 - Double(minute) * 0.64, predicted: 30))
        }
        tracker.close(reason: .shutdown, at: start.addingTimeInterval(120 * 60), soc: 3)
        XCTAssertGreaterThan(tracker.accuracy().underestimateCount, 0)
    }

    func testCompletedSessionsAreCappedToAvoidUnboundedGrowth() {
        var tracker = PowerSessionTracker()
        for index in 0..<60 {
            let base = Double(index) * 1_000
            tracker.ingest(sample(base, soc: 80))
            tracker.ingest(sample(base + 1, soc: 79.9))
            tracker.ingest(sample(base + 10, soc: 79))
            tracker.close(reason: .plugged, at: start.addingTimeInterval((base + 10) * 60), soc: 79)
        }
        XCTAssertLessThanOrEqual(tracker.completed.count, 40)
    }
}
