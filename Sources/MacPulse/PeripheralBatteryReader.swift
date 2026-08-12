import Foundation
import IOKit

/// 一个蓝牙外设的电量。AirPods 一类分左右耳与充电盒,普通外设只有主电量。
struct PeripheralBattery: Identifiable, Sendable, Equatable {
    /// 规范化蓝牙地址(小写冒号形),跨数据源合并的键。
    let id: String
    var name: String
    var percentMain: Int?
    var percentLeft: Int?
    var percentRight: Int?
    var percentCase: Int?

    /// 展示用最低电量:哪个组件最缺电就按哪个提醒。
    var worstPercent: Int? {
        [percentMain, percentLeft, percentRight, percentCase].compactMap { $0 }.min()
    }
}

/// 外设电量读取,双路合并:
///
/// 1. **IORegistry HID 服务**(快,毫秒级):妙控板/妙控键盘一类 HID 外设的
///    `BatteryPercent`。AirPods 不在这条路上。
/// 2. **`system_profiler SPBluetoothDataType`**(慢,约 2 秒,子进程):
///    蓝牙守护进程视角,覆盖 AirPods 的左/右/盒分量。macOS 26 上 IOPS
///    电源列表已不含配件(实测只剩内置电池),这是拿 AirPods 电量仅剩的
///    公开路径。
///
/// 合并规则:同一地址 system_profiler 数据优先(更全),HID 补缺。
actor PeripheralBatteryReader {
    private var cachedFull: [PeripheralBattery] = []
    private var lastFullReadAt: Date = .distantPast
    /// 慢路刷新间隔。外设电量按小时尺度变化,30 秒足够新鲜。
    private static let fullRefreshInterval: TimeInterval = 30

    /// 快照:HID 立即读,慢路结果用缓存;缓存过期就在后台刷,**绝不阻塞本次调用**。
    /// 旧版在这里同步 await 子进程,采样 tick 被拖住约 2 秒,页面所有实时数字
    /// 跟着冻——注释承诺的「首屏快」代码没兑现,审计抓出后改成真异步。
    func sample() async -> [PeripheralBattery] {
        let hid = Self.readHIDBatteries()

        if Date().timeIntervalSince(lastFullReadAt) > Self.fullRefreshInterval {
            lastFullReadAt = .now
            Task { [weak self] in
                let full = await Self.readBluetoothProfile()
                await self?.storeFullResult(full)
            }
        }

        // 慢路优先,HID 只补慢路没有的设备。
        var merged = cachedFull
        let knownIDs = Set(merged.map(\.id))
        for device in hid where !knownIDs.contains(device.id) {
            merged.append(device)
        }
        // 排序补稳定序:sorted 非稳定排序,同电量的两台设备会在两次采样间
        // 无故对调位置,名字与地址作决胜键。
        return merged.sorted {
            ($0.worstPercent ?? 101, $0.name, $0.id) < ($1.worstPercent ?? 101, $1.name, $1.id)
        }
    }

    private func storeFullResult(_ devices: [PeripheralBattery]) {
        cachedFull = devices
    }

    // MARK: - HID 快路

    static func readHIDBatteries() -> [PeripheralBattery] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("AppleDeviceManagementHIDEventService"),
            &iterator
        ) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var result: [PeripheralBattery] = []
        while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
            defer { IOObjectRelease(service) }
            func read(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue()
            }
            // 只收蓝牙外设:内置键盘/触控板也挂同一类服务,但没有电量属性。
            guard (read("BluetoothDevice") as? NSNumber)?.boolValue == true,
                  let percent = (read("BatteryPercent") as? NSNumber)?.intValue,
                  (0...100).contains(percent),
                  let address = read("DeviceAddress") as? String else { continue }

            let product = (read("Product") as? String)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            result.append(PeripheralBattery(
                id: Self.normalizeAddress(address),
                name: product.isEmpty ? Self.fallbackName(read: read) : product,
                percentMain: percent
            ))
        }
        return result
    }

    /// Product 为空时按通知类型前缀推断类别(实测妙控板的 Product 就是空的,
    /// 但通知类型带 "TP" 前缀)。推不出就叫「蓝牙外设」,不硬编设备名。
    private static func fallbackName(read: (String) -> Any?) -> String {
        if let notify = read("BatteryFaultNotificationType") as? String {
            if notify.hasPrefix("TP") { return "妙控板" }
            if notify.hasPrefix("KB") { return "妙控键盘" }
            if notify.hasPrefix("M") { return "妙控鼠标" }
        }
        return "蓝牙外设"
    }

    // MARK: - system_profiler 慢路

    static func readBluetoothProfile() async -> [PeripheralBattery] {
        let data: Data? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
                process.arguments = ["SPBluetoothDataType", "-json", "-detailLevel", "mini"]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let output = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: process.terminationStatus == 0 ? output : nil)
            }
        }
        guard let data else { return [] }
        return parseBluetoothProfile(data)
    }

    /// 解析拆成纯函数,测试用真机抓的 JSON 当样本。
    static func parseBluetoothProfile(_ data: Data) -> [PeripheralBattery] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]] else { return [] }

        var result: [PeripheralBattery] = []
        for section in sections {
            guard let connected = section["device_connected"] as? [[String: Any]] else { continue }
            for entry in connected {
                for (name, value) in entry {
                    guard let props = value as? [String: Any],
                          let address = props["device_address"] as? String else { continue }
                    let device = PeripheralBattery(
                        id: normalizeAddress(address),
                        name: name,
                        percentMain: percentValue(props["device_batteryLevelMain"]),
                        percentLeft: percentValue(props["device_batteryLevelLeft"]),
                        percentRight: percentValue(props["device_batteryLevelRight"]),
                        percentCase: percentValue(props["device_batteryLevelCase"])
                    )
                    // 没有任何电量分量的设备(显示器、手机)不进列表。
                    if device.worstPercent != nil {
                        result.append(device)
                    }
                }
            }
        }
        return result
    }

    /// "73%" / "73" / 73 都接;解不出返回 nil,绝不当 0。
    static func percentValue(_ raw: Any?) -> Int? {
        if let number = raw as? NSNumber { return validPercent(number.intValue) }
        guard let text = raw as? String else { return nil }
        let digits = text.prefix(while: \.isNumber)
        guard !digits.isEmpty, let value = Int(digits) else { return nil }
        return validPercent(value)
    }

    private static func validPercent(_ value: Int) -> Int? {
        (0...100).contains(value) ? value : nil
    }

    static func normalizeAddress(_ raw: String) -> String {
        raw.lowercased().replacingOccurrences(of: "-", with: ":")
    }
}
