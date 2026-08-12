import Foundation
import MacPulseCore
import XCTest
@testable import MacPulse

@MainActor
final class ProcessHistoryStoreTests: XCTestCase {
    func testSeparateStoreSavesLoadsAndPrunesSevenDays() throws {
        let store = try ProcessHistoryStore(inMemory: true)
        let identifier = "com.example.history"
        let recent = point(
            timestamp: Date().addingTimeInterval(-60),
            identifier: identifier
        )
        let expired = point(
            timestamp: Date().addingTimeInterval(-8 * 86_400),
            identifier: identifier
        )

        try store.save([recent, expired])
        XCTAssertEqual(try store.recordCount(), 2)

        try store.prune()

        XCTAssertEqual(try store.recordCount(), 1)
        XCTAssertEqual(
            try store.loadRecent(stableIdentifier: identifier).map(\.timestamp),
            [recent.timestamp]
        )
    }

    func testUniqueMinuteKeyDoesNotDuplicateHistory() throws {
        let store = try ProcessHistoryStore(inMemory: true)
        let point = point(
            timestamp: Date(timeIntervalSince1970: 1_000),
            identifier: "com.example.unique"
        )

        try store.save([point])
        try store.save([point])

        XCTAssertEqual(try store.recordCount(), 1)
    }

    private func point(
        timestamp: Date,
        identifier: String
    ) -> ProcessHistoryPoint {
        ProcessHistoryPoint(
            timestamp: timestamp,
            stableIdentifier: identifier,
            displayName: "Example",
            bundleIdentifier: identifier,
            cpuAveragePercent: 10,
            cpuPeakPercent: 20,
            physicalFootprintAverageBytes: 100,
            physicalFootprintPeakBytes: 200,
            diskReadBytesPerSecond: 1,
            diskWriteBytesPerSecond: 2,
            energyNanojoulesPerSecond: 3,
            compositeScore: 0.5,
            isMacPulse: false
        )
    }
}
