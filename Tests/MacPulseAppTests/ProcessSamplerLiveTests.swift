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
        // 对拍必须在**子进程级**:组按责任 App 折叠,烧机进程会被折进
        // 测试进程(xctest)的组里,组 CPU% = xctest + yes 之和(首版测试
        // 拿组和 ps 单进程比,误差 34% 全是 xctest 自己——比错了对象)。
        let child = unwrapped.children.first { $0.displayName.lowercased().contains("yes") }
        let cpu = child?.cpuPercent ?? unwrapped.cpuPercent ?? 0
        XCTAssertGreaterThan(cpu, 60, "单核烧机的 CPU% 应接近 100(单核制),实测 \(cpu)")
        // 评审加固:上限锁住「修过头」——忘了时基换算是 2.4%,换算两次是 ~4100%。
        XCTAssertLessThan(cpu, 200, "单核烧机不可能超过 200%,多半是重复换算")

        // 独立工具对拍:ps 的 %cpu(同为单核制)。ps 是衰减均值、我们是
        // 窗口差分,口径有天然漂移,±25 个百分点内视为同一量级。
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "%cpu=", "-p", String(burner.processIdentifier)]
        let pipe = Pipe(); ps.standardOutput = pipe
        try ps.run(); ps.waitUntilExit()
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if let psCPU = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            XCTAssertEqual(cpu, psCPU, accuracy: 25, "与 ps 对不上:我们 \(cpu) vs ps \(psCPU)")
        } else {
            throw XCTSkip("ps 没给出数值,跳过对拍")
        }
    }
}
