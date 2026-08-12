import XCTest
@testable import MacPulseCore

final class RuntimeEstimatorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// 本机实测的铭牌能量：5582 mAh × 11.31 V ≈ 63.1 Wh → 0.631 Wh/%。
    /// 但 7 段长放电积分出来是 67.3 Wh/100%，所以学习值是 0.673。
    private let nameplateWhPerPercent = 0.631
    private let learnedWhPerPercent = 0.673

    private func maturedProfile() -> DrainProfile {
        var profile = DrainProfile.shippingPrior()
        // 让 12–25% CPU / 中等亮度这个桶成熟到足以参与融合。
        let context = UsageContext(cpuBand: .moderate, displayBand: .medium, lowPowerMode: false)
        for _ in 0..<200 {
            profile.record(watts: 7.45, context: context, at: now)
        }
        return profile
    }

    // MARK: - 核心：干掉那个 20 小时

    /// 完整复现触发这次改造的场景。
    ///
    /// 实测原始数据：电量 40%、净功率 −7.2W、`IOPSGetTimeRemainingEstimate`
    /// 返回 1200 分（20:00，掉了 1% 都不动），而同一个字典里
    /// `AvgTimeToEmpty` = 176 分。真实答案约 2.5–3 小时。
    func testReproducesTheTwentyHourLieAndRejectsIt() {
        var estimator = RuntimeEstimator()
        let profile = maturedProfile()
        let input = RuntimeEstimatorInput(
            socFinePercent: 36.6, // 2042 / 5582
            wattHoursPerPercent: learnedWhPerPercent,
            netPowerWatts: -7.23,
            gaugeMinutes: 176,
            systemEstimateMinutes: 1_200,
            context: UsageContext(cpuBand: .moderate, displayBand: .medium, lowPowerMode: false),
            isCharging: false,
            now: now,
            recentSocDropPercent: 2.5,
            recentWindowMinutes: 15
        )

        let estimate = estimator.update(input, profile: profile)
        let minutes = try! XCTUnwrap(estimate.minutes)

        // 真实答案约 150–200 分钟。
        XCTAssertGreaterThan(minutes, 100, "不该低估到离谱")
        XCTAssertLessThan(minutes, 260, "更不该给出 20 小时")
        XCTAssertLessThan(minutes, 1_200 / 4, "必须远离系统给的饱和值")

        // 系统值被明确拒绝，并且记录下来供界面解释「为什么和系统不一样」。
        XCTAssertTrue(estimate.rejectedSystemEstimate)
        XCTAssertEqual(estimate.systemEstimateMinutes, 1_200)
        // 系统值绝不能混进候选里参与融合。
        XCTAssertNil(estimate.candidates[.blended])
        XCTAssertEqual(estimate.candidates[.gauge], 176)
    }

    /// 即使**没有**计量芯片读数、**也没有**学到的档案，光靠「观测斜率一致性」
    /// 这一条纯观测钳制也足以否掉 1200。这是最后一道防线。
    func testObservedSlopeAloneKillsSaturatedValue() {
        var estimator = RuntimeEstimator()
        let input = RuntimeEstimatorInput(
            socFinePercent: 34,
            wattHoursPerPercent: learnedWhPerPercent,
            netPowerWatts: -10.85,
            gaugeMinutes: nil,
            systemEstimateMinutes: 1_200,
            context: UsageContext(cpuBand: .moderate, displayBand: .medium, lowPowerMode: false),
            isCharging: false,
            now: now,
            // 15 分钟掉了 2.5% → 隐含约 186 分钟 → 上限 558 分
            recentSocDropPercent: 2.5,
            recentWindowMinutes: 15
        )
        let estimate = estimator.update(input, profile: DrainProfile())
        let minutes = try! XCTUnwrap(estimate.minutes)
        XCTAssertLessThan(minutes, 558)
        XCTAssertLessThan(minutes, 300, "实测功耗本身就指向约 3 小时")
    }

    /// 计量芯片的 65535 是「未知」哨兵，不是 45 天。
    func testGaugeSentinelIsTreatedAsUnknown() {
        var estimator = RuntimeEstimator()
        let input = RuntimeEstimatorInput(
            socFinePercent: 80,
            wattHoursPerPercent: learnedWhPerPercent,
            netPowerWatts: -8,
            gaugeMinutes: 65_535,
            systemEstimateMinutes: nil,
            context: UsageContext(cpuBand: .light, displayBand: .medium, lowPowerMode: false),
            isCharging: false,
            now: now
        )
        let estimate = estimator.update(input, profile: maturedProfile())
        XCTAssertNil(estimate.candidates[.gauge], "65535 必须被当成未知丢掉")
        XCTAssertNotNil(estimate.minutes, "丢掉哨兵之后仍应给得出估计")
    }

    // MARK: - 融合方式

    /// 必须在瓦特空间融合。时间是速率的倒数，对分钟数取平均会过度加权
    /// 最长的那个估计——这正是「一个离谱的大数字把结果拖高」的机制。
    func testBlendingHappensInWattSpaceNotTimeSpace() {
        var estimator = RuntimeEstimator()
        var profile = DrainProfile()
        let context = UsageContext(cpuBand: .idle, displayBand: .low, lowPowerMode: false)
        for _ in 0..<200 { profile.record(watts: 2.0, context: context, at: now) }

        let input = RuntimeEstimatorInput(
            socFinePercent: 50,
            wattHoursPerPercent: 0.673,
            netPowerWatts: -10.0,
            gaugeMinutes: nil,
            systemEstimateMinutes: nil,
            context: context,
            isCharging: false,
            now: now
        )
        let estimate = estimator.update(input, profile: profile)
        let minutes = try! XCTUnwrap(estimate.minutes)

        let usableWh = (50 - 3) * 0.673
        let timeSpaceAverage = (usableWh * 60 / 10.0 + usableWh * 60 / 2.0) / 2  // 错误做法
        let wattSpaceExpected = usableWh * 60 / ((10.0 + 2.0) / 2)               // 正确做法

        XCTAssertLessThan(
            abs(Double(minutes) - wattSpaceExpected),
            abs(Double(minutes) - timeSpaceAverage),
            "结果应当更接近瓦特空间融合"
        )
    }

    /// 三个来源分歧过大时降为低置信度并给区间，而不是硬报一个点值。
    func testWideDisagreementDowngradesToRange() {
        var estimator = RuntimeEstimator()
        let input = RuntimeEstimatorInput(
            socFinePercent: 60,
            wattHoursPerPercent: 0.673,
            netPowerWatts: -3.0,
            gaugeMinutes: 90, // 与实测功耗严重不符
            systemEstimateMinutes: nil,
            context: UsageContext(cpuBand: .intense, displayBand: .high, lowPowerMode: false),
            isCharging: false,
            now: now
        )
        let estimate = estimator.update(input, profile: DrainProfile.shippingPrior())
        XCTAssertEqual(estimate.confidence, .low)
        XCTAssertNotNil(estimate.lowMinutes)
        XCTAssertNotNil(estimate.highMinutes)
        XCTAssertLessThan(estimate.lowMinutes ?? 0, estimate.highMinutes ?? 0)
    }

    // MARK: - 充电

    /// 接电时 `IOPSGetTimeRemainingEstimate` 返回 Unlimited，被 `> 0` 过滤成 nil，
    /// 于是界面永远显示「预计 正在估算 充满」。改用 `AvgTimeToFull`。
    /// 实测当前值：82%、`AvgTimeToFull` = 57 分、pmset 也说 0:57。
    func testChargingUsesTimeToFullInsteadOfPermanentlyEstimating() {
        var estimator = RuntimeEstimator()
        let input = RuntimeEstimatorInput(
            socFinePercent: 81.0, // 4557 / 5625
            wattHoursPerPercent: learnedWhPerPercent,
            netPowerWatts: 33.4, // 13111mV × 2546mA
            gaugeMinutes: 57,
            systemEstimateMinutes: nil, // 接电时系统返回 Unlimited → nil
            context: UsageContext(cpuBand: .light, displayBand: .medium, lowPowerMode: false),
            isCharging: true,
            now: now
        )
        let estimate = estimator.update(input, profile: maturedProfile())
        let minutes = try! XCTUnwrap(estimate.minutes, "充电时必须给得出充满时间，而不是永远『正在估算』")
        XCTAssertGreaterThan(minutes, 20)
        XCTAssertLessThan(minutes, 120)
    }

    /// 充电时的「习惯」项必须来自充电分段模型，而不是放电档案——
    /// 那是两个不同的物理过程。
    ///
    /// 判据：把放电档案换成一个荒谬的值（0.5W），充电估计不应当受任何影响。
    func testChargingUsesChargeBandsNotDischargeProfile() {
        func estimateMinutes(dischargeWatts: Double) -> Int? {
            var estimator = RuntimeEstimator()
            var profile = DrainProfile()
            let context = UsageContext(cpuBand: .moderate, displayBand: .medium, lowPowerMode: false)
            for _ in 0..<300 { profile.record(watts: dischargeWatts, context: context, at: now) }

            return estimator.update(
                RuntimeEstimatorInput(
                    socFinePercent: 50,
                    wattHoursPerPercent: 0.673,
                    netPowerWatts: 30,
                    gaugeMinutes: nil,
                    systemEstimateMinutes: nil,
                    context: context,
                    isCharging: true,
                    now: now,
                    adapterRatedWatts: 70
                ),
                profile: profile
            ).candidates[.learned]
        }

        let withNormalProfile = estimateMinutes(dischargeWatts: 7.45)
        let withAbsurdProfile = estimateMinutes(dischargeWatts: 0.5)
        XCTAssertNotNil(withNormalProfile, "充电时应当给得出分段估计")
        XCTAssertEqual(withNormalProfile, withAbsurdProfile, "放电档案不该影响充电估计")
    }

    /// **CC/CV 拐点。** 从 50% 充到满，最后 20% 要花的时间远超按线性外推的预期。
    /// 用瞬时功率乘剩余能量会把这段严重低估。
    func testChargeEstimateAccountsForTaperAboveEightyPercent() {
        var profile = DrainProfile()
        // 低电量段学到一个恒定速率。
        for _ in 0..<60 {
            profile.chargeProfile.record(wattHoursPerMinute: 0.55, soc: 30, adapterRatedWatts: 70, at: now)
        }

        let wh = 0.673
        let from50 = try! XCTUnwrap(profile.chargeProfile.minutesToFull(
            fromSoc: 50, wattHoursPerPercent: wh, adapterRatedWatts: 70, observedWattHoursPerMinute: 0.55
        ))
        let from80 = try! XCTUnwrap(profile.chargeProfile.minutesToFull(
            fromSoc: 80, wattHoursPerPercent: wh, adapterRatedWatts: 70, observedWattHoursPerMinute: 0.55
        ))

        // 线性外推会认为 80→100 只要 50→100 的 40%。实际因为衰减要更久。
        let linearShare = Double(from80) / Double(from50)
        XCTAssertGreaterThan(linearShare, 0.45, "最后 20% 占的时间应当明显高于线性预期")

        // 而且 80→100 这 20 个点，绝不该比 50→70 这 20 个点更快。
        let twentyPointsLow = Double(from50 - (try! XCTUnwrap(profile.chargeProfile.minutesToFull(
            fromSoc: 70, wattHoursPerPercent: wh, adapterRatedWatts: 70, observedWattHoursPerMinute: 0.55
        ))))
        XCTAssertGreaterThan(Double(from80), twentyPointsLow)
    }

    func testChargeEstimateStopsAtFull() {
        let profile = DrainProfile()
        XCTAssertNil(profile.chargeProfile.minutesToFull(
            fromSoc: 100, wattHoursPerPercent: 0.673, adapterRatedWatts: 70, observedWattHoursPerMinute: 0.5
        ))
    }

    // MARK: - EMA 与变化率

    /// 采样节奏在 2 秒和 10 秒之间切换，α 必须随 dt 变化，
    /// 否则时间常数会随节奏漂移。
    func testEMAIsTimeAwareAcrossChangingSampleIntervals() {
        var fast = RuntimeEstimator()
        var slow = RuntimeEstimator()

        func feed(_ estimator: inout RuntimeEstimator, step: TimeInterval, count: Int) -> Int? {
            var last: RuntimeEstimate?
            for index in 0..<count {
                let input = RuntimeEstimatorInput(
                    socFinePercent: 50,
                    wattHoursPerPercent: 0.673,
                    netPowerWatts: -8,
                    gaugeMinutes: nil,
                    systemEstimateMinutes: nil,
                    context: UsageContext(cpuBand: .light, displayBand: .medium, lowPowerMode: false),
                    isCharging: false,
                    now: now.addingTimeInterval(step * Double(index)),
                    sampleInterval: step
                )
                last = estimator.update(input, profile: DrainProfile())
            }
            return last?.minutes
        }

        // 同样跨越 90 秒，一个走 45 步 × 2 秒，一个走 9 步 × 10 秒。
        let a = feed(&fast, step: 2, count: 46)
        let b = feed(&slow, step: 10, count: 10)
        let first = try! XCTUnwrap(a)
        let second = try! XCTUnwrap(b)
        // 两者应当收敛到接近的结果——若 α 与 dt 无关，节奏不同会明显分叉。
        XCTAssertLessThan(abs(Double(first - second)) / Double(first), 0.15)
    }

    func testDisplayedValueDoesNotJumpWildlyBetweenSamples() {
        var estimator = RuntimeEstimator()
        let profile = maturedProfile()
        let context = UsageContext(cpuBand: .moderate, displayBand: .medium, lowPowerMode: false)

        var input = RuntimeEstimatorInput(
            socFinePercent: 60,
            wattHoursPerPercent: 0.673,
            netPowerWatts: -5,
            gaugeMinutes: nil,
            systemEstimateMinutes: nil,
            context: context,
            isCharging: false,
            now: now
        )
        let first = try! XCTUnwrap(estimator.update(input, profile: profile).minutes)

        // 下一秒功耗突增 8 倍。显示值不应当立刻塌掉。
        input.netPowerWatts = -40
        input.now = now.addingTimeInterval(2)
        let second = try! XCTUnwrap(estimator.update(input, profile: profile).minutes)

        XCTAssertLessThan(Double(abs(first - second)) / Double(first), 0.30, "两秒之间不该出现断崖")
    }

    // MARK: - 边界

    func testZeroRemainingEnergyReportsNothingRatherThanGuessing() {
        var estimator = RuntimeEstimator()
        let input = RuntimeEstimatorInput(
            socFinePercent: 1,
            wattHoursPerPercent: 0.673,
            reserveFloorPercent: 3,
            netPowerWatts: -8,
            gaugeMinutes: nil,
            systemEstimateMinutes: nil,
            context: UsageContext(cpuBand: .idle, displayBand: .low, lowPowerMode: false),
            isCharging: false,
            now: now
        )
        let estimate = estimator.update(input, profile: maturedProfile())
        XCTAssertNil(estimate.minutes, "已经在保留量以下时不该编一个数字")
        XCTAssertEqual(estimate.confidence, .low)
    }

    func testNoPowerReadingYieldsNoEstimateRatherThanZero() {
        var estimator = RuntimeEstimator()
        let input = RuntimeEstimatorInput(
            socFinePercent: 50,
            wattHoursPerPercent: 0.673,
            netPowerWatts: nil,
            gaugeMinutes: nil,
            systemEstimateMinutes: nil,
            context: UsageContext(cpuBand: .idle, displayBand: .asleep, lowPowerMode: false),
            isCharging: false,
            now: now
        )
        let estimate = estimator.update(input, profile: DrainProfile())
        XCTAssertNil(estimate.minutes)
    }
}

