import AppKit
import Combine
import MacPulseCore
import SwiftUI

/// 自建菜单栏项 + 完全自持的玻璃浮窗。
///
/// 放弃 MenuBarExtra 的原因:它的弹窗窗口里有系统私塞的材质底板,
/// 三种手术(清背板/祖先掩膜/全窗掩膜)都拿它没办法——「面板透出桌面」
/// 在别人的窗口里做不到,那就用自己的窗口。这里每一层都归我们管:
/// 无边框 NSPanel、清背板、圆角裁切、behindWindow 玻璃,想多透有多透。
@MainActor
final class StatusItemController: NSObject, NSWindowDelegate {
    private let statusItem: NSStatusItem
    private let panel: NSPanel
    private var cancellables: Set<AnyCancellable> = []
    private var clickMonitors: [Any] = []

    private static let panelSize = NSSize(width: 520, height: 760)

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // .nonactivatingPanel:点开面板不抢当前 App 的激活态——
        // 菜单栏工具的本分是「瞟一眼就走」,不打断用户手头的事。
        panel = KeyableGlassPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.delegate = self

        let root = RootView(presentation: .menuBar)
            .environmentObject(DashboardModel.shared)
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        panel.contentView = NSHostingView(rootView: root)

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePanel)
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        }

        // 标签跟着模型每个采样 tick 刷新;设置页改勾选时立即生效。
        DashboardModel.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateLabel() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.updateLabel() } }
            .store(in: &cancellables)
        updateLabel()
    }

    // MARK: - 菜单栏标签

    private func updateLabel() {
        guard let button = statusItem.button else { return }
        let model = DashboardModel.shared
        let defaults = UserDefaults.standard
        let mode = defaults.string(forKey: "menuBarDisplayMode") ?? MenuBarDisplayMode.standard.rawValue

        // 迷你走势图:开了就用最近的实时功率画一条 28×16 的火花线代替图标,
        // 一眼看出「刚才是不是有个尖峰」。关了走系统符号。
        if defaults.bool(forKey: "menuBarSparkline"),
           let spark = Self.sparklineImage(from: model.liveHistory) {
            button.image = spark
        } else {
            button.image = NSImage(
                systemSymbolName: model.menuBarSymbol,
                accessibilityDescription: model.menuBarAccessibilityLabel
            )
        }
        button.image?.accessibilityDescription = model.menuBarAccessibilityLabel
        button.imagePosition = mode == MenuBarDisplayMode.iconOnly.rawValue ? .imageOnly : .imageLeading

        if mode == MenuBarDisplayMode.iconOnly.rawValue {
            button.title = ""
        } else {
            let metrics = MenuBarMetric.parse(
                defaults.string(forKey: "menuBarMetrics") ?? MenuBarMetric.defaultStorage
            )
            let text = model.menuBarTitle(
                metrics: metrics,
                compact: mode == MenuBarDisplayMode.compact.rawValue
            )
            button.title = " " + text
        }
    }

    // MARK: - 迷你走势图

    /// 用最近的电池净功率画一条火花线。模板图(isTemplate)交给系统上色,
    /// 深色浅色菜单栏都自动跟随,不需要我们判断外观。
    /// 点数不足或全程零流量时返回 nil,由调用方退回图标——不画一条假的平线。
    static func sparklineImage(from history: [HistoryPoint]) -> NSImage? {
        // 先用电池净功率;满电插电时它恒为 0(初版就卡在这——功能开了却
        // 永远画不出线),此时退到 SoC 总功耗,那条轨任何供电状态下都在动。
        let recent = history.suffix(40)
        var values = recent.compactMap { $0.batteryPowerWatts.map(abs) }
        if (values.max() ?? 0) <= 0.3 {
            values = recent.compactMap { $0.systemPowerWatts.map(abs) }
        }
        guard values.count >= 4 else { return nil }
        let peak = values.max() ?? 0
        guard peak > 0.3 else { return nil }

        let size = NSSize(width: 28, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath()
            path.lineWidth = 1.4
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            let inset: CGFloat = 2
            let usableH = rect.height - inset * 2
            let stepX = rect.width / CGFloat(max(1, values.count - 1))
            for (index, value) in values.enumerated() {
                let x = CGFloat(index) * stepX
                let y = inset + CGFloat(value / peak) * usableH
                let point = NSPoint(x: x, y: y)
                if index == 0 { path.move(to: point) } else { path.line(to: point) }
            }
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: - 浮窗开合

    @objc private func togglePanel() {
        if panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        position(panel)
        // 轻手轻脚地出现:淡入 + 上浮 6pt。仪器不弹跳。
        let target = panel.frame
        panel.setFrame(target.offsetBy(dx: 0, dy: -6), display: false)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(target, display: true)
        }
        DashboardModel.shared.presentationDidAppear(.menuBar)
        installClickMonitors()
    }

    private func hidePanel() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
            }
        })
        DashboardModel.shared.presentationDidDisappear(.menuBar)
        removeClickMonitors()
    }

    /// 面板贴着状态栏图标下沿,右缘对齐图标,越界时贴屏幕边收回来。
    private func position(_ panel: NSPanel) {
        guard let button = statusItem.button, let buttonWindow = button.window,
              let screen = buttonWindow.screen ?? NSScreen.main else { return }
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = screen.visibleFrame

        var x = buttonFrame.maxX - Self.panelSize.width
        x = max(visible.minX + 8, min(x, visible.maxX - Self.panelSize.width - 8))
        let y = buttonFrame.minY - Self.panelSize.height - 6
        panel.setFrame(
            NSRect(origin: NSPoint(x: x, y: max(visible.minY + 8, y)), size: Self.panelSize),
            display: true
        )
    }

    /// 点面板外任意处收起:全局监视器管别的 App 与桌面,本地监视器管
    /// 自家其它窗口。监视器只在面板可见期间存活。
    private func installClickMonitors() {
        removeClickMonitors()
        let global = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hidePanel() }
        }
        let local = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window !== self.panel,
                   event.window !== self.statusItem.button?.window {
                    self.hidePanel()
                }
            }
            return event
        }
        clickMonitors = [global, local].compactMap { $0 }
    }

    private func removeClickMonitors() {
        for monitor in clickMonitors {
            NSEvent.removeMonitor(monitor)
        }
        clickMonitors = []
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        // 切到别的窗口时自动收起,与系统弹窗行为一致。
        hidePanel()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hidePanel()
        return false
    }
}

/// 无边框面板默认不能成为 key window——不改这点,面板里的分段选择器、
/// 开关、按钮全都点不动。
private final class KeyableGlassPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
