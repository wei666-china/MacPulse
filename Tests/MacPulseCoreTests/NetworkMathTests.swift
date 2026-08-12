import XCTest
@testable import MacPulseCore

final class NetworkMathTests: XCTestCase {
    // MARK: - 防 4 倍谎报

    /// 构造一条典型的 TCP 慢启动曲线：前 1.5 秒速率从 10MB/s 爬到 50MB/s，
    /// 之后稳定在 50MB/s。这正是实测里「10MB 报 95Mbps、25MB 报 390Mbps」
    /// 那 4 倍差距的成因。
    private func slowStartSamples(
        totalSeconds: Double = 5,
        rampSeconds: Double = 1.5,
        startBytesPerSecond: Double = 10_000_000,
        steadyBytesPerSecond: Double = 50_000_000
    ) -> [(seconds: Double, bytes: Int64)] {
        var samples: [(seconds: Double, bytes: Int64)] = []
        var cumulative = 0.0
        var t = 0.0
        let step = 0.1
        while t <= totalSeconds + 1e-9 {
            samples.append((seconds: t, bytes: Int64(cumulative)))
            let rate: Double
            if t < rampSeconds {
                let progress = t / rampSeconds
                rate = startBytesPerSecond + (steadyBytesPerSecond - startBytesPerSecond) * progress
            } else {
                rate = steadyBytesPerSecond
            }
            cumulative += rate * step
            t += step
        }
        return samples
    }

    /// 块足够长、已经跑进稳态时，丢弃预热段能把真实速率还原出来。
    func testSteadyStateRateRecoversTrueSpeedOnceTransferReachesSteadyState() throws {
        let samples = slowStartSamples()
        let last = try XCTUnwrap(samples.last)

        // 天真做法：总字节 ÷ 总时间，把预热段一起平均进去。
        let naive = Double(last.bytes) * 8 / last.seconds
        let steady = try XCTUnwrap(NetworkMath.steadyStateRate(samples: samples))

        // 真值 50MB/s = 400 Mbps
        XCTAssertEqual(steady / 1_000_000, 400, accuracy: 12, "丢弃预热段后应恢复到真实的 400 Mbps")
        XCTAssertLessThan(naive, steady, "天真做法必然低估")
        XCTAssertGreaterThan(steady / naive, 1.10)
    }

    /// **丢弃前 30% 并不能救回一次被预热主导的短传输。**
    ///
    /// 这条测试存在的意义是把这个局限钉死：实测里「10MB 报 95Mbps、
    /// 25MB 报 390Mbps」的 4 倍差距，靠后处理修不掉——整块传输都还在慢启动里，
    /// 裁掉 30% 剩下的仍然是慢启动。所以设计里必须**另外**先跑一次热身探测
    /// 并整块丢弃，再用观测到的速率给后续块定尺寸。缺了这一步，
    /// 光有 steadyStateRate 依然会谎报。
    func testTrimmingAloneCannotRescueAWarmUpDominatedTransfer() throws {
        // 一次 1 秒的短传输，其中 0.7 秒都在爬坡。
        let short = slowStartSamples(
            totalSeconds: 1.0,
            rampSeconds: 0.7,
            startBytesPerSecond: 5_000_000,
            steadyBytesPerSecond: 50_000_000
        )
        let long = slowStartSamples(
            totalSeconds: 8.0,
            rampSeconds: 0.7,
            startBytesPerSecond: 5_000_000,
            steadyBytesPerSecond: 50_000_000
        )

        let shortTrimmed = try XCTUnwrap(NetworkMath.steadyStateRate(samples: short))
        let longTrimmed = try XCTUnwrap(NetworkMath.steadyStateRate(samples: long))

        XCTAssertEqual(longTrimmed / 1_000_000, 400, accuracy: 12, "够长的块能还原真值")
        XCTAssertLessThan(
            shortTrimmed, longTrimmed * 0.9,
            "短块即使裁掉预热段也仍然明显偏低——这正是需要独立热身探测的理由"
        )
    }

