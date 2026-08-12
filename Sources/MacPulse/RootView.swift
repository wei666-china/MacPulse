import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case overview
    case battery
    case performance
    case network
    case history
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "总览"
        case .battery: "电池"
        case .performance: "性能"
        case .network: "网络"
        case .history: "趋势"
        case .settings: "设置"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "sparkles"
        case .battery: "battery.75percent"
        case .performance: "gauge.with.dots.needle.67percent"
        case .network: "wifi"
        case .history: "chart.xyaxis.line"
        case .settings: "gearshape"
        }
    }
}

struct RootView: View {
    /// 这个实例代表哪一个展示面。菜单栏弹窗和独立窗口会各建一个 `RootView`，
    /// 必须能区分，否则采样率的开关会互相覆盖。
    let presentation: PresentationSource

    @EnvironmentObject private var model: DashboardModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var section: AppSection = .overview
    @Namespace private var tabAnimation

    var body: some View {
        ZStack {
            ambientBackground
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 20)
                    // 独立窗口的红绿灯浮在内容上方,头部多让一口气。
                    .padding(.top, presentation == .window ? 34 : 18)
                    .padding(.bottom, 12)

                Group {
                    switch section {
                    case .overview: OverviewView()
                    case .battery: BatteryView()
                    case .performance: PerformanceView()
                    case .network: NetworkView()
                    case .history: HistoryView()
                    case .settings: SettingsView()
                    }
                }
                .environmentObject(model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                tabBar
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                    .padding(.top, 8)
            }
        }
        .frame(width: 520, height: 760)
        // 系统控件(分段选择器/开关/按钮)统一石墨色:
        // 默认的系统蓝在单色仪表里是最扎眼的杂色。
        .tint(.primary)
        // 官方声明层:窗口容器背景置空。与 BehindWindowBlur 的 AppKit 手术
        // 互为保险——哪层生效都通向同一个结果:透出桌面。
        .containerBackground(.clear, for: .window)
        .preferredColorScheme(nil)
        .onAppear {
            model.presentationDidAppear(presentation)
            model.sectionChanged(section)
        }
        .onDisappear {
            model.presentationDidDisappear(presentation)
            model.sectionChanged(nil)
        }
        .onChange(of: section) { _, value in
            model.sectionChanged(value)
        }
    }

    private var header: some View {
        HStack(spacing: 11) {
            // 单色玻璃标:蓝紫渐变+彩色投影是 v2 装饰遗产,
            // 唯一的颜色语言交给系统强调色。
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(.primary.opacity(0.07))
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 1) {
                Text("MacPulse")
                    .font(.headline.weight(.semibold))
                // 真实芯片名,不写死机型——写死的「M5 MacBook Air」
                // 在别人的机器上就是谎言,开源前必须掐掉。
                Text(model.current.deep.chip?.name ?? "Mac")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Circle()
                .fill(collectorPresentation.color)
                .frame(width: 7, height: 7)
                .shadow(
                    color: collectorPresentation.color.opacity(0.6),
                    radius: 5
                )
                .accessibilityLabel(collectorPresentation.accessibilityLabel)
            Text(collectorPresentation.text)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(AppSection.allCases) { item in
                Button {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.28)) {
                        section = item
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 13, weight: .semibold))
                        Text(item.title)
                            .font(.system(size: 9, weight: .medium))
                    }
                    .foregroundStyle(section == item ? .primary : .secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background {
                        if section == item {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(.primary.opacity(0.09))
                                .matchedGeometryEffect(id: "tab", in: tabAnimation)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(item.title)
            }
        }
        .padding(4)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.clear, lineWidth: 0)
        }
    }

    /// 透桌面的玻璃底:实色底 + 彩色光斑(v2 装饰)换成 behindWindow 材质,
    /// 面板真正与桌面墙纸融为一体——「透明感」的全部来源就是这一层,
    /// 卡片是玻璃上的第二层玻璃,层次由系统材质自己给。
    private var ambientBackground: some View {
        BehindWindowBlur()
            .ignoresSafeArea()
    }

    private var collectorPresentation: (
        text: String,
        color: Color,
        accessibilityLabel: String
    ) {
        switch model.collectorStatus.phase {
        case .live:
            ("实时", MacPulseTheme.normal, "深度传感器已连接")
        case .degraded:
            ("部分数据", MacPulseTheme.warm, "部分深度传感器不可用")
        case .starting:
            ("连接中", MacPulseTheme.plugged, "正在连接深度传感器")
        case .reconnecting:
            ("重连中", MacPulseTheme.warm, "深度传感器正在重新连接")
        case .unavailable:
            ("基础模式", MacPulseTheme.warm, "深度传感器不可用")
        case .sleeping:
            ("已暂停", .secondary, "系统睡眠时已暂停采集")
        }
    }
}
