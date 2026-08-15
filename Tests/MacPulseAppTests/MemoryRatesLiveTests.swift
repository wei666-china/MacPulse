import Foundation
import XCTest
@testable import MacPulse
@testable import MacPulseCore

/// 换页速率读取层的活体检查。与 vm_stat 同源(host_statistics64),
/// 这里验读取协议:首拍无基线必须 nil,第二拍速率非负且量级理智。
final class MemoryRatesLiveTests: XCTestCase {
    func testLiveReaderProducesSaneRates() throws {
        let reader = SystemFallbackReader()
        XCTAssertNil(reader.memoryRates(), "首拍没有基线,必须是 nil 而不是编一个 0")
        Thread.sleep(forTimeInterval: 0.4)
        let rates = try XCTUnwrap(reader.memoryRates(), "第二拍应有差分")
        for value in [rates.pageinBytesPerSecond, rates.pageoutBytesPerSecond,
                      rates.swapinBytesPerSecond, rates.swapoutBytesPerSecond,
                      rates.compressionBytesPerSecond, rates.decompressionBytesPerSecond] {
            XCTAssertGreaterThanOrEqual(value, 0)
            XCTAssertLessThan(value, 100 * 1_073_741_824, "量级失真,多半是页大小或字段读错")
        }
    }
}