    /// 端到端走一遍完整方法：热身探测 → 按观测速率定尺寸 → 在已经预热的
    /// 连接上传输 → 裁掉前 30% → 得到真值。这是上面那条局限的解药，
    /// 两条测试要一起读。
    func testFullMethodRecoversTrueRateAfterWarmUpProbe() throws {
        let trueBytesPerSecond = 50_000_000.0

        // 第一步：热身探测。它本身是偏低的，结果整块丢弃，只用来定尺寸。
        let probe = slowStartSamples(
            totalSeconds: 1.0,
            rampSeconds: 0.7,
            startBytesPerSecond: 5_000_000,
            steadyBytesPerSecond: trueBytesPerSecond
        )
        let observed = try XCTUnwrap(NetworkMath.steadyStateRate(samples: probe))
        XCTAssertLessThan(observed / 1_000_000, 400, "探测块本身必然偏低，所以它只配用来定尺寸")

        let chunkBytes = NetworkMath.nextChunkBytes(
            observedBitsPerSecond: observed,
            targetSeconds: 5,
            minimumBytes: 2_000_000,
            maximumBytes: 50_000_000
        )

        // 第二步：连接已经预热，正式块全程稳态。
        let duration = Double(chunkBytes) / trueBytesPerSecond
        var measured: [(seconds: Double, bytes: Int64)] = []
        var t = 0.0
        while t <= duration + 1e-9 {
            measured.append((seconds: t, bytes: Int64(t * trueBytesPerSecond)))
            t += duration / 20
        }

        let rate = try XCTUnwrap(NetworkMath.steadyStateRate(samples: measured))
        XCTAssertEqual(rate / 1_000_000, 400, accuracy: 1, "走完整套方法才拿得到真值")
    }

    func testSteadyStateRateReturnsNilWhenSamplesAreTooSparse() {
        XCTAssertNil(NetworkMath.steadyStateRate(samples: []))
        XCTAssertNil(NetworkMath.steadyStateRate(samples: [(0, 0)]))
        // 只有起止两点、且时间为零：没有可用的稳态段，宁可返回 nil。
        XCTAssertNil(NetworkMath.steadyStateRate(samples: [(0, 0), (0, 1_000)]))
    }

    func testConstantRateIsUnaffectedByWarmUpTrimming() throws {
        var samples: [(seconds: Double, bytes: Int64)] = []
        for step in 0...50 {
            let t = Double(step) * 0.1
            samples.append((seconds: t, bytes: Int64(t * 12_500_000)))
        }
        let rate = try XCTUnwrap(NetworkMath.steadyStateRate(samples: samples))
        XCTAssertEqual(rate / 1_000_000, 100, accuracy: 0.5)
    }

    // MARK: - 永远带误差区间

    func testCombineReportsMedianWithRangeNotBarePointEstimate() throws {
        let estimate = try XCTUnwrap(NetworkMath.combine(chunkRates: [380e6, 400e6, 420e6], streams: 4))
        XCTAssertEqual(estimate.bitsPerSecond, 400e6, accuracy: 1)
        XCTAssertEqual(estimate.lowBitsPerSecond, 380e6)
        XCTAssertEqual(estimate.highBitsPerSecond, 420e6)
        XCTAssertEqual(estimate.samples, 3)
        XCTAssertTrue(estimate.isTrustworthy, "10% 的离散度属于稳定")
    }

    /// 离散度过大时必须判为不可信，界面据此隐藏头条数字只显示区间。
    func testWildlyVaryingChunksAreMarkedUntrustworthy() throws {
        let estimate = try XCTUnwrap(NetworkMath.combine(chunkRates: [100e6, 300e6, 500e6], streams: 4))
        XCTAssertEqual(estimate.bitsPerSecond, 300e6, accuracy: 1)
        XCTAssertFalse(estimate.isTrustworthy)
        XCTAssertGreaterThan(estimate.relativeSpread, NetworkMath.trustworthySpreadThreshold)
    }

    func testCombineIgnoresNonPositiveAndNonFiniteRates() throws {
        let estimate = try XCTUnwrap(NetworkMath.combine(chunkRates: [0, -5, .nan, .infinity, 200e6], streams: 1))
        XCTAssertEqual(estimate.bitsPerSecond, 200e6)
        XCTAssertEqual(estimate.samples, 1)
        XCTAssertNil(NetworkMath.combine(chunkRates: [0, -1], streams: 1))
    }

    // MARK: - 延迟与抖动

    func testPercentileInterpolatesBetweenSamples() {
        let values = [10.0, 12, 14, 16, 18, 20, 30, 40]
        XCTAssertEqual(NetworkMath.percentile(values, 0.5) ?? 0, 17, accuracy: 0.001)
        XCTAssertEqual(NetworkMath.percentile(values, 0.0) ?? 0, 10, accuracy: 0.001)
        XCTAssertEqual(NetworkMath.percentile(values, 1.0) ?? 0, 40, accuracy: 0.001)
        XCTAssertNil(NetworkMath.percentile([], 0.5))
    }

