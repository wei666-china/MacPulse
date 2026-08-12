import Foundation

// MARK: - 链路读数（零流量）

public enum NetworkInterfaceKind: String, Codable, Sendable {
    case wifi, ethernet, cellular, loopback, other

    public var title: String {
        switch self {
        case .wifi: "Wi-Fi"
        case .ethernet: "以太网"
        case .cellular: "蜂窝"
        case .loopback: "回环"
        case .other: "其他"
        }
    }
}

/// 当前链路的协商信息。全部来自本机读数，不发任何网络请求。
///
/// 刻意**不含 SSID 和 RSSI**：这两项在现代 macOS 上需要
/// `com.apple.security.personal-information.location` 与用户定位授权。
/// 上游 mactop 也是刻意绕开的（用 serviceActive 代替 ssid），保持这个性质。
public struct NetworkLinkInfo: Codable, Sendable, Equatable {
    public var interfaceName: String?
    public var kind: NetworkInterfaceKind?
    /// 例如 "802.11ax"。
    public var phyMode: String?
    /// 例如 "Wi-Fi 6"。
    public var generation: String?
    /// 协商速率（Mbps）。注意这是链路协商值，不是实测吞吐——
    /// Wi-Fi 半双工下实测通常只有它的一半左右。
    public var linkRateMbps: Double?
    public var isConnected: Bool?

    public init(
        interfaceName: String? = nil,
        kind: NetworkInterfaceKind? = nil,
        phyMode: String? = nil,
        generation: String? = nil,
        linkRateMbps: Double? = nil,
        isConnected: Bool? = nil
    ) {
        self.interfaceName = interfaceName
        self.kind = kind
        self.phyMode = phyMode
        self.generation = generation
        self.linkRateMbps = linkRateMbps
        self.isConnected = isConnected
    }

    public var summary: String? {
        let parts = [generation, interfaceName].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// `NWPath` 的可跨隔离域快照。`NWPath` 本身不是 Sendable，绝不能直接传递。
public struct NetworkPathSnapshot: Codable, Sendable, Equatable {
    public var isSatisfied: Bool
    /// 按流量计费（手机热点、蜂窝）。
    public var isExpensive: Bool
    /// 用户开启了「低数据模式」。
    public var isConstrained: Bool
    public var supportsIPv4: Bool
    public var supportsIPv6: Bool
    public var usesVPN: Bool
    public var primaryInterfaceName: String?
    public var primaryInterfaceKind: NetworkInterfaceKind?

    public init(
        isSatisfied: Bool = false,
        isExpensive: Bool = false,
        isConstrained: Bool = false,
        supportsIPv4: Bool = false,
        supportsIPv6: Bool = false,
        usesVPN: Bool = false,
        primaryInterfaceName: String? = nil,
        primaryInterfaceKind: NetworkInterfaceKind? = nil
    ) {
        self.isSatisfied = isSatisfied
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.supportsIPv4 = supportsIPv4
        self.supportsIPv6 = supportsIPv6
        self.usesVPN = usesVPN
        self.primaryInterfaceName = primaryInterfaceName
        self.primaryInterfaceKind = primaryInterfaceKind
    }
}

// MARK: - 测量结果

/// 吞吐估计，**永远带误差区间**。
///
/// 单点估计在网络测量里是不诚实的：同一条链路上连测三次能差 4 倍，
/// 取决于有没有跳出 TCP 慢启动、有没有别的流量、无线信道瞬时质量。
public struct ThroughputEstimate: Codable, Sendable, Equatable {
    public var bitsPerSecond: Double
    public var lowBitsPerSecond: Double
    public var highBitsPerSecond: Double
    public var streams: Int
    public var samples: Int

    public init(bitsPerSecond: Double, lowBitsPerSecond: Double, highBitsPerSecond: Double, streams: Int, samples: Int) {
        self.bitsPerSecond = bitsPerSecond
        self.lowBitsPerSecond = lowBitsPerSecond
        self.highBitsPerSecond = highBitsPerSecond
        self.streams = streams
        self.samples = samples
    }

    /// 相对离散度。超过阈值说明这次测量不稳定，不该报一个头条数字。
    public var relativeSpread: Double {
        guard bitsPerSecond > 0 else { return .infinity }
        return (highBitsPerSecond - lowBitsPerSecond) / bitsPerSecond
    }

    public var isTrustworthy: Bool {
        // 单样本的离散度恒为 0——最弱的数据给出最自信的「±0%」,
        // 恰好是被打断的那次。样本不足两份,一律按不可信给区间。
        samples >= 2 && relativeSpread <= NetworkMath.trustworthySpreadThreshold
    }
}

public struct LatencyEstimate: Codable, Sendable, Equatable {
    public var p50Milliseconds: Double
    public var p95Milliseconds: Double
    /// 抖动用相邻样本差的平均绝对值（RFC 3550 风格），比标准差更贴近体感。
    public var jitterMilliseconds: Double
    public var attempts: Int
    public var failures: Int
    /// 服务端内核测得的 RTT，来自响应头。一个独立的第二意见。
    public var serverMinRttMilliseconds: Double?

    public init(
        p50Milliseconds: Double,
        p95Milliseconds: Double,
        jitterMilliseconds: Double,
        attempts: Int,
        failures: Int,
        serverMinRttMilliseconds: Double? = nil
    ) {
        self.p50Milliseconds = p50Milliseconds
        self.p95Milliseconds = p95Milliseconds
        self.jitterMilliseconds = jitterMilliseconds
        self.attempts = attempts
        self.failures = failures
        self.serverMinRttMilliseconds = serverMinRttMilliseconds
    }
}

public enum NetworkTestTier: String, Codable, Sendable, CaseIterable, Identifiable {
    /// 只测延迟与连通性，约 35KB。
    case light
    /// 完整下载上传，约 65MB。
    case standard
    /// 缩短测量窗口，约 14MB。
    case thrifty

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .light: "轻量"
        case .standard: "标准"
        case .thrifty: "节省流量"
        }
    }

