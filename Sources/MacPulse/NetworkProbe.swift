import Foundation
import MacPulseCore
import Network
import Synchronization

/// 网络实测引擎。
///
/// 端点全部是 Cloudflare 的公开测速节点，无需 API key、无需账号、全程 HTTPS。
/// 发出去的只有无意义的填充字节。
enum NetworkEndpoints {
    static let host = "speed.cloudflare.com"
    /// 实测上限：`bytes=100000000` 返回 403，必须卡在这个值以下。
    static let maximumDownloadBytes: Int64 = 99_000_000

    static func download(bytes: Int64) -> URL {
        URL(string: "https://\(host)/__down?bytes=\(min(bytes, maximumDownloadBytes))")!
    }

    static let upload = URL(string: "https://\(host)/__up")!
    /// HTTPS 可用，因此不需要 ATS 例外。
    static let captive = URL(string: "https://captive.apple.com/hotspot-detect.html")!
}

/// 累计字节记录器。
///
/// **只记 `data.count` 然后立刻丢弃缓冲区。** 其它三种写法都不能用：
/// `session.data(for:)` 会把 50MB 全缓进内存；`session.bytes(for:)` 是逐字节
/// AsyncSequence，50MB/s 下要几百万次续体恢复，直接跑满一个核；
/// `downloadTask` 会把 65MB 写进磁盘——在一个监控磁盘写入的 App 里。
private final class ThroughputRecorder: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct State: Sendable {
        var startedAt: Date?
        var totalBytes: Int64 = 0
        var seconds: [Double] = []
        var bytes: [Int64] = []
        /// 用对象身份而不是 `taskIdentifier` 做键。
        ///
        /// `taskIdentifier` **只在单个 URLSession 内唯一**。多流下载时每条流都是
        /// 独立的 session，各自第一个任务的标识符都是 1，用它做键会直接撞车：
        /// 后注册的续体覆盖前一个，被覆盖的那个永远等不到 resume，整次测量死锁。
        /// 热身探测只有单流，所以这个 bug 只在多流时才现形。
        var completions: [ObjectIdentifier: CheckedContinuation<Void, Never>] = [:]
    }

    private let state = Mutex(State())
    /// 采样间隔 50ms。
    ///
    /// 快链路上一块只跑 0.3–0.7 秒，用 100ms 的话整块只有 2–4 个点、
    /// 丢掉预热段后只剩 1–3 个——那样算出来的「稳态速率」全是噪声。
    private let samplingInterval: TimeInterval = 0.05

    func begin() {
        state.withLock {
            $0 = State(startedAt: Date())
        }
    }

    /// 必须用 `URLSessionDataTask` 而不是 `session.data(for:)`。
    ///
    /// 那个 async 便捷方法有自己的内部 delegate，**不会**回调到 session delegate 的
    /// `didReceive`，于是字节记录器一个样本都收不到；而且它会把整块响应缓进内存——
    /// 正是本文件开头警告过的写法。
    func run(_ task: URLSessionDataTask) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // 先登记续体再 resume，否则任务可能在登记前就完成。
                state.withLock { $0.completions[ObjectIdentifier(task)] = continuation }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // 只记长度，立刻丢弃缓冲区。`data.count` 是 O(1)。
        let count = Int64(data.count)
        state.withLock { state in
            guard let startedAt = state.startedAt else { return }
            state.totalBytes += count
            let elapsed = Date().timeIntervalSince(startedAt)
            if let last = state.seconds.last, elapsed - last < samplingInterval { return }
            state.seconds.append(elapsed)
            state.bytes.append(state.totalBytes)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let continuation = state.withLock { $0.completions.removeValue(forKey: ObjectIdentifier(task)) }
        continuation?.resume()
    }

    /// 兜底：会话失效时把所有还挂着的续体一次性放掉，不留悬空。
    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        let pending = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            let values = Array(state.completions.values)
            state.completions.removeAll()
            return values
        }
        pending.forEach { $0.resume() }
    }

    var totalBytes: Int64 {
        state.withLock { $0.totalBytes }
    }

    var samples: [(seconds: Double, bytes: Int64)] {
        state.withLock { state in
            // 补一个收尾点，否则最后一段（往往是最稳的一段）会被丢掉。
            var seconds = state.seconds
            var bytes = state.bytes
            if let startedAt = state.startedAt, state.totalBytes > (bytes.last ?? 0) {
                seconds.append(Date().timeIntervalSince(startedAt))
                bytes.append(state.totalBytes)
            }
            return zip(seconds, bytes).map { (seconds: $0, bytes: $1) }
        }
    }
}