    /// 抖动用相邻差而不是标准差：同样的分布，一次大偏离和持续小抖动
    /// 对通话的影响完全不同，相邻差能区分，标准差不能。
    func testJitterUsesSuccessiveDifferencesNotStandardDeviation() throws {
        let steadyThenOneSpike = [20.0, 20, 20, 20, 40]
        let alternating = [20.0, 40, 20, 40, 20]

        let spikeJitter = try XCTUnwrap(NetworkMath.meanAbsoluteSuccessiveDifference(steadyThenOneSpike))
        let alternatingJitter = try XCTUnwrap(NetworkMath.meanAbsoluteSuccessiveDifference(alternating))

        XCTAssertEqual(spikeJitter, 5, accuracy: 0.001)
        XCTAssertEqual(alternatingJitter, 20, accuracy: 0.001)
        XCTAssertGreaterThan(alternatingJitter, spikeJitter, "持续抖动应当比单次尖峰得分更差")
        XCTAssertNil(NetworkMath.meanAbsoluteSuccessiveDifference([20]))
    }

    func testBufferbloatGradesMatchPerceptualThresholds() {
        XCTAssertEqual(NetworkMath.bufferbloatGrade(12)?.first, "A")
        XCTAssertEqual(NetworkMath.bufferbloatGrade(45)?.first, "B")
        XCTAssertEqual(NetworkMath.bufferbloatGrade(120)?.first, "C")
        XCTAssertEqual(NetworkMath.bufferbloatGrade(400)?.first, "D")
        XCTAssertNil(NetworkMath.bufferbloatGrade(nil))
        XCTAssertNil(NetworkMath.bufferbloatGrade(.nan))
    }

    // MARK: - 自适应块大小

    func testChunkSizeShrinksOnSlowLinksAndGrowsOnFastOnes() {
        // 10 Mbps 的链路：5 秒目标 → 约 6.25MB，被下限以上、上限以下夹住
        let slow = NetworkMath.nextChunkBytes(
            observedBitsPerSecond: 10_000_000,
            targetSeconds: 5,
            minimumBytes: 2_000_000,
            maximumBytes: 50_000_000
        )
        XCTAssertEqual(slow, 6_250_000)

        // 400 Mbps：5 秒要 250MB，被上限夹到 50MB
        let fast = NetworkMath.nextChunkBytes(
            observedBitsPerSecond: 400_000_000,
            targetSeconds: 5,
            minimumBytes: 2_000_000,
            maximumBytes: 50_000_000
        )
        XCTAssertEqual(fast, 50_000_000)

        // 读不到速率时退到下限，而不是冒险传满
        XCTAssertEqual(
            NetworkMath.nextChunkBytes(observedBitsPerSecond: .nan, targetSeconds: 5, minimumBytes: 2_000_000, maximumBytes: 50_000_000),
            2_000_000
        )
    }

    // MARK: - 陈旧结果

    func testStaleResultsAreFlaggedAndDescribed() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(NetworkMath.isStale(nil, now: now))
        XCTAssertFalse(NetworkMath.isStale(now.addingTimeInterval(-60), now: now))
        XCTAssertTrue(NetworkMath.isStale(now.addingTimeInterval(-7 * 3_600), now: now))

        XCTAssertEqual(NetworkMath.ageDescription(nil, now: now), "尚未测速")
        XCTAssertEqual(NetworkMath.ageDescription(now.addingTimeInterval(-30), now: now), "刚刚测得")
        XCTAssertEqual(NetworkMath.ageDescription(now.addingTimeInterval(-180), now: now), "3 分钟前测得")
        XCTAssertEqual(NetworkMath.ageDescription(now.addingTimeInterval(-7_200), now: now), "2 小时前测得")
    }
}