    public var dataCostDescription: String {
        switch self {
        case .light: "约 35 KB"
        case .standard: "约 65 MB"
        case .thrifty: "约 14 MB"
        }
    }
}

public enum NetworkTestTrigger: String, Codable, Sendable {
    case panelOpen
    case manual
    case pathChanged
}

public enum NetworkTestCompleteness: String, Codable, Sendable {
    case complete
    /// 中途被打断，结果仍然保留——部分结果配更宽的误差区间依然是诚实数据，
    /// 重测反而浪费用户的流量。
    case partial
    case failed
}

public enum NetworkConnectivity: String, Codable, Sendable {
    case online
    case captivePortalSuspected
    case dnsFailure
    case offline

    public var title: String {
        switch self {
        case .online: "正常"
        case .captivePortalSuspected: "疑似需要网页登录"
        case .dnsFailure: "域名解析失败"
        case .offline: "离线"
        }
    }
}

public struct NetworkTestResult: Codable, Sendable, Equatable {
    public var startedAt: Date
    public var durationSeconds: Double
    public var tier: NetworkTestTier
    public var trigger: NetworkTestTrigger
    public var completeness: NetworkTestCompleteness
    public var connectivity: NetworkConnectivity

    public var link: NetworkLinkInfo?
    public var path: NetworkPathSnapshot?

    public var latency: LatencyEstimate?
    public var download: ThroughputEstimate?
    public var upload: ThroughputEstimate?
    public var singleStreamDownloadBitsPerSecond: Double?

    /// 下载期间的 p95 延迟减去空闲 p50。这是解释「开会为什么卡」的那个数字。
    public var bufferbloatMilliseconds: Double?
    public var dnsMilliseconds: Double?
    public var tcpMilliseconds: Double?
    public var tlsMilliseconds: Double?
    public var timeToFirstByteMilliseconds: Double?
    public var dnsWasPossiblyCached: Bool

    public var ipv4Reachable: Bool?
    public var ipv6Reachable: Bool?
    public var serverColo: String?

    public var bytesDownloaded: Int64
    public var bytesUploaded: Int64
    public var failureCode: String?

