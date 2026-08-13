import AppKit
import Charts
import MacPulseCore
import SwiftUI

struct PerformanceView: View {
    @EnvironmentObject private var model: DashboardModel
    @State private var pane: PerformancePane = .soc

    var body: some View {
        VStack(spacing: 9) {
            Picker(String(localized: "性能内容"), selection: $pane) {
                ForEach(PerformancePane.allCases) { item in
                    Text(L(item.rawValue)).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)

            // switch 天然保证只有当前子页的视图树存在，这既是渲染成本的下限，
            // 也是下面那套按子页门控采样的依据。
            Group {
                switch pane {
                case .soc:
                    SoCPanelView()
                case .memory:
                    MemoryPanelView()
                case .disk:
                    DiskPanelView()
                case .startup:
                    StartupItemsView()
                case .thermal:
                    ThermalPanelView()
                case .processes:
                    ProcessExplorerView()
                }
            }
            .environmentObject(model)
        }
        .onAppear {
            model.performancePaneChanged(pane)
        }
        .onChange(of: pane) { _, value in
            model.performancePaneChanged(value)
        }
        .onDisappear {
            model.performancePaneChanged(nil)
        }
    }
}

private enum ProcessCategoryFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case application = "应用"
    case background = "后台"
    case system = "系统"

    var id: String { rawValue }

    func includes(_ category: ProcessCategory) -> Bool {
        switch self {
        case .all: true
        case .application: category == .application
        case .background: category == .background
        case .system: category == .system
        }
    }
}

private struct ProcessExplorerView: View {
    @EnvironmentObject private var model: DashboardModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var metric: ProcessMetricKind = .cpu
    @State private var category: ProcessCategoryFilter = .all
    @State private var searchText = ""
    @State private var expandedIdentifier: String?
    @State private var selfDetailsExpanded = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                monitorStatus
                selfImpactCard
                controls

