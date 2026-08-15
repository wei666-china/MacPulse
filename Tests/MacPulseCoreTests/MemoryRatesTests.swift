import Foundation
import XCTest
@testable import MacPulseCore

/// 换页速率差分。页 → 字节的换算与防御路径(回绕/零时长)是全部要点。
final class MemoryRatesTests: XCTestCase {

    private func counters(
        pageins: UInt64 = 0, pageouts: UInt64 = 0,
        swapins: UInt64 = 0, swapouts: UInt64 = 0,
        compressions: UInt64 = 0, decompressions: UInt64 = 0
    ) -> VMCumulativeCounters {
        .init(pageins: pageins, pageouts: pageouts, swapins: swapins,
              swapouts: swapouts, compressions: compressions, decompressions: decompressions)
    }

    func testRatesArePagesTimesPageSizePerSecond() throws {
        // 2 秒内换出 2000 页 × 16KB = 32MB → 16MB/s。
        let rates = try XCTUnwrap(MemoryRates.compute(
            previous: counters(swapouts: 1_000),
            current: counters(swapouts: 3_000),
            elapsed: 2,
            pageSize: 16_384
        ))
        XCTAssertEqual(rates.swapoutBytesPerSecond, 16_384_000, accuracy: 1)
        XCTAssertEqual(rates.swapinBytesPerSecond, 0)
        XCTAssertEqual(rates.swapBidirectionalBytesPerSecond, 16_384_000, accuracy: 1)
    }

    func testCounterRegressionYieldsNil() {
        // 计数回绕(current < previous)理论不发生,发生了也绝不给负数。
        XCTAssertNil(MemoryRates.compute(
            previous: counters(pageins: 100),
            current: counters(pageins: 99),
            elapsed: 2, pageSize: 16_384
        ))
    }

    func testNonPositiveElapsedYieldsNil() {
        XCTAssertNil(MemoryRates.compute(
            previous: counters(), current: counters(pageins: 10),
            elapsed: 0, pageSize: 16_384
        ))
        XCTAssertNil(MemoryRates.compute(
            previous: counters(), current: counters(pageins: 10),
            elapsed: -1, pageSize: 16_384
        ))
    }

    func testZeroDeltaIsAllZeroRates() throws {
        // 没有任何换页是合法状态(健康机器的常态),是全 0 不是 nil。
        let rates = try XCTUnwrap(MemoryRates.compute(
            previous: counters(pageins: 5, swapouts: 7),
            current: counters(pageins: 5, swapouts: 7),
            elapsed: 2, pageSize: 16_384
        ))
        XCTAssertEqual(rates.pageinBytesPerSecond, 0)
        XCTAssertEqual(rates.swapBidirectionalBytesPerSecond, 0)
    }

}
