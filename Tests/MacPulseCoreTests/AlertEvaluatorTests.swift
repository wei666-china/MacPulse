import Foundation
import XCTest
@testable import MacPulseCore


/// 外设低电量判定:阈值与按设备冷却。
final class PeripheralAlertPolicyTests: XCTestCase {
    private func candidate(_ id: String, _ percent: Int) -> PeripheralAlertCandidate {
        .init(id: id, name: id, worstPercent: percent)
    }

    func testBelowThresholdFires() {
        let due = PeripheralAlertPolicy.due(
            candidates: [candidate("a", 15), candidate("b", 50)],
            threshold: 20, lastSent: [:], now: .now
        )
        XCTAssertEqual(due.map(\.id), ["a"], "只有低于阈值的设备提醒")
    }

    func testExactThresholdFires() {
        let due = PeripheralAlertPolicy.due(
            candidates: [candidate("a", 20)], threshold: 20, lastSent: [:], now: .now
        )
        XCTAssertEqual(due.count, 1, "恰到阈值算低电")
    }

    func testPerDeviceCooldownSuppresses() {
        let now = Date()
        let due = PeripheralAlertPolicy.due(
            candidates: [candidate("a", 10), candidate("b", 10)],
            threshold: 20,
            lastSent: ["a": now.addingTimeInterval(-3600)],   // a 一小时前刚提醒过
            now: now
        )
        XCTAssertEqual(due.map(\.id), ["b"], "冷却按设备记,不连坐")
    }

    func testCooldownExpiresAfterEightHours() {
        let now = Date()
        let due = PeripheralAlertPolicy.due(
            candidates: [candidate("a", 10)],
            threshold: 20,
            lastSent: ["a": now.addingTimeInterval(-9 * 3600)],
            now: now
        )
        XCTAssertEqual(due.count, 1)
    }
}
