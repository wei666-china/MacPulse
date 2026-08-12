import Foundation
import IOKit

/// 按进程读取 GPU 占用时间。
///
/// 为什么不用采集器里现成的 `gpu_ms_per_sec`——三条独立理由，任何一条单独都足够：
///
/// 1. 上游的进程列表是**按 CPU 排序取前 20**，GPU 重、CPU 轻的进程直接不在列表里。
/// 2. 那个值是**重标定**过的估计（乘了 `系统GPU% / 各进程原始占比之和`），不是测量值。
/// 3. 采集器 2 秒一帧、进程采样 5/15/30 秒一轮，按 pid 关联等于拼接错位的时间窗。
///
/// 这里直接读 IORegistry 里 GPU 加速器的 user client。无需权限、无需私有框架，
/// 实测本机有 91 个活跃 client。
final class GPUProcessReader {
    /// 加速器服务在进程生命周期内是稳定的，只匹配一次。
    /// 每次采样都重新匹配会白白多做一次全局服务查找。
    private var accelerator: io_service_t = IO_OBJECT_NULL
    private var acceleratorLookupFailed = false

    deinit {
        if accelerator != IO_OBJECT_NULL {
            IOObjectRelease(accelerator)
        }
    }

    /// 返回 pid → 累计 GPU 时间（纳秒）。
    ///
    /// 这是单调累计量，调用方用差分求速率。返回 nil 表示这台机器读不到，
    /// 界面应当隐藏该列而不是显示 0。
    func accumulatedGPUTimeByPID() -> [pid_t: UInt64]? {
        guard let accelerator = resolveAccelerator() else { return nil }

        var iterator: io_iterator_t = IO_OBJECT_NULL
        guard IORegistryEntryGetChildIterator(accelerator, kIOServicePlane, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var totals: [pid_t: UInt64] = [:]
        while case let child = IOIteratorNext(iterator), child != IO_OBJECT_NULL {
            defer { IOObjectRelease(child) }
            guard IOObjectConformsTo(child, "AGXDeviceUserClient") != 0 else { continue }

            var unmanaged: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(child, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let properties = unmanaged?.takeRetainedValue() as? [String: Any]
            else { continue }

            guard let creator = properties["IOUserClientCreator"] as? String,
                  let pid = Self.parsePID(from: creator)
            else { continue }

            // 一个进程可能同时持有多个 client，累加而不是覆盖。
            totals[pid, default: 0] &+= Self.sumGPUTime(in: properties)
        }

        return totals.isEmpty ? nil : totals
    }

    private func resolveAccelerator() -> io_service_t? {
        if accelerator != IO_OBJECT_NULL { return accelerator }
        guard !acceleratorLookupFailed else { return nil }

        // 具体类名是芯片相关的（本机是 AGXAcceleratorG17G），按父类匹配。
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"))
        guard service != IO_OBJECT_NULL else {
            acceleratorLookupFailed = true
            return nil
        }
        accelerator = service
        return service
    }

    /// `IOUserClientCreator` 形如 `"pid 400, WindowServer"`。
    static func parsePID(from creator: String) -> pid_t? {
        guard let range = creator.range(of: "pid ") else { return nil }
        let rest = creator[range.upperBound...]
        let digits = rest.prefix { $0.isNumber }
        guard !digits.isEmpty, let value = Int32(digits) else { return nil }
        return pid_t(value)
    }

    /// `AppUsage` 是一个数组，每项形如 `{"API"="Metal", "accumulatedGPUTime"=4428215912916}`。
    static func sumGPUTime(in properties: [String: Any]) -> UInt64 {
        guard let usage = properties["AppUsage"] as? [[String: Any]] else { return 0 }
        var total: UInt64 = 0
        for entry in usage {
            guard let raw = entry["accumulatedGPUTime"] as? NSNumber else { continue }
            let value = raw.int64Value
            guard value > 0 else { continue }
            total &+= UInt64(value)
        }
        return total
    }
}
