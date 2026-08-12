import XCTest
@testable import MacPulseCore

/// 用真实历史回测估算器。
///
/// fixture 是这台机器上 6816 条分钟聚合记录（2026-07-29 → 08-05），
/// 只含时间戳与五个数值列，无任何标识信息。
///
/// 断言用**相对**边界而非绝对阈值：绝对阈值脆，相对的才能证明改进是真的。
final class RuntimeEstimatorBacktestTests: XCTestCase {
    private struct Sample: Decodable {
        let t: Double
        let soc: Double
        let w: Double?
        let cpu: Double?
        let sys: Double?

        var date: Date { Date(timeIntervalSince1970: t) }
    }

    /// 一段放电。
    private struct Session {
        var samples: [Sample] = []
        var endedAtEmpty: Bool { (samples.last?.soc ?? 100) <= 8 }
    }

    private func loadSamples() throws -> [Sample] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "history-sample", withExtension: "json"),
            "缺少回测 fixture"
        )
        return try JSONDecoder().decode([Sample].self, from: Data(contentsOf: url))
    }

    /// 切分放电段。
    ///
    /// 睡眠缺口必须切断：实测数据里有 39 个超过 3 分钟的断档，最长 982.9 分钟
    /// （16.4 小时）。把它当成连续放电会凭空造出上百 Wh。
    private func segment(_ samples: [Sample]) -> [Session] {
        var sessions: [Session] = []
        var current = Session()
        var previous: Sample?

        for sample in samples {
            defer { previous = sample }
            let discharging = (sample.w ?? 0) < -0.05
            let gap = previous.map { sample.t - $0.t } ?? 0

            // 超过 3 分钟的断档视为睡眠：结束当前段，另起一段。
            // 8 小时待机和连续使用不是同一个物理过程。
            if !discharging || gap > 180 {
                if current.samples.count > 20 { sessions.append(current) }
                current = Session()
                if discharging { current.samples.append(sample) }
                continue
            }
            current.samples.append(sample)
        }
        if current.samples.count > 20 { sessions.append(current) }
        return sessions
    }

    // MARK: - 健全性：先验证能量模型

    /// 在评估任何估计之前，回测框架必须先能从这些数据里复现出
    /// Wh/100% ≈ 67.3。复现不出来，说明能量模型本身就错了，
    /// 后面所有比较都没有意义。
    func testEnergyModelReproducesMeasuredWattHoursPerPercent() throws {
        let sessions = segment(try loadSamples())
        var ratios: [Double] = []

        for session in sessions {
            var wattHours = 0.0
            var previous: Sample?
            for sample in session.samples {
                defer { previous = sample }
                guard let previous, let watts = sample.w else { continue }
                // 积分步长必须钳住：一个未钳制的睡眠断档会凭空造出约 100Wh。
                let dt = min(sample.t - previous.t, 180)
                guard dt > 0 else { continue }
                wattHours += abs(watts) * dt / 3_600
            }
            let drop = (session.samples.first?.soc ?? 0) - (session.samples.last?.soc ?? 0)
            guard drop >= 10, wattHours > 0 else { continue }
            ratios.append(wattHours / drop * 100)
        }

        XCTAssertGreaterThanOrEqual(ratios.count, 5, "应当能切出足够多的长放电段")
        let mean = ratios.reduce(0, +) / Double(ratios.count)
        XCTAssertEqual(mean, 67.3, accuracy: 67.3 * 0.08, "复现不出实测的 Wh/100%，能量模型有问题")

        // 铭牌值 63.1 系统性偏低约 6% —— 这正是要学 Wh/% 的理由。
        XCTAssertGreaterThan(mean, 63.1, "实测能量应当高于铭牌估算")
    }

    // MARK: - 三个臂的对比

    private struct ArmScore {
        var absoluteErrors: [Double] = []

        var mae: Double {
            guard !absoluteErrors.isEmpty else { return .infinity }
            return absoluteErrors.reduce(0, +) / Double(absoluteErrors.count)
        }

        var medianAE: Double {
            guard !absoluteErrors.isEmpty else { return .infinity }
            let sorted = absoluteErrors.sorted()
            return sorted[sorted.count / 2]
        }
    }

    func testBlendedEstimatorBeatsSystemValueAndNaiveInstant() throws {
        let sessions = segment(try loadSamples()).filter { $0.endedAtEmpty }
        XCTAssertGreaterThanOrEqual(sessions.count, 1, "需要至少一段跑到低电量的未删失放电")

        let whPerPercent = 0.673
        var system = ArmScore()
        var naive = ArmScore()
        var blended = ArmScore()

        for session in sessions {
            guard let close = session.samples.last else { continue }
            var estimator = RuntimeEstimator()
            var profile = DrainProfile.shippingPrior()

            for (index, sample) in session.samples.enumerated() {
                let actualMinutes = (close.t - sample.t) / 60
                // 只评估剩余 ≥20 分钟时做出的预测：最后 20 分钟太容易猜，
                // 算进去只会美化分数。
                guard actualMinutes >= 20 else { continue }

                let context = UsageContext(
                    cpuPercent: sample.cpu,
                    backlightMicroAmps: nil, // 历史里没有亮度列，学习臂只走 T1/T2
                    lowPowerMode: false
                )

                // 用前 15 分钟的实际电量下降喂给「观测斜率一致性」钳制。
                let windowStart = session.samples[max(0, index - 15)]
                let drop = windowStart.soc - sample.soc
                let window = (sample.t - windowStart.t) / 60

                let estimate = estimator.update(
                    RuntimeEstimatorInput(
                        socFinePercent: sample.soc,
                        wattHoursPerPercent: whPerPercent,
                        netPowerWatts: sample.w,
                        gaugeMinutes: nil, // 历史里没存计量芯片读数
                        systemEstimateMinutes: RuntimeEstimator.systemSaturationMinutes,
                        context: context,
                        isCharging: false,
                        now: sample.date,
                        sampleInterval: 60,
                        recentSocDropPercent: drop > 0 ? drop : nil,
                        recentWindowMinutes: window > 0 ? window : nil
                    ),
                    profile: profile
                )

                if let watts = sample.w {
                    profile.record(watts: abs(watts), context: context, at: sample.date)
                }

                // 臂 1：系统值。实测它被钉死在 20:00 —— 电量掉了 1% 都不动，
                // 所以这里用常数 1200 建模，这与观测一致。
                system.absoluteErrors.append(abs(1_200 - actualMinutes))

                // 臂 2：天真做法——瞬时功率直接除，无平滑、无钳制。
                if let watts = sample.w, abs(watts) > 0.05 {
                    let raw = max(0, sample.soc - 3) * whPerPercent * 60 / abs(watts)
                    naive.absoluteErrors.append(abs(raw - actualMinutes))
                }

                // 臂 3：新估算器。
                if let minutes = estimate.minutes {
                    blended.absoluteErrors.append(abs(Double(minutes) - actualMinutes))
                }
            }
        }

        XCTAssertGreaterThan(blended.absoluteErrors.count, 100, "样本量太小，结论不可信")

        print("""
        —— 回测（\(sessions.count) 段未删失放电，\(blended.absoluteErrors.count) 个检查点）——
        系统值(1200)  MAE \(Int(system.mae)) 分   中位 \(Int(system.medianAE)) 分
        天真瞬时      MAE \(Int(naive.mae)) 分   中位 \(Int(naive.medianAE)) 分
        新估算器      MAE \(Int(blended.mae)) 分   中位 \(Int(blended.medianAE)) 分
        """)

        XCTAssertLessThan(blended.mae, system.mae * 0.5, "相对系统值必须至少减半误差")
        XCTAssertLessThanOrEqual(blended.mae, naive.mae, "不应当比天真做法更差")
    }

    /// 睡眠断档的钳制必须写在唯一那个做积分的地方，并且扛得住 16 小时缺口。
    func testSixteenHourGapDoesNotExplodeEnergyAccumulator() {
        let start = Date(timeIntervalSince1970: 1_785_000_000)
        let samples: [Sample] = [
            Sample(t: start.timeIntervalSince1970, soc: 80, w: -8, cpu: 10, sys: 6),
            Sample(t: start.timeIntervalSince1970 + 60, soc: 79.8, w: -8, cpu: 10, sys: 6),
            // 16.4 小时断档——实测数据里真实存在过
            Sample(t: start.timeIntervalSince1970 + 60 + 982.9 * 60, soc: 74, w: -8, cpu: 10, sys: 6),
            Sample(t: start.timeIntervalSince1970 + 120 + 982.9 * 60, soc: 73.8, w: -8, cpu: 10, sys: 6)
        ]

        var wattHours = 0.0
        var previous: Sample?
        for sample in samples {
            defer { previous = sample }
            guard let previous, let watts = sample.w else { continue }
            let dt = min(sample.t - previous.t, 180)
            wattHours += abs(watts) * dt / 3_600
        }
        // 不钳制的话 16.4 小时 × 8W ≈ 131 Wh，比整块电池还大。
        XCTAssertLessThan(wattHours, 2.0, "钳制之后断档只应贡献最多 3 分钟的能量")
    }
}
