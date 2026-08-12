import Charts
import MacPulseCore
import SwiftUI

struct NetworkView: View {
    @EnvironmentObject private var model: DashboardModel
    @AppStorage("networkTestConsent") private var consentRaw = NetworkConsent.notDetermined.rawValue
    @State fileprivate var trendMetric: NetworkTrendMetric = .download
    @State fileprivate var trendRange: NetworkTrendRange = .week

    private var consent: NetworkConsent {
        NetworkConsent(rawValue: consentRaw) ?? .notDetermined
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                linkCard
                if consent == .notDetermined {
                    consentCard
                } else {
                    liveThroughputCard
                    if model.networkHistory.count >= 2 {
                        trendCard
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    // MARK: - 连接（零流量，永远可见）

    private var linkCard: some View {
        LiquidCard {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    SectionHeader(title: "当前连接", subtitle: link?.summary)
                    Spacer(minLength: 0)
                    StatusPill(
                        text: model.networkPath.isSatisfied ? "已连接" : "离线",
                        symbol: model.networkPath.isSatisfied ? "wifi" : "wifi.slash",
                        color: model.networkPath.isSatisfied ? MacPulseTheme.normal : MacPulseTheme.critical
                    )
                }

                ValueRow(
                    title: "接口",
                    value: interfaceText,
                    symbol: "point.3.connected.trianglepath.dotted"
                )
                // 改名「当前发射速率」并当场解释:这是瞬时 PHY 速率,空闲时
                // Wi-Fi 自动降速省电,实测下载超过它是正常物理——旧版标着
                // 「协商速率 360」配「下载 458」,解释藏在折叠详情里,主屏像坏了。
                ValueRow(
                    title: "当前发射速率",
                    value: link?.linkRateMbps.map { String(format: "%.0f Mbps", $0) } ?? "不可用",
                    symbol: "gauge.with.dots.needle.67percent"
                )
                if link?.linkRateMbps != nil {
                    Text("瞬时链路速率,空闲时会自动降速省电;实测吞吐高于它属正常。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ValueRow(
                    title: "实时下行",
                    value: liveRateText(model.current.deep.networkInBytesPerSecond),
                    symbol: "arrow.down.circle",
                    tint: .green
                )
                ValueRow(
                    title: "实时上行",
                    value: liveRateText(model.current.deep.networkOutBytesPerSecond),
                    symbol: "arrow.up.circle",
                    tint: .blue
                )

                if !badges.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(badges, id: \.text) { badge in
                            StatusPill(text: badge.text, symbol: badge.symbol, color: badge.tint)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private var link: NetworkLinkInfo? { model.current.deep.networkLink }

    /// 实时吞吐补一个 Mbps 括号:同卡上下文全是 Mbps(bit),
    /// 只有这两行是字节速率,差 8 倍,不注明必被拿去硬比。
    private func liveRateText(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond, bytesPerSecond.isFinite, bytesPerSecond >= 0 else { return "不可用" }
        let mbps = bytesPerSecond * 8 / 1_000_000
        return "\(MetricFormat.rate(bytesPerSecond))（≈\(String(format: mbps < 10 ? "%.1f" : "%.0f", mbps)) Mbps）"
    }

    private var interfaceText: String {
        let name = link?.interfaceName ?? model.networkPath.primaryInterfaceName
        let kind = link?.kind ?? model.networkPath.primaryInterfaceKind
        switch (kind, name) {
        case let (kind?, name?): return "\(kind.title) · \(name)"
        case let (kind?, nil): return kind.title
        case let (nil, name?): return name
        default: return "不可用"
        }
    }

    private var badges: [(text: String, symbol: String, tint: Color)] {
        var result: [(String, String, Color)] = []
        if model.networkPath.isExpensive {
            result.append(("按流量计费", "dollarsign.circle", MacPulseTheme.warm))
        }
        if model.networkPath.isConstrained {
            result.append(("低数据模式", "tortoise", MacPulseTheme.warm))
        }
        // 「无 IPv6」徽章已删:它用的 supportsIPv6 是本地配置位,探针代码
        // 自己注明那是误导信号(链路本地地址也算「支持」);实测可达性
        // 在测速详情里,不在这里抢答。
        if model.networkPath.usesVPN {
            result.append(("VPN", "lock.shield", MacPulseTheme.plugged))
        }
        return result.map { (text: $0.0, symbol: $0.1, tint: $0.2) }
    }

    // MARK: - 首次同意

    /// 放在标签页内而不是弹窗：在菜单栏弹窗上盖一层模态很粗暴。
    /// 选「保持完全离线」之后上面那张连接卡照常可用，不惩罚这个选择。
    private var consentCard: some View {
        LiquidCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "网络测速", subtitle: "需要你先同意")

                Text("开启后，MacPulse 会连接 Cloudflare 的公开测速节点来实测你的网速。这是这个 App 唯一会发出的网络请求。")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 7) {
                    ConsentPoint(symbol: "paperplane", text: "只发送无意义的填充字节用于计时，不发送设备信息、进程名、电池数据或任何标识符。")
                    ConsentPoint(symbol: "eye", text: "对方能看到的只有你的公网 IP 和由 IP 推断的大致地区——任何网络请求都无法避免这一点。")
                    ConsentPoint(symbol: "internaldrive", text: "结果只写入本机，不含 IP、Wi-Fi 名称或精确位置。")
                    ConsentPoint(symbol: "arrow.up.arrow.down", text: "完整测速每次约 65 MB；轻量检测约 35 KB。强度和自动测速都能在设置里改。")
                }

                HStack(spacing: 9) {
                    Button("开启网络测速") {
                        consentRaw = NetworkConsent.granted.rawValue
                    }
                    .buttonStyle(.borderedProminent)

                    Button("保持完全离线") {
                        consentRaw = NetworkConsent.denied.rawValue
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.top, 2)
            }
        }
    }

    // MARK: - 测速结果

    @ViewBuilder
    private var liveThroughputCard: some View {
        LiquidCard {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    SectionHeader(
                        title: "测速结果",
                        subtitle: NetworkMath.ageDescription(model.networkResult?.startedAt, now: .now)
                    )
                    Spacer(minLength: 0)
                    if model.isNetworkTestRunning {
                        Button("停止") { model.cancelNetworkTest() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    } else if consent == .granted {
                        Button("重新测速") { model.requestManualNetworkTest() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }

                if let phase = model.networkPhase {
                    // 测速期间不用动画表盘：一个比被测对象还费 CPU 的界面
                    // 在这个 App 里是自我讽刺。普通线性条，放在卡片之外的层级。
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(phase).font(.caption).foregroundStyle(.secondary)
                    }
                }

                // 跳过原因独立成行,不再被「已有结果」压死——类型注释自己写着
                // 「静默跳过等于让人以为测过了」,旧版恰好在有结果后全部静默,
                // 手动点「重新测速」被跳过时无声无息。
                if let skip = model.networkSkipReason, model.networkPhase == nil {
                    Text("本次未测:\(skip.title)")
                        .font(.caption)
                        .foregroundStyle(MacPulseTheme.warm)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let result = model.networkResult {
                    if result.connectivity != .online {
                        // 失败的测速不摆四块「不可用」大牌装哑巴,直接说原因;
                        // 头部的「已连接」胶囊只代表本地链路,断的可能是 DNS。
                        Text("测速未完成:\(result.connectivity.title)")
                            .font(.callout.weight(.semibold))
                        Text("本地链路正常不代表出网正常,常见于 DNS 或门户认证故障。")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    } else {
                        resultGrid(result)
                        footnote(result)
                        detail(result)
                    }
                } else if consent == .denied {
                    Text("网络测速已关闭。上面的接口、发射速率和实时吞吐都是本机读数，不需要联网。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if model.networkPhase == nil, model.networkSkipReason == nil {
                    Text("打开面板时会自动测速。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func resultGrid(_ result: NetworkTestResult) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            MetricCard(
                title: "下载",
                value: throughputText(result.download),
                detail: throughputDetail(result.download),
                symbol: "arrow.down.circle.fill",
                tint: MacPulseTheme.normal
            )
            MetricCard(
                title: "上传",
                value: throughputText(result.upload),
                detail: throughputDetail(result.upload),
                symbol: "arrow.up.circle.fill",
                tint: MacPulseTheme.plugged
            )
            MetricCard(
                title: "延迟",
                value: result.latency.map { String(format: "%.0f ms", $0.p50Milliseconds) } ?? "不可用",
                detail: result.latency.map { String(format: "抖动 %.0f ms", $0.jitterMilliseconds) } ?? "—",
                symbol: "timer",
                tint: MacPulseTheme.violet
            )
            MetricCard(
                title: "负载延迟",
                value: result.bufferbloatMilliseconds.map { String(format: "+%.0f ms", $0) } ?? "不可用",
                detail: NetworkMath.bufferbloatGrade(result.bufferbloatMilliseconds) ?? "—",
                symbol: "chart.line.uptrend.xyaxis",
                tint: MacPulseTheme.warm
            )
        }
    }

    /// 离散度过大时**隐藏头条数字**，只显示区间。这是诚实的关键一环：
    /// 同一条链路连测三次能差 40%，硬报一个数就是在假装精确。
    private func throughputText(_ estimate: ThroughputEstimate?) -> String {
        guard let estimate else { return "不可用" }
        guard estimate.isTrustworthy else {
            return "\(NetworkMath.megabitsPerSecond(estimate.lowBitsPerSecond))–\(NetworkMath.megabitsPerSecond(estimate.highBitsPerSecond))"
        }
        return NetworkMath.megabitsPerSecond(estimate.bitsPerSecond)
    }

    private func throughputDetail(_ estimate: ThroughputEstimate?) -> String {
        guard let estimate else { return "—" }
        guard estimate.isTrustworthy else { return "测量不稳定" }
        return String(format: "±%.0f%% · %d 连接", estimate.relativeSpread * 50, estimate.streams)
    }

    /// 没有下载估计就不报「样本 0 次」——那是被规范点名禁止的假 0;
    /// 用量走字节格式化,轻量档的几百 KB 不再被整数除法碾成「0 MB」。
    private func footnoteText(_ result: NetworkTestResult) -> String {
        var parts: [String] = []
        if let samples = result.download?.samples, samples > 0 {
            parts.append("样本 \(samples) 次")
        }
        let totalBytes = result.bytesDownloaded + result.bytesUploaded
        if totalBytes > 0 {
            parts.append("用了 \(MetricFormat.bytes(UInt64(totalBytes)))")
        }
        parts.append("测的是到最近的 Cloudflare 节点")
        return parts.joined(separator: " · ")
    }

    private func footnote(_ result: NetworkTestResult) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(footnoteText(result))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if let downgrade = model.networkDowngradeReason {
                Text(downgrade.title)
                    .font(.caption2)
                    .foregroundStyle(MacPulseTheme.warm)
            }
            if result.completeness == .partial {
                Text("这次测量被中断，结果按已完成的部分给出，误差区间更宽。")
                    .font(.caption2)
                    .foregroundStyle(MacPulseTheme.warm)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func detail(_ result: NetworkTestResult) -> some View {
        DisclosureGroup("详情") {
            VStack(spacing: 7) {
                ValueRow(title: "空闲延迟 p95", value: result.latency.map { String(format: "%.0f ms", $0.p95Milliseconds) } ?? "不可用", symbol: "timer")
                ValueRow(title: "服务端测得 RTT", value: result.latency?.serverMinRttMilliseconds.map { String(format: "%.1f ms", $0) } ?? "不可用", symbol: "server.rack")
                ValueRow(title: "握手失败", value: result.latency.map { "\($0.failures)/\($0.attempts)" } ?? "不可用", symbol: "exclamationmark.triangle")
                if let utilisation = result.linkUtilisation {
                    ValueRow(title: "链路利用率", value: String(format: "%.0f%%", utilisation * 100), symbol: "percent")
                }
                ValueRow(title: "IPv6 可达", value: result.ipv6Reachable.map { $0 ? "是" : "否" } ?? "不可用", symbol: "6.circle")
                ValueRow(title: "连通性", value: result.connectivity.title, symbol: "checkmark.seal")

                Text("丢包率：未测量（需要 ICMP 探测）。TCP 的重传会把丢包表现成延迟升高，从 TCP 数据里印一个「丢包 0%」是编造。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let rate = result.link?.linkRateMbps, result.linkUtilisation != nil {
                    Text("链路协商 \(String(format: "%.0f", rate)) Mbps 与实测的差距属正常：Wi-Fi 是半双工，协商速率是理论上限。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.top, 6)
        }
        .font(.caption)
    }
}

private enum NetworkTrendMetric: String, CaseIterable, Identifiable {
    case download = "下载"
    case upload = "上传"
    case latency = "延迟"

    var id: String { rawValue }
}

private enum NetworkTrendRange: String, CaseIterable, Identifiable {
    case week = "7 天"
    case month = "30 天"

    var id: String { rawValue }
    var days: Int { self == .week ? 7 : 30 }
}

extension NetworkView {
    /// 测速趋势。
    ///
    /// 用 `PointMark` + `LineMark` 而不是 `AreaMark`：测速是**离散事件**，
    /// 不是连续采样序列。填充面积会暗示两次测速之间的时间也有数据，那是假的。
    /// 按网络分色，「家里」和「公司」自然分成两条线。
    @ViewBuilder
    var trendCard: some View {
        LiquidCard {
            VStack(alignment: .leading, spacing: 10) {
                // 计数与图同口径:旧版数 90 天全量,轻量档用户会看到
                // 「42 次记录」顶着一张「这个范围内还没有可用记录」的空图。
                SectionHeader(title: "测速趋势", subtitle: "\(trendPoints.count) 次记录")

                Picker("指标", selection: $trendMetric) {
                    ForEach(NetworkTrendMetric.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Picker("范围", selection: $trendRange) {
                    ForEach(NetworkTrendRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                let points = trendPoints
                if points.isEmpty {
                    Text("这个范围内还没有可用记录。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    Chart(points, id: \.id) { point in
                        LineMark(
                            x: .value("时间", point.date),
                            y: .value(trendMetric.rawValue, point.value),
                            series: .value("网络", point.series)
                        )
                        .foregroundStyle(by: .value("网络", point.series))
                        .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round))

                        PointMark(
                            x: .value("时间", point.date),
                            y: .value(trendMetric.rawValue, point.value)
                        )
                        .foregroundStyle(by: .value("网络", point.series))
                        .symbolSize(28)
                    }
                    .chartLegend(points.contains { $0.series != points[0].series } ? .visible : .hidden)
                    .chartYAxis {
                        AxisMarks(position: .leading) { value in
                            AxisGridLine().foregroundStyle(.primary.opacity(0.06))
                            AxisValueLabel {
                                if let raw = value.as(Double.self) {
                                    Text(trendAxisLabel(raw)).font(.caption2)
                                }
                            }
                        }
                    }
                    .frame(height: 120)

                    Text("每个点是一次实测，不是连续采样——两点之间没有数据。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    struct TrendPoint: Identifiable {
        let id: String
        let date: Date
        let value: Double
        let series: String
    }

    var trendPoints: [TrendPoint] {
        let cutoff = Date().addingTimeInterval(-Double(trendRange.days) * 86_400)
        return model.networkHistory.compactMap { record -> TrendPoint? in
            guard record.startedAt >= cutoff else { return nil }
            let value: Double?
            switch trendMetric {
            case .download: value = record.downloadBitsPerSecond.map { $0 / 1_000_000 }
            case .upload: value = record.uploadBitsPerSecond.map { $0 / 1_000_000 }
            case .latency: value = record.latencyP50Ms
            }
            guard let value, value.isFinite, value > 0 else { return nil }
            // 用友好名称优先；没起名就用哈希前 4 位区分，仍然不暴露任何标识。
            let series = record.networkLabel
                ?? record.networkKeyHash.map { "网络 \($0.prefix(4))" }
                ?? (record.interfaceName ?? "未知网络")
            return TrendPoint(id: record.recordKey, date: record.startedAt, value: value, series: series)
        }
    }

    func trendAxisLabel(_ value: Double) -> String {
        trendMetric == .latency ? "\(Int(value)) ms" : "\(Int(value))M"
    }
}

private struct ConsentPoint: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
