import Foundation
import XCTest
@testable import MacPulse
@testable import MacPulseCore

/// 诊断候选榜的第二道并集(采样层 topGroups 是第一道)。
/// 评审反例:CPU 轻、GPU 重的进程在综合分前十之外,GPU 饱和报了却点不出名。
@MainActor
final class BottleneckCandidatesTests: XCTestCase {
    private func group(_ name: String, score: Double, cpu: Double, gpu: Double? = nil) -> ProcessGroupSnapshot {
        ProcessGroupSnapshot(
            stableIdentifier: name, displayName: name, category: .application,
            primaryPID: 1, children: [], cpuPercent: cpu, smoothedCPUPercent: cpu,
            physicalFootprintBytes: nil, diskReadBytesPerSecond: nil,
            diskWriteBytesPerSecond: nil, wakeupsPerSecond: nil,
            energyNanojoulesPerSecond: nil, gpuNanosecondsPerSecond: gpu,
            compositeScore: score
        )
    }

    func testLowCPUHighGPUProcessBecomesCandidate() {
        var groups = (0..<12).map { group("app\($0)", score: Double(50 - $0), cpu: 80) }
        groups.append(group("推理器", score: 0.1, cpu: 3, gpu: 8.0e8))   // 综合分第 13 名
        let candidates = DashboardModel.bottleneckCandidates(from: groups)
        XCTAssertTrue(candidates.contains { $0.name == "推理器" }, "GPU 重进程必须进候选榜")
        // 并且真的能被点名
        let verdict = BottleneckDiagnosis.diagnose(.init(
            window: .init(ticks: [
                .init(cpuUsagePercent: 20, gpuUsagePercent: 96, collectorLive: true),
                .init(cpuUsagePercent: 22, gpuUsagePercent: 97, collectorLive: true),
                .init(cpuUsagePercent: 21, gpuUsagePercent: 95, collectorLive: true),
            ]),
            processes: candidates,
            activeProcessorCount: 10,
            physicalMemoryBytes: 24 * 1_073_741_824
        ))
        XCTAssertEqual(verdict?.kind, .gpuSaturated)
        XCTAssertEqual(verdict?.findings.first { $0.kind == .gpuSaturated }?.culpritName, "推理器")
    }
}
