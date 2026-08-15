import AppKit
import Charts
import MacPulseCore
import SwiftUI
import UserNotifications

/// 总览页可编辑卡片。hero(身份)与警示条(安全)固定,其余用户自选。
/// rawValue 是存储标识(英文,进 AppStorage),显示名走本地化。
enum OverviewCard: String, CaseIterable, Identifiable {
    case bottleneck
    case powerVerdict
    case consumers
    case metricsGrid
    case liveChart
    case aiBalance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bottleneck: String(localized: "「为什么卡」诊断")
        case .powerVerdict: String(localized: "充电结论")
        case .consumers: String(localized: "谁在耗电")
        case .metricsGrid: String(localized: "芯片热点与功耗")
        case .liveChart: String(localized: "实时能量")
        case .aiBalance: String(localized: "AI 余额")
        }
    }

    /// 读当前布局:顺序 + 启用状态。新版本加的卡自动补在末尾(默认启用),
    /// 老用户升级不丢新功能。
    static func currentLayout() -> [(card: OverviewCard, enabled: Bool)] {
        let defaults = UserDefaults.standard
        let storedOrder = (defaults.string(forKey: "overviewCardOrder") ?? "")
            .split(separator: ",").compactMap { OverviewCard(rawValue: String($0)) }
        let hidden = Set((defaults.string(forKey: "overviewHiddenCards") ?? "")
            .split(separator: ",").map(String.init))
        // 去重:外部写坏(defaults write / 迁移损坏)会让同一张卡出现两次,
        // 造成 SwiftUI 重复 ID(未定义行为)且按 index 的排序操作错位。
        var order: [OverviewCard] = []
        for card in storedOrder where !order.contains(card) {
            order.append(card)
        }
        for card in OverviewCard.allCases where !order.contains(card) {
            order.append(card)
        }
        return order.map { ($0, !hidden.contains($0.rawValue)) }
    }

    static func save(layout: [(card: OverviewCard, enabled: Bool)]) {
        let defaults = UserDefaults.standard
        defaults.set(layout.map(\.card.rawValue).joined(separator: ","), forKey: "overviewCardOrder")
        defaults.set(
            layout.filter { !$0.enabled }.map(\.card.rawValue).joined(separator: ","),
            forKey: "overviewHiddenCards"
        )
    }
}

struct OverviewView: View {
    @EnvironmentObject private var model: DashboardModel

    private var snapshot: MetricSnapshot { model.current }
    private var statusColor: Color { MacPulseTheme.statusColor(for: snapshot) }

    // 总览一屏答三件事:现在健康吗(英雄卡+警示条)、谁在耗电(进程 top3)、
    // 电源怎么样(插电时给充电结论)。CPU/内存宫格删了——那是性能页数字的
    // 复读,首屏每一格都该给出性能页给不了的「结论」。
    /// 让视图跟着设置页的布局改动即时刷新(AppStorage 变化触发重渲染)。
    @AppStorage("overviewCardOrder") private var overviewCardOrder = ""
    @AppStorage("overviewHiddenCards") private var overviewHiddenCards = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                hero
                // 警示条不进可编辑清单:硬件报警不许被用户关掉后错过。
                if let attention = attentionLine {
                    attentionCard(attention)
                }
                ForEach(OverviewCard.currentLayout().filter(\.enabled).map(\.card)) { card in
                    overviewCardView(card)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .overlay {
            if model.isLoading {
                ProgressView(String(localized: "正在读取传感器…"))
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            }
        }
    }

    @ViewBuilder
    private func overviewCardView(_ card: OverviewCard) -> some View {
        switch card {
        case .bottleneck:
            bottleneckCard
        case .powerVerdict:
            if snapshot.battery.powerSource == .external, let diagnosis = model.chargeLinkDiagnosis {
                powerVerdictCard(diagnosis)
            }
        case .consumers:
            consumersCard
        case .metricsGrid:
            metricsGrid
        case .liveChart:
            liveChart
        case .aiBalance:
            aiBalanceCard
        }
    }

