import AppKit
import SwiftUI

/// 菜单栏可选指标。Stats 式自由组合:选哪几个,菜单栏就显示哪几个。
enum MenuBarMetric: String, CaseIterable, Identifiable {
    case netPower
    case hotspotTemperature
    case batteryPercent
    case socPower
    case memoryPercent
    case aiQuota

    var id: String { rawValue }

    var title: String {
        switch self {
        case .netPower: String(localized: "电池净功率")
        case .hotspotTemperature: String(localized: "热点温度")
        case .batteryPercent: String(localized: "电量百分比")
        case .socPower: String(localized: "SoC 总功耗")
        case .memoryPercent: String(localized: "内存占用")
        case .aiQuota: String(localized: "AI 额度")
        }
    }

    /// 逗号串 ↔ 选择集。空/全非法时回落到老默认(功率+温度),
    /// 保证升级用户和手滑清空的用户都不会得到一个空菜单栏。
    static func parse(_ raw: String) -> [MenuBarMetric] {
        let parsed = raw.split(separator: ",").compactMap { MenuBarMetric(rawValue: String($0)) }
        return parsed.isEmpty ? [.netPower, .hotspotTemperature] : parsed
    }

    static let defaultStorage = "netPower,hotspotTemperature"
}

enum MenuBarDisplayMode: String, CaseIterable, Identifiable {
    case standard
    case compact
    case iconOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: String(localized: "自选指标")
        case .compact: String(localized: "紧凑")
        case .iconOnly: String(localized: "仅图标")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var dashboardWindow: NSWindow?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var windowObservers: [NSObjectProtocol] = []

    /// 自建菜单栏项与玻璃浮窗。强持有:它没了菜单栏图标就没了。
    private var statusController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 双形态:Dock 里是正经 App(有图标、能从启动台打开、⌘Tab 切得到),
        // 同时常驻菜单栏。想要纯后台的用户可在设置里关掉 Dock 图标。
        applyActivationPolicy()
        DashboardModel.shared.start()
        statusController = StatusItemController()
        observeSleepAndWake()
        observeDockPreference()

        // Dock 模式下点开就该有窗口(像任何正经 Mac App);纯菜单栏模式
        // 只在首次运行时开一次,之后靠点菜单栏图标。
        let showsDock = UserDefaults.standard.object(forKey: "showsDockIcon") as? Bool ?? true
        if showsDock || !UserDefaults.standard.bool(forKey: "MacPulse.hasShownDashboard") {
            showDashboardWindow()
            UserDefaults.standard.set(true, forKey: "MacPulse.hasShownDashboard")
        }
    }

    /// Dock 图标开关。默认显示(像 ChatGPT 那样是个能点开的正经 App);
    /// accessory 模式则回到纯菜单栏后台。
    private func applyActivationPolicy() {
        let showsDock = UserDefaults.standard.object(forKey: "showsDockIcon") as? Bool ?? true
        NSApp.setActivationPolicy(showsDock ? .regular : .accessory)
    }

    private func observeDockPreference() {
        let observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyActivationPolicy() }
        }
        windowObservers.append(observer)
    }

    func applicationWillTerminate(_ notification: Notification) {
        workspaceObservers.forEach {
            NSWorkspace.shared.notificationCenter.removeObserver($0)
        }
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        DashboardModel.shared.stop()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        showDashboardWindow()
        return true
    }

    private func showDashboardWindow() {
        if let dashboardWindow {
            dashboardWindow.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        // 独立窗口可缩放:正经 App 该让人拉大看(菜单栏弹窗保持固定尺寸)。
        let rootView = RootView(presentation: .window)
            .environmentObject(DashboardModel.shared)
        // 用 NSHostingView 而不是 NSHostingController:
        // 把 controller 的 view 挂到 window.contentView 上时没人持有
        // controller,它随即释放、视图连同窗口一起塌成 0×0(实测 6 个
        // 0×0 窗口)。NSHostingView 是自包含的,窗口持有它即可。
        let hostingView = NSHostingView(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 800),
            // fullSizeContentView 显式声明:玻璃面板要一直画到标题栏下面,
            // 不声明时行为随系统版本漂移(实测出现过内容压住红绿灯)。
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 460, height: 620)
        window.title = "MacPulse"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        // 尺寸主权归窗口:挂 contentView 而不是 contentViewController。
        // 走 contentViewController 时 AppKit 会按 preferredContentSize 定尺寸,
        // 而 sizingOptions=[] 让它恒为 .zero → 窗口被压成 0×0(实测);
        // 保留默认 sizingOptions 又会让内容的最小尺寸反推窗口成 460×652、
        // 右侧内容被切。直接挂 view + autoresizing 两个坑都绕开。
        hostingView.frame = NSRect(x: 0, y: 0, width: 560, height: 800)
        hostingView.autoresizingMask = [.width, .height]
        window.contentView = hostingView
        // 显式定尺寸并关掉窗口状态恢复:实测出现过系统记住早前一次异常的
        // 460×652 并每次还原,内容被切在窗外。窗口尺寸由代码说了算。
        window.setContentSize(NSSize(width: 560, height: 800))
        window.isRestorable = false
        window.center()
        // 先落 dashboardWindow 再注册观察者：观察回调会回读这个属性。
        dashboardWindow = window
        observeDashboardWindowVisibility(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// 独立窗口不能只依赖 SwiftUI 的 `onDisappear`。
    ///
    /// `isReleasedWhenClosed = false` 意味着关闭只是把窗口 order out，视图层级仍然完好，
    /// SwiftUI 未必判定为「消失」。于是 `presentationDidAppear` 永远等不到配对的
    /// `presentationDidDisappear`，采样率被钉死在 2 秒。这里直接用 AppKit 的窗口通知
    /// 兜底，并把「被其它窗口完全遮挡」和「最小化」也算作不需要高频采样——
    /// 用户看不见的面板，没有理由每 2 秒去读一次 SMC。
    private func observeDashboardWindowVisibility(_ window: NSWindow) {
        let center = NotificationCenter.default
        windowObservers.forEach(center.removeObserver)
        windowObservers = [
            center.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    DashboardModel.shared.presentationDidDisappear(.window)
                }
            },
            center.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                // 不从 notification 里取窗口：Notification 非 Sendable，跨隔离域传会被
                // 严格并发拦下。观察者本来就是按 object: window 注册的，直接回读
                // AppDelegate 持有的那一个即可。
                MainActor.assumeIsolated {
                    guard let window = self?.dashboardWindow else { return }
                    if window.occlusionState.contains(.visible) {
                        DashboardModel.shared.presentationDidAppear(.window)
                    } else {
                        DashboardModel.shared.presentationDidDisappear(.window)
                    }
                }
            }
        ]
    }

    private func observeSleepAndWake() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            center.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    DashboardModel.shared.suspend()
                }
            },
            center.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    DashboardModel.shared.resume()
                }
            }
        ]
    }
}

@main
struct MacPulseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// 菜单栏项与弹出面板不再走 MenuBarExtra——它的窗口里有系统私塞的
    /// 材质底板,「面板透出桌面」在别人的窗口里做不到。图标、指标标签、
    /// 玻璃浮窗全部由 StatusItemController(AppKit 自建)接管;
    /// SwiftUI 场景只剩一个空设置位(App 协议要求至少一个场景)。
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