actor NetworkProbe {
    struct Plan: Sendable {
        var tier: NetworkTestTier
        var latencySampleCount = 8
        var latencyIntervalMilliseconds = 120
        var downloadStreams = 4
        var uploadStreams = 3
        var measurementSeconds = 5.0
        var measurementChunks = 3
        var downloadByteBudget: Int64 = 50_000_000
        var uploadByteBudget: Int64 = 16_000_000
        var overallDeadlineSeconds = 25.0

        static let light = Plan(
            tier: .light,
            downloadStreams: 0,
            uploadStreams: 0,
            measurementChunks: 0,
            downloadByteBudget: 0,
            uploadByteBudget: 0,
            overallDeadlineSeconds: 8
        )

        static let standard = Plan(tier: .standard)

        static let thrifty = Plan(
            tier: .thrifty,
            downloadStreams: 2,
            uploadStreams: 1,
            measurementSeconds: 2.5,
            measurementChunks: 2,
            downloadByteBudget: 10_000_000,
            uploadByteBudget: 4_000_000,
            overallDeadlineSeconds: 15
        )

        static func forTier(_ tier: NetworkTestTier) -> Plan {
            switch tier {
            case .light: .light
            case .standard: .standard
            case .thrifty: .thrifty
            }
        }
    }

    enum Progress: Sendable {
        case phase(String)
        case fraction(Double)
    }

    private var runningTask: Task<NetworkTestResult, Error>?
    private var gracefulStopRequested = false

    var isRunning: Bool { runningTask != nil }

    /// 并发触发会合并到同一个任务上，永远不会同时跑两次测速。
    func run(
        plan: Plan,
        trigger: NetworkTestTrigger,
        link: NetworkLinkInfo?,
        path: NetworkPathSnapshot,
        onProgress: @escaping @Sendable (Progress) -> Void
    ) async throws -> NetworkTestResult {
        if let runningTask {
            return try await runningTask.value
        }
        gracefulStopRequested = false
        let task = Task<NetworkTestResult, Error> { [plan, trigger, link, path] in
            try await Self.execute(
                plan: plan,
                trigger: trigger,
                link: link,
                path: path,
                onProgress: onProgress,
                shouldStop: { [weak self] in await self?.gracefulStopRequested ?? false }
            )
        }
        runningTask = task
        defer { runningTask = nil }
        return try await task.value
    }

    /// 优雅停止：跑完当前这一块就收尾并返回 `.partial`。
    /// 部分结果配更宽的误差区间依然是诚实数据，重测反而浪费用户的流量。
    func requestGracefulStop() {
        gracefulStopRequested = true
    }

    /// 硬取消。睡眠、切换网络这类场景用它——跨越睡眠的测量是垃圾。
    func cancel() {
        runningTask?.cancel()
        runningTask = nil
    }

    // MARK: - 执行

    private static func execute(
        plan: Plan,
        trigger: NetworkTestTrigger,
        link: NetworkLinkInfo?,
        path: NetworkPathSnapshot,
        onProgress: @escaping @Sendable (Progress) -> Void,
        shouldStop: @escaping @Sendable () async -> Bool
    ) async throws -> NetworkTestResult {
        let startedAt = Date()
        var result = NetworkTestResult(
            startedAt: startedAt,
            tier: plan.tier,
            trigger: trigger,
            link: link,
            path: path
        )

        onProgress(.phase("检查连通性"))
        result.connectivity = await withTimeout(8, fallback: NetworkConnectivity.offline) {
            await checkConnectivity()
        }
        guard result.connectivity != .offline else {
            result.completeness = .failed
            result.failureCode = "offline"
            result.durationSeconds = Date().timeIntervalSince(startedAt)
            return result
        }

        onProgress(.phase("测量延迟"))
        let idleLatency = await measureLatency(count: plan.latencySampleCount, intervalMilliseconds: plan.latencyIntervalMilliseconds)
        result.latency = idleLatency

        onProgress(.phase("握手分解"))
        let header = await probeHeaders()
        result.serverColo = header.colo
        result.dnsMilliseconds = header.dns
        result.tcpMilliseconds = header.tcp
        result.tlsMilliseconds = header.tls
        result.timeToFirstByteMilliseconds = header.ttfb
        result.dnsWasPossiblyCached = header.dnsWasCached
        result.ipv4Reachable = path.supportsIPv4 ? true : nil
        result.ipv6Reachable = path.supportsIPv6 ? await probeIPv6() : false
        if var latency = result.latency, let serverRtt = header.serverMinRttMilliseconds {
            latency.serverMinRttMilliseconds = serverRtt
            result.latency = latency
        }
        result.bytesDownloaded += header.bytes

        guard plan.tier != .light else {
            result.durationSeconds = Date().timeIntervalSince(startedAt)
            return result
        }

        if Task.isCancelled { throw CancellationError() }

        // 连接建一次，热身与后续所有块共用。慢启动因此只发生一次。
        let recorder = ThroughputRecorder()
        let sessions = (0..<max(1, plan.downloadStreams)).map { _ in
            URLSession(
                configuration: ephemeralConfiguration(singleConnection: true),
                delegate: recorder,
                delegateQueue: nil
            )
        }
        defer { sessions.forEach { $0.invalidateAndCancel() } }

        // 热身探测：整块丢弃，唯一作用是把这几条连接的拥塞窗口撑开，
        // 并给出定尺寸用的速率。
        onProgress(.phase("热身"))
        let warmUp = await withTimeout(20, fallback: ChunkOutcome(bitsPerSecond: nil, bytes: 0)) {
            await measureDownloadChunk(
                bytes: 3_000_000,
                streams: plan.downloadStreams,
                sessions: sessions,
                recorder: recorder
            )
        }
        result.bytesDownloaded += warmUp.bytes
        // 刻意不再填 singleStreamDownloadBitsPerSecond：热身现在是多流的，
        // 它的速率是「冷启动聚合」，标成「单流下载」就是又一个标签谎言。
        // 要真的单流数据就得多花约 10MB 单独测一轮，不值得。

        var observed = warmUp.bitsPerSecond ?? 50_000_000
        var chunkRates: [Double] = []
        var loadedLatencies: [Double] = []
        var downloadedBytes: Int64 = 0

        for chunk in 0..<plan.measurementChunks {
            if Task.isCancelled { throw CancellationError() }
            if await shouldStop() {
                result.completeness = .partial
                result.failureCode = "panel_closed"
                break
            }
            if downloadedBytes >= plan.downloadByteBudget {
                break
            }

            onProgress(.phase("测量下载"))
            onProgress(.fraction(Double(chunk) / Double(max(1, plan.measurementChunks))))

            let perStream = NetworkMath.nextChunkBytes(
                observedBitsPerSecond: observed / Double(max(1, plan.downloadStreams)),
                targetSeconds: plan.measurementSeconds,
                minimumBytes: 2_000_000,
                maximumBytes: min(NetworkEndpoints.maximumDownloadBytes, plan.downloadByteBudget / Int64(max(1, plan.measurementChunks * plan.downloadStreams)))
            )

            // 负载延迟与下载并发进行：这个差值才是解释「开会为什么卡」的数字。
            async let loaded = measureLatency(count: 4, intervalMilliseconds: 250)
            let outcome = await withTimeout(
                plan.measurementSeconds * 4 + 10,
                fallback: ChunkOutcome(bitsPerSecond: nil, bytes: 0)
            ) { [perStream, streams = plan.downloadStreams] in
                await measureDownloadChunk(
                    bytes: perStream,
                    streams: streams,
                    sessions: sessions,
                    recorder: recorder
                )
            }
            let loadedResult = await loaded

            downloadedBytes += outcome.bytes
            result.bytesDownloaded += outcome.bytes
            if let rate = outcome.bitsPerSecond {
                chunkRates.append(rate)
                observed = rate
            }
            if let p95 = loadedResult?.p95Milliseconds {
                loadedLatencies.append(p95)
            }
        }

        result.download = NetworkMath.combine(chunkRates: chunkRates, streams: plan.downloadStreams)
        if let idle = idleLatency?.p50Milliseconds, let loadedP95 = loadedLatencies.max() {
            result.bufferbloatMilliseconds = max(0, loadedP95 - idle)
        }

        if !Task.isCancelled, result.completeness == .complete, plan.uploadStreams > 0 {
            onProgress(.phase("测量上传"))
            let upload = await withTimeout(
                plan.measurementSeconds * 6 + 15,
                fallback: UploadOutcome(estimate: nil, bytes: 0)
            ) { [budget = plan.uploadByteBudget, streams = plan.uploadStreams, target = plan.measurementSeconds] in
                await measureUpload(budget: budget, streams: streams, targetSeconds: target)
            }
            result.upload = upload.estimate
            result.bytesUploaded += upload.bytes
        }

        result.durationSeconds = Date().timeIntervalSince(startedAt)
        return result
    }

    // MARK: - 延迟

    /// 用原始 TCP 握手而不是 ICMP，也不是 URLSession。
    ///
    /// ICMP 被中间设备降级和限速，会产生看起来像丢包的假象；URLSession 会复用
    /// 连接，测不到握手。TCP:443 走的正是 App 流量真正走的那条路。
    private static func measureLatency(count: Int, intervalMilliseconds: Int) async -> LatencyEstimate? {
        var samples: [Double] = []
        var failures = 0

        for index in 0..<count {
            if Task.isCancelled { break }
            if index > 0 {
                try? await Task.sleep(for: .milliseconds(intervalMilliseconds))
            }
            if let milliseconds = await singleHandshakeMilliseconds() {
                samples.append(milliseconds)
            } else {
                failures += 1
            }
        }

        guard !samples.isEmpty else { return nil }
        return LatencyEstimate(
            p50Milliseconds: NetworkMath.percentile(samples, 0.5) ?? samples[0],
            p95Milliseconds: NetworkMath.percentile(samples, 0.95) ?? samples[0],
            jitterMilliseconds: NetworkMath.meanAbsoluteSuccessiveDifference(samples) ?? 0,
            attempts: count,
            failures: failures
        )
    }

    private static func singleHandshakeMilliseconds() async -> Double? {
        await TCPHandshakeTimer(parameters: .tcp, timeout: 2).measure()
    }

    // MARK: - 连通性与握手分解

    private static func checkConnectivity() async -> NetworkConnectivity {
        var request = URLRequest(url: NetworkEndpoints.captive)
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let session = URLSession(configuration: ephemeralConfiguration())
        defer { session.invalidateAndCancel() }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .offline }
            let body = String(data: data, encoding: .utf8) ?? ""
            // 强制门户会返回 200 但内容不是 Apple 那段 Success。
            if http.statusCode == 200, body.contains("Success") { return .online }
            return .captivePortalSuspected
        } catch let error as URLError {
            switch error.code {
            case .cannotFindHost, .dnsLookupFailed: return .dnsFailure
            case .notConnectedToInternet, .networkConnectionLost: return .offline
            default: return .offline
            }
        } catch {
            return .offline
        }
    }

    private struct HeaderProbe: Sendable {
        var colo: String?
        var serverMinRttMilliseconds: Double?
        var dns: Double?
        var tcp: Double?
        var tls: Double?
        var ttfb: Double?
        var dnsWasCached = false
        var bytes: Int64 = 0
    }

    private static func probeHeaders() async -> HeaderProbe {
        var probe = HeaderProbe()
        var request = URLRequest(url: NetworkEndpoints.download(bytes: 1_000))
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let collector = MetricsCollector()
        let session = URLSession(configuration: ephemeralConfiguration(), delegate: collector, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse
        else { return probe }

        probe.bytes = Int64(data.count)
        probe.colo = http.value(forHTTPHeaderField: "cf-meta-colo")
        // Server-Timing 里的 cfL4 段带着服务器内核测得的 RTT（微秒），
        // 这是一个由对端独立产生的第二意见。
        if let timing = http.value(forHTTPHeaderField: "Server-Timing"),
           let microseconds = parseServerMinRtt(timing) {
            probe.serverMinRttMilliseconds = microseconds / 1_000
        }

        let metrics = collector.snapshot
        probe.dns = metrics.dns
        probe.tcp = metrics.tcp
        probe.tls = metrics.tls
        probe.ttfb = metrics.ttfb
        probe.dnsWasCached = metrics.reusedConnection || (metrics.dns ?? 0) < 1
        return probe
    }

    static func parseServerMinRtt(_ header: String) -> Double? {
        guard let range = header.range(of: "min_rtt=") else { return nil }
        let rest = header[range.upperBound...]
        let digits = rest.prefix { $0.isNumber }
        return Double(digits)
    }

    /// 强制走 IPv6 试一次握手。成功才算真正可达——`NWPath.supportsIPv6`
    /// 只说明本机配置了 v6，不代表出口通。本机实测只有链路本地地址，
    /// 因此会如实报告「无 IPv6」。
    private static func probeIPv6() async -> Bool {
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v6
        }
        return await TCPHandshakeTimer(parameters: parameters, timeout: 3).measure() != nil
    }

    // MARK: - 吞吐

    private struct ChunkOutcome: Sendable {
        var bitsPerSecond: Double?
        var bytes: Int64
    }

    /// 多流下载。
    ///
    /// **每条流必须是独立的 `URLSession`。** HTTP/2 下同一 session 的并发请求会
    /// 复用同一条 TCP 连接，「4 个并行请求」只有一个拥塞窗口，什么都没多测到。
    /// 四个 `.ephemeral` session、各自 `httpMaximumConnectionsPerHost = 1`，
    /// 才是四条真实的 TCP 连接。
    ///
    /// **session 由调用方创建并跨块复用。** 之前每块都新建 session，等于每块都
    /// 重新经历一次 TCP 慢启动——而快链路上一块只有 0.3–0.7 秒，整块都还在爬坡。
    /// 三块「测量」实际测的是三次慢启动，离散度自然大到每次都被判为不可信。
    /// 连接复用之后，慢启动只在热身探测那一次发生。
    private static func measureDownloadChunk(
        bytes: Int64,
        streams: Int,
        sessions: [URLSession],
        recorder: ThroughputRecorder
    ) async -> ChunkOutcome {
        recorder.begin()

        await withTaskGroup(of: Void.self) { group in
            for session in sessions {
                group.addTask { [recorder] in
                    var request = URLRequest(url: NetworkEndpoints.download(bytes: bytes))
                    request.timeoutInterval = 20
                    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                    await recorder.run(session.dataTask(with: request))
                }
            }
            await group.waitForAll()
        }

        return ChunkOutcome(
            bitsPerSecond: NetworkMath.steadyStateRate(samples: recorder.samples),
            bytes: recorder.totalBytes
        )
    }

    private struct UploadOutcome: Sendable {
        var estimate: ThroughputEstimate?
        var bytes: Int64
    }

    private static func measureUpload(budget: Int64, streams: Int, targetSeconds: Double) async -> UploadOutcome {
        // 用随机块而不是零填充：零可能被中间设备做去重优化，测出虚高的速度。
        let blockSize = 1_000_000
        var block = Data(count: blockSize)
        block.withUnsafeMutableBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for index in 0..<blockSize { base[index] = UInt8.random(in: 0...255) }
        }

        // 热身探测：结果**整块丢弃**，只用来给正式轮次定尺寸。
        //
        // 之前把这个 1MB 单流探测的速率和后面 3 流并发的聚合速率一起丢进
        // combine()，等于拿苹果跟橘子比大小——一个是慢启动里的单流，一个是
        // 三流稳态聚合，两者本来就该差好几倍。界面上那个「28–53 Mbps・
        // 测量不稳定」完全是这个比较造出来的假象，不是链路真在抖。
        let probeBytes = Int64(min(Int(budget), blockSize))
        let probeRate = await singleUpload(payload: block.prefix(Int(probeBytes)), timeout: 15)

        var rates: [Double] = []
        var total = probeBytes

        let remaining = max(0, budget - probeBytes)
        let rounds = 2
        let perStream = NetworkMath.nextChunkBytes(
            observedBitsPerSecond: (probeRate ?? 40_000_000) / Double(max(1, streams)),
            targetSeconds: targetSeconds,
            minimumBytes: 1_000_000,
            maximumBytes: max(1_000_000, remaining / Int64(max(1, streams) * rounds))
        )
        guard perStream > 0, remaining > 0 else {
            return UploadOutcome(estimate: nil, bytes: total)
        }

        let payload: Data = {
            var buffer = Data()
            buffer.reserveCapacity(Int(perStream))
            while buffer.count < Int(perStream) {
                buffer.append(block.prefix(min(blockSize, Int(perStream) - buffer.count)))
            }
            return buffer
        }()

        // 多轮**同样配置**的并发上传，这样区间才反映真实波动而不是配置差异。
        for _ in 0..<rounds {
            if Task.isCancelled { break }
            let results = await withTaskGroup(of: Double?.self, returning: [Double?].self) { group in
                for _ in 0..<max(1, streams) {
                    group.addTask { [payload] in await singleUpload(payload: payload, timeout: 20) }
                }
                var collected: [Double?] = []
                for await value in group { collected.append(value) }
                return collected
            }
            let concurrent = results.compactMap { $0 }.reduce(0, +)
            if concurrent > 0 { rates.append(concurrent) }
            total += perStream * Int64(max(1, streams))
        }

        return UploadOutcome(
            estimate: NetworkMath.combine(chunkRates: rates, streams: streams),
            bytes: total
        )
    }

    private static func singleUpload(payload: Data, timeout: TimeInterval) async -> Double? {
        var request = URLRequest(url: NetworkEndpoints.upload)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        let session = URLSession(configuration: ephemeralConfiguration(singleConnection: true))
        defer { session.invalidateAndCancel() }

        let start = Date()
        guard (try? await session.upload(for: request, from: payload)) != nil else { return nil }
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed > 0 else { return nil }
        return Double(payload.count) * 8 / elapsed
    }

    /// 给任意一段测量套一个硬超时。
    ///
    /// 这不是可有可无的保险：网络代码里最常见的故障不是报错，而是**永远不返回**。
    /// 每一段都必须自带出口，否则一处挂起就吃掉整次测量。
    private static func withTimeout<T: Sendable>(
        _ seconds: Double,
        fallback: T,
        _ operation: @escaping @Sendable () async -> T
    ) async -> T {
        await withTaskGroup(of: T.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return fallback
            }
            let first = await group.next() ?? fallback
            group.cancelAll()
            return first
        }
    }

    // MARK: - 会话配置

    private static func ephemeralConfiguration(singleConnection: Bool = false) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        // 系统级兜底：就算我们自己的守卫链有 bug，也不会在手机热点上推 65MB。
        configuration.allowsExpensiveNetworkAccess = false
        configuration.allowsConstrainedNetworkAccess = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        if singleConnection {
            configuration.httpMaximumConnectionsPerHost = 1
        }
        return configuration
    }
}

