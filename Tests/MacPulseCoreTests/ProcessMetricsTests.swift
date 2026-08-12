import Foundation
import XCTest
@testable import MacPulseCore

final class ProcessMetricsTests: XCTestCase {
    func testCPUAndRatesUseCounterDeltas() {
        let start = Date(timeIntervalSince1970: 1_000)
        let previous = counters(
            pid: 10,
            start: 50,
            timestamp: start,
            userTime: 1_000_000_000,
            systemTime: 500_000_000,
            diskRead: 1_000,
            diskWrite: 2_000,
            wakeups: 10,
            energy: 100
        )
        let current = counters(
            pid: 10,
            start: 50,
            timestamp: start.addingTimeInterval(2),
            userTime: 2_000_000_000,
            systemTime: 500_000_000,
            diskRead: 5_000,
            diskWrite: 8_000,
            wakeups: 30,
            energy: 2_100
        )

        let result = ProcessAggregation.makeSnapshot(
            current: current,
            previous: previous,
            previousSmoothedCPU: nil,
            currentUserID: 501
        )

        XCTAssertEqual(result.cpuPercent ?? 0, 50, accuracy: 0.001)
        XCTAssertEqual(result.diskReadBytesPerSecond ?? 0, 2_000, accuracy: 0.001)
        XCTAssertEqual(result.diskWriteBytesPerSecond ?? 0, 3_000, accuracy: 0.001)
        XCTAssertEqual(result.wakeupsPerSecond ?? 0, 10, accuracy: 0.001)
        XCTAssertEqual(result.energyNanojoulesPerSecond ?? 0, 1_000, accuracy: 0.001)
        XCTAssertFalse(result.isEstablishingBaseline)
    }

    func testPIDReuseCreatesNewBaseline() {
        let previous = counters(
            pid: 10,
            start: 50,
            timestamp: Date(timeIntervalSince1970: 1_000),
            userTime: 9_000
        )
        let current = counters(
            pid: 10,
            start: 99,
            timestamp: Date(timeIntervalSince1970: 1_005),
            userTime: 100
        )

        let result = ProcessAggregation.makeSnapshot(
            current: current,
            previous: previous,
            previousSmoothedCPU: 80,
            currentUserID: 501
        )

        XCTAssertNil(result.cpuPercent)
        XCTAssertNil(result.diskReadBytesPerSecond)
        XCTAssertTrue(result.isEstablishingBaseline)
    }

    func testCounterRollbackDoesNotCreateSpike() {
        XCTAssertNil(ProcessDeltaMath.rate(
            previous: 1_000,
            current: 10,
            elapsed: 2
        ))
        XCTAssertNil(ProcessDeltaMath.cpuPercent(
            previousUser: 1_000,
            previousSystem: 1_000,
            currentUser: 10,
            currentSystem: 10,
            elapsed: 2
        ))
    }

    func testPermissionLimitedProcessKeepsStaticFieldsButNoRates() {
        var previous = counters(
            pid: 8,
            start: 1,
            timestamp: Date(timeIntervalSince1970: 1_000),
            userTime: 100
        )
        previous.isPermissionLimited = true
        var current = previous
        current.timestamp = Date(timeIntervalSince1970: 1_005)
        current.physicalFootprintBytes = nil

        let result = ProcessAggregation.makeSnapshot(
            current: current,
            previous: previous,
            previousSmoothedCPU: nil,
            currentUserID: 501
        )

        XCTAssertTrue(result.isPermissionLimited)
        XCTAssertTrue(result.isEstablishingBaseline)
        XCTAssertNil(result.cpuPercent)
    }

