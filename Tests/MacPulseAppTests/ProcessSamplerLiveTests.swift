import Foundation
import XCTest
@testable import MacPulse
@testable import MacPulseCore

/// 进程采样活体检查:自造一个单核烧机进程,采样器必须看得见它、
/// 且给出接近一个核的 CPU%。「为什么卡」的归因链靠这条兜底。
final class ProcessSamplerLiveTests: XCTestCase {
    func testFreshCPUBurnerIsVisibleWithPlausibleCPU() async throws {
        let burner = Process()
        burner.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
        burner.standardOutput = FileHandle.nullDevice
        try burner.run()
        defer { burner.terminate() }

        let sampler = ProcessSampler()
        _ = await sampler.sample()                       // 基线
        try await Task.sleep(nanoseconds: 2_000_000_000) // 差分窗口
        let result = await sampler.sample()

        let group = result.groups.first { group in
            group.displayName.lowercased().contains("yes")
                || group.children.contains { $0.displayName.lowercased().contains("yes") }
        }
        let unwrapped = try XCTUnwrap(group, "烧机进程必须出现在进程组里;在场组名:\(result.groups.prefix(12).map(\.displayName))")
        let cpu = unwrapped.cpuPercent ?? 0
        XCTAssertGreaterThan(cpu, 60, "单核烧机的 CPU% 应接近 100(单核制),实测 \(cpu)")
    }
}
