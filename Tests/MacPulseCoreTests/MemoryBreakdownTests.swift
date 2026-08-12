import XCTest
@testable import MacPulseCore

final class MemoryBreakdownTests: XCTestCase {
    /// 取自本机一次真实的 `vm_stat`（页大小 16384，物理内存 24 GiB）。
    /// 用真实快照而不是编出来的圆整数字，是为了让公式一旦被人改动，
    /// 失败信息能直接跟活动监视器对照。
    private var liveCounts: VMPageCounts {
        VMPageCounts(
            free: 41_945,
            active: 341_190,
            inactive: 338_277,
            speculative: 1_631,
            wired: 201_215,
            purgeable: 36_993,
            anonymous: 445_660,
            fileBacked: 235_438,
            compressorOccupied: 605_950,
            uncompressedInCompressor: 1_587_537
        )
    }

    private let pageSize: UInt64 = 16_384
    private let totalBytes: UInt64 = 25_769_803_776

    func testLiveSnapshotBreaksDownToTheByte() {
        let breakdown = MemoryBreakdown(
            counts: liveCounts,
            pageSize: pageSize,
            totalBytes: totalBytes,
            swapTotalBytes: 1_073_741_824,
            swapUsedBytes: 216_268_800,
            pressureLevel: .normal
        )

        // 应用内存 = 匿名页 − 可丢弃页
        XCTAssertEqual(breakdown.appBytes, 6_695_600_128)
        XCTAssertEqual(breakdown.wiredBytes, 3_296_706_560)
        XCTAssertEqual(breakdown.compressedBytes, 9_927_884_800)
        // 缓存文件 = 文件页 + 可丢弃页，不计入「已使用」
        XCTAssertEqual(breakdown.cachedFilesBytes, 4_463_509_504)
        XCTAssertEqual(breakdown.usedBytes, 19_920_191_488)
        XCTAssertEqual(breakdown.freeBytes, 1_386_102_784)
        XCTAssertEqual(breakdown.compressorSavedBytes, 16_082_321_408)
        XCTAssertEqual(breakdown.swapUsedBytes, 216_268_800)
        XCTAssertEqual(breakdown.pressureLevel, .normal)
    }

    /// 四类之和必须严格等于「已使用 + 缓存文件」，而余量就是可用。
    /// 界面上的堆叠条依赖这个恒等式，差一个字节都会露白边。
    func testSegmentsAndRemainderCoverTotal() {
        let breakdown = MemoryBreakdown(counts: liveCounts, pageSize: pageSize, totalBytes: totalBytes)
        let sum = breakdown.appBytes
            + breakdown.wiredBytes
            + breakdown.compressedBytes
            + breakdown.cachedFilesBytes
            + breakdown.freeBytes
        XCTAssertEqual(sum, totalBytes)
        XCTAssertEqual(breakdown.unaccountedBytes, breakdown.freeBytes)
    }

    func testUsedFractionMatchesActivityMonitorScale() throws {
        let breakdown = MemoryBreakdown(counts: liveCounts, pageSize: pageSize, totalBytes: totalBytes)
        let fraction = try XCTUnwrap(breakdown.usedFraction)
        XCTAssertEqual(fraction, 0.773_005, accuracy: 0.000_001)
    }

    func testNoSwapReportsNilRatherThanZero() {
        let breakdown = MemoryBreakdown(counts: liveCounts, pageSize: pageSize, totalBytes: totalBytes)
        // 没读到就是没读到。写 0 会被读成「交换区存在且未使用」。
        XCTAssertNil(breakdown.swapTotalBytes)
        XCTAssertNil(breakdown.swapUsedBytes)
    }

    /// 统计不是原子快照，各计数可能瞬时不一致。任何一处用无符号减法都会
    /// 回绕成 16EB，界面上直接炸出天文数字。这里逼出那些边界。
    func testInconsistentSnapshotSaturatesInsteadOfWrapping() {
        let oversubscribed = VMPageCounts(
            wired: 900_000,
            purgeable: 0,
            anonymous: 900_000,
            fileBacked: 900_000,
            compressorOccupied: 900_000,
            uncompressedInCompressor: 0 // 比压缩后还小：不可能，但必须扛住
        )
        let breakdown = MemoryBreakdown(
            counts: oversubscribed,
            pageSize: pageSize,
            totalBytes: 1_073_741_824 // 故意远小于各分项之和
        )
        XCTAssertEqual(breakdown.freeBytes, 0)
        XCTAssertEqual(breakdown.unaccountedBytes, 0)
        XCTAssertNil(breakdown.compressorSavedBytes)
        XCTAssertLessThan(breakdown.usedBytes, UInt64.max / 2)
    }

    func testPurgeableLargerThanAnonymousDoesNotWrap() {
        let odd = VMPageCounts(purgeable: 10_000, anonymous: 1_000)
        let breakdown = MemoryBreakdown(counts: odd, pageSize: pageSize, totalBytes: totalBytes)
        XCTAssertEqual(breakdown.appBytes, 0)
    }

    func testZeroTotalDoesNotDivideByZero() {
        let breakdown = MemoryBreakdown(counts: liveCounts, pageSize: pageSize, totalBytes: 0)
        XCTAssertNil(breakdown.usedFraction)
        XCTAssertNil(breakdown.approximatePressurePercent)
    }
}