    private var metricsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            MetricCard(
                title: String(localized: "芯片热点"),
                value: MetricFormat.temperature(snapshot.deep.hotspotTemperature),
                detail: snapshot.deep.thermalLevel.title,
                symbol: "thermometer.medium",
                tint: temperatureColor,
                progress: snapshot.deep.hotspotTemperature.map { $0 / 100 }
            )
            MetricCard(
                title: String(localized: "SoC 总功耗"),
                value: MetricFormat.watts(snapshot.deep.systemPowerWatts),
                // 有读数就别说「等待」:采集器状态标志在重启后有几秒滞后,
                // 以数据本身为准。
                detail: snapshot.deep.systemPowerWatts != nil ? String(localized: "SMC 实时读数") : String(localized: "等待采集器"),
                symbol: "bolt.horizontal.fill",
                tint: MacPulseTheme.plugged
            )
        }
    }

    /// AI 余额:已配置服务商的余额 + Claude Code 本地用量(零配置)。
    /// 什么都没有时显示一行引导,不摆空卡。
    @ViewBuilder
    private var aiBalanceCard: some View {
        if model.aiBalances.isEmpty, model.aiBalanceErrors.isEmpty, model.claudeCodeUsage == nil {
            // 体验走查(R2)裁定:没配 key 也没本地用量的用户,常驻一行
            // 引导就是占屏噪音——空态直接消失,发现入口在设置页与主页
            // 卡片清单(那里的「AI 余额」开关自带说明)。
            EmptyView()
        } else {
            LiquidCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        SectionHeader(
                            title: String(localized: "AI 余额"),
                            subtitle: model.aiBalanceRefreshedAt.map { aiRefreshedText($0) }
                        )
                        Spacer(minLength: 0)
                        Button {
                            model.refreshAIBalances(force: true)
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                    }
                    ForEach(model.aiBalances) { reading in
                        VStack(alignment: .leading, spacing: 2) {
                            ValueRow(
                                title: reading.provider.displayName,
                                value: reading.primary,
                                symbol: "creditcard",
                                tint: MacPulseTheme.ink
                            )
                            if let detail = reading.detail {
                                Text(detail)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .padding(.leading, 28)
                            }
                        }
                    }
                    ForEach(Array(model.aiBalanceErrors.keys.sorted { $0.rawValue < $1.rawValue }), id: \.self) { provider in
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(MacPulseTheme.warm)
                            Text("\(provider.displayName):\(model.aiBalanceErrors[provider] ?? "")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let usage = model.claudeCodeUsage {
                        if !model.aiBalances.isEmpty || !model.aiBalanceErrors.isEmpty {
                            Divider()
                        }
                        ValueRow(
                            title: String(localized: "Claude Code 今日"),
                            value: String(
                                format: String(localized: "入 %@ · 出 %@"),
                                tokenText(usage.inputTokens + usage.cacheReadTokens + usage.cacheCreationTokens),
                                tokenText(usage.outputTokens)
                            ),
                            symbol: "terminal",
                            tint: MacPulseTheme.ink
                        )
                        Text(String(
                            format: String(localized: "%@ 个会话 · 本地日志统计(含缓存读写),零网络"),
                            String(describing: usage.sessionCount)
                        ))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 28)
                    }
                    Text(String(localized: "余额请求只发往各服务商官方接口,key 存在系统钥匙串,不进任何报告。"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func aiRefreshedText(_ date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        if seconds < 90 { return String(localized: "刚刚更新") }
        return String(format: String(localized: "%@ 分钟前更新"), String(describing: Int(seconds / 60)))
    }

    private func tokenText(_ count: Int) -> String { AITokenFormat.text(count) }

    /// 只在真有事时出现的警示行;一切正常时这张卡不存在,首屏保持安静。
    private var attentionLine: (text: String, symbol: String)? {
        // 数字统一四舍五入:截断会造出「警示条 79% / 英雄卡 80%」同屏打架。
        // 热点阈值 90°C 与卡片量表的变红线对齐,不留「量表红了却没警示」的空档。
        if let hotspot = snapshot.deep.hotspotTemperature, hotspot >= 90 {
            return (String(format: String(localized: "芯片热点 %@°C,已接近降频线"), String(describing: Int(hotspot.rounded()))), "thermometer.high")
        }
        if snapshot.deep.thermalLevel == .serious || snapshot.deep.thermalLevel == .critical {
            return (String(format: String(localized: "系统热压力:%@"), String(describing: snapshot.deep.thermalLevel.title)), "exclamationmark.thermometer")
        }
        if let health = snapshot.battery.healthPercent, health.rounded() < 80 {
            return (String(format: String(localized: "电池健康度 %@%%,建议预约检修"), String(describing: Int(health.rounded()))), "battery.25percent")
        }
        return nil
    }

    /// 「为什么卡」入口与结果。idle 一行高不喧宾;取样中纯文本计数
    /// (不做动画——监控 App 不许自己费电);结果内嵌展开,小白看
    /// summary 一句话,高手逐条展开 findings 的证据。
    @ViewBuilder
    private var bottleneckCard: some View {
        switch model.bottleneckProbe {
        case .idle:
            bottleneckEntryRow
        case .sampling(let collected, let required):
            LiquidCard(padding: 12) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(String(
                        format: String(localized: "正在专注取样… %@/%@"),
                        String(describing: collected), String(describing: required)
                    ))
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
        case .done(_, let at) where Date().timeIntervalSince(at) > 600:
            // 结论是那一瞬间的快照,不该永远霸占首屏(用户原话:「这个怎么
            // 一直在」)。10 分钟后自动收回入口态;lastBottleneck 仍在,
            // 体检报告的 60 分钟窗口不受影响。视图每 2 秒随模型刷新,
            // 到点自然切换,无需定时器。
            bottleneckEntryRow
        case .done(let diagnosis, let at):
            LiquidCard {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: diagnosis.isWarning
                            ? "exclamationmark.triangle.fill"
                            : "checkmark.circle.fill")
                            .foregroundStyle(diagnosis.isWarning ? MacPulseTheme.warm : MacPulseTheme.normal)
                        Text(diagnosis.summary)
                            .font(.callout.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    if !diagnosis.detail.isEmpty {
                        Text(diagnosis.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if diagnosis.findings.count == 1, diagnosis.findings[0].kind == diagnosis.kind {
                        // 唯一发现就是头条本身:直接铺证据,不再折叠一行重复的标题。
                        bottleneckEvidenceBlock(diagnosis.findings[0])
                    } else {
                        ForEach(Array(diagnosis.findings.enumerated()), id: \.offset) { _, finding in
                            bottleneckFindingRow(finding)
                        }
                    }
                    HStack {
                        Text(String(format: String(localized: "诊断于 %@"), relativeTime(at)))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Spacer(minLength: 0)
                        Button(String(localized: "收起")) {
                            model.dismissBottleneckResult()
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        Button(String(localized: "重新诊断")) {
                            model.startBottleneckProbe()
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                }
            }
        }
    }

    /// 入口态一行卡。idle 与「结果过期自动收起」共用。
    private var bottleneckEntryRow: some View {
        Button {
            model.startBottleneckProbe()
        } label: {
            LiquidCard(padding: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(MacPulseTheme.ink)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(String(localized: "为什么卡?"))
                            .font(.callout.weight(.semibold))
                        Text(String(localized: "点一下,约 8 秒定位瓶颈"))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func bottleneckEvidenceBlock(_ finding: BottleneckDiagnosis.Finding) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(finding.evidence, id: \.self) { line in
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button {
                model.requestNavigation(
                    section: bottleneckTarget(finding.subsystem).section,
                    pane: bottleneckTarget(finding.subsystem).pane
                )
            } label: {
                Label(String(localized: "去对应页查看"), systemImage: "arrow.right")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
        }
    }

    private func bottleneckFindingRow(_ finding: BottleneckDiagnosis.Finding) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(finding.evidence, id: \.self) { line in
                    Text(line)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button {
                    model.requestNavigation(
                        section: bottleneckTarget(finding.subsystem).section,
                        pane: bottleneckTarget(finding.subsystem).pane
                    )
                } label: {
                    Label(String(localized: "去对应页查看"), systemImage: "arrow.right")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
            }
            .padding(.top, 2)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: bottleneckSymbol(finding.subsystem))
                    .font(.caption)
                    .foregroundStyle(finding.isWarning ? MacPulseTheme.warm : MacPulseTheme.ink)
                    .frame(width: 16)
                Text(finding.summary)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.caption)
    }

    private func bottleneckSymbol(_ subsystem: BottleneckDiagnosis.Subsystem) -> String {
        switch subsystem {
        case .cpu: "cpu"
        case .gpu: "video"
        case .memory: "memorychip"
        case .disk: "internaldrive"
        case .thermal: "thermometer.medium"
        case .power: "battery.25percent"
        }
    }

    private func bottleneckTarget(_ subsystem: BottleneckDiagnosis.Subsystem) -> (section: AppSection, pane: PerformancePane?) {
        switch subsystem {
        case .cpu: (.performance, .processes)
        case .gpu: (.performance, .soc)
        case .memory: (.performance, .memory)
        case .disk: (.performance, .disk)
        case .thermal: (.performance, .thermal)
        case .power: (.battery, nil)
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        if seconds < 90 { return String(localized: "刚刚") }
        if seconds < 3_600 { return String(format: String(localized: "%@ 分钟前"), String(describing: Int(seconds / 60))) }
        return String(format: String(localized: "%@ 小时前"), String(describing: Int(seconds / 3_600)))
    }

    private func attentionCard(_ line: (text: String, symbol: String)) -> some View {
        LiquidCard(padding: 12) {
            HStack(spacing: 8) {
                Image(systemName: line.symbol)
                    .foregroundStyle(MacPulseTheme.warm)
                Text(line.text)
                    .font(.callout.weight(.semibold))
                Spacer(minLength: 0)
            }
        }
    }

    /// 充电结论:电池页「充电链路」卡的一句话版。细节去电池页看。
    private func powerVerdictCard(_ diagnosis: ChargeLinkDiagnosis) -> some View {
        LiquidCard(padding: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: diagnosis.isWarning
                    ? "exclamationmark.triangle.fill"
                    : "checkmark.circle.fill")
                    .foregroundStyle(diagnosis.isWarning ? MacPulseTheme.warm : MacPulseTheme.normal)
                VStack(alignment: .leading, spacing: 2) {
                    Text(diagnosis.summary)
                        .font(.callout.weight(.semibold))
                    Text(String(localized: "详情在「电池」页的充电链路卡"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// 谁在耗电:能耗前三的进程组 + 三项负载脚注。
    /// 这是首屏最值钱的一张卡——数字后面第一次有了名字。
    private var consumersCard: some View {
        LiquidCard {
            VStack(spacing: 10) {
                SectionHeader(title: String(localized: "谁在耗电"))
                let top = topConsumers
                if top.isEmpty {
                    Text(String(localized: "进程采样准备中…"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(top) { group in
                        ValueRow(
                            title: group.displayName,
                            value: normalizedCPUText(group),
                            symbol: "app.badge",
                            tint: MacPulseTheme.violet
                        )
                    }
                    // 前三名远小于总负载时,差额不是 bug 是长尾:
                    // 点破它,免得「总 19% 但列表只有 2%」看着像坏了。
                    if let residual = consumerResidualPercent {
                        Text(String(format: String(localized: "其余约 %@%% 由大量小进程与系统服务分摊"), String(describing: residual)))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Divider()
                HStack {
                    consumerFooter(String(localized: "CPU 总负载"), MetricFormat.percent(snapshot.deep.cpuUsagePercent))
                    Divider().frame(height: 24)
                    consumerFooter(String(localized: "内存已用"), memoryPercentText)
                    Divider().frame(height: 24)
                    consumerFooter(String(localized: "整机功耗"), model.wholeMachineWattsText)
                }
            }
        }
    }

    /// 采样层已按综合负载排好序(与进程页同一榜),这里不再自创排序——
    /// 旧版把能耗(纳焦级)和 CPU%(0-100)混在一个排序键里,顺序看着是乱的。
    /// MacPulse 自己不进榜:进程页有专门的自身负担卡。
    private var topConsumers: [ProcessGroupSnapshot] {
        // 门槛与显示同一把尺(归一化后 ≥0.05%),否则会出现「0.0%」占行。
        model.processGroups
            .filter { !$0.isMacPulse && (normalizedGroupPercent($0) ?? 0) >= 0.05 }
            .prefix(3)
            .map { $0 }
    }

    /// 进程 CPU 是「单核=100%」制,页脚总负载是「全机=100%」制——
    /// 必须除以核数换算成同一把尺,否则重活时进程行 380% 配总负载 42%,
    /// 且差额相减直接变负数。
    private func normalizedGroupPercent(_ group: ProcessGroupSnapshot) -> Double? {
        guard let raw = group.smoothedCPUPercent ?? group.cpuPercent else { return nil }
        return raw / Double(max(1, ProcessInfo.processInfo.activeProcessorCount))
    }

    private func normalizedCPUText(_ group: ProcessGroupSnapshot) -> String {
        guard let value = normalizedGroupPercent(group) else { return String(localized: "不可用") }
        // 10% 以下保留一位小数,不然满屏「0%」像全都没在干活。
        return value < 10 ? String(format: "%.1f%%", value) : String(format: "%.0f%%", value)
    }

    /// CPU 总负载减去榜上前三的占比(同尺换算后)。差额 ≥5% 才值得点破。
    private var consumerResidualPercent: Int? {
        guard let total = snapshot.deep.cpuUsagePercent else { return nil }
        let covered = topConsumers.compactMap(normalizedGroupPercent).reduce(0, +)
        let residual = total - covered
        guard residual >= 5 else { return nil }
        return Int(residual.rounded())
    }

    private func consumerFooter(_ title: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }

    private var hero: some View {
        LiquidCard {
            VStack(spacing: 14) {
                HStack(spacing: 18) {
                    BatteryRing(
                        percentage: snapshot.battery.hasReadableBattery ? snapshot.battery.percentage : nil,
                        color: statusColor,
                        isCharging: snapshot.battery.state == .charging
                    )

                    VStack(alignment: .leading, spacing: 8) {
                        StatusPill(
                            text: snapshot.battery.state.title,
                            symbol: snapshot.battery.state.symbol,
                            color: statusColor
                        )

                        Text(MetricFormat.watts(snapshot.battery.netPowerWatts, signed: true))
                            .font(.system(size: 27, weight: .semibold))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .accessibilityLabel(String(format: String(localized: "电池净功率 %@"), String(describing: MetricFormat.watts(snapshot.battery.netPowerWatts, signed: true))))

                        VStack(alignment: .leading, spacing: 1) {
                            Text(heroRuntimeText)
                                .font(.callout.weight(.semibold))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                            Text(MetricFormat.runtimeBasis(model.runtimeEstimate))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }

                Divider().opacity(0.55)

                HStack {
                    heroFooter(
                        String(localized: "适配器"),
                        MetricFormat.watts(snapshot.battery.adapterRatedWatts),
                        "powerplug"
                    )
                    Divider().frame(height: 28)
                    heroFooter(
                        String(localized: "电池温度"),
                        MetricFormat.temperature(snapshot.battery.temperatureCelsius),
                        "thermometer.low"
                    )
                    Divider().frame(height: 28)
                    heroFooter(
                        String(localized: "健康度"),
                        MetricFormat.percent(snapshot.battery.healthPercent),
                        "heart.text.square"
                    )
                }
            }
        }
    }

    private func heroFooter(_ title: String, _ value: String, _ symbol: String) -> some View {
        VStack(spacing: 3) {
            Label(title, systemImage: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }

    private var liveChart: some View {
        LiquidCard(padding: 13) {
            VStack(spacing: 8) {
                SectionHeader(title: String(localized: "实时能量"), subtitle: String(localized: "最近几分钟"))
                if model.liveHistory.count < 3 {
                    // 刚启动只有一两个点,画出来是条秃线。如实说明,几秒即好。
                    Text(String(localized: "正在积累数据,几个采样点后出图…"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(height: 48)
                } else if recentPeakPowerWatts < 0.3 {
                    // 满电插电静置时净功率恒为 0,曲线是一条贴底的死线,
                    // 画出来像坏了。如实说明这个状态,比硬画一条线诚实。
                    // 文案按供电来源分:全 nil 的窗口在电池上也会落到这里,
                    // 不能断言「电源直供」。
                    Text(snapshot.battery.powerSource == .external
                        ? String(localized: "电源直供,电池几乎零净流量")
                        : String(localized: "电池净流量数据不足"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(height: 48)
                } else {
                    liveChartBody
                }
            }
        }
    }

    private var liveChartBody: some View {
        Chart {
                    ForEach(Array(model.liveHistory.suffix(60))) { point in
                        if let power = point.batteryPowerWatts {
                            // 带符号绘制:零线以上是充入、以下是放出。
                            // 旧版取绝对值,充电和放电画出来一模一样,方向全丢。
                            LineMark(
                                x: .value(String(localized: "时间"), point.timestamp),
                                y: .value(String(localized: "功率"), power)
                            )
                            .interpolationMethod(.catmullRom)
                            .foregroundStyle(power >= 0 ? MacPulseTheme.normal : MacPulseTheme.ink)
                            .lineStyle(.init(lineWidth: 2.2, lineCap: .round))

                            AreaMark(
                                x: .value(String(localized: "时间"), point.timestamp),
                                y: .value(String(localized: "功率"), power)
                            )
                            .interpolationMethod(.catmullRom)
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [
                                        (power >= 0 ? MacPulseTheme.normal : MacPulseTheme.ink).opacity(0.22),
                                        .clear
                                    ],
                                    startPoint: power >= 0 ? .top : .bottom,
                                    endPoint: power >= 0 ? .bottom : .top
                                )
                            )
                        }
                    }
                    RuleMark(y: .value(String(localized: "零"), 0))
                        .foregroundStyle(.secondary.opacity(0.3))
                        .lineStyle(.init(lineWidth: 0.5, dash: [3, 3]))
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                // 纵轴锁个下限:微瓦级噪声不放大成惊涛骇浪。
                .chartYScale(domain: -max(recentPeakPowerWatts * 1.25, 1)...max(recentPeakPowerWatts * 1.25, 1))
                .frame(height: 48)
                .accessibilityLabel(String(localized: "实时电池功率曲线"))
    }

    private var recentPeakPowerWatts: Double {
        model.liveHistory.suffix(60)
            .compactMap { $0.batteryPowerWatts.map(abs) }
            .max() ?? 0
    }

    /// 充电挂起时不给倒计时。
    ///
    /// 接电 + 未充电 + 净功率接近零 + 电量 75–85%，几乎可以断定是系统的
    /// 「优化电池充电」在 80% 挂起。在那里显示一个倒计时正是要根除的假数字。
    private var heroRuntimeText: String {
        let battery = snapshot.battery
        if battery.state == .pluggedNotCharging,
           (75...85).contains(battery.percentage),
           abs(battery.netPowerWatts ?? 0) < 0.6 {
            return String(format: String(localized: "已优化充电，暂停在 %@%%"), String(describing: Int(battery.percentage)))
        }
        if battery.state == .full { return String(localized: "电池已充满") }
        let value = MetricFormat.runtime(model.runtimeEstimate)
        return battery.state == .charging ? String(format: String(localized: "预计 %@ 充满"), String(describing: value)) : String(format: String(localized: "预计可用 %@"), String(describing: value))
    }

    private var temperatureColor: Color {
        guard let value = snapshot.deep.hotspotTemperature else { return .secondary }
        if value >= 90 { return MacPulseTheme.critical }
        if value >= 75 { return MacPulseTheme.warm }
        return MacPulseTheme.normal
    }

    private var memoryProgress: Double? {
        model.memory?.usedFraction
    }

    private var memoryPercentText: String {
        guard let memoryProgress else { return String(localized: "不可用") }
        return String(format: "%.0f%%", memoryProgress * 100)
    }
}

struct BatteryView: View {
    @EnvironmentObject private var model: DashboardModel
    private var battery: BatteryMetrics { model.current.battery }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                LiquidCard {
                    HStack(spacing: 18) {
                        BatteryRing(
                            percentage: battery.hasReadableBattery ? battery.percentage : nil,
                            color: MacPulseTheme.statusColor(for: model.current),
                            isCharging: battery.state == .charging
                        )
                        VStack(alignment: .leading, spacing: 7) {
                            Text(String(localized: "电池状态"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(battery.state.title)
                                .font(.title3.weight(.bold))
                            Text(battery.cycleCount.map { String(format: String(localized: "循环 %@ 次"), String(describing: $0)) } ?? String(localized: "循环次数不可用"))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }

                LiquidCard {
                    VStack(spacing: 12) {
                        SectionHeader(title: String(localized: "充电与供电"))
                        ValueRow(title: String(localized: "当前供电来源"), value: powerSourceTitle, symbol: "cable.connector", tint: .blue)
                        ValueRow(title: String(localized: "电池净功率"), value: MetricFormat.watts(battery.netPowerWatts, signed: true), symbol: "bolt.fill", tint: .green)
                        // 只叫「额定」:这个键读的是铭牌值,从来不是协商结果——
                        // 协商在下面充电链路卡里,标混了等于三个瓦数三种口径。
                        // 读不到时用充电链路的充电器上限兜底,不轻易「不可用」。
                        ValueRow(
                            title: String(localized: "适配器额定功率"),
                            value: battery.adapterRatedWatts.map { "\(Int($0.rounded()))W" }
                                ?? model.chargeLink?.chargerMaxWatts.map { String(format: String(localized: "%@W(PD 广告)"), String(describing: $0)) }
                                ?? String(localized: "不可用"),
                            symbol: "powerplug.fill",
                            tint: .blue
                        )
                        ValueRow(title: String(localized: "SoC 总功耗"), value: MetricFormat.watts(model.current.deep.systemPowerWatts), symbol: "cpu", tint: .purple)
                        ValueRow(title: String(localized: "整机功耗"), value: model.wholeMachineWattsText, symbol: "desktopcomputer", tint: .indigo)
                        ValueRow(title: String(localized: "实时电压"), value: battery.voltageVolts.map { String(format: "%.2f V", $0) } ?? String(localized: "不可用"), symbol: "waveform.path")
                        ValueRow(title: String(localized: "实时电流"), value: battery.currentAmps.map { String(format: "%+.2f A", $0) } ?? String(localized: "不可用"), symbol: "arrow.left.arrow.right")
                        ValueRow(title: String(localized: "预计时间"), value: MetricFormat.runtime(model.runtimeEstimate), symbol: "clock")
                    }
                }

                // 判定为 nil 就整卡不出现,兑现「读不到就不显示」的承诺——
                // 旧版会渲染一张没有结论行的无头卡。
                if let link = model.chargeLink, battery.powerSource == .external,
                   model.chargeLinkDiagnosis != nil {
                    chargeLinkCard(link)
                }

                if !model.peripheralBatteries.isEmpty {
                    peripheralBatteryCard
                }

                if let latest = model.sleepSessions.first(where: { $0.onBattery }) {
                    sleepCard(latest)
                }

                runtimeEstimateCard

                LiquidCard {
                    VStack(spacing: 12) {
                        SectionHeader(title: String(localized: "健康与容量"))
                        ValueRow(title: String(localized: "估算健康度"), value: MetricFormat.percent(battery.healthPercent), symbol: "heart.fill", tint: .pink)
                        ValueRow(title: String(localized: "电池温度"), value: MetricFormat.temperature(battery.temperatureCelsius), symbol: "thermometer.medium", tint: .orange)
                        ValueRow(title: String(localized: "当前容量"), value: capacity(battery.currentCapacityMAh), symbol: "battery.50percent")
                        ValueRow(title: String(localized: "最大容量"), value: capacity(battery.maxCapacityMAh), symbol: "battery.100percent")
                        ValueRow(title: String(localized: "设计容量"), value: capacity(battery.designCapacityMAh), symbol: "ruler")
                        // 主动点破两把尺子:mAh 是原始电量计刻度,和上面圆环的
                        // 显示百分比刻度不同,手算相除对不上是正常的。
                        Text(String(localized: "容量为原始电量计读数,与显示百分比是两套刻度,相除对不上环上的数字属正常。"))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .onAppear { model.batteryPageChanged(true) }
        .onDisappear { model.batteryPageChanged(false) }
    }

    private func capacity(_ value: Int?) -> String {
        value.map { "\($0) mAh" } ?? String(localized: "不可用")
    }

    /// 充电链路：充电器 → 线缆 → 协商结果，配一句话结论。
    /// 只在外接电源且采样有货时出现；读不到就整卡不显示，不编数据。
    @ViewBuilder
    private func chargeLinkCard(_ link: ChargeLinkSnapshot) -> some View {
        // 判定推导挪进了 model.chargeLinkDiagnosis:总览的「充电结论」卡
        // 与这里共用同一份,电池状态到判定布尔的映射规则只存在一处。
        let diagnosis = model.chargeLinkDiagnosis
        LiquidCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: String(localized: "充电链路"), subtitle: portLabel(link))

                if let diagnosis {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: diagnosis.isWarning
                            ? "exclamationmark.triangle.fill"
                            : "checkmark.circle.fill")
                            .foregroundStyle(diagnosis.isWarning ? MacPulseTheme.warm : MacPulseTheme.normal)
                        Text(diagnosis.summary)
                            .font(.callout.weight(.semibold))
                    }
                    Text(diagnosis.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider()
                }

                ValueRow(
                    title: String(localized: "充电器上限"),
                    value: link.chargerMaxWatts.map { String(format: String(localized: "%@W · %@ 档"), String(describing: $0), String(describing: link.chargerOptions.count)) } ?? String(localized: "不可用"),
                    symbol: "powerplug.fill",
                    tint: .blue
                )
                ValueRow(
                    title: String(localized: "线缆额定"),
                    value: cableRatingText(link),
                    symbol: "cable.connector",
                    tint: .teal
                )
                ValueRow(
                    title: String(localized: "实际协商"),
                    value: link.negotiated.map { "\($0.wattsLabel)（\($0.voltsAmpsLabel)）" } ?? String(localized: "协商中"),
                    symbol: "bolt.fill",
                    tint: .green
                )

                if let cable = link.cable {
                    Text(cableFootnote(cable))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func portLabel(_ link: ChargeLinkSnapshot) -> String {
        link.portTypeDescription == "USB-C"
            ? String(format: String(localized: "USB-C %@ 号口"), String(describing: link.portNumber))
            : link.portTypeDescription
    }

    private func cableRatingText(_ link: ChargeLinkSnapshot) -> String {
        if let cable = link.cable {
            return "\(cable.maxWatts)W · \(Int(cable.maxAmps))A"
        }
        // 没有 e-marker 应答：USB-C 上这是「无芯片线」这个事实（PD 按 3A 封顶）；
        // MagSafe 线不走 SOP' 应答，读不到是常态，不能当成线的属性来展示。
        return link.portTypeDescription == "USB-C" ? String(localized: "无身份芯片 · 按 3A 上限") : String(localized: "不适用（MagSafe）")
    }

    private func cableFootnote(_ cable: CableEmarkerInfo) -> String {
        var parts = [cable.typeLabel, cable.speedLabel, String(format: String(localized: "厂商 0x%04X"), cable.vendorID)]
        if cable.eprCapable { parts.append("EPR") }
        if cable.hasCertificationID { parts.append(String(localized: "USB-IF 认证")) }
        return parts.joined(separator: " · ")
    }

    /// 睡眠掉电诊断:合盖那几小时到底掉了多少电、被谁吵醒的。
    /// 只在有「电池上睡过」的记录时出现——接电睡眠的掉电数据没有意义。
    private func sleepCard(_ session: SleepSession) -> some View {
        let diagnosis = SleepDiagnosis.diagnose(session)
        let recent = model.sleepSessions.filter(\.onBattery).prefix(4)
        return LiquidCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(
                    title: String(localized: "睡眠掉电"),
                    subtitle: session.start.formatted(.dateTime.month().day().hour().minute())
                )
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: diagnosis.isWarning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(diagnosis.isWarning ? MacPulseTheme.warm : MacPulseTheme.normal)
                    Text(diagnosis.summary)
                        .font(.callout.weight(.semibold))
                    Spacer(minLength: 0)
                }
                Text(diagnosis.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if recent.count > 1 {
                    Divider()
                    ForEach(Array(recent)) { item in
                        ValueRow(
                            title: item.start.formatted(.dateTime.month().day().hour().minute()),
                            value: sleepRowValue(item),
                            symbol: "moon.zzz"
                        )
                    }
                    Text(String(localized: "数据来自系统电源日志,掉电量是入睡与醒来时的实测差值。"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func sleepRowValue(_ session: SleepSession) -> String {
        String(
            format: String(localized: "%.1fh 掉 %d%% · 唤醒 %d 次"),
            session.hours, max(0, session.droppedPercent), session.darkWakeCount
        )
    }

    /// 蓝牙外设电量。空列表整卡不出现;AirPods 分左/右/盒,普通外设只有主电量。
    private var peripheralBatteryCard: some View {
        LiquidCard {
            VStack(spacing: 12) {
                SectionHeader(title: String(localized: "外设电量"))
                ForEach(model.peripheralBatteries) { device in
                    ValueRow(
                        title: device.name,
                        value: peripheralValue(device),
                        symbol: peripheralSymbol(device.name),
                        tint: (device.worstPercent ?? 100) <= 20 ? MacPulseTheme.warm : .green
                    )
                }
            }
        }
    }

    private func peripheralValue(_ device: PeripheralBattery) -> String {
        var parts: [String] = []
        if let left = device.percentLeft { parts.append(String(format: String(localized: "左 %@%%"), String(describing: left))) }
        if let right = device.percentRight { parts.append(String(format: String(localized: "右 %@%%"), String(describing: right))) }
        if let box = device.percentCase { parts.append(String(format: String(localized: "盒 %@%%"), String(describing: box))) }
        if parts.isEmpty, let main = device.percentMain { parts.append("\(main)%") }
        return parts.isEmpty ? String(localized: "不可用") : parts.joined(separator: " · ")
    }

    private func peripheralSymbol(_ name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("airpods") { return "airpods" }
        if lower.contains("keyboard") || name.contains(String(localized: "键盘")) { return "keyboard" }
        if lower.contains("trackpad") || name.contains(String(localized: "妙控板")) { return "rectangle.and.hand.point.up.left" }
        if lower.contains("mouse") || name.contains(String(localized: "鼠标")) { return "computermouse" }
        return "antenna.radiowaves.left.and.right"
    }

    /// 三个来源并排显示，并在系统值明显偏离时把它点名。
    ///
    /// 把「系统给的是 20 小时 0 分——那是上限值，不是测量值」直接写在界面上，
    /// 是这一整块工作里最重要的一行文案：它不回避那个假数字，而是指名道姓。
    /// 充电时估算器算的是「充满还要多久」,卡片必须跟着改口——
    /// 旧版插电时标题仍是「续航估算」、行名仍是「按你的日常习惯」,
    /// 用户把 52 分钟充满时间当成 52 分钟续航,整卡挂羊头(审计高危)。
    private var isChargingEstimate: Bool { battery.state == .charging }

    private func estimateRowTitle(_ basis: RuntimeBasis) -> String {
        guard isChargingEstimate else { return basis.title }
        switch basis {
        case .instant: return String(localized: "按当前充电速率")
        case .learned: return String(localized: "按你的充电分段")
        case .gauge: return String(localized: "系统电量计")
        case .blended: return basis.title
        }
    }

    @ViewBuilder
    private var runtimeEstimateCard: some View {
        let estimate = model.runtimeEstimate
        LiquidCard {
            VStack(alignment: .leading, spacing: 10) {
                // 空卡不再打肿脸:没有任何候选时,置信度副题(会显示
                // 「负载波动较大,给出区间」却给不出区间)一并压掉,换一句实话。
                SectionHeader(
                    title: isChargingEstimate ? String(localized: "充满估算") : String(localized: "续航估算"),
                    subtitle: estimate.candidates.isEmpty ? nil : estimate.confidence.title
                )

                if estimate.candidates.isEmpty {
                    Text(battery.state == .full
                        ? String(localized: "电池已满,无需估算")
                        : String(localized: "正在积累实测数据,稍后给出估算"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                ForEach(RuntimeBasis.allCases.filter { $0 != .blended }, id: \.self) { basis in
                    if let minutes = estimate.candidates[basis] {
                        ValueRow(
                            title: estimateRowTitle(basis),
                            value: MetricFormat.duration(minutes),
                            symbol: basisSymbol(basis)
                        )
                    }
                }

                if !estimate.candidates.isEmpty {
                    Divider()
                    ValueRow(
                        title: isChargingEstimate ? String(localized: "综合充满估算") : String(localized: "综合估算"),
                        value: MetricFormat.runtime(estimate),
                        symbol: "sparkles",
                        tint: MacPulseTheme.normal
                    )
                }

                // 让估算器自己报账。这是「不专业」那条抱怨最直接的回应：
                // 不是声称准，是把过去预测和实际的差距摆出来。
                Text(model.estimateAccuracy.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if estimate.rejectedSystemEstimate, let system = estimate.systemEstimateMinutes {
                    Text(String(format: String(localized: "系统给的是 %@——那是 powerd 的上限值，不是测量值，已排除。"), String(describing: MetricFormat.duration(system))))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !isChargingEstimate, let brightness = model.backlight?.brightnessFraction {
                    Text(String(format: String(localized: "当前亮度 %@%%。耗电估算按你在这个亮度和负载下的实测用电学习，不是按标称值推算。"), String(describing: Int(brightness * 100))))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func basisSymbol(_ basis: RuntimeBasis) -> String {
        switch basis {
        case .instant: "speedometer"
        case .learned: "person.crop.circle.badge.clock"
        case .gauge: "cpu"
        case .blended: "sparkles"
        }
    }

    private var powerSourceTitle: String {
        switch battery.powerSource {
        case .battery: String(localized: "电池")
        case .external: String(localized: "外接电源")
        case .ups: "UPS"
        case .unknown: battery.adapterAttached == true ? String(localized: "检测到适配器") : String(localized: "不可用")
        }
    }
}

struct PowerRailRow: View {
    let name: String
    let watts: Double?
    let color: Color
    let maxWatts: Double
    /// 读数缺失时给出的说明，例如「本机型不提供」。默认沿用 `MetricFormat` 的「不可用」。
    var unavailableNote: String?

    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Text(name)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(watts == nil ? (unavailableNote ?? MetricFormat.watts(nil)) : MetricFormat.watts(watts))
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(watts == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.07))
                    if let watts {
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [color.opacity(0.55), color],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: proxy.size.width * min(max(watts / maxWatts, 0), 1))
                    } else {
                        // 没有读数时画空的虚线轨，而不是一条 0 宽度的实心条。
                        // 实心条会被读成「已测量，值为 0」——那正是要根除的假象。
                        Capsule()
                            .strokeBorder(
                                .primary.opacity(0.16),
                                style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                            )
                    }
                }
            }
            .frame(height: 6)
        }
    }
}

private enum HistoryMetric: String, CaseIterable, Identifiable {
    case power = "功率"
    case temperature = "温度"
    case battery = "电量"
    var id: String { rawValue }
}

private enum HistoryRange: String, CaseIterable, Identifiable {
    case day = "24 小时"
    case week = "7 天"
    var id: String { rawValue }
}

struct HistoryView: View {
    @EnvironmentObject private var model: DashboardModel
    @State private var metric: HistoryMetric = .power
    @State private var range: HistoryRange = .day
    @State private var selectedDate: Date?

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                HStack {
                    Picker(String(localized: "指标"), selection: $metric) {
                        ForEach(HistoryMetric.allCases) { Text(L($0.rawValue)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker(String(localized: "范围"), selection: $range) {
                        ForEach(HistoryRange.allCases) { Text(L($0.rawValue)).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 96)
                }

                LiquidCard {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: String(format: String(localized: "%@趋势"), L(metric.rawValue)), subtitle: L(range.rawValue))

                        if filteredPoints.count < 2 {
                            // 一个点画不成线,和零个点同样按空态处理。
                            ContentUnavailableView(
                                String(localized: "这个指标还没有足够的历史数据"),
                                systemImage: "chart.xyaxis.line",
                                description: Text(String(localized: "MacPulse 每分钟保存一个聚合点"))
                            )
                            .frame(height: 210)
                        } else {
                            Chart {
                                ForEach(filteredPoints) { point in
                                    if let reading = value(point) {
                                        AreaMark(
                                            x: .value(String(localized: "时间"), point.timestamp),
                                            y: .value(metric.rawValue, reading)
                                        )
                                        .interpolationMethod(.catmullRom)
                                        .foregroundStyle(
                                            LinearGradient(
                                                colors: [chartColor.opacity(0.32), chartColor.opacity(0.02)],
                                                startPoint: .top,
                                                endPoint: .bottom
                                            )
                                        )
                                        LineMark(
                                            x: .value(String(localized: "时间"), point.timestamp),
                                            y: .value(metric.rawValue, reading)
                                        )
                                        .interpolationMethod(.catmullRom)
                                        .foregroundStyle(chartColor)
                                        .lineStyle(.init(lineWidth: 2.3, lineCap: .round))
                                    }
                                }

                                if let selectedPoint, let reading = value(selectedPoint) {
                                    RuleMark(x: .value(String(localized: "选择时间"), selectedPoint.timestamp))
                                        .foregroundStyle(.secondary.opacity(0.45))
                                    PointMark(
                                        x: .value(String(localized: "选择时间"), selectedPoint.timestamp),
                                        y: .value(metric.rawValue, reading)
                                    )
                                    .symbolSize(55)
                                    .foregroundStyle(chartColor)
                                }
                            }
                            // 横轴锁定到所选范围:数据少时不再收缩成十分钟
                            // 却顶着「24 小时」的标题,轴标签也不会四个全是同一小时。
                            .chartXScale(domain: rangeCutoff...Date())
                            .chartXAxis {
                                AxisMarks(values: .automatic(desiredCount: 4)) {
                                    AxisGridLine().foregroundStyle(.secondary.opacity(0.12))
                                    AxisValueLabel(format: range == .day ? .dateTime.hour() : .dateTime.weekday(.abbreviated))
                                }
                            }
                            .chartYAxis {
                                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) {
                                    AxisGridLine().foregroundStyle(.secondary.opacity(0.12))
                                    AxisValueLabel()
                                }
                            }
                            .frame(height: 220)
                            .chartOverlay { proxy in
                                GeometryReader { geometry in
                                    Rectangle()
                                        .fill(.clear)
                                        .contentShape(Rectangle())
                                        .onContinuousHover { phase in
                                            switch phase {
                                            case .active(let location):
                                                guard let plotFrame = proxy.plotFrame else { return }
                                                let frame = geometry[plotFrame]
                                                let x = location.x - frame.origin.x
                                                selectedDate = proxy.value(atX: x, as: Date.self)
                                            case .ended:
                                                selectedDate = nil
                                            }
                                        }
                                }
                            }

                            if let selectedPoint, let reading = value(selectedPoint) {
                                HStack {
                                    Text(selectedPoint.timestamp, format: .dateTime.month().day().hour().minute())
                                    // 口径后缀:图上每个点是分钟聚合均值,不是瞬时读数。
                                    // 不点破,读者会拿它跟首页的实时数字对不上而怀疑数据。
                                    Text(String(localized: "分钟均值"))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                    Spacer()
                                    Text(formatHistoryValue(reading))
                                        .fontWeight(.semibold)
                                        .monospacedDigit()
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                }

                summary
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    private var summary: some View {
        LiquidCard {
            let values = filteredPoints.compactMap(value).filter(\.isFinite)
            return HStack {
                summaryValue(String(localized: "平均"), values.isEmpty ? nil : values.reduce(0, +) / Double(values.count))
                Divider().frame(height: 32)
                summaryValue(String(localized: "最低"), values.min())
                Divider().frame(height: 32)
                summaryValue(String(localized: "最高"), values.max())
            }
        }
    }

    private func summaryValue(_ title: String, _ value: Double?) -> some View {
        VStack(spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(formatHistoryValue(value))
                .font(.callout.weight(.semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }

    private var rangeCutoff: Date {
        let interval: TimeInterval = range == .day ? 86_400 : 7 * 86_400
        return Date().addingTimeInterval(-interval)
    }

    /// 只用分钟均值,不再把 2 秒实时点拼进来。仓库教训写得明明白白
    /// (「chartPoints 把最近 10 分钟加权约 30 倍」),学习路径修了,
    /// 用户看的图却一直没修:接缝处曲线倒退、重复时间戳、平均值被
    /// 最近十分钟统治——这次全部随单一数据源消失。
    /// 同时按当前指标过滤掉无值点:一根轴配空曲线不算「有数据」。
    private var filteredPoints: [HistoryPoint] {
        model.history
            .filter { $0.timestamp >= rangeCutoff && value($0) != nil }
            .sorted { $0.timestamp < $1.timestamp }
    }

    private func value(_ point: HistoryPoint) -> Double? {
        switch metric {
        case .power:
            // 只画电池净功率,带符号:+ 充 − 放。旧版取绝对值并悄悄回落到
            // SoC 功耗——两种口径一条曲线,整夜充电和高强度放电长得一样。
            point.batteryPowerWatts
        case .temperature:
            // 只认芯片热点。旧版回落到电池温度:采集器一断,曲线从 70°C
            // 一步跳到 33°C,像机器一分钟降温四十度。缺口就让它缺着。
            point.hotspotTemperature
        case .battery: point.batteryPercent
        }
    }

    private var selectedPoint: HistoryPoint? {
        guard let selectedDate else { return nil }
        return filteredPoints
            .filter { value($0) != nil }
            .min {
                abs($0.timestamp.timeIntervalSince(selectedDate))
                    < abs($1.timestamp.timeIntervalSince(selectedDate))
            }
    }

    /// 一律墨色:按类别配色(温度=橙、电量=绿)是把语义色当装饰,
    /// 25°C 的凉曲线披着「注意」橙、掉到 3% 的电量曲线披着「好」绿,
    /// 规范铁律 2 明令禁止。
    private var chartColor: Color { MacPulseTheme.ink }

    private func formatHistoryValue(_ value: Double?) -> String {
        switch metric {
        // 功率带符号:曲线里 + 是充电、− 是放电,读数不带符号会读反方向。
        case .power: MetricFormat.watts(value, signed: true)
        case .temperature: MetricFormat.temperature(value)
        case .battery: MetricFormat.percent(value)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: DashboardModel
    @AppStorage("notificationsEnabled") private var notificationsEnabled = true
    @AppStorage("temperatureThreshold") private var temperatureThreshold = 40.0
    @AppStorage("temperatureAlertsEnabled") private var temperatureAlertsEnabled = true
    @AppStorage("thermalAlertsEnabled") private var thermalAlertsEnabled = true
    @AppStorage("healthAlertsEnabled") private var healthAlertsEnabled = true
    @AppStorage("peripheralAlertsEnabled") private var peripheralAlertsEnabled = true
    @AppStorage("peripheralAlertThreshold") private var peripheralAlertThreshold = 20
    @AppStorage("alertCooldownMinutes") private var alertCooldownMinutes = 60.0
    @AppStorage("menuBarDisplayMode") private var menuBarDisplayMode = MenuBarDisplayMode.standard.rawValue
    @AppStorage("menuBarMetrics") private var menuBarMetrics = MenuBarMetric.defaultStorage
    @AppStorage("menuBarGraphic") private var menuBarGraphic = ""
    @AppStorage("processMonitoringEnabled") private var processMonitoringEnabled = true
    @AppStorage("processHistoryEnabled") private var processHistoryEnabled = true
    @AppStorage("networkAutoRun") private var networkAutoRun = true
    @AppStorage("networkTestTier") private var networkTestTier = NetworkTestTier.standard.rawValue

    /// 菜单栏指标自选。至少留一项:全取消时解析层会回落到默认组合,
    /// 开关状态也跟着显示回去,不让「空菜单栏」这个状态存在。
    private var menuBarMetricToggles: some View {
        let selected = Set(MenuBarMetric.parse(menuBarMetrics))
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(MenuBarMetric.allCases) { metric in
                Toggle(isOn: Binding(
                    get: { selected.contains(metric) },
                    set: { isOn in
                        var next = MenuBarMetric.allCases.filter { selected.contains($0) }
                        if isOn {
                            if !next.contains(metric) { next.append(metric) }
                        } else {
                            next.removeAll { $0 == metric }
                        }
                        // 保持 allCases 的稳定顺序,菜单栏段落不随点击次序跳动。
                        menuBarMetrics = next.map(\.rawValue).joined(separator: ",")
                    }
                )) {
                    Text(metric.title).font(.caption)
                }
                .toggleStyle(.checkbox)
            }
            Text(String(localized: "紧凑模式只显示所选的第一项;读不到的指标自动跳过。"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.leading, 30)
    }

    /// 把流量代价直接摆在开关下面。用户选的是「每次打开都完整测」，
    /// 那就该让他随时看得见这个选择每月要花多少流量。
    private var networkDataCostNote: String {
        guard networkAutoRun else { return String(localized: "已关闭自动测速，仍可在网络页手动点「重新测速」。") }
        switch NetworkTestTier(rawValue: networkTestTier) ?? .standard {
        case .standard:
            return String(localized: "每次约 78 MB(含预热块)。按一天开 10 次估算约 780 MB/天、23 GB/月。")
        case .thrifty:
            return String(localized: "每次约 20 MB(含预热块)。按一天开 10 次估算约 200 MB/天、6 GB/月。")
        case .light:
            return String(localized: "每次约 35 KB，只测延迟与连通性，不测下载上传速度。")
        }
    }
    @State private var launchAtLogin = false
    @State private var loginStatus: LoginItemStatus = .disabled
    @State private var loginError: String?
    @State private var reportText = ""
    @State private var showReport = false
    @State private var copiedAt: Date?

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                LiquidCard {
                    VStack(spacing: 14) {
                        SectionHeader(title: String(localized: "常规"))
                        HStack {
                            settingLabel(String(localized: "菜单栏显示"), String(localized: "空间不足时可切换紧凑或仅图标"), "menubar.rectangle")
                            Spacer()
                            Picker(String(localized: "菜单栏显示"), selection: $menuBarDisplayMode) {
                                ForEach(MenuBarDisplayMode.allCases) { mode in
                                    Text(mode.title).tag(mode.rawValue)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 122)
                        }
                        if menuBarDisplayMode != MenuBarDisplayMode.iconOnly.rawValue {
                            menuBarMetricToggles
                        }
                        HStack {
                            settingLabel(
                                String(localized: "菜单栏图形"),
                                menuBarDisplayMode == MenuBarDisplayMode.iconOnly.rawValue
                                    ? String(localized: "「仅图标」模式下不能选「不显示」,否则菜单栏项会变成空白")
                                    : String(localized: "文字左边那格:图标、功率走势图,或者干脆不要"),
                                "waveform.path.ecg"
                            )
                            Spacer(minLength: 12)
                            Picker("", selection: Binding(
                                get: {
                                    menuBarGraphic.isEmpty
                                        ? (UserDefaults.standard.bool(forKey: "menuBarSparkline") ? "sparkline" : "icon")
                                        : menuBarGraphic
                                },
                                set: { menuBarGraphic = $0 }
                            )) {
                                Text(String(localized: "系统图标")).tag("icon")
                                Text(String(localized: "功率走势图")).tag("sparkline")
                                Text(String(localized: "不显示")).tag("hidden")
                                    .disabled(menuBarDisplayMode == MenuBarDisplayMode.iconOnly.rawValue)
                            }
                            .labelsHidden()
                            .frame(width: 122)
                        }
                        Divider()
                        Toggle(isOn: $launchAtLogin) {
                            settingLabel(String(localized: "登录时启动"), String(localized: "开机后自动常驻菜单栏"), "arrow.clockwise.circle")
                        }
                        .onChange(of: launchAtLogin) { _, value in
                            do {
                                try LoginItemService.setEnabled(value)
                                loginError = nil
                                loginStatus = LoginItemService.status
                            } catch {
                                loginError = error.localizedDescription
                                launchAtLogin = LoginItemService.isEnabled
                                loginStatus = LoginItemService.status
                            }
                        }
                        HStack {
                            Text(loginStatus.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            if loginStatus == .requiresApproval {
                                Button(String(localized: "打开系统设置")) {
                                    LoginItemService.openSystemSettings()
                                }
                                .buttonStyle(.link)
                            }
                        }
                        Divider()
                        Toggle(isOn: $notificationsEnabled) {
                            settingLabel(String(localized: "本地提醒"), String(localized: "高温、热压力和健康度提醒"), "bell.badge")
                        }
                        notificationPermissionRow
                    }
                }

                LiquidCard {
                    VStack(alignment: .leading, spacing: 13) {
                        SectionHeader(title: String(localized: "提醒规则"))
                        Toggle(String(localized: "电池持续高温"), isOn: $temperatureAlertsEnabled)
                        Toggle(String(localized: "系统热压力"), isOn: $thermalAlertsEnabled)
                        Toggle(String(localized: "电池健康度低于 80%"), isOn: $healthAlertsEnabled)
                        Toggle(isOn: $peripheralAlertsEnabled) {
                            settingLabel(
                                String(localized: "外设电量提醒"),
                                String(format: String(localized: "AirPods、键鼠低于 %@%% 时提醒;同一设备 8 小时内只提醒一次"), String(describing: peripheralAlertThreshold)),
                                "airpods"
                            )
                        }
                        if peripheralAlertsEnabled {
                            Slider(value: Binding(
                                get: { Double(peripheralAlertThreshold) },
                                set: { peripheralAlertThreshold = Int($0) }
                            ), in: 10...40, step: 5)
                        }
                        if !notificationsEnabled {
                            Text(String(localized: "本地提醒已关闭,以上规则暂不生效。"))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Divider()
                        HStack {
                            Text(String(localized: "电池持续两分钟高于"))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Int(temperatureThreshold))°C")
                                .font(.callout.weight(.bold))
                                .monospacedDigit()
                                .foregroundStyle(MacPulseTheme.warm)
                        }
                        Slider(value: $temperatureThreshold, in: 35...50, step: 1)
                            .tint(MacPulseTheme.warm)
                        HStack {
                            Text("35°")
                            Spacer()
                            Text("50°")
                        }
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        Divider()
                        HStack {
                            Text(String(localized: "重复提醒冷却"))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(String(format: String(localized: "%@ 分钟"), String(describing: Int(alertCooldownMinutes))))
                                .font(.callout.weight(.bold))
                                .monospacedDigit()
                        }
                        Slider(value: $alertCooldownMinutes, in: 15...180, step: 15)
                    }
                }

                aiBalanceSettingsCard

                sectionsEditor

                homeCardsEditor

                healthReportCard

                sensorCoverageCard

                LiquidCard {
                    VStack(alignment: .leading, spacing: 11) {
                        SectionHeader(title: String(localized: "隐私与采集"))
                        Label(String(localized: "所有历史数据仅保存在这台 Mac"), systemImage: "lock.shield.fill")
                            .foregroundStyle(MacPulseTheme.normal)
                        Text(String(localized: "除网络测速外，MacPulse 不发送任何网络请求。深度硬件数据由 App 内的原生传感器采集器读取（IOReport + SMC，思路改编自 mactop 与 Stats，均为 MIT，见第三方声明）；传感器不可用时自动退回基础模式。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Label(model.historyStoreStatus, systemImage: "clock.arrow.circlepath")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let backup = model.historyBackupStatus {
                            Label(backup, systemImage: "shippingbox")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Divider()

                        Toggle(isOn: $networkAutoRun) {
                            settingLabel(
                                String(localized: "打开面板时自动测速"),
                                String(localized: "只连接 speed.cloudflare.com 公开测速节点"),
                                "wifi"
                            )
                        }
                        Picker(String(localized: "测速强度"), selection: $networkTestTier) {
                            ForEach(NetworkTestTier.allCases) { tier in
                                Text("\(tier.title)（\(tier.dataCostDescription)）").tag(tier.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        Text(networkDataCostNote)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(String(localized: "测速只发送无意义的填充字节用于计时，不发送设备信息、进程名、电池数据或任何标识符。对方能看到的只有你的公网 IP 和由 IP 推断的大致地区——这是任何网络请求都无法避免的。结果只写入本机 network.store，不含 IP、Wi-Fi 名称或精确位置。热点与低数据模式下永不自动进行完整测速。"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Divider()
                        Toggle(isOn: $processMonitoringEnabled) {
                            settingLabel(
                                String(localized: "进程监控"),
                                String(localized: "查看 App、后台和系统进程的本机负担"),
                                "list.bullet.rectangle"
                            )
                        }
                        .onChange(of: processMonitoringEnabled) { _, value in
                            model.setProcessMonitoringEnabled(value)
                        }
                        Toggle(isOn: $processHistoryEnabled) {
                            settingLabel(
                                String(localized: "重点进程 7 天历史"),
                                String(localized: "每分钟只保存 MacPulse 与综合排行前五名"),
                                "clock.arrow.trianglehead.counterclockwise.rotate.90"
                            )
                        }
                        .disabled(!processMonitoringEnabled)
                        .onChange(of: processHistoryEnabled) { _, value in
                            model.setProcessHistoryEnabled(value)
                        }
                        Label(model.processHistoryStatus, systemImage: "externaldrive.badge.checkmark")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }

                acknowledgementsCard

                if let loginError {
                    Text(loginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                HStack {
                    // 从 bundle 读，不再硬编码——上一个硬编码在 1.2.1 时代
                    // 还写着 1.2，又是一个小型的报数不实。
                    Text("MacPulse \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(String(localized: "退出 MacPulse")) {
                        NSApp.terminate(nil)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                }
                .padding(.horizontal, 4)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .onAppear {
            syncLoginItemState()
        }
        // 权限是会在系统设置里变的:页面出现和 App 回前台都重查一次,
        // 否则「已允许/已关闭」可能双向说谎(授权后仍显示关闭、吊销后仍显示允许)。
        .task { await model.refreshNotificationAuthorization() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            syncLoginItemState()
            Task { await model.refreshNotificationAuthorization() }
        }
    }

    /// AI 余额:各服务商 API key 的录入与清除。key 只进系统钥匙串。
    @State private var aiKeyDrafts: [AIProvider: String] = [:]

    private var aiBalanceSettingsCard: some View {
        LiquidCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: String(localized: "AI 余额"), subtitle: String(localized: "查各家还剩多少钱"))
                Text(String(localized: "填入服务商的 API key 后,总览页的「AI 余额」卡会显示余额。key 只存系统钥匙串;余额请求只发往各服务商官方接口,不发送任何设备信息;Claude Code 用量为本地日志统计,零配置零网络。"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(AIProvider.allCases) { provider in
                    aiProviderRow(provider)
                }
            }
        }
    }

    @ViewBuilder
    private func aiProviderRow(_ provider: AIProvider) -> some View {
        HStack(spacing: 8) {
            Text(provider.displayName)
                .font(.callout)
                .frame(width: 130, alignment: .leading)
            if model.aiConfiguredProviders.contains(provider) {
                Label(String(localized: "已配置"), systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(MacPulseTheme.normal)
                Spacer(minLength: 0)
                Button(String(localized: "清除")) {
                    AIKeyStore.delete(for: provider)
                    model.reloadAIProviders()
                    model.refreshAIBalances(force: true)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.red)
            } else {
                SecureField(String(localized: "粘贴 API key"), text: Binding(
                    get: { aiKeyDrafts[provider] ?? "" },
                    set: { aiKeyDrafts[provider] = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                Button(String(localized: "保存")) {
                    let draft = aiKeyDrafts[provider] ?? ""
                    guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    AIKeyStore.save(draft, for: provider)
                    aiKeyDrafts[provider] = ""
                    model.reloadAIProviders()
                    model.refreshAIBalances(force: true)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled((aiKeyDrafts[provider] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    /// 板块编辑:哪些一级板块出现在底栏。总览与设置固定。
    @AppStorage("hiddenSections") private var hiddenSectionsRaw = "history"

    private var sectionsEditor: some View {
        LiquidCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: String(localized: "板块"), subtitle: String(localized: "底栏显示哪几个"))
                Text(String(localized: "不想看的板块直接藏掉。总览与设置固定显示;「趋势」默认收起,随时勾回来。"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(AppSection.allCases.filter { $0 != .overview && $0 != .settings }) { section in
                    Toggle(isOn: Binding(
                        get: { AppSection.visibleSections.contains(section) },
                        set: { visible in
                            AppSection.setHidden(section, hidden: !visible)
                            hiddenSectionsRaw = UserDefaults.standard.string(forKey: "hiddenSections") ?? ""
                        }
                    )) {
                        Label(section.title, systemImage: section.symbol)
                            .font(.callout)
                    }
                }
            }
        }
    }

    /// 主页卡片编辑:开关 + 上下排序。hero 与警示条固定不进清单
    /// (身份与硬件报警不许被藏);布局改动即时生效,总览页跟着重排。
    @AppStorage("overviewCardOrder") private var overviewCardOrder = ""
    @AppStorage("overviewHiddenCards") private var overviewHiddenCards = ""

    private var homeCardsEditor: some View {
        LiquidCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: String(localized: "主页卡片"), subtitle: String(localized: "自己排你的头版"))
                Text(String(localized: "勾选显示哪些卡、用箭头调顺序。英雄卡与硬件警示条固定显示,不在此列。"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                let layout = OverviewCard.currentLayout()
                ForEach(Array(layout.enumerated()), id: \.element.card) { index, entry in
                    HStack(spacing: 8) {
                        Toggle(isOn: Binding(
                            get: { entry.enabled },
                            set: { enabled in
                                var next = OverviewCard.currentLayout()
                                next[index].enabled = enabled
                                OverviewCard.save(layout: next)
                                overviewHiddenCards = UserDefaults.standard.string(forKey: "overviewHiddenCards") ?? ""
                            }
                        )) {
                            Text(entry.card.title).font(.callout)
                        }
                        Spacer(minLength: 0)
                        Button {
                            var next = OverviewCard.currentLayout()
                            guard index > 0 else { return }
                            next.swapAt(index, index - 1)
                            OverviewCard.save(layout: next)
                            overviewCardOrder = UserDefaults.standard.string(forKey: "overviewCardOrder") ?? ""
                        } label: { Image(systemName: "chevron.up") }
                        .buttonStyle(.borderless)
                        .disabled(index == 0)
                        Button {
                            var next = OverviewCard.currentLayout()
                            guard index < next.count - 1 else { return }
                            next.swapAt(index, index + 1)
                            OverviewCard.save(layout: next)
                            overviewCardOrder = UserDefaults.standard.string(forKey: "overviewCardOrder") ?? ""
                        } label: { Image(systemName: "chevron.down") }
                        .buttonStyle(.borderless)
                        .disabled(index == layout.count - 1)
                    }
                }
            }
        }
    }

    /// 一键体检:把全 App 的结论汇成一页可复制文本。
    /// 生成的报告不含任何标识信息(序列号/网络名/IP/用户名/路径),
    /// 所以可以放心贴到 issue、论坛或发给朋友。
    private var healthReportCard: some View {
        LiquidCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: String(localized: "体检报告"))
                Text(String(localized: "把电池、充电、内存、温度、睡眠、存储、自启与显示器的结论汇成一页,可直接复制粘贴。报告不含序列号、网络名称、IP、用户名或文件路径。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button {
                        let report = model.buildHealthReport()
                        reportText = report.markdown()
                        showReport = true
                    } label: {
                        Label(String(localized: "生成报告"), systemImage: "stethoscope")
                    }
                    .buttonStyle(.borderedProminent)
                    if !reportText.isEmpty {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(reportText, forType: .string)
                            copiedAt = .now
                        } label: {
                            Label(
                                copiedAt.map { Date().timeIntervalSince($0) < 3 } == true ? String(localized: "已复制") : String(localized: "复制"),
                                systemImage: "doc.on.doc"
                            )
                        }
                        .buttonStyle(.bordered)
                    }
                }
                if showReport, !reportText.isEmpty {
                    ScrollView {
                        Text(reportText)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 260)
                    .padding(10)
                    .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
    }

    /// 本机传感器覆盖自检:每类数据源一行,读到 ✓ 读不到「不可用」。
    /// 为开源准备的地基——MacPulse 只在一台 M5 Air 上实测过,装到别的
    /// 机器上,这张卡让用户第一眼看清自己机器的覆盖情况,报 issue 有的抄;
    /// 任何一行不可用都只是缺数据,不是故障,App 其余部分照常工作。
    /// 致谢卡。MacPulse 的几块硬核能力是站在别人肩膀上学来的,
    /// 这必须写在用户看得见的地方——只藏在仓库文件里不算尊重。
    private var acknowledgementsCard: some View {
        LiquidCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: String(localized: "致谢"))
                Text(String(localized: "MacPulse 的关键读取技术学习并改编自以下开源项目(均为 MIT 许可),完整授权文本见 App 内附带的第三方声明:"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                acknowledgementRow(
                    name: "mactop",
                    author: "Carsen Klock",
                    detail: String(localized: "IOReport 能耗与集群频率的原生读取思路"),
                    url: "https://github.com/metaspartan/mactop"
                )
                acknowledgementRow(
                    name: "Stats",
                    author: "Serhiy Mytrovtsiy",
                    detail: String(localized: "SMC 温度/功率读取的结构布局与类型解码"),
                    url: "https://github.com/exelban/stats"
                )
                acknowledgementRow(
                    name: "one-api",
                    author: "JustSong",
                    detail: String(localized: "各 AI 服务商余额接口的调法清单(channel-billing)"),
                    url: "https://github.com/songquanpeng/one-api"
                )
                acknowledgementRow(
                    name: "ccusage",
                    author: "ryoppippi",
                    detail: String(localized: "Claude Code 本地会话日志统计用量的思路"),
                    url: "https://github.com/ryoppippi/ccusage"
                )
                acknowledgementRow(
                    name: "WhatCable",
                    author: "Darryl Morley",
                    detail: String(localized: "USB-C 充电口与线缆芯片的 PD 位解码、瓶颈判定"),
                    url: "https://github.com/darrylmorley/whatcable"
                )
            }
        }
    }

    private func acknowledgementRow(name: String, author: String, detail: String, url: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.callout.weight(.semibold))
                    Text(author)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let link = URL(string: url) {
                Link(destination: link) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.callout)
                }
                .foregroundStyle(.secondary)
                .help(url)
            }
        }
    }

    private var sensorCoverageCard: some View {
        let deep = model.current.deep
        func mark(_ available: Bool) -> String { available ? "✓" : String(localized: "不可用") }
        return LiquidCard {
            VStack(alignment: .leading, spacing: 11) {
                SectionHeader(title: String(localized: "本机传感器覆盖"), subtitle: deep.chip?.name ?? String(localized: "未识别"))
                ValueRow(title: String(localized: "深度采集器"), value: model.collectorStatus.phase == .live ? String(localized: "✓ 实时") : model.collectorStatus.phase == .degraded ? String(localized: "部分可用") : String(localized: "未连接"), symbol: "antenna.radiowaves.left.and.right")
                ValueRow(title: String(localized: "功耗轨(IOReport)"), value: mark(deep.cpuPowerWatts != nil), symbol: "bolt.horizontal")
                ValueRow(title: String(localized: "集群频率(pmgr)"), value: mark(deep.socCompute?.eClusterFreqMHz != nil), symbol: "gauge.with.dots.needle.50percent")
                ValueRow(title: String(localized: "温度传感器(SMC)"), value: (deep.thermalGroups?.isEmpty == false) ? String(format: String(localized: "✓ %@ 组"), String(describing: deep.thermalGroups!.count)) : String(localized: "不可用"), symbol: "thermometer.medium")
                // 这两项依赖插电状态:拔电时读不到是物理,不是机器不支持。
                ValueRow(
                    title: String(localized: "电源输入(PDTR)"),
                    value: model.current.battery.powerSource == .external ? mark(deep.dcInputWatts != nil) : String(localized: "插电时检测"),
                    symbol: "powerplug"
                )
                ValueRow(title: String(localized: "风扇"), value: deep.isUnsupported(SensorAvailabilityKey.fans) ? String(localized: "本机型无风扇") : String(localized: "存在"), symbol: "fan")
                ValueRow(
                    title: String(localized: "充电协商节点(PD)"),
                    value: model.current.battery.powerSource == .external ? mark(model.chargeLink != nil) : String(localized: "插电时检测"),
                    symbol: "cable.connector"
                )
                Text(String(localized: "读不到的项在别的机型上属预期(如 Intel 无功耗轨、M1 Pro/Max/Ultra 的 USB-C 无协商节点),对应功能会如实隐藏,其余照常。"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 「等待在系统设置中允许」状态下开关必须保持在「开」——用户刚打开它,
    /// 只是系统还没批;旧版回读 isEnabled(此时 false)把开关自己弹回去,
    /// 与正下方「等待允许」的文字打架。
    private func syncLoginItemState() {
        loginStatus = LoginItemService.status
        launchAtLogin = LoginItemService.isEnabled || loginStatus == .requiresApproval
    }

    @ViewBuilder
    private var notificationPermissionRow: some View {
        HStack {
            Text(notificationPermissionText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            switch model.notificationAuthorizationStatus {
            case .notDetermined:
                Button(String(localized: "允许通知")) {
                    model.requestNotificationAuthorization()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            case .denied:
                Button(String(localized: "打开系统设置")) {
                    model.openNotificationSettings()
                }
                .buttonStyle(.link)
            default:
                EmptyView()
            }
        }
    }

    private var notificationPermissionText: String {
        switch model.notificationAuthorizationStatus {
        case .authorized: String(localized: "系统通知权限已允许")
        case .provisional: String(localized: "系统通知为临时允许")
        case .denied: String(localized: "系统通知权限已关闭")
        case .notDetermined: String(localized: "尚未请求系统通知权限")
        case .ephemeral: String(localized: "系统通知为临时授权")
        @unknown default: String(localized: "系统通知权限状态未知")
        }
    }

    private func settingLabel(_ title: String, _ subtitle: String, _ symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(MacPulseTheme.plugged)
                .frame(width: 25, height: 25)
                .background(MacPulseTheme.plugged.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
