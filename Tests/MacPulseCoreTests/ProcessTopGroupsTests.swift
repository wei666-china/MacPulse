import Foundation
import XCTest
@testable import MacPulseCore

/// 榜单截断的并集规则。评审反例:55 个普通进程 + 1 个 GPU-only,
/// 纯综合分 prefix(50) 把 GPU-only 排到 rank 56 直接截掉。
final class ProcessTopGroupsTests: XCTestCase {
    private func group(_ name: String, score: Double, gpu: Double? = nil) -> ProcessGroupSnapshot {
        ProcessGroupSnapshot(
            stableIdentifier: name, displayName: name, category: .application,
            primaryPID: 1, children: [], cpuPercent: score, smoothedCPUPercent: score,
            physicalFootprintBytes: nil, diskReadBytesPerSecond: nil,
            diskWriteBytesPerSecond: nil, wakeupsPerSecond: nil,
            energyNanojoulesPerSecond: nil, gpuNanosecondsPerSecond: gpu,
            compositeScore: score
        )
    }

    func testGPUOnlyProcessSurvivesTheCut() {
        var groups = (0..<55).map { group("app\($0)", score: Double(100 - $0)) }
        groups.append(group("推理器", score: 0.1, gpu: 9.0e8))   // rank 56
        let kept = ProcessAggregation.topGroups(groups)
        XCTAssertTrue(kept.contains { $0.displayName == "推理器" },
                      "GPU 过线进程必须在并集里,否则诊断永远点不到名")
        XCTAssertEqual(kept.count, 51, "top-50 + 1 个 GPU 补录")
    }

    func testGPUBelowFloorIsNotRescued() {
        var groups = (0..<55).map { group("app\($0)", score: Double(100 - $0)) }
        groups.append(group("轻GPU", score: 0.1, gpu: 1.0e8))   // 低于 2e8 点名线
        let kept = ProcessAggregation.topGroups(groups)
        XCTAssertFalse(kept.contains { $0.displayName == "轻GPU" })
        XCTAssertEqual(kept.count, 50)
    }
}
