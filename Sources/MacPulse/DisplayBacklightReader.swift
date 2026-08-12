import Foundation
import IOKit

/// 屏幕背光读数。
///
/// 走公开的 IORegistry，**不需要任何权限，也不碰私有框架**：
/// `AppleARMBacklight` 服务的 `IODisplayParameters` 字典里有
/// `brightness`（0–65536）、`rawBrightness`、`BrightnessMilliNits`，
/// 以及 `BrightnessMicroAmps` —— 背光的实际电流。
///
/// 用电流而不是 nits 作为耗电分档的依据：µA 对功率线性。但我们**从不**把它
/// 换算成瓦特，它只是个桶键；瓦特永远从真实的电池放电里学。
struct BacklightSample: Sendable, Equatable {
    /// 用户亮度，0–1。
    var brightnessFraction: Double?
    var milliNits: Double?
    /// 背光实际电流（µA）。
    var microAmps: Double?
    /// 屏幕是否处于熄灭状态。
    var isAsleep: Bool { (microAmps ?? 0) < 300 }
}

final class DisplayBacklightReader {
    /// 服务句柄缓存：每次采样都重新匹配等于每次做一遍全局服务查找。
    private var service: io_service_t = IO_OBJECT_NULL
    private var lookupFailed = false

    deinit {
        if service != IO_OBJECT_NULL {
            IOObjectRelease(service)
        }
    }

    /// 读不到返回 nil —— 外接显示器独占、或未来机型换了服务名都属于这种情况，
    /// 此时耗电分档会自动降一级，而不是拿一个假亮度去猜。
    func read() -> BacklightSample? {
        guard let service = resolveService() else { return nil }

        guard let raw = IORegistryEntryCreateCFProperty(
            service,
            "IODisplayParameters" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? [String: Any] else { return nil }

        func value(_ key: String) -> Double? {
            guard let entry = raw[key] as? [String: Any],
                  let number = entry["value"] as? NSNumber
            else { return nil }
            return number.doubleValue
        }

        func maximum(_ key: String) -> Double? {
            guard let entry = raw[key] as? [String: Any],
                  let number = entry["max"] as? NSNumber
            else { return nil }
            return number.doubleValue
        }

        var sample = BacklightSample()
        if let current = value("brightness"), let max = maximum("brightness"), max > 0 {
            sample.brightnessFraction = current / max
        }
        sample.milliNits = value("BrightnessMilliNits")
        sample.microAmps = value("BrightnessMicroAmps")

        // 三项全空说明这个服务不是我们要的，当作读不到。
        guard sample.brightnessFraction != nil || sample.milliNits != nil || sample.microAmps != nil else {
            return nil
        }
        return sample
    }

    private func resolveService() -> io_service_t? {
        if service != IO_OBJECT_NULL { return service }
        guard !lookupFailed else { return nil }

        let matched = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleARMBacklight"))
        guard matched != IO_OBJECT_NULL else {
            lookupFailed = true
            return nil
        }
        service = matched
        return matched
    }
}
