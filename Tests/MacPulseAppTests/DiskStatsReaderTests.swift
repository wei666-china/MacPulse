import XCTest
@testable import MacPulse

/// 磁盘读取真机对账。真值:`df`(卷容量)与 `iostat`(累计读写),
/// 与实现(FileManager / IOBlockStorageDriver)走完全不同的代码路径。
final class DiskStatsReaderTests: XCTestCase {
    private func shell(_ command: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    func testRootVolumePresentAndCoherent() throws {
        let overview = DiskStatsReader.read()
        let root = try XCTUnwrap(overview.volumes.first(where: \.isRoot), "启动卷必须在列")
        XCTAssertGreaterThan(root.totalBytes, 0)
        XCTAssertLessThanOrEqual(root.usedBytes, root.totalBytes)
        XCTAssertGreaterThanOrEqual(root.purgeableBytes, 0)
        XCTAssertLessThanOrEqual(
            Double(root.usedBytes + root.purgeableBytes),
            Double(root.totalBytes) * 1.01,
            "已用+可腾出超过总容量,读数不自洽"
        )
    }

    func testRootCapacityAgreesWithDF() throws {
        let overview = DiskStatsReader.read()
        let root = try XCTUnwrap(overview.volumes.first(where: \.isRoot))
        // df -k 的第二列是 1K 块总数。
        let output = shell("df -k / | tail -1 | awk '{print $2}'")
        guard let dfKB = Int64(output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw XCTSkip("df 输出解析不了")
        }
        let dfBytes = dfKB * 1024
        let ratio = Double(root.totalBytes) / Double(dfBytes)
        XCTAssertEqual(ratio, 1.0, accuracy: 0.02, "与 df 的总容量差超过 2%")
    }

    func testSessionTotalsAgreeWithIostatMagnitude() throws {
        let overview = DiskStatsReader.read()
        guard let read = overview.sessionReadBytes, let write = overview.sessionWriteBytes else {
            throw XCTSkip("本机读不到累计读写")
        }
        // iostat -Id disk0 第三列是开机以来**读+写合计** MB(主物理盘)。
        // 第一版拿它对「只读」量,被这条测试自己抓出来——对账先对口径。
        // 两边仍有口径差(单盘 vs 全部驱动求和),按数量级对:
        // 全机合计 ≥ 主盘合计的 95%,且 ≤ 主盘 5 倍。
        let output = shell("iostat -Id disk0 | tail -1 | awk '{print $3}'")
        guard let disk0MB = Double(output.trimmingCharacters(in: .whitespacesAndNewlines)),
              disk0MB > 0 else {
            throw XCTSkip("iostat 输出解析不了")
        }
        let totalMB = Double(read + write) / 1_048_576
        XCTAssertGreaterThanOrEqual(totalMB * 1.05, disk0MB, "全机累计合计还小于单盘,口径必有一边错")
        XCTAssertLessThan(totalMB, disk0MB * 5 + 10_240, "全机累计合计超过主盘 5 倍,疑似重复计数")
    }
}
