import AppKit
import Foundation

/// 一块屏幕的实际工作状态。诊断的核心问题是「我这块屏为什么没跑到它该有的样子」。
struct DisplayInfo: Identifiable, Sendable, Equatable {
    let id: UInt32
    let name: String
    /// 当前实际输出的像素尺寸。
    let pixelWidth: Int
    let pixelHeight: Int
    /// 当前刷新率。内置屏与部分外接屏可能报 0(系统不提供),此时为 nil。
    let refreshHz: Double?
    /// 这块屏支持的最高刷新率(同分辨率下)。比当前高就说明没跑满。
    let maxRefreshHz: Double?
    let isBuiltIn: Bool
    let isMain: Bool

    /// 没跑到自己支持的最高刷新率(留 1Hz 容差,避免 59.97 vs 60 的浮点噪声)。
    ///
    /// **只判外接屏**:ProMotion 机型的内置屏空闲时本来就会降到 60Hz 甚至更低,
    /// 那是自适应刷新在省电,不是故障。对内置屏喊「没跑满、换根线」既错误又荒唐——
    /// 内置屏根本没有线可换。
    var isBelowMaxRefresh: Bool {
        guard !isBuiltIn, let refreshHz, let maxRefreshHz else { return false }
        return maxRefreshHz - refreshHz > 1
    }
}

/// 屏幕读取。全部走 CoreGraphics 公开接口,无需权限、不启子进程。
enum DisplayReader {
    static func read() -> [DisplayInfo] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }

        return ids.compactMap { id in
            guard let mode = CGDisplayCopyDisplayMode(id) else { return nil }
            let isBuiltIn = CGDisplayIsBuiltin(id) != 0
            let current = mode.refreshRate > 0 ? mode.refreshRate : nil

            // 同分辨率下这块屏支持的最高刷新率。分辨率不同的模式不参与比较——
            // 「4K@60 vs 1080p@144」不是一回事,拿来比会得出错误结论。
            var maxRefresh: Double?
            if let modes = CGDisplayCopyAllDisplayModes(id, nil) as? [CGDisplayMode] {
                maxRefresh = modes
                    .filter { $0.pixelWidth == mode.pixelWidth && $0.pixelHeight == mode.pixelHeight }
                    .map(\.refreshRate)
                    .filter { $0 > 0 }
                    .max()
            }

            return DisplayInfo(
                id: id,
                name: displayName(for: id, isBuiltIn: isBuiltIn),
                pixelWidth: mode.pixelWidth,
                pixelHeight: mode.pixelHeight,
                refreshHz: current,
                maxRefreshHz: maxRefresh,
                isBuiltIn: isBuiltIn,
                isMain: CGDisplayIsMain(id) != 0
            )
        }
    }

    /// 屏幕名走 NSScreen 的本地化名称(系统怎么叫我们就怎么叫);
    /// 对不上号时退回「内置显示器 / 外接显示器」,不编型号。
    private static func displayName(for id: CGDirectDisplayID, isBuiltIn: Bool) -> String {
        let matched = NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value == id
        }
        if let name = matched?.localizedName, !name.isEmpty { return name }
        return isBuiltIn ? String(localized: "内置显示器") : String(localized: "外接显示器")
    }
}
