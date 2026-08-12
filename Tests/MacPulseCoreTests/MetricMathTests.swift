import Foundation
import XCTest
@testable import MacPulseCore

final class MetricMathTests: XCTestCase {
    func testBatteryPowerUsesSignedCurrent() {
        let voltage = NSNumber(value: 12_000)
        let current = NSNumber(value: Int64(-2_000))
        let result = MetricMath.batteryPowerWatts(
            voltageMillivolts: voltage,
            currentMilliamps: current
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result ?? 0, -24, accuracy: 0.001)
    }

    func testUnsignedIORegistryValueWrapsToSignedCurrent() {
        let encodedNegative = NSNumber(value: UInt64.max - 349)
        XCTAssertEqual(MetricMath.signedInt64(from: encodedNegative), -350)
    }

    func testHealthIsClampedAtOneHundredPercent() {
        XCTAssertEqual(
            MetricMath.healthPercent(
                maxCapacity: NSNumber(value: 5_900),
                designCapacity: NSNumber(value: 5_760)
            ),
            100
        )
    }

    func testMinuteAggregatorAveragesAvailableValues() {
        var aggregator = MinuteAggregator()
        var first = MetricSnapshot()
        first.timestamp = Date(timeIntervalSince1970: 100)
        first.battery.percentage = 50
        first.battery.netPowerWatts = 10
        first.deep.cpuUsagePercent = 20

        var second = MetricSnapshot()
        second.timestamp = Date(timeIntervalSince1970: 110)
        second.battery.percentage = 60
        second.battery.netPowerWatts = 20
        second.deep.cpuUsagePercent = nil

        aggregator.append(first)
        aggregator.append(second)
        let point = aggregator.flush()

        XCTAssertEqual(point?.batteryPercent, 55)
        XCTAssertEqual(point?.batteryPowerWatts, 15)
        XCTAssertEqual(point?.cpuUsagePercent, 20)
        XCTAssertEqual(point?.timestamp, second.timestamp)
        XCTAssertNil(aggregator.flush())
    }

    func testMinuteAggregatorFlushesAtWallClockBoundary() {
        var aggregator = MinuteAggregator()
        var first = MetricSnapshot()
        first.timestamp = Date(timeIntervalSince1970: 119)
        first.battery.percentage = 48

        var second = MetricSnapshot()
        second.timestamp = Date(timeIntervalSince1970: 120)
        second.battery.percentage = 49

        XCTAssertNil(aggregator.append(first))
        let completedMinute = aggregator.append(second)

        XCTAssertEqual(completedMinute?.timestamp, first.timestamp)
        XCTAssertEqual(completedMinute?.batteryPercent, 48)
        XCTAssertEqual(aggregator.flush()?.batteryPercent, 49)
    }

    func testTemperatureAlertRequiresSustainedDurationAndCooldown() {
        var evaluator = AlertEvaluator()
        var snapshot = MetricSnapshot()
        snapshot.battery.temperatureCelsius = 42
        let start = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(evaluator.evaluate(
            snapshot: snapshot,
            now: start,
            temperatureThreshold: 40
        ).isEmpty)

        XCTAssertEqual(evaluator.evaluate(
            snapshot: snapshot,
            now: start.addingTimeInterval(121),
            temperatureThreshold: 40
        ), ["temperature"])

        XCTAssertTrue(evaluator.evaluate(
            snapshot: snapshot,
            now: start.addingTimeInterval(180),
            temperatureThreshold: 40
        ).isEmpty)
    }

    func testAlertCooldownCanBeRestoredAcrossLaunches() {
        let sentAt = Date(timeIntervalSince1970: 2_000)
        var evaluator = AlertEvaluator(lastSent: ["thermal": sentAt])
        var snapshot = MetricSnapshot()
        snapshot.deep.thermalLevel = .serious

        XCTAssertTrue(evaluator.evaluate(
            snapshot: snapshot,
            now: sentAt.addingTimeInterval(300),
            temperatureThreshold: 40
        ).isEmpty)
    }

    func testInvalidTemperaturesAreRejected() {
        XCTAssertNil(MetricMath.validTemperature(-1))
        XCTAssertNil(MetricMath.validTemperature(150))
        XCTAssertEqual(MetricMath.validTemperature(42.5), 42.5)
    }

    func testExternalPowerCanStillDrainBattery() {
        let state = PowerStateResolver.resolve(
            isCharging: false,
            fullyCharged: false,
            powerSource: .external,
            adapterAttached: true,
            netBatteryPowerWatts: -14.2
        )

        XCTAssertEqual(state, .pluggedDischarging)
    }

    func testZeroPowerIsAValidSensorReading() {
        XCTAssertEqual(MetricMath.nonNegative(0), 0)
        XCTAssertNil(MetricMath.nonNegative(-0.01))
    }

    func testCollectorV2DecodesPartialMetrics() throws {
        let json = """
        {
          "schemaVersion": 2,
          "sequence": 7,
          "timestamp": "2026-07-29T00:00:00Z",
          "metrics": {
            "cpuUsagePercent": 12.5,
            "thermalLevel": "nominal"
          },
          "warnings": ["gpu_sensor_missing"]
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let frame = try decoder.decode(CollectorFrameV2.self, from: Data(json.utf8))

        XCTAssertEqual(frame.sequence, 7)
        XCTAssertEqual(frame.metrics.cpuUsagePercent, 12.5)
        XCTAssertNil(frame.metrics.gpuUsagePercent)
        XCTAssertEqual(frame.warnings, ["gpu_sensor_missing"])
    }

    func testIntervalChangeLaunchesImmediatelyWhenRestartIsPending() {
        let plan = CollectorLifecyclePolicy.intervalChange(processIsRunning: false)

        XCTAssertTrue(plan.launchImmediately)
        XCTAssertFalse(plan.terminateRunningProcess)
        XCTAssertTrue(plan.retainLastMetrics)
    }

    func testCPUUsageHandles32BitTickCounterWraparound() {
        let usage = MetricMath.cpuUsagePercent(
            previous: (
                user: UInt32.max - 5,
                system: 100,
                idle: 200,
                nice: 50
            ),
            current: (
                user: 3,
                system: 104,
                idle: 215,
                nice: 52
            )
        )

        XCTAssertEqual(usage ?? 0, 50, accuracy: 0.001)
    }

    func testCollectorStopsWhenItsOriginalParentDisappears() {
        XCTAssertFalse(CollectorParentPolicy.shouldTerminate(
            configuredParentPID: 500,
            signalResult: 0,
            errorCode: 0
        ))
        XCTAssertTrue(CollectorParentPolicy.shouldTerminate(
            configuredParentPID: 500,
            signalResult: -1,
            errorCode: ESRCH
        ))
        XCTAssertFalse(CollectorParentPolicy.shouldTerminate(
            configuredParentPID: nil,
            signalResult: -1,
            errorCode: ESRCH
        ))
        XCTAssertFalse(CollectorParentPolicy.shouldTerminate(
            configuredParentPID: 500,
            signalResult: -1,
            errorCode: EPERM
        ))
    }
}
