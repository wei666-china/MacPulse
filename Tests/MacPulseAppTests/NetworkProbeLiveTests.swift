import XCTest
@testable import MacPulse
@testable import MacPulseCore

/// 真网络测试。
///
/// 这些用例会真的发出请求，因此断言只做合理性检查（量级、单调性、字段完整性），
/// 不钉死具体数值——网速本来就会变。离线时跳过而不是失败。
final class NetworkProbeLiveTests: XCTestCase {
    /// 会真的发请求的用例默认跳过。
    ///
    /// 它们的结果取决于当时的网络状况，放在默认套件里会随机失败——
    /// 一个偶尔变红的测试套件，用处还不如没有：真出问题时没人会当回事。
    /// 需要跑时设 `MACPULSE_LIVE_NETWORK_TESTS=1`。
    private func requireLiveNetworkOptIn() throws {
        guard ProcessInfo.processInfo.environment["MACPULSE_LIVE_NETWORK_TESTS"] == "1" else {
            throw XCTSkip("默认跳过真网络测试；设 MACPULSE_LIVE_NETWORK_TESTS=1 开启")
        }
    }

    private let path = NetworkPathSnapshot(
        isSatisfied: true,
        supportsIPv4: true,
        supportsIPv6: false,
        primaryInterfaceName: "en0",
        primaryInterfaceKind: .wifi
    )

    func testServerTimingHeaderParsing() {
        // 实测响应头形如：cfL4;desc="...rtt=6209&min_rtt=5965&..."
        let header = #"cfL4;desc="?proto=tcp&rtt=6209&min_rtt=5965&sent=12""#
        XCTAssertEqual(NetworkProbe.parseServerMinRtt(header), 5965)
        XCTAssertNil(NetworkProbe.parseServerMinRtt("cfCacheStatus;desc=HIT"))
        XCTAssertNil(NetworkProbe.parseServerMinRtt(""))
    }

    /// 轻量档：约 35KB，只测延迟与连通性。
    func testLightTierProducesLatencyWithoutBurningBandwidth() async throws {
        try requireLiveNetworkOptIn()
        let probe = NetworkProbe()
        let result = try await probe.run(
            plan: .light,
            trigger: .manual,
            link: nil,
            path: path,
            onProgress: { _ in }
        )

        guard result.connectivity != .offline else {
            throw XCTSkip("当前离线")
        }

        let latency = try XCTUnwrap(result.latency, "轻量档必须给出延迟")
        XCTAssertGreaterThan(latency.p50Milliseconds, 0)
        XCTAssertLessThan(latency.p50Milliseconds, 2_000, "p50 超过 2 秒说明测量方式有问题")
        XCTAssertGreaterThanOrEqual(latency.p95Milliseconds, latency.p50Milliseconds)
        XCTAssertGreaterThanOrEqual(latency.jitterMilliseconds, 0)
        XCTAssertEqual(latency.attempts, 8)

        // 轻量档绝不能跑吞吐测试。
        XCTAssertNil(result.download)
        XCTAssertNil(result.upload)
        XCTAssertLessThan(result.bytesDownloaded, 100_000, "轻量档应当只用几十 KB")
        XCTAssertEqual(result.bytesUploaded, 0)

        // 丢包率永远不报——TCP 的重传会把丢包表现成延迟，印一个 0% 就是编造。
        XCTAssertLessThanOrEqual(latency.failures, latency.attempts)
    }

