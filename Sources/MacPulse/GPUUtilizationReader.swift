import Foundation
import IOKit

/// GPU 设备利用率,读 AGXAccelerator 的 PerformanceStatistics(活动监视器同源)。
///
/// 为什么不用 IOReport GPUPH 的驻留占比判「GPU 忙不忙」:GPUPH 算的是
/// 「不在 OFF/IDLE 态的时间占比」——只要有视频在播、界面在动,GPU 就几乎
/// 不完全空转,驻留占比会趋近 100%,而真实利用率可能只有 40%。实测本机:
/// 抖音播放中驻留 ≈95%、Device Utilization = 48%。拿驻留判饱和,
/// 「为什么卡」会在每台放着视频的机器上喊冤案。驻留占比仍用于芯片页的
/// 频率档位展示(那是它的本职),饱和判定一律用这里的利用率。
///
/// 公开 IORegistry 属性,无权限、无子进程,微秒级读取。
enum GPUUtilizationReader {
    static func read() -> Double? {
        guard let matching = IOServiceMatching("AGXAccelerator") else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = properties?.takeRetainedValue() as? [String: Any],
              let stats = dictionary["PerformanceStatistics"] as? [String: Any],
              let value = stats["Device Utilization %"] as? NSNumber
        else { return nil }

        let percent = value.doubleValue
        guard percent >= 0, percent <= 100 else { return nil }
        return percent
    }
}