    public init(
        startedAt: Date,
        durationSeconds: Double = 0,
        tier: NetworkTestTier,
        trigger: NetworkTestTrigger,
        completeness: NetworkTestCompleteness = .complete,
        connectivity: NetworkConnectivity = .online,
        link: NetworkLinkInfo? = nil,
        path: NetworkPathSnapshot? = nil,
        latency: LatencyEstimate? = nil,
        download: ThroughputEstimate? = nil,
        upload: ThroughputEstimate? = nil,
        singleStreamDownloadBitsPerSecond: Double? = nil,
        bufferbloatMilliseconds: Double? = nil,
        dnsMilliseconds: Double? = nil,
        tcpMilliseconds: Double? = nil,
        tlsMilliseconds: Double? = nil,
        timeToFirstByteMilliseconds: Double? = nil,
        dnsWasPossiblyCached: Bool = false,
        ipv4Reachable: Bool? = nil,
        ipv6Reachable: Bool? = nil,
        serverColo: String? = nil,
        bytesDownloaded: Int64 = 0,
        bytesUploaded: Int64 = 0,
        failureCode: String? = nil
    ) {
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.tier = tier
        self.trigger = trigger
        self.completeness = completeness
        self.connectivity = connectivity
        self.link = link
        self.path = path
        self.latency = latency
        self.download = download
        self.upload = upload
        self.singleStreamDownloadBitsPerSecond = singleStreamDownloadBitsPerSecond
        self.bufferbloatMilliseconds = bufferbloatMilliseconds
        self.dnsMilliseconds = dnsMilliseconds
        self.tcpMilliseconds = tcpMilliseconds
        self.tlsMilliseconds = tlsMilliseconds
        self.timeToFirstByteMilliseconds = timeToFirstByteMilliseconds
        self.dnsWasPossiblyCached = dnsWasPossiblyCached
        self.ipv4Reachable = ipv4Reachable
        self.ipv6Reachable = ipv6Reachable
        self.serverColo = serverColo
        self.bytesDownloaded = bytesDownloaded
        self.bytesUploaded = bytesUploaded
        self.failureCode = failureCode
    }

    /// 链路协商速率的实测利用率。Wi-Fi 半双工下 50% 左右属正常。
    public var linkUtilisation: Double? {
        guard let rate = link?.linkRateMbps, rate > 0, let down = download else { return nil }
        return down.bitsPerSecond / (rate * 1_000_000)
    }
}

// MARK: - 自动测速策略

public enum NetworkConsent: String, Codable, Sendable {
    case notDetermined
    case granted
    case denied
}

public enum NetworkSkipReason: String, Codable, Sendable, Equatable {
    case needsConsent
    case userDeclined
    case offline
    case alreadyRunning
    case tooSoon
    case meteredNetwork
    case lowDataMode
    case lowBattery
    case thermalPressure

    /// 每一条都要能显示给用户看。静默跳过等于让人以为测过了。
    public var title: String {
        switch self {
        case .needsConsent: "尚未开启网络测速"
        case .userDeclined: "网络测速已关闭"
        case .offline: "当前离线"
        case .alreadyRunning: "正在测速"
        case .tooSoon: "刚测过，稍后自动重测"
        case .meteredNetwork: "已跳过完整测速：按流量计费网络"
        case .lowDataMode: "已跳过完整测速：低数据模式"
        case .lowBattery: "已跳过完整测速：电量偏低"
        case .thermalPressure: "已跳过完整测速：机器过热"
        }
    }
}

public enum NetworkRunDecision: Sendable, Equatable {
    case run(NetworkTestTier)
    case skip(NetworkSkipReason)
}

/// 纯函数策略，可零网络单测。
public enum NetworkTestPolicy {
    /// 同一次开启事件可能触发多次 appear；这个下限只用来去重，
    /// 不是在替用户节流。默认 60 秒，设置里可调。
    public static let defaultMinimumInterval: TimeInterval = 60
    /// 计费网络上强制降级为轻量，并把间隔拉长。
    public static let meteredMinimumInterval: TimeInterval = 1_800
    public static let minimumBatteryPercentForFullTest: Double = 20
    /// 超过这个时长的结果视为过期，界面变灰。
    public static let stalenessThreshold: TimeInterval = 6 * 3_600

    public struct Input: Sendable {
        public var trigger: NetworkTestTrigger
        public var consent: NetworkConsent
        public var autoRunEnabled: Bool
        public var preferredTier: NetworkTestTier
        public var path: NetworkPathSnapshot
        public var now: Date
        public var lastCompletedAt: Date?
        public var lastTier: NetworkTestTier?
        public var networkKeyChanged: Bool
        public var minimumInterval: TimeInterval
        public var batteryPercent: Double
        public var isDischarging: Bool
        public var thermalUnderPressure: Bool
        public var isRunning: Bool

