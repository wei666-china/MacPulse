import Charts
import MacPulseCore
import SwiftUI

/// 设计规范「玻璃仪表」(v3,开源前定稿,详见 docs/design-system.md):
///
/// 1. **色彩只表达状态,不做装饰。** 语义色只有三个:normal(好)、
///    warm(注意)、critical(出事)。行图标一律单色,唯一的强调色跟随
///    系统设置(`accent`)——用户选什么色,App 就是什么色,这是最彻底的
///    「有主题」:主题就是 macOS 本身。
/// 2. 图表数据系列色是功能色(要能区分序列),不受本条约束。
/// 3. plugged/violet 是 v2 装饰时代的遗产,仅存量图表引用,新代码禁用。
enum MacPulseTheme {
    static let normal = Color(red: 0.24, green: 0.84, blue: 0.55)
    static let warm = Color(red: 1.00, green: 0.65, blue: 0.22)
    static let critical = Color(red: 1.00, green: 0.33, blue: 0.36)
    /// 单色墨阶:装饰与序列区分只用深浅,不用色相(亮暗外观自适应)。
    /// 「跟随系统强调色」方案已被否——默认蓝廉价感,Wei 原话「丑到爆」。
    static let ink = Color.primary.opacity(0.85)
    static let inkSoft = Color.primary.opacity(0.45)
    /// 旧色名向后兼容别名:plugged(原蓝)= 深墨,violet(原紫)= 浅墨。
    /// 全部存量引用(集群条/每核条/图表序列)借此一次性单色化。
    static let plugged = ink
    static let violet = inkSoft

    static func statusColor(for snapshot: MetricSnapshot) -> Color {
        if snapshot.deep.thermalLevel == .critical { return critical }
        if snapshot.deep.thermalLevel == .serious { return warm }
        if let temperature = snapshot.battery.temperatureCelsius, temperature >= 40 { return warm }
        if snapshot.battery.state == .charging { return normal }
        return ink
    }
}

struct LiquidCard<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Group {
            if reduceTransparency {
                content
                    .padding(padding)
                    .background(
                        Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 22, style: .continuous)
                    )
            } else {
                content
                    .padding(padding)
                    .glassEffect(
                        .regular,
                        in: RoundedRectangle(cornerRadius: 22, style: .continuous)
                    )
            }
        }
            // 不给系统玻璃叠妆:白色渐变描边和大阴影是自绘玻璃时代的遗产,
            // 官方 glassEffect 自带边缘处理与景深,叠上去反而露出「非原生感」。
            // 描边只留给开了「增强对比度」的用户——那是无障碍需求,不是装饰。
            .overlay {
                if contrast == .increased {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1.5)
                }
            }
            .shadow(
                color: .black.opacity(reduceTransparency ? 0.03 : 0),
                radius: reduceTransparency ? 5 : 0,
                y: reduceTransparency ? 2 : 0
            )
    }
}

/// 台式 Mac(mini/Studio)没有电池:读不到任何电池硬件字段时,
/// percentage 的 0 是假值——环必须显示占位,不许渲染「0%」。
extension BatteryMetrics {
    var hasReadableBattery: Bool {
        designCapacityMAh != nil || currentCapacityMAh != nil
            || healthPercent != nil || voltageVolts != nil
    }
}

struct BatteryRing: View {
    /// nil = 本机读不到电池(台式机),显示「—」占位。
    let percentage: Double?
    let color: Color
    let isCharging: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // 充电标识原本是一圈持续扩散的脉冲。实测过三版：
            //   TimelineView(1/20s)            面板打开时约 11% CPU
            //   CoreAnimation repeatForever    约 7%
            //   只动 opacity 不动几何          约 6.4%
            //   完全去掉持续动画               约 1%
            // 瓶颈不是动画本身的实现方式，而是它位于 .glassEffect() 卡片内部——
            // 玻璃材质必须逐帧重新混合。对一款电量监控 App 来说，一圈装饰光环
            // 吃掉的电比它监控的其它所有事情加起来还多，因此换成静态柔光：
            // 充电状态照样有视觉标记，但不产生任何持续重绘。
            if isCharging {
                Circle()
                    .stroke(color.opacity(0.35), lineWidth: 2)
                    .frame(width: 116, height: 116)
            }

            Circle()
                .stroke(.primary.opacity(0.08), lineWidth: 9)
            // 纯色平环,不加发光:仪表的精确感来自克制,辉光属于「科技气泡」。
            // 9pt 而不是 11pt:同直径下更细的环更像仪器刻度。
            if let percentage {
                Circle()
                    .trim(from: 0, to: min(max(percentage / 100, 0), 1))
                    .stroke(color, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: percentage)
            }