    /// 完整档：会真的跑约 65MB。断言的是「结果自洽且量级合理」。
    func testStandardTierProducesTrustworthyThroughput() async throws {
        try requireLiveNetworkOptIn()
        let probe = NetworkProbe()
        let result = try await probe.run(
            plan: .standard,
            trigger: .manual,
            link: NetworkLinkInfo(kind: .wifi, linkRateMbps: 960),
            path: path,
            onProgress: { _ in }
        )

        guard result.connectivity != .offline else {
            throw XCTSkip("当前离线")
        }

        let download = try XCTUnwrap(result.download, "完整档必须给出下载吞吐")
        XCTAssertGreaterThan(download.bitsPerSecond, 1_000_000, "低于 1 Mbps 基本可以断定是测量错误")
        XCTAssertLessThan(download.bitsPerSecond, 10_000_000_000)
        // 永远带区间，绝不裸报点估计。
        XCTAssertLessThanOrEqual(download.lowBitsPerSecond, download.bitsPerSecond)
        XCTAssertGreaterThanOrEqual(download.highBitsPerSecond, download.bitsPerSecond)
        XCTAssertGreaterThanOrEqual(download.samples, 1)
        XCTAssertEqual(download.streams, 4)

        // 多流聚合必须至少不低于热身探测的单流速率——低了说明并发没生效
        // （典型原因：几条流复用了同一条 TCP 连接）。
        if let single = result.singleStreamDownloadBitsPerSecond {
            XCTAssertGreaterThan(download.bitsPerSecond, single * 0.8)
        }

        if let upload = result.upload {
            XCTAssertGreaterThan(upload.bitsPerSecond, 100_000)
        }

        // 负载延迟必须不小于空闲延迟——小于说明两次测的不是同一条路。
        if let bloat = result.bufferbloatMilliseconds {
            XCTAssertGreaterThanOrEqual(bloat, 0)
        }

        XCTAssertGreaterThan(result.bytesDownloaded, 1_000_000)
        XCTAssertLessThan(result.bytesDownloaded, 120_000_000, "不应超出预算太多")
        XCTAssertLessThan(result.durationSeconds, 60)

        // 链路利用率：Wi-Fi 半双工下通常在 30–70%，超过 100% 说明协商速率
        // 或吞吐算错了。
        if let utilisation = result.linkUtilisation {
            XCTAssertGreaterThan(utilisation, 0)
            XCTAssertLessThan(utilisation, 1.5)
        }

        print("""
        —— 实测结果 ——
        下载: \(NetworkMath.megabitsPerSecond(download.bitsPerSecond)) \
        [\(NetworkMath.megabitsPerSecond(download.lowBitsPerSecond))–\(NetworkMath.megabitsPerSecond(download.highBitsPerSecond))] \
        \(download.streams) 流 / \(download.samples) 样本 / 可信=\(download.isTrustworthy)
        单流: \(NetworkMath.megabitsPerSecond(result.singleStreamDownloadBitsPerSecond))
        上传: \(NetworkMath.megabitsPerSecond(result.upload?.bitsPerSecond))
        延迟: p50 \(result.latency?.p50Milliseconds ?? -1) ms / 抖动 \(result.latency?.jitterMilliseconds ?? -1) ms
        服务端 RTT: \(result.latency?.serverMinRttMilliseconds ?? -1) ms
        缓冲膨胀: \(result.bufferbloatMilliseconds ?? -1) ms → \(NetworkMath.bufferbloatGrade(result.bufferbloatMilliseconds) ?? "不可用")
        节点: \(result.serverColo ?? "?") / IPv6 可达: \(String(describing: result.ipv6Reachable))
        用量: 下行 \(result.bytesDownloaded / 1_048_576) MB / 上行 \(result.bytesUploaded / 1_048_576) MB
        耗时: \(String(format: "%.1f", result.durationSeconds)) 秒
        """)
    }

    /// 并发触发必须合并到同一次测量，不能同时跑两次。
    func testConcurrentRunsCollapseIntoOne() async throws {
        try requireLiveNetworkOptIn()
        let probe = NetworkProbe()
        let snapshot = path
        async let first = probe.run(plan: .light, trigger: .manual, link: nil, path: snapshot, onProgress: { _ in })
        async let second = probe.run(plan: .light, trigger: .panelOpen, link: nil, path: snapshot, onProgress: { _ in })

        let (a, b) = try await (first, second)
        guard a.connectivity != .offline else { throw XCTSkip("当前离线") }
        // 同一次测量的两个引用，开始时间必然一致。
        XCTAssertEqual(a.startedAt, b.startedAt)
        XCTAssertEqual(a.trigger, b.trigger)
    }
}
