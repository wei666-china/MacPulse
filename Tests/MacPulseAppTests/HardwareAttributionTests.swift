import XCTest
@testable import MacPulse

final class HardwareAttributionTests: XCTestCase {
    // MARK: - 纯解析

    func testParsesPIDFromUserClientCreator() {
        XCTAssertEqual(GPUProcessReader.parsePID(from: "pid 400, WindowServer"), 400)
        XCTAssertEqual(GPUProcessReader.parsePID(from: "pid 1589, Safari"), 1589)
        XCTAssertEqual(GPUProcessReader.parsePID(from: "pid 7, a, b, c"), 7)
    }

    func testRejectsMalformedCreatorInsteadOfGuessing() {
        XCTAssertNil(GPUProcessReader.parsePID(from: "WindowServer"))
        XCTAssertNil(GPUProcessReader.parsePID(from: "pid , WindowServer"))
        XCTAssertNil(GPUProcessReader.parsePID(from: ""))
        XCTAssertNil(GPUProcessReader.parsePID(from: "process 400"))
    }

    func testSumsGPUTimeAcrossAppUsageEntries() {
        let properties: [String: Any] = [
            "AppUsage": [
                ["API": "Metal", "accumulatedGPUTime": NSNumber(value: 4_777_509_612_083 as Int64)],
                ["API": "Metal", "accumulatedGPUTime": NSNumber(value: 72_283_000 as Int64)],
                ["API": "Metal", "accumulatedGPUTime": NSNumber(value: 0 as Int64)]
            ]
        ]
        XCTAssertEqual(GPUProcessReader.sumGPUTime(in: properties), 4_777_581_895_083)
    }

    func testMissingOrNegativeGPUTimeContributesNothing() {
        XCTAssertEqual(GPUProcessReader.sumGPUTime(in: [:]), 0)
        XCTAssertEqual(GPUProcessReader.sumGPUTime(in: ["AppUsage": []]), 0)
        // 负值只可能来自计数器异常，不能让它把总和拉低。
        let negative: [String: Any] = [
            "AppUsage": [["accumulatedGPUTime": NSNumber(value: -5 as Int64)]]
        ]
        XCTAssertEqual(GPUProcessReader.sumGPUTime(in: negative), 0)
    }

    // MARK: - 真机读取
    //
    // 这几项依赖本机硬件。读不到时跳过而不是失败——在没有 GPU 加速器
    // 或没有 ANE 的机器上，"读不到" 是正确结果，不是缺陷。

    func testGPUTimeIsReadableAndMonotonic() throws {
        let reader = GPUProcessReader()
        guard let first = reader.accumulatedGPUTimeByPID() else {
            throw XCTSkip("本机读不到 GPU user client")
        }
        XCTAssertFalse(first.isEmpty)
        // 自己这个测试进程未必用 GPU，但 WindowServer 一定在用。
        XCTAssertTrue(first.values.contains { $0 > 0 })

        guard let second = reader.accumulatedGPUTimeByPID() else {
            return XCTFail("第二次读取失败，说明服务句柄缓存有问题")
        }
        // accumulatedGPUTime 是单调累计量。倒退意味着我们把不同 client
        // 的值张冠李戴了，速率差分会算出负数。
        for (pid, earlier) in first {
            guard let later = second[pid] else { continue }
            XCTAssertGreaterThanOrEqual(later, earlier, "pid \(pid) 的累计 GPU 时间倒退了")
        }
    }

    func testANEHolderListIsReadableOnThisMachine() throws {
        let reader = ANEClientReader()
        guard let pids = reader.activeClientPIDs() else {
            throw XCTSkip("本机读不到 ANE 驱动节点")
        }
        // 空集合是合法结果：表示当前没有 App 在用神经引擎。
        // 关键是它与「读不到」（nil）能区分开——界面靠这个区别决定
        // 是显示「当前没有 App 打开神经引擎」还是隐藏整张卡。
        for pid in pids {
            XCTAssertGreaterThan(pid, 0)
        }
    }

    /// 缓存句柄后重复调用不应泄漏。粗粒度但能抓住最明显的错误：
    /// 忘记 IOObjectRelease 会让迭代器句柄迅速耗尽。
    func testRepeatedReadsDoNotExhaustIOKitHandles() throws {
        let gpu = GPUProcessReader()
        let ane = ANEClientReader()
        guard gpu.accumulatedGPUTimeByPID() != nil else {
            throw XCTSkip("本机读不到 GPU user client")
        }
        for _ in 0..<200 {
            _ = gpu.accumulatedGPUTimeByPID()
            _ = ane.activeClientPIDs()
        }
        XCTAssertNotNil(gpu.accumulatedGPUTimeByPID(), "200 轮之后仍应可读")
    }
}