            VStack(spacing: -1) {
                Text(percentage.map { "\(Int($0.rounded()))" } ?? "—")
                    .font(.system(size: 29, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if percentage != nil {
                    Text("%")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 104, height: 104)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(percentage.map { String(format: String(localized: "电池电量 %@%%"), String(describing: Int($0.rounded()))) } ?? String(localized: "不可用"))
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String
    let tint: Color
    var progress: Double? = nil

    var body: some View {
        LiquidCard(padding: 13) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    // 图标单色化:彩色圆底图标是 v2 装饰遗产。
                    // 环形量表保留调用方的 tint——那是「进度到哪了」的语义色。
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 25, height: 25)
                        .background(.primary.opacity(0.06), in: Circle())
                    Spacer()
                    if let progress {
                        Gauge(value: min(max(progress, 0), 1)) {}
                            .gaugeStyle(.accessoryCircularCapacity)
                            .tint(tint)
                            .scaleEffect(0.70)
                            .frame(width: 22, height: 22)
                    }
                }

                Text(value)
                    .font(.system(size: 20, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .contentTransition(.numericText())
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

struct SectionHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.headline)
            Spacer()
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct ValueRow: View {
    let title: String
    let value: String
    var symbol: String? = nil
    /// 历史参数。规范 v3 起行图标一律单色(彩虹图标正是「没主题」的病根),
    /// 保留签名是为了不动几十处调用点;真正的状态色由各行的值文本/警示图标承担。
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 10) {
            if let symbol {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
            }
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
                .monospacedDigit()
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}

struct StatusPill: View {
    let text: String
    let symbol: String
    let color: Color

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color.opacity(0.12), in: Capsule())
    }
}

struct EmptyMetric: View {
    var compact = false

    var body: some View {
        Text("—")
            .font(.system(size: compact ? 16 : 20, weight: .semibold))
            .foregroundStyle(.tertiary)
    }
}

enum MetricFormat {
    static func watts(_ value: Double?, signed: Bool = false) -> String {
        guard let value, value.isFinite else { return String(localized: "不可用") }
        return String(format: signed ? "%+.1f W" : "%.1f W", value)
    }

    static func temperature(_ value: Double?) -> String {
        guard let value, value.isFinite else { return String(localized: "不可用") }
        return String(format: "%.1f°C", value)
    }

    static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return String(localized: "不可用") }
        return String(format: "%.0f%%", value)
    }

    static func bytes(_ value: UInt64?) -> String {
        guard let value else { return String(localized: "不可用") }
        return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }

    /// 存储容量专用:走 .file(十进制 GB),与访达、「关于本机」一个口径。
    /// 内存那套 .memory 是二进制 GiB,拿来报磁盘会把 512GB 说成 465.6GB,
    /// 用户拿去和系统对不上账。
    static func storageBytes(_ value: UInt64?) -> String {
        guard let value else { return String(localized: "不可用") }
        return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
    }

    static func rate(_ value: Double?) -> String {
        guard let value, value.isFinite else { return String(localized: "不可用") }
        return ByteCountFormatter.string(fromByteCount: Int64(max(0, value)), countStyle: .file) + "/s"
    }

    /// GPU 时间，单位毫秒/秒。
    ///
    /// 刻意不换算成百分比：`accumulatedGPUTime` 是 Metal 命令缓冲耗时，
    /// 各进程之和不等于系统 GPU 活跃度（合成器与驱动的开销落在别处）。
    /// 报一个看起来像占用率的数字会暗示一种并不存在的精度。
    static func gpuTime(_ nanosecondsPerSecond: Double?) -> String {
        guard let value = nanosecondsPerSecond, value.isFinite else { return String(localized: "不可用") }
        let milliseconds = max(0, value) / 1_000_000
        if milliseconds < 1 { return String(format: "%.2f ms/s", milliseconds) }
        return String(format: "%.0f ms/s", milliseconds)
    }

    /// 内存/ANE 带宽，读写合计。
    static func gigabytesPerSecond(_ read: Double?, _ write: Double?) -> String {
        let total = (read ?? 0) + (write ?? 0)
        guard read != nil || write != nil else { return String(localized: "不可用") }
        return String(format: "%.1f GB/s", total)
    }

    /// 三态渲染：有值给值；无值且已知本机型不提供，说「本机型不提供」；
    /// 无值但原因未知，说「不可用」。这两种「没有」必须能区分开。
    static func value(
        _ formatted: @autoclosure () -> String,
        available: Bool,
        unsupported: Bool
    ) -> String {
        if available { return formatted() }
        return unsupported ? String(localized: "本机型不提供") : String(localized: "不可用")
    }

    /// 缺失时说「不可用」，和 `MetricFormat` 其余部分一致。
    ///
    /// 原来返回「正在估算」——那个词把三种完全不同的状态混成一句话：
    /// 真的还在积累数据、读数确实不可用、以及接电时系统返回 Unlimited。
    /// 第三种情况让充电界面永远显示「预计 正在估算 充满」。
    static func duration(_ minutes: Int?) -> String {
        guard let minutes, minutes > 0 else { return String(localized: "不可用") }
        if minutes < 60 { return String(format: String(localized: "%@ 分钟"), String(describing: minutes)) }
        return String(format: String(localized: "%@ 小时 %@ 分"), String(describing: minutes / 60), String(describing: minutes % 60))
    }

    /// 续航估算的主文案。低置信度时给区间而不是点值。
    static func runtime(_ estimate: RuntimeEstimate) -> String {
        if let minutes = estimate.minutes {
            if estimate.confidence == .low,
               let low = estimate.lowMinutes,
               let high = estimate.highMinutes,
               high > low {
                return String(format: String(localized: "约 %@–%@"), String(describing: hoursText(low)), String(describing: hoursText(high)))
            }
            return duration(minutes)
        }
        return String(localized: "数据不足")
    }

    private static func hoursText(_ minutes: Int) -> String {
        if minutes < 60 { return String(format: String(localized: "%@ 分钟"), String(describing: minutes)) }
        let hours = Double(minutes) / 60
        return String(format: String(localized: "%.1f 小时"), hours)
    }

    static func runtimeBasis(_ estimate: RuntimeEstimate) -> String {
        guard estimate.minutes != nil else { return String(localized: "正在积累用量数据") }
        return "\(estimate.basis.title) · \(estimate.confidence.title)"
    }
}
