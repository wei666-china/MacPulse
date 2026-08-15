import Foundation
import XCTest
@testable import MacPulseCore

/// 内存诊断判据。这个诊断上线时漏了测试文件(项目约定的欠账),现在补上。
/// 判据铁律:不看「已用」,只看换页量、压缩占比、系统压力三个硬信号。
final class MemoryDiagnosisTests: XCTestCase {

    private let gb: UInt64 = 1_073_741_824

    /// 24GB 机器的基准分项;compressedPages 用 16KB 页折算。
    private func breakdown(compressedBytes: UInt64 = 0) -> MemoryBreakdown {
        MemoryBreakdown(
            counts: VMPageCounts(
                free: 100_000, active: 400_000, inactive: 200_000, speculative: 10_000,
                wired: 150_000, purgeable: 50_000, anonymous: 500_000, fileBacked: 300_000,
                compressorOccupied: compressedBytes / 16_384,
                uncompressedInCompressor: compressedBytes / 16_384
            ),
            pageSize: 16_384,
            totalBytes: 24 * gb
        )
    }

    private func extras(swapUsed: UInt64? = nil, pressure: Int? = nil) -> MemorySnapshotExtras {
        .init(swapUsedBytes: swapUsed, swapTotalBytes: swapUsed, pressureLevel: pressure)
    }

    func testZeroTotalYieldsNil() {
        let broken = MemoryBreakdown(counts: VMPageCounts(
            free: 0, active: 0, inactive: 0, speculative: 0, wired: 0,
            purgeable: 0, anonymous: 0, fileBacked: 0,
            compressorOccupied: 0, uncompressedInCompressor: 0
        ), pageSize: 16_384, totalBytes: 0)
        XCTAssertNil(MemoryDiagnosis.diagnose(breakdown: broken, extras: extras()),
                     "总量读不到就不下结论")
    }

    func testComfortableBaseline() throws {
        let verdict = try XCTUnwrap(MemoryDiagnosis.diagnose(
            breakdown: breakdown(), extras: extras(swapUsed: 0, pressure: 1)
        ))
        XCTAssertEqual(verdict.kind, .comfortable)
        XCTAssertFalse(verdict.isWarning)
        XCTAssertNil(verdict.advice, "一切正常时不该硬给建议")
    }

    func testMildSwapBoundaryTriggersOccasional() throws {
        // 恰到 1GB 触发;差 1 字节不触发。
        let at = try XCTUnwrap(MemoryDiagnosis.diagnose(
            breakdown: breakdown(), extras: extras(swapUsed: MemoryDiagnosis.mildSwapBytes, pressure: 1)
        ))
        XCTAssertEqual(at.kind, .occasionalPressure)
        XCTAssertFalse(at.isWarning, "偶尔吃紧不是警告")
        let below = try XCTUnwrap(MemoryDiagnosis.diagnose(
            breakdown: breakdown(), extras: extras(swapUsed: MemoryDiagnosis.mildSwapBytes - 1, pressure: 1)
        ))
        XCTAssertEqual(below.kind, .comfortable)
    }

    func testHeavySwapBoundaryTriggersInsufficient() throws {
        let verdict = try XCTUnwrap(MemoryDiagnosis.diagnose(
            breakdown: breakdown(), extras: extras(swapUsed: MemoryDiagnosis.heavySwapBytes, pressure: 1)
        ))
        XCTAssertEqual(verdict.kind, .insufficient)
        XCTAssertTrue(verdict.isWarning)
        XCTAssertNotNil(verdict.advice)
    }

    func testSystemPressureAloneConvicts() throws {
        // 系统自己报压力是最权威信号,swap 为零也定罪。
        let verdict = try XCTUnwrap(MemoryDiagnosis.diagnose(
            breakdown: breakdown(), extras: extras(swapUsed: 0, pressure: 2)
        ))
        XCTAssertEqual(verdict.kind, .insufficient)
        XCTAssertTrue(verdict.detail.contains("压力"), "detail 要点明是系统压力定的罪")
    }

    func testHeavyCompressionTriggersOccasional() throws {
        // 压缩占比 ≥25%(24GB × 25% = 6GB)且无换页、无压力 → 偶尔吃紧。
        let verdict = try XCTUnwrap(MemoryDiagnosis.diagnose(
            breakdown: breakdown(compressedBytes: 7 * gb),
            extras: extras(swapUsed: 0, pressure: 1)
        ))
        XCTAssertEqual(verdict.kind, .occasionalPressure)
    }

    /// 本机实测回归(2026-08-13,M5/24GB):压缩 6.6GB(27.5%)、swap 2.48GB、
    /// 压力正常 → 判「偶尔吃紧」。当时与实况核对过,这个样本定住判据。
    func testRealMachineSampleRegression() throws {
        let verdict = try XCTUnwrap(MemoryDiagnosis.diagnose(
            breakdown: breakdown(compressedBytes: UInt64(6.6 * Double(gb))),
            extras: extras(swapUsed: UInt64(2.48 * Double(gb)), pressure: 1)
        ))
        XCTAssertEqual(verdict.kind, .occasionalPressure)
        XCTAssertFalse(verdict.isWarning)
    }

    func testMissingExtrasDefaultsToBenign() throws {
        // swap/压力读不到时按 0/正常处理——判据宁可漏报不误报。
        let verdict = try XCTUnwrap(MemoryDiagnosis.diagnose(
            breakdown: breakdown(), extras: extras()
        ))
        XCTAssertEqual(verdict.kind, .comfortable)
    }
}