    func testNestedHelperUsesOutermostAppGroup() {
        let app = snapshot(
            pid: 100,
            parentPID: 1,
            name: "Browser",
            path: "/Applications/Browser.app/Contents/MacOS/Browser",
            bundle: "com.example.browser",
            category: .application
        )
        let helper = snapshot(
            pid: 101,
            parentPID: 100,
            name: "Browser Helper",
            path: "/Applications/Browser.app/Contents/Frameworks/Browser Helper.app/Contents/MacOS/Browser Helper",
            bundle: "com.example.browser.helper.renderer",
            category: .background
        )

        let groups = ProcessAggregation.group([app, helper])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.stableIdentifier, "com.example.browser")
        XCTAssertEqual(groups.first?.children.count, 2)
        XCTAssertEqual(groups.first?.category, .application)
    }

    func testMacPulseComponentsAlwaysMerge() {
        let app = snapshot(
            pid: 200,
            parentPID: 1,
            name: "MacPulse",
            path: "/Applications/MacPulse.app/Contents/MacOS/MacPulse",
            bundle: ProcessAggregation.macPulseIdentifier,
            category: .application
        )
        let collector = snapshot(
            pid: 201,
            parentPID: 200,
            name: "MacPulseCollector",
            path: "/Applications/MacPulse.app/Contents/Helpers/MacPulseCollector",
            category: .background
        )
        let mactop = snapshot(
            pid: 202,
            parentPID: 201,
            name: "mactop",
            path: "/Applications/MacPulse.app/Contents/Helpers/mactop",
            category: .background
        )

        let groups = ProcessAggregation.group([app, collector, mactop])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.stableIdentifier, ProcessAggregation.macPulseIdentifier)
        XCTAssertEqual(groups.first?.children.count, 3)
        XCTAssertTrue(groups.first?.isMacPulse == true)
    }

    func testMinuteHistoryKeepsMacPulseAndTopFive() {
        var aggregator = ProcessMinuteAggregator(topLimit: 5)
        let timestamp = Date(timeIntervalSince1970: 120)
        let groups = [
            historyGroup(id: ProcessAggregation.macPulseIdentifier, score: 0.01, selfGroup: true)
        ] + (0..<7).map {
            historyGroup(id: "app.\($0)", score: Double($0) / 10)
        }

        XCTAssertNil(aggregator.append(timestamp: timestamp, groups: groups))
        let completed = aggregator.append(
            timestamp: timestamp.addingTimeInterval(60),
            groups: []
        )

        XCTAssertEqual(completed?.count, 6)
        XCTAssertTrue(completed?.contains(where: \.isMacPulse) == true)
        XCTAssertEqual(
            Set(completed?.filter { !$0.isMacPulse }.map(\.stableIdentifier) ?? []),
            Set(["app.2", "app.3", "app.4", "app.5", "app.6"])
        )
    }

    private func counters(
        pid: Int32,
        start: UInt64,
        timestamp: Date,
        userTime: UInt64 = 0,
        systemTime: UInt64 = 0,
        diskRead: UInt64 = 0,
        diskWrite: UInt64 = 0,
        wakeups: UInt64 = 0,
        energy: UInt64 = 0
    ) -> ProcessCounters {
        ProcessCounters(
            pid: pid,
            parentPID: 1,
            userID: 501,
            startAbstime: start,
            timestamp: timestamp,
            userTimeNanoseconds: userTime,
            systemTimeNanoseconds: systemTime,
            physicalFootprintBytes: 1_000,
            diskReadBytes: diskRead,
            diskWriteBytes: diskWrite,
            wakeups: wakeups,
            energyNanojoules: energy,
            threadCount: 2,
            displayName: "Test",
            executablePath: "/usr/bin/test"
        )
    }

    private func snapshot(
        pid: Int32,
        parentPID: Int32,
        name: String,
        path: String,
        bundle: String? = nil,
        category: ProcessCategory
    ) -> ProcessSnapshot {
        ProcessSnapshot(
            pid: pid,
            parentPID: parentPID,
            startAbstime: UInt64(pid),
            stableIdentifier: bundle ?? path,
            displayName: name,
            bundleIdentifier: bundle,
            executablePath: path,
            launchDate: Date(timeIntervalSince1970: 100),
            category: category,
            cpuPercent: 1,
            smoothedCPUPercent: 1,
            physicalFootprintBytes: 1_000,
            diskReadBytesPerSecond: 1,
            diskWriteBytesPerSecond: 1,
            wakeupsPerSecond: 1,
            energyNanojoulesPerSecond: 1,
            threadCount: 1,
            isEstablishingBaseline: false,
            isPermissionLimited: false
        )
    }

    private func historyGroup(
        id: String,
        score: Double,
        selfGroup: Bool = false
    ) -> ProcessGroupSnapshot {
        ProcessGroupSnapshot(
            stableIdentifier: id,
            displayName: id,
            category: .application,
            primaryPID: 1,
            children: [],
            cpuPercent: score * 100,
            smoothedCPUPercent: score * 100,
            physicalFootprintBytes: 1_000,
            diskReadBytesPerSecond: 1,
            diskWriteBytesPerSecond: 1,
            wakeupsPerSecond: 1,
            energyNanojoulesPerSecond: 1,
            compositeScore: score,
            isMacPulse: selfGroup
        )
    }
}
