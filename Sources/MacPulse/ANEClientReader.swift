import Foundation
import IOKit

/// 当前持有神经引擎会话的进程。
///
/// **macOS 不提供按进程的 ANE 用量。** 这不是我们没找到，是确实不存在：
/// ANE 的 user client（`H1xANELoadBalancerDirectPathClient`）只暴露
/// `IOUserClientCreator` 和五个 locking 布尔值——没有 `AppUsage`，没有累计时间，
/// 没有任何计数器。`ANE0` 也不暴露按 client 的属性，`powermetrics --samplers ane`
/// 同样只有封装级数据。
///
/// 所以这里给出的是**持有者名单**，不是用量排行。界面必须把这个区别说清楚，
/// 否则就是在暗示一个并不存在的精度。
final class ANEClientReader {
    /// ANE 的 client 节点是 `!registered, !matched`，`IOServiceGetMatchingServices`
    /// 找不到它们。但它们的父节点 `ANEDriverRoot`（类 `H1xANELoadBalancer`）
    /// 是 registered 的，可以直接匹配，然后遍历它的子节点——
    /// 这比递归遍历全表 2400+ 个节点便宜得多。
    private var driverRoot: io_service_t = IO_OBJECT_NULL
    private var driverRootLookupFailed = false

    deinit {
        if driverRoot != IO_OBJECT_NULL {
            IOObjectRelease(driverRoot)
        }
    }

    /// 返回当前持有 ANE 会话的 pid 集合。
    ///
    /// 返回 nil 表示**读不到**（这台机器没有 ANE，或接口变了）——
    /// 界面应当隐藏整张卡。返回空集合表示**确实没人在用**，可以如实显示。
    /// 这两种情况绝不能混为一谈：前者说「不知道」，后者说「没有」。
    func activeClientPIDs() -> Set<pid_t>? {
        guard let root = resolveDriverRoot() else { return nil }

        var iterator: io_iterator_t = IO_OBJECT_NULL
        guard IORegistryEntryGetChildIterator(root, kIOServicePlane, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var pids: Set<pid_t> = []
        while case let child = IOIteratorNext(iterator), child != IO_OBJECT_NULL {
            defer { IOObjectRelease(child) }
            // 按接口一致性判断而不是类名相等：实际类名是
            // H1xANELoadBalancerDirectPathClient，会随芯片代次变化。
            guard IOObjectConformsTo(child, "H11ANEInDirectPathClient") != 0 else { continue }

            var unmanaged: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(child, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let properties = unmanaged?.takeRetainedValue() as? [String: Any],
                  let creator = properties["IOUserClientCreator"] as? String,
                  let pid = GPUProcessReader.parsePID(from: creator)
            else { continue }
            pids.insert(pid)
        }
        return pids
    }

    private func resolveDriverRoot() -> io_service_t? {
        if driverRoot != IO_OBJECT_NULL { return driverRoot }
        guard !driverRootLookupFailed else { return nil }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("H1xANELoadBalancer"))
        guard service != IO_OBJECT_NULL else {
            driverRootLookupFailed = true
            return nil
        }
        driverRoot = service
        return service
    }
}