        public init(
            trigger: NetworkTestTrigger,
            consent: NetworkConsent,
            autoRunEnabled: Bool,
            preferredTier: NetworkTestTier,
            path: NetworkPathSnapshot,
            now: Date,
            lastCompletedAt: Date? = nil,
            lastTier: NetworkTestTier? = nil,
            networkKeyChanged: Bool = false,
            minimumInterval: TimeInterval = NetworkTestPolicy.defaultMinimumInterval,
            batteryPercent: Double = 100,
            isDischarging: Bool = false,
            thermalUnderPressure: Bool = false,
            isRunning: Bool = false
        ) {
            self.trigger = trigger
            self.consent = consent
            self.autoRunEnabled = autoRunEnabled
            self.preferredTier = preferredTier
            self.path = path
            self.now = now
            self.lastCompletedAt = lastCompletedAt
            self.lastTier = lastTier
            self.networkKeyChanged = networkKeyChanged
            self.minimumInterval = minimumInterval
            self.batteryPercent = batteryPercent
            self.isDischarging = isDischarging
            self.thermalUnderPressure = thermalUnderPressure
            self.isRunning = isRunning
        }
    }

    /// 守卫按顺序短路，第一条失败就返回可显示的理由。
    public static func decide(_ input: Input) -> NetworkRunDecision {
        switch input.consent {
        case .notDetermined: return .skip(.needsConsent)
        case .denied: return .skip(.userDeclined)
        case .granted: break
        }

        if input.trigger != .manual, !input.autoRunEnabled {
            return .skip(.userDeclined)
        }
        guard input.path.isSatisfied else { return .skip(.offline) }
        if input.isRunning { return .skip(.alreadyRunning) }

        // 手动触发绕过间隔限制——用户明确点了按钮就该立刻测。
        if input.trigger != .manual, !input.networkKeyChanged {
            let interval = input.path.isExpensive || input.path.isConstrained
                ? max(input.minimumInterval, meteredMinimumInterval)
                : input.minimumInterval
            if let last = input.lastCompletedAt, input.now.timeIntervalSince(last) < interval {
                return .skip(.tooSoon)
            }
        }

        // 降级判据。注意这里返回的是 .run(.light) 而不是 skip：
        // 轻量检测只有 35KB，在热点上也完全可以跑，用户仍然能看到延迟和连通性。
        if input.preferredTier != .light {
            if input.path.isExpensive { return .run(.light) }
            if input.path.isConstrained { return .run(.light) }
            if input.isDischarging, input.batteryPercent < minimumBatteryPercentForFullTest {
                return .run(.light)
            }
            if input.thermalUnderPressure { return .run(.light) }
        }

        return .run(input.preferredTier)
    }

    /// 完整测速被降级的原因，用于在界面上说明「为什么这次只测了延迟」。
    public static func downgradeReason(_ input: Input) -> NetworkSkipReason? {
        guard input.preferredTier != .light else { return nil }
        if input.path.isExpensive { return .meteredNetwork }
        if input.path.isConstrained { return .lowDataMode }
        if input.isDischarging, input.batteryPercent < minimumBatteryPercentForFullTest { return .lowBattery }
        if input.thermalUnderPressure { return .thermalPressure }
        return nil
    }
}

// MARK: - 测量数学

public enum NetworkMath {
    /// 相对离散度超过这个值就不给头条数字，只给区间。
    public static let trustworthySpreadThreshold = 0.35
    /// 每块丢弃开头这个比例的样本。
    ///
    /// 这是整套方法里最关键的一个常数：实测同一条链路，不丢弃预热段测出
    /// ~95 Mbps，丢弃后测出 ~390 Mbps —— 4 倍差距，全部来自 TCP 慢启动。
    public static let warmUpFraction = 0.30

