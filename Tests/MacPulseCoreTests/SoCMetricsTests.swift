import XCTest
@testable import MacPulseCore

final class SoCMetricsTests: XCTestCase {
    /// 保持 schemaVersion = 2 的全部依据：新版 App 读旧版采集器的帧不能失败。
    ///
    /// 旧帧里没有 socPower / socCompute / chip / thermalGroups / unsupported 这些键，
    /// 必须解成 nil 与空数组（界面显示「不可用」），而不是抛解码错误——
    /// 一旦抛错，整个采集链会被判定为不可用。
    func testFrameFromOlderCollectorDecodesWithoutNewKeys() throws {
        let legacy = """
        {
          "cpuUsagePercent": 21.5,
          "gpuUsagePercent": 8.5,
          "memoryUsedBytes": 17179869184,
          "cpuPowerWatts": 2.4,
          "systemPowerWatts": 6.7,
          "thermalLevel": "nominal",
          "collectorAvailable": true
        }
        """
        let deep = try JSONDecoder().decode(DeepMetrics.self, from: Data(legacy.utf8))

        XCTAssertEqual(deep.cpuUsagePercent, 21.5)
        XCTAssertEqual(deep.systemPowerWatts, 6.7)
        XCTAssertNil(deep.socPower)
        XCTAssertNil(deep.socCompute)
        XCTAssertNil(deep.chip)
        XCTAssertNil(deep.thermalGroups)
        XCTAssertEqual(deep.unsupported, [])
        XCTAssertFalse(deep.isUnsupported(SensorAvailabilityKey.dramBandwidth))
    }

    /// 反向兼容：新采集器发的帧带了旧 App 不认识的键，旧 App 会忽略它们。
    /// 这里验证的是我们自己的往返不丢字段。
    func testNewFieldsSurviveRoundTrip() throws {
        var deep = DeepMetrics(
            cpuPowerWatts: 5.06,
            gpuPowerWatts: 0.14,
            anePowerWatts: 0,
            dramPowerWatts: 0.60,
            systemPowerWatts: 23.38,
            socPower: SoCPowerMetrics(packageWatts: 23.38, residualWatts: 17.58, gpuSRAMWatts: 0),
            socCompute: SoCComputeMetrics(
                eClusterActivePercent: 73.5,
                eClusterFreqMHz: 2365,
                pClusterActivePercent: 65.06,
                pClusterFreqMHz: 3627,
                gpuFreqMHz: 338,
                aneActivePercent: 0
            ),
            chip: ChipIdentity(
                name: "Apple M5",
                coreCount: 10,
                eCoreCount: 6,
                pCoreCount: 4,
                gpuCoreCount: 10,
                tflopsFP32: 4.03968,
                tflopsFP16: 8.07936
            ),
            thermalGroups: [ThermalGroup(rawName: "CPU P-Core", averageCelsius: 45.2, sensorCount: 14)],
            unsupported: [SensorAvailabilityKey.fans],
            collectorAvailable: true
        )
        deep.thermalLevel = .nominal

        let data = try JSONEncoder().encode(deep)
        let restored = try JSONDecoder().decode(DeepMetrics.self, from: data)
        XCTAssertEqual(restored, deep)
        XCTAssertTrue(restored.isUnsupported(SensorAvailabilityKey.fans))
    }

    /// 功耗轨恒等式：各具名轨之和 + 残差 == 封装总功耗。
    /// 界面上五条轨要严格加总到总功耗，破坏这条恒等式就说明标签又错位了。
    func testRailsPlusResidualEqualsPackage() {
        // 取自本机一帧真实数据。
        let cpu = 5.062_442_699_476_694
        let gpu = 0.143_009_915_259_224_35
        let ane = 0.0
        let dram = 0.600_065_601_829_863_1
        let gpuSRAM = 0.0
        let residual = 17.573_285_036_608_05
        let package = 23.378_803_253_173_828

        XCTAssertEqual(cpu + gpu + ane + dram + gpuSRAM + residual, package, accuracy: 0.001)
    }

    func testThermalGroupNamesMapToKnownKinds() {
        XCTAssertEqual(ThermalGroupKind(rawName: "CPU E-Core"), .cpuECore)
        XCTAssertEqual(ThermalGroupKind(rawName: "SoC Package"), .socPackage)
        XCTAssertEqual(ThermalGroupKind(rawName: "NVMe"), .nvme)
        XCTAssertEqual(ThermalGroupKind(rawName: "CPU E-Core").section, .chip)
        XCTAssertEqual(ThermalGroupKind(rawName: "SSD").section, .storage)
        XCTAssertEqual(ThermalGroupKind(rawName: "VRM").section, .chassis)
    }

    /// 未识别的组名要原样保留并显示，不能悄悄丢掉——上游哪天加了新分组，
    /// 我们应该照样把它显示出来，而不是让它从界面上消失。
    func testUnknownThermalGroupKeepsRawNameInsteadOfBeingDropped() {
        let group = ThermalGroup(rawName: "Fancy New Sensor Block", averageCelsius: 40)
        XCTAssertEqual(group.kind, .other)
        XCTAssertEqual(group.rawName, "Fancy New Sensor Block")
        XCTAssertEqual(group.kind.section, .chassis)
    }

    /// 实测出现过 `VRM min 1.0°C` 这种失灵读数。区间条要丢掉它，
    /// 但平均值和最高值必须保留——坏一个传感器不该让整组数据消失。
    func testImplausibleMinimumIsExcludedFromRangeButGroupSurvives() {
        let group = ThermalGroup(
            rawName: "VRM",
            averageCelsius: 46.1,
            minimumCelsius: 1.0,
            maximumCelsius: 52.0,
            sensorCount: 16
        )
        XCTAssertNil(group.trustworthyMinimumCelsius)
        XCTAssertEqual(group.averageCelsius, 46.1)
        XCTAssertEqual(group.maximumCelsius, 52.0)
    }

    func testCoreLayoutDegradesInsteadOfInventingNumbers() {
        let full = ChipIdentity(name: "Apple M5", coreCount: 10, eCoreCount: 6, pCoreCount: 4)
        XCTAssertEqual(full.coreLayoutDescription, "10 核（6 能效 + 4 性能）")

        let partial = ChipIdentity(name: "Apple M5", coreCount: 10)
        XCTAssertEqual(partial.coreLayoutDescription, "10 核")

        let empty = ChipIdentity(name: "Apple M5")
        XCTAssertNil(empty.coreLayoutDescription)
    }
}
