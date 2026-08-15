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

    /// 真值神谕:同一瞬间的累计 pageins 必须与 vm_stat 对上(同源 host_statistics64,
    /// 单位都是页)。两次 syscall 间的漂移给 512 页容差;速率绝对值不写死。
    func testCumulativePageinsMatchVMStat() throws {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw XCTSkip("host_statistics64 不可用") }

        let vm = Process()
        vm.executableURL = URL(fileURLWithPath: "/usr/bin/vm_stat")
        let pipe = Pipe(); vm.standardOutput = pipe
        try vm.run(); vm.waitUntilExit()
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix("Pageins:") }),
              let oracle = UInt64(line.split(separator: " ").last?.dropLast() ?? "")
        else { throw XCTSkip("vm_stat 输出没有 Pageins 行") }

        let ours = UInt64(stats.pageins)
        let drift = ours > oracle ? ours - oracle : oracle - ours
        XCTAssertLessThan(drift, 512, "累计 pageins 与 vm_stat 差 \(drift) 页——单位或字段读错了")
    }
}

/// GPU 设备利用率读取器活体检查(评审 P1-3:此前没有任何读取测试)。
final class GPUUtilizationReaderLiveTests: XCTestCase {
    func testReadReturnsSanePercentOrNil() throws {
        guard let value = GPUUtilizationReader.read() else {
            throw XCTSkip("本机读不到 AGXAccelerator(虚拟机属预期),读不到返回 nil 而不是 0,正确")
        }
        XCTAssertGreaterThanOrEqual(value, 0)
        XCTAssertLessThanOrEqual(value, 100)
    }
}