    public static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        guard sorted.count > 1 else { return sorted[0] }
        let position = p * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = Int(position.rounded(.up))
        guard upper < sorted.count else { return sorted[lower] }
        let weight = position - Double(lower)
        return sorted[lower] * (1 - weight) + sorted[upper] * weight
    }

    /// 抖动 = 相邻样本差的平均绝对值。
    /// 比标准差更贴近体感：连续的小幅抖动比偶发的一次大偏离更影响通话。
    public static func meanAbsoluteSuccessiveDifference(_ values: [Double]) -> Double? {
        guard values.count > 1 else { return nil }
        var total = 0.0
        for index in 1..<values.count {
            total += abs(values[index] - values[index - 1])
        }
        return total / Double(values.count - 1)
    }

    /// 从「累计字节 vs 时间」的采样序列里算稳态速率，丢弃开头的预热段。
    ///
    /// - Parameter samples: (自块开始的秒数, 累计字节)，按时间递增。
    /// - Returns: 比特/秒。样本不足以覆盖预热段时返回 nil，而不是硬算一个偏低的值。
    public static func steadyStateRate(
        samples: [(seconds: Double, bytes: Int64)],
        warmUpFraction: Double = NetworkMath.warmUpFraction
    ) -> Double? {
        guard samples.count >= 2, let last = samples.last, last.seconds > 0 else { return nil }
        let cutoff = last.seconds * warmUpFraction
        guard let startIndex = samples.firstIndex(where: { $0.seconds >= cutoff }) else { return nil }
        let start = samples[startIndex]
        let elapsed = last.seconds - start.seconds
        let bytes = last.bytes - start.bytes
        guard elapsed > 0, bytes > 0 else { return nil }
        return Double(bytes) * 8 / elapsed
    }

    /// 把多块的速率合成一个带区间的估计：中位数 + [最小, 最大]。
    /// 绝不返回裸点估计。
    public static func combine(chunkRates: [Double], streams: Int) -> ThroughputEstimate? {
        let valid = chunkRates.filter { $0.isFinite && $0 > 0 }
        guard !valid.isEmpty else { return nil }
        let median = percentile(valid, 0.5) ?? valid[0]
        return ThroughputEstimate(
            bitsPerSecond: median,
            lowBitsPerSecond: valid.min() ?? median,
            highBitsPerSecond: valid.max() ?? median,
            streams: streams,
            samples: valid.count
        )
    }

    /// 按上一块观测到的速率决定下一块要传多少字节：目标是固定的测量时长，
    /// 而不是固定的字节数。慢链路上自动收敛到小块，不会让用户等半分钟。
    public static func nextChunkBytes(
        observedBitsPerSecond: Double,
        targetSeconds: Double,
        minimumBytes: Int64,
        maximumBytes: Int64
    ) -> Int64 {
        guard observedBitsPerSecond.isFinite, observedBitsPerSecond > 0 else { return minimumBytes }
        let bytes = observedBitsPerSecond / 8 * targetSeconds
        guard bytes.isFinite else { return minimumBytes }
        return min(maximumBytes, max(minimumBytes, Int64(bytes)))
    }

    /// 缓冲膨胀评级。这是最能解释「网速不慢但视频会议卡」的指标。
    public static func bufferbloatGrade(_ milliseconds: Double?) -> String? {
        guard let milliseconds, milliseconds.isFinite else { return nil }
        switch milliseconds {
        case ..<30: return "A · 几乎无排队"
        case ..<60: return "B · 轻微"
        case ..<150: return "C · 明显"
        default: return "D · 严重"
        }
    }

    public static func isStale(_ completedAt: Date?, now: Date, threshold: TimeInterval = NetworkTestPolicy.stalenessThreshold) -> Bool {
        guard let completedAt else { return true }
        return now.timeIntervalSince(completedAt) > threshold
    }

    /// 「3 分钟前测得」。永远不要把过期数字当现值展示。
    public static func ageDescription(_ completedAt: Date?, now: Date) -> String {
        guard let completedAt else { return "尚未测速" }
        let seconds = max(0, now.timeIntervalSince(completedAt))
        if seconds < 60 { return "刚刚测得" }
        if seconds < 3_600 { return "\(Int(seconds / 60)) 分钟前测得" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600)) 小时前测得" }
        return "\(Int(seconds / 86_400)) 天前测得"
    }

    public static func megabitsPerSecond(_ bitsPerSecond: Double?) -> String {
        guard let bitsPerSecond, bitsPerSecond.isFinite, bitsPerSecond > 0 else { return "不可用" }
        let mbps = bitsPerSecond / 1_000_000
        if mbps < 10 { return String(format: "%.1f Mbps", mbps) }
        return String(format: "%.0f Mbps", mbps)
    }
}
