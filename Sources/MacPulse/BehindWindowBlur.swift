import AppKit
import SwiftUI

/// 真·玻璃板:透过窗体模糊桌面墙纸。
///
/// 透明的敌人是 MenuBarExtra 窗口里系统私塞的材质底板。前两刀的教训:
/// 清窗口背板不够(底板是独立视图),扫祖先链也不够(底板可能是兄弟视图,
/// 压在 SwiftUI 内容后面)。这一刀全窗清扫:从窗口根视图遍历整棵树,
/// **凡是不在 NSHostingView 子树里的材质视图一律糊空掩膜**——
/// 系统底板全在 hosting 外面,而卡片的 glassEffect 全在 hosting 里面,
/// 这条分界线天然安全。
///
/// `alphaValue` 是透明度档位旋钮:数值越低桌面透得越清。
struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = TransparentBackingView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.alphaValue = 0.55
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private final class TransparentBackingView: NSVisualEffectView {
    /// 1×1 的空图:什么都不画的掩膜 = 材质画区为零 = 底板消失。
    private static let emptyMask: NSImage = {
        NSImage(size: NSSize(width: 1, height: 1), flipped: false) { _ in true }
    }()

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stripHostingChrome()
        // SwiftUI 装底板的时机不定,连补三刀覆盖入窗后的各个阶段。
        DispatchQueue.main.async { [weak self] in self?.stripHostingChrome() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.stripHostingChrome()
        }
    }

    private func stripHostingChrome() {
        guard let window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear

        // 找到承载 SwiftUI 内容的 hosting 视图(我们必然是它的后代)。
        var hosting: NSView?
        var node: NSView? = self
        while let current = node {
            if String(describing: type(of: current)).contains("NSHostingView") {
                hosting = current
                break
            }
            node = current.superview
        }

        guard let root = window.contentView?.superview ?? window.contentView else { return }
        mask(in: root, sparing: hosting)
    }

    /// 递归清扫:hosting 子树整体跳过(卡片玻璃都在里面),其余材质视图掩掉。
    private func mask(in view: NSView, sparing hosting: NSView?) {
        if let hosting, view === hosting { return }
        if let effect = view as? NSVisualEffectView, effect !== self {
            effect.maskImage = Self.emptyMask
        }
        for subview in view.subviews {
            mask(in: subview, sparing: hosting)
        }
    }
}