                if filteredGroups.isEmpty {
                    emptyState
                } else {
                    ForEach(filteredGroups) { group in
                        ProcessGroupRow(
                            group: group,
                            metric: metric,
                            maximumValue: maximumValue,
                            isExpanded: expandedIdentifier == group.stableIdentifier
                        ) {
                            withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
                                expandedIdentifier = expandedIdentifier == group.stableIdentifier
                                    ? nil
                                    : group.stableIdentifier
                            }
                            if expandedIdentifier == group.stableIdentifier {
                                model.loadProcessHistory(for: group.stableIdentifier)
                            }
                        }
                        .environmentObject(model)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private var monitorStatus: some View {
        if model.processMonitorStatus.phase != .live {
            HStack(spacing: 8) {
                Image(systemName: statusSymbol)
                    .foregroundStyle(statusColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle)
                        .font(.caption.weight(.semibold))
                    Text(statusDetail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 4)
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private var selfImpactCard: some View {
        LiquidCard(padding: 14) {
            if let group = selfGroup {
                VStack(spacing: 12) {
                    HStack(spacing: 11) {
                        ProcessIcon(group: group, size: 38)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(localized: "MacPulse 自身负担"))
                                .font(.headline)
                            Text(String(format: String(localized: "%@ 个组件 · 本机实时"), String(describing: group.children.count)))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        StatusPill(
                            text: selfImpactTitle(group),
                            symbol: selfImpactSymbol(group),
                            color: selfImpactColor(group)
                        )
                    }

                    HStack(spacing: 0) {
                        compactValue(
                            title: "CPU",
                            value: processCPU(group.smoothedCPUPercent)
                        )
                        Divider().frame(height: 34)
                        compactValue(
                            title: String(localized: "物理内存"),
                            value: MetricFormat.bytes(group.physicalFootprintBytes)
                        )
                        Divider().frame(height: 34)
                        compactValue(
                            title: String(localized: "能耗趋势"),
                            value: group.energyImpact.title
                        )
                    }

                    Button {
                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) {
                            selfDetailsExpanded.toggle()
                        }
                    } label: {
                        HStack {
                            Text(selfDetailsExpanded ? String(localized: "收起组件") : String(localized: "查看组件"))
                            Spacer()
                            Image(systemName: "chevron.down")
                                .rotationEffect(.degrees(selfDetailsExpanded ? 180 : 0))
                        }
                        .font(.caption.weight(.semibold))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if selfDetailsExpanded {
                        Divider()
                        ForEach(group.children) { child in
                            ProcessChildRow(process: child)
                        }
                    }
                }
            } else {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "正在测量 MacPulse 自身负担"))
                            .font(.callout.weight(.semibold))
                        Text(String(localized: "取得第二个样本后显示 CPU 和能耗趋势"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        }
    }

    private var controls: some View {
        LiquidCard(padding: 12) {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(String(localized: "搜索 App 或进程"), text: $searchText)
                        .textFieldStyle(.plain)
                        .accessibilityLabel(String(localized: "搜索 App 或进程"))
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(String(localized: "清除搜索"))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))

                HStack(spacing: 8) {
                    Picker(String(localized: "排行指标"), selection: $metric) {
                        ForEach(ProcessMetricKind.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker(String(localized: "进程分类"), selection: $category) {
                        ForEach(ProcessCategoryFilter.allCases) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 82)
                }

                if metric == .cpu {
                    Text(String(localized: "CPU 以一个核心为 100%，多核任务可以超过 100%。"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if metric == .energy {
                    Text(String(localized: "能耗为系统估算的相对趋势，不代表精确瓦数。"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if metric == .gpu {
                    // ms/s 这种单位不解释没人看得懂,和 CPU/能耗一样给一句边界。
                    Text(String(localized: "GPU 时间是各 App 提交的 Metal 命令耗时，加起来不等于系统 GPU 占用率。"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var emptyState: some View {
        LiquidCard {
            VStack(spacing: 8) {
                Image(systemName: model.processMonitorStatus.phase == .disabled
                      ? "pause.circle" : "magnifyingglass")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text(model.processMonitorStatus.phase == .disabled
                     ? String(localized: "进程监控已关闭") : String(localized: "没有符合条件的进程"))
                    .font(.callout.weight(.semibold))
                Text(model.processMonitorStatus.phase == .disabled
                     ? String(localized: "可在设置中重新开启。")
                     : String(localized: "尝试清除搜索或切换分类。搜索只覆盖负载最高的 50 个 App，后台小工具可能不在其列。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var selfGroup: ProcessGroupSnapshot? {
        model.processGroups.first(where: \.isMacPulse)
    }

    private var filteredGroups: [ProcessGroupSnapshot] {
        model.processGroups
            .filter { !$0.isMacPulse }
            .filter { category.includes($0.category) }
            .filter {
                searchText.isEmpty
                    || $0.displayName.localizedCaseInsensitiveContains(searchText)
                    || $0.children.contains {
                        $0.displayName.localizedCaseInsensitiveContains(searchText)
                    }
            }
            .sorted { metricValue($0) > metricValue($1) }
    }

    private var maximumValue: Double {
        max(1, filteredGroups.map(metricValue).max() ?? 1)
    }

    private func metricValue(_ group: ProcessGroupSnapshot) -> Double {
        switch metric {
        case .cpu: group.smoothedCPUPercent ?? -1
        case .memory: Double(group.physicalFootprintBytes ?? 0)
        case .gpu: group.gpuNanosecondsPerSecond ?? -1
        case .disk:
            (group.diskReadBytesPerSecond ?? 0) + (group.diskWriteBytesPerSecond ?? 0)
        case .energy:
            group.energyNanojoulesPerSecond ?? -1
        }
    }

    private func compactValue(title: String, value: String) -> some View {
        VStack(spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func selfImpactTitle(_ group: ProcessGroupSnapshot) -> String {
        if (group.smoothedCPUPercent ?? 0) >= 2
            || (group.physicalFootprintBytes ?? 0) >= 200 * 1_048_576 {
            return String(localized: "需关注")
        }
        return String(localized: "低负担")
    }

    private func selfImpactSymbol(_ group: ProcessGroupSnapshot) -> String {
        selfImpactTitle(group) == String(localized: "低负担") ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
    }

    private func selfImpactColor(_ group: ProcessGroupSnapshot) -> Color {
        selfImpactTitle(group) == String(localized: "低负担") ? MacPulseTheme.normal : MacPulseTheme.warm
    }

    private var statusTitle: String {
        switch model.processMonitorStatus.phase {
        case .disabled: String(localized: "进程监控已关闭")
        case .starting: String(localized: "正在建立进程基线")
        case .live: String(localized: "进程监控正常")
        case .partial: String(localized: "部分系统进程权限受限")
        case .unavailable: String(localized: "进程数据暂不可用")
        case .sleeping: String(localized: "睡眠期间暂停进程采样")
        }
    }

    private var statusDetail: String {
        switch model.processMonitorStatus.phase {
        case .partial:
            String(format: String(localized: "已读取 %@ 个进程，其中 %@ 个读不到用量；受限项不会影响其他排行。"), String(describing: model.processMonitorStatus.sampledProcessCount), String(describing: model.processMonitorStatus.limitedProcessCount))
        case .starting:
            String(localized: "CPU、磁盘和能耗需要两个样本，通常约 5 秒。")
        case .unavailable:
            model.processMonitorStatus.errorMessage ?? String(localized: "稍后会自动重试。")
        case .disabled:
            String(localized: "可在设置页重新开启。")
        case .sleeping:
            String(localized: "唤醒后会重新建立差值基线。")
        case .live:
            String(localized: "数据正常")
        }
    }

    private var statusSymbol: String {
        switch model.processMonitorStatus.phase {
        case .disabled: "pause.circle.fill"
        case .starting: "hourglass"
        case .live: "checkmark.circle.fill"
        case .partial: "lock.trianglebadge.exclamationmark"
        case .unavailable: "exclamationmark.triangle.fill"
        case .sleeping: "moon.zzz.fill"
        }
    }

    private var statusColor: Color {
        switch model.processMonitorStatus.phase {
        case .live: MacPulseTheme.normal
        case .starting: MacPulseTheme.plugged
        case .partial: MacPulseTheme.warm
        case .disabled, .sleeping: .secondary
        case .unavailable: MacPulseTheme.critical
        }
    }
}

private struct ProcessGroupRow: View {
    @EnvironmentObject private var model: DashboardModel
    let group: ProcessGroupSnapshot
    let metric: ProcessMetricKind
    let maximumValue: Double
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        LiquidCard(padding: 12) {
            VStack(spacing: 10) {
                Button(action: toggle) {
                    HStack(spacing: 10) {
                        ProcessIcon(group: group, size: 32)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 5) {
                                Text(group.displayName)
                                    .font(.callout.weight(.semibold))
                                    .lineLimit(1)
                                if group.isPermissionLimited {
                                    Image(systemName: "lock.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            HStack(spacing: 5) {
                                Text(group.category.title)
                                Text("·")
                                Text(String(format: String(localized: "%@ 个进程"), String(describing: group.children.count)))
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 5)
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(primaryValue)
                                .font(.callout.weight(.bold))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                            Text(group.isEstablishingBaseline ? String(localized: "建立基线") : metric.title)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(group.displayName)，\(primaryValue)")
                .accessibilityHint(isExpanded ? String(localized: "收起详情") : String(localized: "展开详情"))

                GeometryReader { proxy in
                    Capsule()
                        .fill(.primary.opacity(0.06))
                        .overlay(alignment: .leading) {
                            // 没有读数时只留空槽。画一条 0 宽度的实心条会被读成
                            // 「已测量，值为 0」，和旁边写着「不可用」的文字自相矛盾。
                            if let progress {
                                Capsule()
                                    .fill(
                                        LinearGradient(
                                            colors: [tint.opacity(0.55), tint],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .frame(width: proxy.size.width * progress)
                            }
                        }
                }
                .frame(height: 5)
                .accessibilityHidden(true)

                if isExpanded {
                    Divider()
                    detail
                }
            }
        }
    }

    private var detail: some View {
        VStack(spacing: 11) {
            HStack(spacing: 0) {
                detailValue("CPU", processCPU(group.smoothedCPUPercent))
                Divider().frame(height: 31)
                detailValue(String(localized: "内存"), MetricFormat.bytes(group.physicalFootprintBytes))
                Divider().frame(height: 31)
                detailValue(
                    String(localized: "磁盘"),
                    MetricFormat.rate(
                        optionalSum(group.diskReadBytesPerSecond, group.diskWriteBytesPerSecond)
                    )
                )
                Divider().frame(height: 31)
                detailValue(String(localized: "能耗"), group.energyImpact.title)
            }

            VStack(spacing: 8) {
                ValueRow(
                    title: String(localized: "磁盘读取"),
                    value: MetricFormat.rate(group.diskReadBytesPerSecond),
                    symbol: "arrow.up.left"
                )
                ValueRow(
                    title: String(localized: "磁盘写入"),
                    value: MetricFormat.rate(group.diskWriteBytesPerSecond),
                    symbol: "arrow.down.right"
                )
                ValueRow(
                    title: String(localized: "唤醒次数"),
                    value: group.wakeupsPerSecond.map {
                        String(format: String(localized: "%.1f 次/秒"), $0)
                    } ?? String(localized: "不可用"),
                    symbol: "bell"
                )
            }

            if let path = group.executablePath {
                VStack(alignment: .leading, spacing: 3) {
                    Text(String(localized: "路径"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(path)
                        .font(.caption2.monospaced())
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if group.children.count > 1 {
                VStack(spacing: 7) {
                    ForEach(group.children) { child in
                        ProcessChildRow(process: child)
                    }
                }
            }

            ProcessHistoryChart(
                points: model.processHistory(for: group.stableIdentifier),
                metric: metric
            )
        }
    }

    private var primaryValue: String {
        if group.isEstablishingBaseline, metric != .memory {
            return String(localized: "采集中")
        }
        return switch metric {
        case .cpu: processCPU(group.smoothedCPUPercent)
        case .memory: MetricFormat.bytes(group.physicalFootprintBytes)
        case .gpu: MetricFormat.gpuTime(group.gpuNanosecondsPerSecond)
        case .disk:
            MetricFormat.rate(optionalSum(
                group.diskReadBytesPerSecond,
                group.diskWriteBytesPerSecond
            ))
        case .energy: group.energyImpact.title
        }
    }

    private var progress: Double? {
        switch metric {
        case .energy:
            switch group.energyImpact {
            case .unavailable: nil
            case .low: 0.25
            case .medium: 0.60
            case .high: 1
            }
        default:
            metricValue.map { min(max($0 / maximumValue, 0), 1) }
        }
    }

    /// 供渲染使用，读不到就是 nil。
    /// 排序另有一套带 `-1` 哨兵的比较函数（`ProcessExplorerView.metricValue(_:)`），
    /// 两者不可混用：哨兵是为了把「不可用」沉到列表底部，不是一个可以画出来的值。
    private var metricValue: Double? {
        switch metric {
        case .cpu: group.smoothedCPUPercent
        case .memory: group.physicalFootprintBytes.map(Double.init)
        case .gpu: group.gpuNanosecondsPerSecond
        case .disk: optionalSum(group.diskReadBytesPerSecond, group.diskWriteBytesPerSecond)
        case .energy: group.energyNanojoulesPerSecond
        }
    }

    private var tint: Color {
        switch metric {
        // 单色化补刀:青/蓝绿是别名重定义没覆盖到的字面量彩条(审计中危)。
        // 能耗保留语义三色——那是「好/注意/出事」,不是装饰。
        case .cpu: MacPulseTheme.ink
        case .memory: MacPulseTheme.ink
        case .gpu: MacPulseTheme.ink
        case .disk: MacPulseTheme.ink
        case .energy:
            switch group.energyImpact {
            case .unavailable, .low: MacPulseTheme.normal
            case .medium: MacPulseTheme.warm
            case .high: MacPulseTheme.critical
            }
        }
    }

    private func detailValue(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ProcessChildRow: View {
    let process: ProcessSnapshot

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: childSymbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 17)
            VStack(alignment: .leading, spacing: 2) {
                Text(process.displayName)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text("PID \(process.pid)")
                    if let launchDate = process.launchDate {
                        Text("·")
                        Text(runtime(from: launchDate))
                    }
                    if let count = process.threadCount {
                        Text(String(format: String(localized: "· %@ 线程"), String(describing: count)))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(processCPU(process.smoothedCPUPercent))
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                Text(MetricFormat.bytes(process.physicalFootprintBytes))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var childSymbol: String {
        if process.displayName == "MacPulse" { return "waveform.path.ecg" }
        if process.displayName == "MacPulseCollector" { return "sensor.tag.radiowaves.forward" }
        return "gearshape.2"
    }

    private func runtime(from launchDate: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(launchDate))
        if seconds < 60 { return String(localized: "<1 分钟") }
        if seconds < 3_600 { return String(format: String(localized: "%@ 分钟"), String(describing: Int(seconds / 60))) }
        if seconds < 86_400 { return String(format: String(localized: "%@ 小时"), String(describing: Int(seconds / 3_600))) }
        return String(format: String(localized: "%@ 天"), String(describing: Int(seconds / 86_400)))
    }
}

private struct ProcessHistoryChart: View {
    let points: [ProcessHistoryPoint]
    let metric: ProcessMetricKind

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(String(localized: "7 天趋势"))
                    .font(.caption.weight(.semibold))
                Spacer()
                // 计数与图表同一口径:旧版数未过滤的 points,GPU 指标下
                // 「245 个分钟点」和「还没有记录」同屏自打嘴巴。
                Text(chartPoints.isEmpty ? String(localized: "暂无历史") : String(format: String(localized: "%@ 个分钟点"), String(describing: chartPoints.count)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if chartPoints.isEmpty {
                Text(String(localized: "进入每分钟重点排行后会在这里留下记录；缺失区间不会补零。"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .center)
            } else {
                Chart(chartPoints) { point in
                    // chartPoints 已经滤掉了 nil，这里用 if let 把这个不变量写进类型里，
                    // 而不是留一个 `?? 0` —— 那会让人以为图上真会出现补零的点。
                    if let value = historyValue(point) {
                        AreaMark(
                            x: .value(String(localized: "时间"), point.timestamp),
                            y: .value(metric.title, value)
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [chartColor.opacity(0.30), chartColor.opacity(0.02)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                        LineMark(
                            x: .value(String(localized: "时间"), point.timestamp),
                            y: .value(metric.title, value)
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(chartColor)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    }
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 62)
                .accessibilityLabel(String(format: String(localized: "%@七天趋势，共 %@ 个数据点"), String(describing: metric.title), String(describing: chartPoints.count)))
            }
        }
    }

    private var chartPoints: [ProcessHistoryPoint] {
        points.filter { historyValue($0) != nil }
    }

    private func historyValue(_ point: ProcessHistoryPoint) -> Double? {
        switch metric {
        case .cpu: point.cpuAveragePercent
        case .memory: point.physicalFootprintAverageBytes.map(Double.init)
        // 历史库里还没有 GPU 列。与其补零画一条假的平线，不如让图表留空——
        // 等新数据攒够了自然会有。
        case .gpu: nil
        case .disk:
            optionalSum(point.diskReadBytesPerSecond, point.diskWriteBytesPerSecond)
        case .energy: point.energyNanojoulesPerSecond
        }
    }

    private var chartColor: Color {
        // 一律墨色:按指标配色是把颜色当分类标签用,规范铁律 2 禁止。
        MacPulseTheme.ink
    }
}

private struct ProcessIcon: View {
    let group: ProcessGroupSnapshot
    let size: CGFloat

    var body: some View {
        Group {
            if let image = icon {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: fallbackSymbol)
                    .font(.system(size: size * 0.48, weight: .semibold))
                    .foregroundStyle(fallbackColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(fallbackColor.opacity(0.12))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        .accessibilityHidden(true)
    }

    private var icon: NSImage? {
        if group.isMacPulse,
           let url = NSWorkspace.shared.urlForApplication(
               withBundleIdentifier: ProcessAggregation.macPulseIdentifier
           ) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        if let path = group.executablePath {
            return NSWorkspace.shared.icon(forFile: path)
        }
        return nil
    }

    private var fallbackSymbol: String {
        switch group.category {
        case .application: "app.fill"
        case .background: "gearshape.2.fill"
        case .system: "apple.logo"
        }
    }

    private var fallbackColor: Color {
        switch group.category {
        case .application: MacPulseTheme.plugged
        case .background: MacPulseTheme.violet
        case .system: .secondary
        }
    }
}

private func processCPU(_ value: Double?) -> String {
    guard let value, value.isFinite else { return String(localized: "不可用") }
    if value >= 100 {
        return String(format: "%.0f%%", value)
    }
    return String(format: "%.1f%%", value)
}

private func optionalSum(_ lhs: Double?, _ rhs: Double?) -> Double? {
    if lhs == nil, rhs == nil { return nil }
    return (lhs ?? 0) + (rhs ?? 0)
}