final class DrainProfileTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testBucketMeanConvergesToObservedWatts() {
        var bucket = DrainBucket()
        for _ in 0..<300 { bucket.update(watts: 7.45, at: now) }
        XCTAssertEqual(bucket.meanWatts, 7.45, accuracy: 0.05)
        XCTAssertGreaterThan(bucket.sampleMinutes, 200)
    }

    /// 行为改变后应当在数小时内适应，而不是几天。
    func testProfileAdaptsToChangedBehaviourWithinHours() {
        var bucket = DrainBucket()
        for _ in 0..<240 { bucket.update(watts: 3.0, at: now) }
        XCTAssertEqual(bucket.meanWatts, 3.0, accuracy: 0.1)

        // 用户换了用法：持续 12W。
        for minute in 0..<180 {
            bucket.update(watts: 12.0, at: now.addingTimeInterval(Double(minute) * 60))
        }
        XCTAssertGreaterThan(bucket.meanWatts, 9.0, "三小时后应当基本跟上新习惯")
    }

    /// 未成熟的桶按比例向父级收缩，不做硬切换——桶成熟时不能出现跳变。
    func testImmatureBucketShrinksTowardParentWithoutDiscontinuity() {
        var profile = DrainProfile()
        let context = UsageContext(cpuBand: .moderate, displayBand: .high, lowPowerMode: false)

        // 父级（tier2，只按 CPU）已经很成熟，均值 7W。
        for _ in 0..<300 {
            profile.record(watts: 7.0, context: UsageContext(cpuBand: .moderate, displayBand: .low, lowPowerMode: false), at: now)
        }
        let beforeChild = try! XCTUnwrap(profile.expectedWatts(for: context, now: now)).watts

        // 子桶刚积累 15 分钟、均值 14W：应当只贡献约四分之一。
        for _ in 0..<15 { profile.record(watts: 14.0, context: context, at: now) }
        let afterChild = try! XCTUnwrap(profile.expectedWatts(for: context, now: now)).watts

        XCTAssertGreaterThan(afterChild, beforeChild, "子桶应当把估计往上带")
        XCTAssertLessThan(afterChild, 14.0, "但远没到完全采信子桶的程度")
    }

    func testSampleWeightDecaysOverTime() {
        var bucket = DrainBucket()
        for _ in 0..<200 { bucket.update(watts: 5, at: now) }
        let after30Days = bucket.decayed(to: now.addingTimeInterval(30 * 86_400))
        XCTAssertEqual(after30Days.sampleMinutes, bucket.sampleMinutes / 2, accuracy: 1)
        XCTAssertEqual(after30Days.meanWatts, bucket.meanWatts, "衰减的是权重，不是均值")
    }

    /// Wh/% 必须钳在铭牌 ±20% 内：一段异常数据不能毁掉整个能量模型。
    func testLearnedEnergyPerPercentIsClampedToNameplate() {
        var profile = DrainProfile()
        profile.recordWattHoursPerPercent(0.673, nameplate: 0.631)
        XCTAssertEqual(profile.learnedWattHoursPerPercent ?? 0, 0.673, accuracy: 0.001)

        // 一段离谱的数据。
        profile.recordWattHoursPerPercent(5.0, nameplate: 0.631)
        let value = try! XCTUnwrap(profile.learnedWattHoursPerPercent)
        XCTAssertLessThan(value, 0.631 * 1.2 + 0.01)
        XCTAssertGreaterThan(value, 0.631 * 0.8 - 0.01)
    }

    /// 出厂先验必须能立刻给出合理量级，但样本权重要低到很快被真实数据盖过。
    func testShippingPriorIsUsableButEasilyOverridden() {
        let prior = DrainProfile.shippingPrior()
        let context = UsageContext(cpuBand: .intense, displayBand: .high, lowPowerMode: false)
        let expectation = try! XCTUnwrap(prior.expectedWatts(for: context, now: now))
        XCTAssertGreaterThan(expectation.watts, 15)
        XCTAssertLessThan(expectation.maturityMinutes, DrainProfile.maturityMinutes, "先验不能冒充成熟的知识")
    }
}