/// 一次 TCP 握手的计时器。
///
/// 独立成类而不是写成局部闭包：`NWConnection` 与续体要在多个回调之间共享，
/// 局部函数捕获它们会被严格并发拒绝。所有「只能 resume 一次」的保证都收在
/// `finish` 里，由一个 Mutex 守住。
private final class TCPHandshakeTimer: @unchecked Sendable {
    private struct State: Sendable {
        var continuation: CheckedContinuation<Double?, Never>?
        var finished = false
    }

    private let connection: NWConnection
    private let timeout: TimeInterval
    private let state = Mutex(State())
    private let start = Date()

    init(parameters: NWParameters, timeout: TimeInterval) {
        connection = NWConnection(
            host: NWEndpoint.Host(NetworkEndpoints.host),
            port: 443,
            using: parameters
        )
        self.timeout = timeout
    }

    func measure() async -> Double? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Double?, Never>) in
                state.withLock { $0.continuation = continuation }
                // 两个回调都必须强持有 self。用 [weak self] 的话，除了这两个闭包
                // 之外没有任何东西持有计时器——它可能在挂起期间就被释放，于是
                // 两条唤醒路径同时失效，续体永远等不到 resume，整个测量死锁。
                connection.stateUpdateHandler = { [self] state in
                    switch state {
                    case .ready:
                        finish(Date().timeIntervalSince(self.start) * 1_000)
                    case .failed, .cancelled:
                        finish(nil)
                    default:
                        break
                    }
                }
                connection.start(queue: .global(qos: .userInitiated))
                // 单次握手超时，避免一条不通的路把整轮拖死。
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in
                    finish(nil)
                }
            }
        } onCancel: {
            finish(nil)
        }
    }

    private func finish(_ value: Double?) {
        let continuation = state.withLock { state -> CheckedContinuation<Double?, Never>? in
            guard !state.finished else { return nil }
            state.finished = true
            let pending = state.continuation
            state.continuation = nil
            return pending
        }
        guard let continuation else { return }
        // 先摘掉 handler 再 cancel，断开保留环。
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation.resume(returning: value)
    }
}

/// 从 `URLSessionTaskMetrics` 里抽出握手分解。
/// `URLSessionTaskMetrics` 不是 Sendable，必须在回调内部就地抽成普通值。
private final class MetricsCollector: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    struct Snapshot: Sendable {
        var dns: Double?
        var tcp: Double?
        var tls: Double?
        var ttfb: Double?
        var reusedConnection = false
    }

    private let state = Mutex(Snapshot())

    var snapshot: Snapshot { state.withLock { $0 } }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let transaction = metrics.transactionMetrics.last else { return }
        func milliseconds(_ from: Date?, _ to: Date?) -> Double? {
            guard let from, let to else { return nil }
            return to.timeIntervalSince(from) * 1_000
        }
        let value = Snapshot(
            dns: milliseconds(transaction.domainLookupStartDate, transaction.domainLookupEndDate),
            tcp: milliseconds(transaction.connectStartDate, transaction.secureConnectionStartDate ?? transaction.connectEndDate),
            tls: milliseconds(transaction.secureConnectionStartDate, transaction.secureConnectionEndDate),
            ttfb: milliseconds(transaction.requestEndDate, transaction.responseStartDate),
            reusedConnection: transaction.isReusedConnection
        )
        state.withLock { $0 = value }
    }
}
