import AppKit
import MacPulseCore
import SwiftUI

// MARK: - 芯片

struct SoCPanelView: View {
    @EnvironmentObject private var model: DashboardModel

    private var deep: DeepMetrics { model.current.deep }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                // 空闲时不出现:与总览警示条同一条克制原则,没事就别占屏。
                if let throttle = throttleDiagnosis, throttle.kind != .idle {
                    throttleCard(throttle)
                }
                cpuCard
                gpuCard
                aneCard
                powerCard
                displayCard
                throughputCard
                CollectorStatusBanner()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    /// 「机器怎么突然变慢了」。推导在 model.throttleDiagnosis 单点维护
    /// (判据用性能集群:它是重活的主力,能效集群常年低频,拿它判会天天误报)。
    private var throttleDiagnosis: ThrottleDiagnosis? {
        model.throttleDiagnosis
    }

    private func throttleCard(_ diagnosis: ThrottleDiagnosis) -> some View {
        LiquidCard {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: throttleSymbol(diagnosis.kind))
                        .foregroundStyle(diagnosis.isWarning ? MacPulseTheme.warm : MacPulseTheme.normal)
                    Text(diagnosis.summary)
                        .font(.callout.weight(.semibold))
                    Spacer(minLength: 0)
                    if let headroom = diagnosis.frequencyHeadroomPercent {
                        Text(String(format: String(localized: "%@%% 频率"), String(describing: Int(headroom))))
                            .font(.caption.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Text(diagnosis.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 显示器:分辨率与刷新率,并点名「没跑到这块屏支持的最高刷新率」。
    /// 外接屏跑不满多半是线或转接头的锅——这正是充电链路那套诊断的视频版。
    @ViewBuilder
    private var displayCard: some View {
        if !model.displays.isEmpty {
            LiquidCard {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: String(localized: "显示器"), subtitle: String(format: String(localized: "%@ 块"), String(describing: model.displays.count)))
                    ForEach(model.displays) { display in
                        ValueRow(
                            title: display.name + (display.isMain ? String(localized: "(主)") : ""),
                            value: displayValue(display),
                            symbol: display.isBuiltIn ? "laptopcomputer" : "display",
                            tint: display.isBelowMaxRefresh ? MacPulseTheme.warm : .secondary
                        )
                    }
                    if let limited = model.displays.first(where: \.isBelowMaxRefresh),
                       let max = limited.maxRefreshHz {
                        Text(String(format: String(localized: "「%@」当前 %@Hz,这块屏在同分辨率下支持到 %@Hz。外接屏跑不满通常是线材或转接头带宽不够,换一根支持更高带宽的线可以解决。"), String(describing: limited.name), String(describing: Int(limited.refreshHz ?? 0)), String(describing: Int(max))))
                            .font(.caption2)
                            .foregroundStyle(MacPulseTheme.warm)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func displayValue(_ display: DisplayInfo) -> String {
        let size = "\(display.pixelWidth)×\(display.pixelHeight)"
        guard let hz = display.refreshHz else { return size }
        return "\(size) · \(Int(hz))Hz"
    }

    private func throttleSymbol(_ kind: ThrottleDiagnosis.Kind) -> String {
        switch kind {
        case .fullSpeed: "checkmark.circle.fill"
        case .thermal: "thermometer.high"
        case .lowPowerMode: "battery.25percent"
        case .powerLimit: "bolt.badge.clock"
        case .idle: "moon.zzz"
        }
    }

    private var cpuCard: some View {
        LiquidCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(
                    title: deep.chip?.name ?? "CPU",
                    subtitle: deep.chip?.coreLayoutDescription
                )
                ClusterRow(
                    name: String(localized: "能效集群"),
                    activePercent: deep.socCompute?.eClusterActivePercent,
                    freqMHz: deep.socCompute?.eClusterFreqMHz,
                    color: MacPulseTheme.violet
                )
                ClusterRow(
                    name: String(localized: "性能集群"),
                    activePercent: deep.socCompute?.pClusterActivePercent,
                    freqMHz: deep.socCompute?.pClusterFreqMHz,
                    color: MacPulseTheme.plugged
                )
                if !model.perCoreUsage.isEmpty {
                    Divider()
                    PerCoreBars(
                        usage: model.perCoreUsage,
                        eCoreCount: deep.chip?.eCoreCount
                    )
                }
            }
        }
    }

    private var gpuCard: some View {
        LiquidCard {
            VStack(alignment: .leading, spacing: 11) {
                SectionHeader(
                    title: "GPU",
                    subtitle: deep.chip?.gpuCoreCount.map { String(format: String(localized: "%@ 核"), String(describing: $0)) }
                )
                ValueRow(
                    title: String(localized: "占用"),
                    value: MetricFormat.percent(deep.gpuUsagePercent),
                    symbol: "square.3.layers.3d",
                    tint: .cyan
                )
                ValueRow(
                    title: String(localized: "频率"),
                    value: deep.socCompute?.gpuFreqMHz.map { "\($0) MHz" } ?? String(localized: "不可用"),
                    symbol: "metronome"
                )
                ValueRow(
                    title: String(localized: "温度"),
                    value: MetricFormat.temperature(deep.gpuTemperature),
                    symbol: "thermometer.medium"
                )
                if let fp32 = deep.chip?.tflopsFP32, let fp16 = deep.chip?.tflopsFP16 {
                    // 这是规格推算值（核数 × 最高频率），不是实测算力。
                    // 不标「理论峰值」就会被当成当前吞吐读。
                    Text(String(format: String(localized: "理论峰值 FP32 %.2f TFLOPs · FP16 %.2f TFLOPs"), fp32, fp16))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var aneCard: some View {
        LiquidCard {
            VStack(alignment: .leading, spacing: 11) {
                SectionHeader(title: String(localized: "神经引擎"), subtitle: aneStateTitle)
                ValueRow(
                    title: String(localized: "功耗"),
                    value: MetricFormat.watts(deep.anePowerWatts),
                    symbol: "bolt.fill",
                    tint: .pink
                )
                // 「活跃度」行已删:原生迁移后该通道无来源,恒显「不可用」,
                // 与标题栏的「空闲/工作中」三行打架。状态由功率单独驱动,
                // 依据写在下面的边界说明里。

                if let holders = model.aneHolderNames {
                    Divider()
                    if holders.isEmpty {
                        Text(String(localized: "当前没有 App 打开神经引擎"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(String(
                            format: String(localized: "正在占用：%@"),
                            holders.joined(separator: String(localized: "、"))
                        ))
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // 这句是本页最重要的一行文案：说清仪器的边界在哪。
                    Text(String(localized: "macOS 不提供按进程的神经引擎用量，这里只显示当前持有 ANE 会话的 App。"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// ANE 功率为 0 是**空闲**，是真读数，不是缺失。状态只看功率——
    /// 活跃度通道在原生路径上没有来源,不能参与判断。
    private var aneStateTitle: String? {
        guard let watts = deep.anePowerWatts else { return nil }
        return watts <= 0.001 ? String(localized: "空闲") : String(localized: "工作中")
    }

    private var powerCard: some View {
        LiquidCard {
            VStack(spacing: 13) {
                SectionHeader(title: String(localized: "功耗"), subtitle: String(localized: "实时"))
                // 五档墨阶,深→浅:青/粉/薄荷是单色化的漏网彩条(审计高危)。
                // GPU 行并入 GPU-SRAM:残差的减数含它,不并的话
                // 「各行相加 ≠ 总数」恰好打脸下面那句脚注。
                PowerRailRow(name: "CPU", watts: deep.cpuPowerWatts, color: .primary.opacity(0.85), maxWatts: powerScale)
                PowerRailRow(name: String(localized: "GPU(含 SRAM)"), watts: gpuRailWatts, color: .primary.opacity(0.65), maxWatts: powerScale)
                PowerRailRow(name: String(localized: "神经引擎"), watts: deep.anePowerWatts, color: .primary.opacity(0.48), maxWatts: powerScale)
                PowerRailRow(name: String(localized: "统一内存"), watts: deep.dramPowerWatts, color: .primary.opacity(0.32), maxWatts: powerScale)
                PowerRailRow(
                    name: String(localized: "其他（未细分）"),
                    watts: deep.socPower?.residualWatts,
                    color: .primary.opacity(0.18),
                    maxWatts: powerScale
                )
                Text(String(localized: "「其他」= SoC 总功耗减去上列各项。它来自能量模型内部，无法断言具体构成。"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Divider()
                ValueRow(
                    title: String(localized: "SoC 总功耗"),
                    value: MetricFormat.watts(deep.socPower?.packageWatts ?? deep.systemPowerWatts),
                    symbol: "cpu",
                    tint: .blue
                )
                ValueRow(
                    title: String(localized: "整机功耗"),
                    value: model.wholeMachineWattsText,
                    symbol: "desktopcomputer",
                    tint: .indigo
                )
                ValueRow(
                    title: String(localized: "屏幕与外设"),
                    value: MetricFormat.watts(model.nonSoCWatts),
                    symbol: "display",
                    tint: .orange
                )
            }
        }
    }

    private var throughputCard: some View {
        LiquidCard {
            VStack(spacing: 12) {
                SectionHeader(title: String(localized: "数据吞吐"))
                ValueRow(title: String(localized: "网络下载"), value: MetricFormat.rate(deep.networkInBytesPerSecond), symbol: "arrow.down.circle", tint: .green)
                ValueRow(title: String(localized: "网络上传"), value: MetricFormat.rate(deep.networkOutBytesPerSecond), symbol: "arrow.up.circle", tint: .blue)
                ValueRow(title: String(localized: "磁盘读取"), value: MetricFormat.rate(deep.diskReadBytesPerSecond), symbol: "internaldrive")
                ValueRow(title: String(localized: "磁盘写入"), value: MetricFormat.rate(deep.diskWriteBytesPerSecond), symbol: "square.and.arrow.down")
                ValueRow(
                    title: String(localized: "内存带宽"),
                    value: MetricFormat.value(
                        MetricFormat.gigabytesPerSecond(deep.socCompute?.dramReadGBs, deep.socCompute?.dramWriteGBs),
                        available: deep.socCompute?.dramReadGBs != nil,
                        unsupported: deep.isUnsupported(SensorAvailabilityKey.dramBandwidth)
                    ),
                    symbol: "arrow.left.arrow.right"
                )
            }
        }
    }

    /// GPU 核心轨 + GPU-SRAM 轨。任一有值就有值,两个都缺才是缺。
    private var gpuRailWatts: Double? {
        let parts = [deep.gpuPowerWatts, deep.socPower?.gpuSRAMWatts].compactMap { $0 }
        return parts.isEmpty ? nil : parts.reduce(0, +)
    }

    /// 条的满刻度用封装总功耗:旧版用「最大的那条轨」,最大轨永远顶满,
    /// 紧邻的「SoC 总功耗」又诱导人把条读成占比——现在它就是占比。
    private var powerScale: Double {
        if let package = deep.socPower?.packageWatts, package > 0 {
            return package
        }
        let rails = [
            gpuRailWatts,
            deep.cpuPowerWatts,
            deep.anePowerWatts,
            deep.dramPowerWatts,
            deep.socPower?.residualWatts
        ].compactMap { $0 }
        return max(5, rails.max() ?? 5)
    }
}

private struct ClusterRow: View {
    let name: String
    let activePercent: Double?
    let freqMHz: Int?
    let color: Color

    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Text(name)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(MetricFormat.percent(activePercent))
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                Text(freqMHz.map { "\($0) MHz" } ?? "—")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 78, alignment: .trailing)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.07))
                    if let activePercent {
                        Capsule()
                            .fill(LinearGradient(colors: [color.opacity(0.55), color], startPoint: .leading, endPoint: .trailing))
                            .frame(width: proxy.size.width * min(max(activePercent / 100, 0), 1))
                    } else {
                        Capsule()
                            .strokeBorder(.primary.opacity(0.16), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                }
            }
            .frame(height: 6)
        }
    }
}

/// 每核占用柱状图。
///
/// 用一个 `Canvas` 画完所有柱子，而不是 N 个 `GeometryReader` + `Capsule`：
/// 这些柱子在 `.glassEffect()` 卡片内部，每 2 秒刷新一次，逐元素的视图树
/// 重建代价远高于一次 Canvas 重绘。
private struct PerCoreBars: View {
    let usage: [Double]
    let eCoreCount: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(String(localized: "每核占用"))
                // 口径注记:每核数据是 App 本机直接采样(host_processor_info),
                // 不走采集器——这解释了为什么采集器断连时它照常更新。
                Text(String(localized: "本机直接采样"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
                .font(.caption)
                .foregroundStyle(.secondary)

            Canvas { context, size in
                guard !usage.isEmpty else { return }
                let pitch = size.width / CGFloat(usage.count)
                let barWidth = min(26, pitch * 0.62)
                for (index, value) in usage.enumerated() {
                    let fraction = min(max(value / 100, 0), 1)
                    let height = max(2, size.height * fraction)
                    let x = pitch * CGFloat(index) + (pitch - barWidth) / 2
                    let rect = CGRect(x: x, y: size.height - height, width: barWidth, height: height)
                    let isEfficiency = eCoreCount.map { index < $0 } ?? false
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: barWidth / 2.6),
                        with: .color(isEfficiency ? MacPulseTheme.violet : MacPulseTheme.plugged)
                    )
                    // 轨道底色，让空闲核也看得见位置
                    let track = CGRect(x: x, y: 0, width: barWidth, height: size.height)
                    context.stroke(
                        Path(roundedRect: track, cornerRadius: barWidth / 2.6),
                        with: .color(.primary.opacity(0.06)),
                        lineWidth: 1
                    )
                }
            }
            .frame(height: 44)

            if let eCoreCount, eCoreCount > 0, usage.count > eCoreCount {
                HStack(spacing: 12) {
                    LegendDot(color: MacPulseTheme.violet, label: String(format: String(localized: "%@ 能效核"), String(describing: eCoreCount)))
                    LegendDot(color: MacPulseTheme.plugged, label: String(format: String(localized: "%@ 性能核"), String(describing: usage.count - eCoreCount)))
                }
            }
        }
    }
}

private struct LegendDot: View {
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: - 内存

struct MemoryPanelView: View {
    @EnvironmentObject private var model: DashboardModel

    /// 「我这台机器内存够不够」——判据只看换页量、压缩占比、系统压力等级,
    /// 不看「已用」:macOS 把闲置内存拿去做缓存,占用高是好事。
    @ViewBuilder
    fileprivate var memoryVerdictCard: some View {
        if let verdict = model.memoryDiagnosis {
            LiquidCard {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: verdict.isWarning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(verdict.isWarning ? MacPulseTheme.warm : MacPulseTheme.normal)
                        Text(verdict.summary)
                            .font(.callout.weight(.semibold))
                        Spacer(minLength: 0)
                        if let swap = model.memoryExtras.swapUsedBytes, swap > 0 {
                            Text(String(format: String(localized: "换页 %@"), String(describing: MetricFormat.storageBytes(swap))))
                                .font(.caption.weight(.medium))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(verdict.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let advice = verdict.advice {
                        Text(advice)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let memory = model.memory {
                    memoryVerdictCard
                    breakdownCard(memory)
                    pressureCard(memory)
                } else {
                    LiquidCard {
                        Text(String(localized: "内存读数暂不可用"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 60)
                    }
                }
                topConsumersCard
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    private func breakdownCard(_ memory: MemoryBreakdown) -> some View {
        LiquidCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(
                    title: String(localized: "统一内存"),
                    subtitle: String(format: String(localized: "已使用 %@ / 共 %@"), String(describing: MetricFormat.bytes(memory.usedBytes)), String(describing: MetricFormat.bytes(memory.totalBytes)))
                )
                MemoryStackedBar(memory: memory)
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 7) {
                    MemoryLegendItem(color: .primary.opacity(0.85), title: String(localized: "应用内存"), bytes: memory.appBytes)
                    MemoryLegendItem(color: .primary.opacity(0.60), title: String(localized: "联动内存"), bytes: memory.wiredBytes)
                    MemoryLegendItem(color: .primary.opacity(0.38), title: String(localized: "压缩内存"), bytes: memory.compressedBytes)
                    MemoryLegendItem(color: .primary.opacity(0.20), title: String(localized: "缓存文件"), bytes: memory.cachedFilesBytes)
                    MemoryLegendItem(color: .primary.opacity(0.08), title: String(localized: "可用"), bytes: memory.freeBytes)
                }
                Text(String(localized: "与「活动监视器 → 内存 → 已使用内存」口径一致：应用 + 联动 + 压缩，不含缓存文件。"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func pressureCard(_ memory: MemoryBreakdown) -> some View {
        LiquidCard {
            VStack(alignment: .leading, spacing: 11) {
                SectionHeader(title: String(localized: "内存压力"), subtitle: memory.pressureLevel.title)
                ValueRow(
                    title: String(localized: "压力（近似）"),
                    value: memory.approximatePressurePercent.map { String(format: "%.0f%%", $0) } ?? String(localized: "不可用"),
                    symbol: "gauge.with.dots.needle.50percent",
                    tint: pressureColor(memory.pressureLevel)
                )
                // Apple 从未公开活动监视器那条压力曲线的算法。标注为近似值，
                // 并让颜色由内核给的等级驱动，而不是由这个估算值驱动。
                Text(String(localized: "Apple 未公开确切算法，此处按「已联动 + 已压缩」占比估算；左侧状态色取自内核给出的压力等级。"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()
                ValueRow(
                    title: String(localized: "交换空间"),
                    value: swapText(memory),
                    symbol: "arrow.triangle.swap"
                )
                ValueRow(
                    title: String(localized: "压缩节省"),
                    value: MetricFormat.bytes(memory.compressorSavedBytes),
                    symbol: "arrow.down.right.and.arrow.up.left"
                )
            }
        }
    }

    private func swapText(_ memory: MemoryBreakdown) -> String {
        guard let used = memory.swapUsedBytes else { return String(localized: "不可用") }
        guard let total = memory.swapTotalBytes else { return MetricFormat.bytes(used) }
        return "\(MetricFormat.bytes(used)) / \(MetricFormat.bytes(total))"
    }

    private func pressureColor(_ level: MemoryPressureLevel) -> Color {
        switch level {
        case .normal: MacPulseTheme.normal
        case .warning: MacPulseTheme.warm
        case .critical: MacPulseTheme.critical
        case .unknown: .secondary
        }
    }

    private var topConsumersCard: some View {
        LiquidCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: String(localized: "占用最多的 App"))
                let top = model.processGroups
                    .filter { ($0.physicalFootprintBytes ?? 0) > 0 }
                    .sorted { ($0.physicalFootprintBytes ?? 0) > ($1.physicalFootprintBytes ?? 0) }
                    .prefix(6)
                if top.isEmpty {
                    Text(String(localized: "进程监控未开启或仍在采集"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(top)) { group in
                        ValueRow(
                            title: group.displayName,
                            value: MetricFormat.bytes(group.physicalFootprintBytes),
                            symbol: "app.dashed"
                        )
                    }
                    Text(ProcessMetricKind.memory.caption ?? "")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// 内存分项堆叠条。同样用单个 `Canvas`，理由见 `PerCoreBars`。
private struct MemoryStackedBar: View {
    let memory: MemoryBreakdown

    var body: some View {
        Canvas { context, size in
            let total = Double(memory.totalBytes)
            guard total > 0 else { return }
            // 四档墨阶,深→浅 = 应用→缓存:占用越「硬」颜色越重,
            // 单色下依然一眼读出结构。
            let segments: [(UInt64, Color)] = [
                (memory.appBytes, .primary.opacity(0.85)),
                (memory.wiredBytes, .primary.opacity(0.60)),
                (memory.compressedBytes, .primary.opacity(0.38)),
                (memory.cachedFilesBytes, .primary.opacity(0.20))
            ]
            let radius = size.height / 2
            context.fill(
                Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: radius),
                with: .color(.primary.opacity(0.07))
            )
            var x: CGFloat = 0
            context.clip(to: Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: radius))
            for (bytes, color) in segments {
                let width = size.width * CGFloat(Double(bytes) / total)
                guard width > 0 else { continue }
                context.fill(
                    Path(CGRect(x: x, y: 0, width: width, height: size.height)),
                    with: .color(color)
                )
                x += width
            }
        }
        .frame(height: 14)
    }
}

private struct MemoryLegendItem: View {
    let color: Color
    let title: String
    let bytes: UInt64

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2.5).fill(color).frame(width: 9, height: 9)
            Text(title).font(.caption)
            Spacer(minLength: 2)
            Text(MetricFormat.bytes(bytes))
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 磁盘

struct DiskPanelView: View {
    @EnvironmentObject private var model: DashboardModel

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let overview = model.diskOverview, !overview.volumes.isEmpty {
                    ForEach(overview.volumes) { volume in
                        volumeCard(volume)
                    }
                    throughputCard(overview)
                    ssdTemperatureCard
                } else {
                    LiquidCard {
                        VStack(spacing: 8) {
                            SectionHeader(title: String(localized: "磁盘"))
                            Text(String(localized: "正在读取卷信息…"))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    private func volumeCard(_ volume: VolumeInfo) -> some View {
        LiquidCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(
                    title: volume.name,
                    subtitle: String(
                        format: String(localized: "%@ · 共 %@"),
                        volume.isRoot
                            ? String(localized: "启动卷")
                            : (volume.isInternal ? String(localized: "内置") : String(localized: "外置")),
                        MetricFormat.storageBytes(UInt64(volume.totalBytes))
                    )
                )
                VolumeCapacityBar(volume: volume)
                HStack(spacing: 12) {
                    DiskLegendItem(color: MacPulseTheme.ink, title: String(localized: "已用"),
                                   bytes: UInt64(volume.exclusiveUsedBytes), storage: true)
                    if volume.purgeableBytes > 0 {
                        DiskLegendItem(color: .primary.opacity(0.25), title: String(localized: "可自动腾出"),
                                       bytes: UInt64(volume.purgeableBytes), storage: true)
                    }
                    DiskLegendItem(color: .clear, title: String(localized: "可用"),
                                   bytes: UInt64(volume.availableBytes), storage: true)
                }
                if volume.purgeableBytes > 0 {
                    Text(String(localized: "「可自动腾出」是缓存与本地快照,系统需要空间时会自己清,不用手动删。"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func throughputCard(_ overview: DiskOverview) -> some View {
        LiquidCard {
            VStack(spacing: 12) {
                SectionHeader(title: String(localized: "读写活动"))
                ValueRow(
                    title: String(localized: "实时读取"),
                    value: MetricFormat.rate(model.current.deep.diskReadBytesPerSecond),
                    symbol: "arrow.down.circle",
                    tint: .blue
                )
                ValueRow(
                    title: String(localized: "实时写入"),
                    value: MetricFormat.rate(model.current.deep.diskWriteBytesPerSecond),
                    symbol: "arrow.up.circle",
                    tint: .orange
                )
                ValueRow(
                    title: String(localized: "本次开机累计读取"),
                    value: MetricFormat.storageBytes(overview.sessionReadBytes),
                    symbol: "tray.and.arrow.down"
                )
                ValueRow(
                    title: String(localized: "本次开机累计写入"),
                    value: MetricFormat.storageBytes(overview.sessionWriteBytes),
                    symbol: "tray.and.arrow.up"
                )
                // 写入量给参照系,否则「1.2TB」读不出好坏。SSD 写入寿命按 TBW 计,
                // 现代 1TB 级 SSD 通常在数百 TBW 量级——单日几十 GB 完全正常。
                Text(String(localized: "累计量从开机起算,重启归零。"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// SSD/NAND 温度来自采集器的温度分组,有就显示,没有整卡不出现。
    @ViewBuilder
    private var ssdTemperatureCard: some View {
        let groups = (model.current.deep.thermalGroups ?? [])
            .filter { $0.kind == .ssd || $0.kind == .nand || $0.kind == .nvme }
        if !groups.isEmpty {
            LiquidCard {
                VStack(spacing: 12) {
                    SectionHeader(title: String(localized: "存储温度"))
                    ForEach(groups) { group in
                        ValueRow(
                            title: group.kind.title,
                            value: MetricFormat.temperature(group.averageCelsius),
                            symbol: "thermometer.medium",
                            tint: .orange
                        )
                    }
                }
            }
        }
    }
}

/// 卷容量条:已用 + 可自动腾出,底轨是总容量。同 MemoryStackedBar 用单个 Canvas。
private struct VolumeCapacityBar: View {
    let volume: VolumeInfo

    var body: some View {
        Canvas { context, size in
            let total = Double(volume.totalBytes)
            guard total > 0 else { return }
            let radius = size.height / 2
            let track = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: radius)
            context.fill(track, with: .color(.primary.opacity(0.07)))
            context.clip(to: track)
            // 已用(扣腾出)+ 可腾出 + 可用 == 总容量,三段账目闭合。
            let segments: [(Int64, Color)] = [
                (volume.exclusiveUsedBytes, MacPulseTheme.ink),
                (volume.purgeableBytes, .primary.opacity(0.25))
            ]
            var x: CGFloat = 0
            for (bytes, color) in segments {
                let width = size.width * CGFloat(Double(bytes) / total)
                guard width > 0 else { continue }
                context.fill(
                    Path(CGRect(x: x, y: 0, width: width, height: size.height)),
                    with: .color(color)
                )
                x += width
            }
        }
        .frame(height: 14)
    }
}

private struct DiskLegendItem: View {
    let color: Color
    let title: String
    let bytes: UInt64
    var storage = false

    var body: some View {
        HStack(spacing: 6) {
            if color != .clear {
                RoundedRectangle(cornerRadius: 2.5).fill(color).frame(width: 9, height: 9)
            }
            Text(title).font(.caption)
            Text(storage ? MetricFormat.storageBytes(bytes) : MetricFormat.bytes(bytes))
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 启动项

/// 开机/登录自启的后台项,和「它现在是否真在跑、吃多少」对账。
/// 只读不改:告诉你有什么,删不删是你在系统设置里的决定。
struct StartupItemsView: View {
    @EnvironmentObject private var model: DashboardModel

    private var items: [BackgroundItem] { model.backgroundItems }
    private var runningCount: Int { items.filter(\.isRunning).count }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                LiquidCard {
                    VStack(alignment: .leading, spacing: 9) {
                        SectionHeader(
                            title: String(localized: "后台常驻"),
                            subtitle: items.isEmpty ? nil : String(format: String(localized: "%@ / %@ 在运行"), String(describing: runningCount), String(describing: items.count))
                        )
                        Text(String(localized: "这些是磁盘上 launchd 配置里的第三方自启项。新式 App 通过系统接口注册的登录项不落盘,不在此列——完整清单请看「系统设置 → 通用 → 登录项与扩展」。苹果自家组件已滤除。"))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if items.isEmpty {
                    LiquidCard {
                        Text(String(localized: "没有第三方自启项,或正在读取…"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    ForEach(BackgroundItem.Scope.allOrdered, id: \.rawValue) { scope in
                        let group = items.filter { $0.scope == scope }
                        if !group.isEmpty {
                            LiquidCard {
                                VStack(spacing: 10) {
                                    SectionHeader(title: L(scope.rawValue), subtitle: String(format: String(localized: "%@ 项"), String(describing: group.count)))
                                    ForEach(group) { item in
                                        ValueRow(
                                            title: item.displayName,
                                            value: statusText(item),
                                            symbol: item.isRunning ? "circle.fill" : "circle",
                                            tint: item.isRunning ? MacPulseTheme.normal : .secondary
                                        )
                                    }
                                }
                            }
                        }
                    }

                    LiquidCard {
                        Text(String(localized: "要停用某一项,请去「系统设置 → 通用 → 登录项与扩展」。MacPulse 只读不改。"))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    /// 在跑且对上了进程就报真实占用;在跑但对不上(权限或短命进程)只说「运行中」;
    /// 没跑就说「未运行」——三种状态各自诚实。
    private func statusText(_ item: BackgroundItem) -> String {
        guard item.isRunning else { return String(localized: "未运行") }
        if let cpu = item.cpuPercent, let memory = item.memoryBytes {
            return String(format: "%.1f%% · %@", cpu, MetricFormat.bytes(memory))
        }
        return String(localized: "运行中")
    }
}

extension BackgroundItem.Scope {
    static var allOrdered: [BackgroundItem.Scope] { [.userAgent, .systemAgent, .daemon] }
}

// MARK: - 温度

struct ThermalPanelView: View {
    @EnvironmentObject private var model: DashboardModel

    /// 16 组一次铺开会淹没信息。只默认展开芯片，其余按需。
    @State private var expanded: Set<ThermalGroupKind.Section> = [.chip]

    private var groups: [ThermalGroup] { model.current.deep.thermalGroups ?? [] }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                summaryCard
                throttleHistoryCard
                if groups.isEmpty {
                    LiquidCard {
                        Text(String(localized: "温度分组数据暂不可用"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 60)
                    }
                } else {
                    ForEach(ThermalGroupKind.Section.allCases, id: \.self) { section in
                        let sectionGroups = groups
                            .filter { $0.kind.section == section }
                            .sorted { ($0.averageCelsius ?? 0) > ($1.averageCelsius ?? 0) }
                        if !sectionGroups.isEmpty {
                            sectionCard(section, sectionGroups)
                        }
                    }
                }
                CollectorStatusBanner()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    /// 热降频事件历史。瞬时诊断只能回答「现在热不热」,
    /// 攒成历史才回答「是偶发还是天天如此、都发生在什么时候」。
    @ViewBuilder
    private var throttleHistoryCard: some View {
        let events = model.throttleEvents
        if !events.isEmpty {
            LiquidCard {
                VStack(alignment: .leading, spacing: 9) {
                    SectionHeader(title: String(localized: "热降频记录"), subtitle: String(format: String(localized: "近 7 天 %@ 次"), String(describing: events.count)))
                    Text(throttleHistorySummary(events))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(String(localized: "同一次持续降频只记开头。记录随 App 重启清零,不写入磁盘。"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// 找出降频最集中的时段,把「什么时候容易热」说出来。
    private func throttleHistorySummary(_ events: [Date]) -> String {
        let calendar = Calendar.current
        var byHour: [Int: Int] = [:]
        for event in events {
            byHour[calendar.component(.hour, from: event), default: 0] += 1
        }
        let latest = events.last.map {
            $0.formatted(.dateTime.month().day().hour().minute())
        } ?? "—"
        guard let peak = byHour.max(by: { $0.value < $1.value }), peak.value > 1 else {
            return String(format: String(localized: "最近一次在 %@。次数还少,看不出规律。"), String(describing: latest))
        }
        return String(format: String(localized: "最近一次在 %@;出现最多的时段是 %@ 点前后(%@ 次)——那个时间你通常在做的事,就是让它发热的事。"), String(describing: latest), String(describing: peak.key), String(describing: peak.value))
    }

    private var summaryCard: some View {
        LiquidCard {
            VStack(spacing: 11) {
                SectionHeader(title: String(localized: "热状态"), subtitle: model.current.deep.thermalLevel.title)
                ValueRow(
                    title: String(localized: "芯片热点（单点最高）"),
                    value: MetricFormat.temperature(model.current.deep.hotspotTemperature),
                    symbol: "thermometer.high",
                    tint: MacPulseTheme.warm
                )
                Text(String(localized: "分组行显示的是该组平均温度;上面的热点是全芯片单点最高值,两者口径不同。"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                ValueRow(
                    title: String(localized: "传感器分组"),
                    // 采集器断线时分组为空:「0 组 · 0 个传感器」是假 0,如实说不可用。
                    value: groups.isEmpty
                        ? String(localized: "不可用")
                        : String(format: String(localized: "%@ 组 · %@ 个传感器"), String(describing: groups.count), String(describing: groups.compactMap(\.sensorCount).reduce(0, +))),
                    symbol: "sensor"
                )
            }
        }
    }

    private func sectionCard(_ section: ThermalGroupKind.Section, _ items: [ThermalGroup]) -> some View {
        LiquidCard {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    if expanded.contains(section) {
                        expanded.remove(section)
                    } else {
                        expanded.insert(section)
                    }
                } label: {
                    HStack {
                        SectionHeader(title: L(section.rawValue), subtitle: String(format: String(localized: "%@ 组"), String(describing: items.count)))
                        Spacer(minLength: 0)
                        Image(systemName: expanded.contains(section) ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if expanded.contains(section) {
                    ForEach(items) { group in
                        ThermalGroupRow(group: group)
                    }
                }
            }
        }
    }
}

private struct ThermalGroupRow: View {
    let group: ThermalGroup

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(group.kind == .other ? group.rawName : group.kind.title)
                    .font(.callout)
                Spacer()
                Text(MetricFormat.temperature(group.averageCelsius))
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                Text(group.sensorCount.map { String(format: String(localized: "%@ 个"), String(describing: $0)) } ?? "—")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
            if let minimum = group.trustworthyMinimumCelsius, let maximum = group.maximumCelsius, maximum >= minimum {
                // 两端标数值:光一条区间条读不出「区间是多少度到多少度」。
                // min==max(单传感器组)也照画,点会落在中间,数值说明一切。
                HStack(spacing: 6) {
                    Text(MetricFormat.temperature(minimum))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                    RangeBar(minimum: minimum, maximum: maximum, current: group.averageCelsius)
                    Text(MetricFormat.temperature(maximum))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
        }
    }
}

/// 传感器组的 min–max 区间条。
///
/// 只有最小值可信时才画：实测出现过 `VRM min 1.0°C` 这种明显失灵的读数，
/// 画一条从 1° 开始的区间会让整组数据看起来荒唐，但平均值本身是好的。
private struct RangeBar: View {
    let minimum: Double
    let maximum: Double
    let current: Double?

    var body: some View {
        GeometryReader { proxy in
            let span = max(maximum - minimum, 0.1)
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.07))
                if let current {
                    let fraction = min(max((current - minimum) / span, 0), 1)
                    Circle()
                        .fill(MacPulseTheme.warm)
                        .frame(width: 5, height: 5)
                        .offset(x: proxy.size.width * fraction - 2.5)
                }
            }
        }
        .frame(height: 5)
    }
}

// MARK: - 共用

/// 采集器状态提示。芯片页与温度页共用，只在非正常状态下出现。
struct CollectorStatusBanner: View {
    @EnvironmentObject private var model: DashboardModel

    var body: some View {
        if model.collectorStatus.phase != .live {
            LiquidCard(padding: 12) {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: symbol)
                        .foregroundStyle(color)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.callout.weight(.semibold))
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var title: String {
        switch model.collectorStatus.phase {
        case .starting: String(localized: "正在连接深度采集器")
        case .live: String(localized: "深度采集器运行正常")
        case .degraded: String(localized: "部分传感器暂不可用")
        case .reconnecting: String(localized: "正在重新连接采集器")
        case .unavailable: String(localized: "当前使用基础系统指标")
        case .sleeping: String(localized: "睡眠期间暂停采集")
        }
    }

    private var detail: String {
        switch model.collectorStatus.phase {
        case .degraded:
            model.collectorStatus.warnings.isEmpty
                ? String(localized: "可用数据会继续刷新，缺失项明确显示为「不可用」。")
                : String(format: String(localized: "有 %@ 项深度数据缺失，其余读数仍会继续更新。"), String(describing: model.collectorStatus.warnings.count))
        case .reconnecting:
            String(localized: "CPU、内存与热状态由本机直接读取，不受影响；连接恢复后自动补回功耗与温度分组。")
        case .unavailable:
            String(localized: "找不到内嵌采集器。CPU、内存、每核占用与进程数据仍然可用。")
        case .sleeping:
            String(localized: "唤醒 Mac 后会自动恢复采集，不会把睡眠间隔补成零值。")
        case .starting:
            String(localized: "首次读取通常只需几秒钟。")
        case .live:
            String(localized: "所有可用传感器均在更新。")
        }
    }

    private var symbol: String {
        switch model.collectorStatus.phase {
        case .starting, .reconnecting: "arrow.trianglehead.2.clockwise.rotate.90"
        case .degraded, .unavailable: "exclamationmark.triangle.fill"
        case .sleeping: "moon.zzz.fill"
        case .live: "checkmark.circle.fill"
        }
    }

    private var color: Color {
        switch model.collectorStatus.phase {
        case .live: MacPulseTheme.normal
        case .starting: MacPulseTheme.plugged
        case .sleeping: .secondary
        case .degraded, .reconnecting, .unavailable: MacPulseTheme.warm
        }
    }
}
