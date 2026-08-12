import XCTest
@testable import MacPulseCore

/// 学习档案的 JSON 演进回归测试。
///
/// 背景：给 DrainProfile 加 chargeProfile 字段那次，合成 Decodable 因旧文件
/// 缺键而整体抛错，加载方静默回退到出厂先验——6900 分钟的回填学习被丢了。
/// 这组测试钉死「旧格式永远解得开」，让同类改动再也不能悄悄毁档案。
final class DrainProfilePersistenceTests: XCTestCase {
    /// chargeProfile 引入之前的档案格式（真实字段、无 chargeProfile 键）。
    private let legacyProfileJSON = """
    {
      "buckets": {
        "t2|cpu0": {"meanWatts": 2.44, "varianceAccumulator": 1.2, "sampleMinutes": 1223, "lastUpdated": 776000000},
        "t2|cpu2": {"meanWatts": 8.93, "varianceAccumulator": 4.1, "sampleMinutes": 2734, "lastUpdated": 776000000}
      },
      "globalBucket": {"meanWatts": 7.7, "varianceAccumulator": 9.0, "sampleMinutes": 5388, "lastUpdated": 776000000},
      "learnedWattHoursPerPercent": 0.671
    }
    """

    func testLegacyProfileWithoutChargeProfileStillDecodes() throws {
        let profile = try JSONDecoder().decode(DrainProfile.self, from: Data(legacyProfileJSON.utf8))
        // 学到的东西一个都不能丢。
        XCTAssertEqual(profile.buckets["t2|cpu0"]?.meanWatts ?? 0, 2.44, accuracy: 0.001)
        XCTAssertEqual(profile.buckets["t2|cpu0"]?.sampleMinutes ?? 0, 1223, accuracy: 0.5)
        XCTAssertEqual(profile.buckets["t2|cpu2"]?.meanWatts ?? 0, 8.93, accuracy: 0.001)
        XCTAssertEqual(profile.globalBucket.sampleMinutes, 5388, accuracy: 0.5)
        XCTAssertEqual(profile.learnedWattHoursPerPercent ?? 0, 0.671, accuracy: 0.001)
        // 缺失的新字段补默认值，而不是让整个文件作废。
        XCTAssertTrue(profile.chargeProfile.bands.isEmpty)
        XCTAssertNil(profile.observedFloorPercent)
    }

    /// 空对象也要能解——极端但便宜，防住「全部字段都是后加的」这种未来。
    func testEmptyObjectDecodesToEmptyProfile() throws {
        let profile = try JSONDecoder().decode(DrainProfile.self, from: Data("{}".utf8))
        XCTAssertTrue(profile.buckets.isEmpty)
        XCTAssertEqual(profile.globalBucket.sampleMinutes, 0)
    }

    /// 当前格式往返无损。
    func testCurrentFormatRoundTripsLosslessly() throws {
        var profile = DrainProfile.shippingPrior()
        let context = UsageContext(cpuBand: .moderate, displayBand: .high, lowPowerMode: false)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        for _ in 0..<90 { profile.record(watts: 9.1, context: context, at: date) }
        profile.chargeProfile.record(wattHoursPerMinute: 0.5, soc: 30, adapterRatedWatts: 70, at: date)
        profile.recordWattHoursPerPercent(0.68, nameplate: 0.64)
        profile.observedFloorPercent = 2

        let data = try JSONEncoder().encode(profile)
        let restored = try JSONDecoder().decode(DrainProfile.self, from: data)
        XCTAssertEqual(restored, profile)
    }
}