final class NetworkTestPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func input(
        trigger: NetworkTestTrigger = .panelOpen,
        consent: NetworkConsent = .granted,
        autoRun: Bool = true,
        tier: NetworkTestTier = .standard,
        expensive: Bool = false,
        constrained: Bool = false,
        satisfied: Bool = true,
        lastCompletedAt: Date? = nil,
        battery: Double = 100,
        discharging: Bool = false,
        thermal: Bool = false,
        running: Bool = false
    ) -> NetworkTestPolicy.Input {
        NetworkTestPolicy.Input(
            trigger: trigger,
            consent: consent,
            autoRunEnabled: autoRun,
            preferredTier: tier,
            path: NetworkPathSnapshot(
                isSatisfied: satisfied,
                isExpensive: expensive,
                isConstrained: constrained
            ),
            now: now,
            lastCompletedAt: lastCompletedAt,
            batteryPercent: battery,
            isDischarging: discharging,
            thermalUnderPressure: thermal,
            isRunning: running
        )
    }

    /// 用户选的是「每次打开都完整测」，默认路径必须真的跑完整测速。
    func testDefaultPanelOpenRunsFullTest() {
        XCTAssertEqual(NetworkTestPolicy.decide(input()), .run(.standard))
    }

    func testConsentGatesEverything() {
        XCTAssertEqual(NetworkTestPolicy.decide(input(consent: .notDetermined)), .skip(.needsConsent))
        XCTAssertEqual(NetworkTestPolicy.decide(input(consent: .denied)), .skip(.userDeclined))
        // 即使用户手动点按钮，未同意也不能发请求。
        XCTAssertEqual(
            NetworkTestPolicy.decide(input(trigger: .manual, consent: .notDetermined)),
            .skip(.needsConsent)
        )
    }

    func testOfflineSkipsWithVisibleReason() {
        XCTAssertEqual(NetworkTestPolicy.decide(input(satisfied: false)), .skip(.offline))
    }

    func testConcurrentTriggersCollapseInsteadOfStartingSecondTest() {
        XCTAssertEqual(NetworkTestPolicy.decide(input(running: true)), .skip(.alreadyRunning))
    }

    /// 60 秒下限只用来去重同一次开启事件，不是替用户节流。
    func testShortIntervalDeduplicatesRepeatedOpens() {
        let justTested = now.addingTimeInterval(-5)
        XCTAssertEqual(NetworkTestPolicy.decide(input(lastCompletedAt: justTested)), .skip(.tooSoon))

        let aWhileAgo = now.addingTimeInterval(-120)
        XCTAssertEqual(NetworkTestPolicy.decide(input(lastCompletedAt: aWhileAgo)), .run(.standard))
    }

    /// 手动点「重新测速」永远立刻执行，不受间隔限制。
    func testManualTriggerBypassesInterval() {
        let justTested = now.addingTimeInterval(-5)
        XCTAssertEqual(
            NetworkTestPolicy.decide(input(trigger: .manual, lastCompletedAt: justTested)),
            .run(.standard)
        )
    }

    /// 热点上降级为轻量而不是完全跳过——35KB 在热点上完全可以接受，
    /// 用户仍然能看到延迟和连通性。65MB 才是不能推的那个。
    func testMeteredNetworkDowngradesToLightRatherThanSkipping() {
        XCTAssertEqual(NetworkTestPolicy.decide(input(expensive: true)), .run(.light))
        XCTAssertEqual(NetworkTestPolicy.downgradeReason(input(expensive: true)), .meteredNetwork)

        XCTAssertEqual(NetworkTestPolicy.decide(input(constrained: true)), .run(.light))
        XCTAssertEqual(NetworkTestPolicy.downgradeReason(input(constrained: true)), .lowDataMode)
    }

    func testLowBatteryAndThermalPressureDowngrade() {
        XCTAssertEqual(
            NetworkTestPolicy.decide(input(battery: 15, discharging: true)),
            .run(.light)
        )
        XCTAssertEqual(
            NetworkTestPolicy.downgradeReason(input(battery: 15, discharging: true)),
            .lowBattery
        )
        // 接电时低电量不降级——正在充电就没有省电的理由。
        XCTAssertEqual(NetworkTestPolicy.decide(input(battery: 15, discharging: false)), .run(.standard))
        XCTAssertEqual(NetworkTestPolicy.decide(input(thermal: true)), .run(.light))
    }

    /// 用户选了轻量档，不该被「降级」逻辑再动一次。
    func testLightTierIsNeverDowngradedFurther() {
        XCTAssertEqual(NetworkTestPolicy.decide(input(tier: .light, expensive: true)), .run(.light))
        XCTAssertNil(NetworkTestPolicy.downgradeReason(input(tier: .light, expensive: true)))
    }

    func testAutoRunDisabledStillAllowsManualTest() {
        XCTAssertEqual(NetworkTestPolicy.decide(input(autoRun: false)), .skip(.userDeclined))
        XCTAssertEqual(NetworkTestPolicy.decide(input(trigger: .manual, autoRun: false)), .run(.standard))
    }

    /// 换了网络就该立刻重测，旧网络的结果对新网络没有意义。
    func testNetworkChangeBypassesInterval() {
        var value = input(lastCompletedAt: now.addingTimeInterval(-5))
        value.networkKeyChanged = true
        XCTAssertEqual(NetworkTestPolicy.decide(value), .run(.standard))
    }

    /// 计费网络上把去重间隔拉长到 30 分钟，避免反复开面板反复发请求。
    func testMeteredNetworkUsesLongerInterval() {
        let value = input(expensive: true, lastCompletedAt: now.addingTimeInterval(-600))
        XCTAssertEqual(NetworkTestPolicy.decide(value), .skip(.tooSoon))
    }
}
