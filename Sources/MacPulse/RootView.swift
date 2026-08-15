import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case overview
    case battery
    case performance
    case network
    case ai
    case history
    case settings

    /// 可见板块。默认「AI」顶替「趋势」的位置(Wei 拍板)——趋势没删,
    /// 在设置的板块编辑里随时勾回来。总览与设置固定,不许藏。
    static var visibleSections: [AppSection] {
        let hidden = Set((UserDefaults.standard.string(forKey: "hiddenSections") ?? "history")
            .split(separator: ",").map(String.init))
        return allCases.filter { $0 == .overview || $0 == .settings || !hidden.contains($0.rawValue) }
    }

    static func setHidden(_ section: AppSection, hidden: Bool) {
        var set = Set((UserDefaults.standard.string(forKey: "hiddenSections") ?? "history")
            .split(separator: ",").map(String.init))
        if hidden { set.insert(section.rawValue) } else { set.remove(section.rawValue) }
        UserDefaults.standard.set(set.sorted().joined(separator: ","), forKey: "hiddenSections")
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: String(localized: "总览")
        case .ai: "AI"
        case .battery: String(localized: "电池")
        case .performance: String(localized: "性能")
        case .network: String(localized: "网络")
        case .history: String(localized: "趋势")
        case .settings: String(localized: "设置")
        }
    }

    var symbol: String {
        switch self {
        case .overview: "sparkles"
        case .ai: "brain"
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
    /// 板块配置变化时让 tab 栏重算(设置页写这个键)。
    @AppStorage("hiddenSections") private var hiddenSectionsRaw = "history"
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
                    case .ai: AIView()
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
        // 菜单栏弹窗是固定尺寸(弹窗本来就该是定值);独立窗口跟随用户
        // 拖拽——写死 520×760 会和可缩放窗口打架,内容被切在窗外。
        // 菜单栏弹窗固定尺寸;独立窗口给出 min/ideal/max 三档——
        // 只给 maxWidth 会让 NSHostingController 用内容的理想宽度
        // 撑出窗口边界(实测右侧被切)。
        // 弹窗固定尺寸;窗口态填满窗口(尺寸由 NSWindow 决定,
        // hosting 的 sizingOptions 已关掉反向传播)。
        .frame(
            width: presentation == .menuBar ? 520 : nil,
            height: presentation == .menuBar ? 760 : nil
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .onAppear {
            // 调试钩子:-MacPulseOpenSection ai 启动后直达指定板块,
            // 供无辅助功能权限的自动化截图验收;正常启动无此参数零影响。
            if let raw = UserDefaults.standard.string(forKey: "MacPulseOpenSection"),
               let target = AppSection(rawValue: raw) {
                section = target
            }
        }
        .onChange(of: hiddenSectionsRaw) { _, _ in
            // 用户把自己正停留的板块藏了:页面不能悬空,退回总览。
            if !AppSection.visibleSections.contains(section) {
                section = .overview
            }
        }
        .onChange(of: model.navigationRequest) { _, request in
            guard let request else { return }
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) {
                section = request.section
            }
            // 不带子页的请求当场消费;带子页的留给 PerformanceView 消费。
            if request.pane == nil {
                model.consumeNavigationRequest()
            }
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
            ForEach(AppSection.visibleSections) { item in
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
            (String(localized: "实时"), MacPulseTheme.normal, String(localized: "深度传感器已连接"))
        case .degraded:
            (String(localized: "部分数据"), MacPulseTheme.warm, String(localized: "部分深度传感器不可用"))
        case .starting:
            (String(localized: "连接中"), MacPulseTheme.plugged, String(localized: "正在连接深度传感器"))
        case .reconnecting:
            (String(localized: "重连中"), MacPulseTheme.warm, String(localized: "深度传感器正在重新连接"))
        case .unavailable:
            (String(localized: "基础模式"), MacPulseTheme.warm, String(localized: "深度传感器不可用"))
        case .sleeping:
            (String(localized: "已暂停"), .secondary, String(localized: "系统睡眠时已暂停采集"))
        }
    }
}
