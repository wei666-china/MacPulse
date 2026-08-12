import Foundation
import IOKit
import MacPulseCore

/// 充电链路采样:找出当前在供电的那个口,拼出 充电器 → 线缆 → Mac 的完整链路。
///
/// 读三类 IORegistry 公开节点(读法与类名清单改编自 WhatCable,MIT,见
/// THIRD_PARTY_NOTICES.md):
/// - `IOPortFeaturePowerSource`:充电器广告的 PDO 档位与协商结果
/// - `AppleHPMInterfaceType10/11/12/18`、`AppleTCControllerType10/11`:物理口状态
/// - `IOPortTransportComponentCCUSBPDSOPp`:线缆芯片(e-marker)的身份应答
///
/// 与 BatterySampler 不同,这里**不缓存服务句柄**:插拔充电器会让这些服务
/// 生灭,句柄一缓存就成了悬空引用。每次采样现场走一遍,节点总数只有个位数,
/// 且只在电池页可见时才被调用。
///
/// 全程逐 key `IORegistryEntryCreateCFProperty`,不做整树物化——服务拆除中的
/// 批量读会在 IOCFUnserializeBinary 里把进程带崩(WhatCable issue #181 的教训)。
actor ChargeLinkSampler {

    /// 物理口控制器的类名随芯片代际变:M3+ 是 AppleHPMInterfaceType10(USB-C)/
    /// 11(MagSafe)/12,M1/M2 是 AppleTCControllerType10/11,A 系芯片是 Type18。
    /// 清单来自 WhatCable 跨 200+ 台机器的语料验证。
    private static let portControllerClasses = [
        "AppleHPMInterfaceType10",
        "AppleHPMInterfaceType11",
        "AppleHPMInterfaceType12",
        "AppleHPMInterfaceType18",
        "AppleTCControllerType10",
        "AppleTCControllerType11"
    ]

    /// 一个 IOPortFeaturePowerSource 节点的解析结果。
    struct RawPowerSource: Sendable, Equatable {
        var name: String
        var portType: Int
        var portNumber: Int
        var portTypeDescription: String
        var options: [PDPowerOption]
        var winning: PDPowerOption?
    }

    func sample() -> ChargeLinkSnapshot? {
        let sources = readPowerSources()
        guard let winner = Self.preferredSource(in: sources) else { return nil }

        // 拔线后控制器会缓存上一次协商的 PDO,单看供电源节点会把已拔掉的
        // 充电器显示成还在充。必须拿物理口的 ConnectionActive 做门闸;
        // 口找不到(未知机型的类名缺口)同样不显示,宁缺毋假。
        guard portConnectionActive(
            typeDescription: winner.portTypeDescription,
            number: winner.portNumber
        ) == true else { return nil }

        let cable = readCableInfo(portType: winner.portType, portNumber: winner.portNumber)

        return ChargeLinkSnapshot(
            portTypeDescription: winner.portTypeDescription,
            portNumber: winner.portNumber,
            chargerOptions: winner.options,
            negotiated: winner.winning,
            cable: cable
        )
    }

    // MARK: - 供电源

    private func readPowerSources() -> [RawPowerSource] {
        var results: [RawPowerSource] = []
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOPortFeaturePowerSource"),
            &iterator
        ) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
            defer { IOObjectRelease(service) }
            if let source = Self.parseSource(read: { Self.property(service, $0) }) {
                results.append(source)
            }
        }
        return results
    }

    /// 从属性读取闭包解析一个供电源。拆成纯函数是为了让真机测试能用
    /// ioreg 文本喂假数据对拍。
    nonisolated static func parseSource(read: (String) -> Any?) -> RawPowerSource? {
        guard let name = read("PowerSourceName") as? String else { return nil }
        // ParentBuiltInPort* 是带内建口语义的新键,旧键作后备。
        let type = (read("ParentBuiltInPortType") as? NSNumber)?.intValue
            ?? (read("ParentPortType") as? NSNumber)?.intValue
        let number = (read("ParentBuiltInPortNumber") as? NSNumber)?.intValue
            ?? (read("ParentPortNumber") as? NSNumber)?.intValue
        guard let type, let number else { return nil }
        let desc = (read("ParentBuiltInPortTypeDescription") as? String)
            ?? (read("ParentPortTypeDescription") as? String)
            ?? "USB-C"

        return RawPowerSource(
            name: name,
            portType: type,
            portNumber: number,
            portTypeDescription: desc,
            options: parseOptions(read("PowerSourceOptions")),
            winning: parseOption(read("WinningPowerSourceOption"))
        )
    }

    /// PowerSourceOptions 的真实 CF 类型是 **Set**,ioreg 渲染成 `[{…}]` 纯属
    /// 误导。两种都接,按功率从高到低排。
    nonisolated static func parseOptions(_ value: Any?) -> [PDPowerOption] {
        let items: [Any]
        if let set = value as? NSSet {
            items = set.allObjects
        } else if let array = value as? NSArray {
            items = array.compactMap { $0 }
        } else {
            return []
        }
        return items.compactMap { parseOption($0) }
            .sorted { $0.maxPowerMW > $1.maxPowerMW }
    }

    nonisolated static func parseOption(_ value: Any?) -> PDPowerOption? {
        guard let dict = value as? [String: Any] else { return nil }
        let voltage = (dict["Voltage (mV)"] as? NSNumber)?.intValue ?? 0
        let current = (dict["Max Current (mA)"] as? NSNumber)?.intValue ?? 0
        let power = (dict["Max Power (mW)"] as? NSNumber)?.intValue ?? (voltage * current / 1000)
        guard voltage > 0 else { return nil }
        return PDPowerOption(voltageMV: voltage, maxCurrentMA: current, maxPowerMW: power)
    }

    /// 代表这个口的供电源。优先级 USB-PD > Brick ID > TypeC,且持有协商合同的
    /// 优先于只挂了名的——否则一个还没协商完的 Brick ID 空节点会把真在供电的
    /// TypeC(非 PD 充电器)顶掉。逻辑照搬 WhatCable。
    nonisolated static func preferredSource(in sources: [RawPowerSource]) -> RawPowerSource? {
        let priority = ["USB-PD", "Brick ID", "TypeC"]
        for name in priority {
            if let source = sources.first(where: {
                $0.name == name && ($0.winning?.maxPowerMW ?? 0) > 0
            }) {
                return source
            }
        }
        for name in priority {
            if let source = sources.first(where: { $0.name == name }) {
                return source
            }
        }
        return nil
    }

    // MARK: - 口状态

    /// 找到 (类型描述, 口号) 对应的物理口,返回它的 ConnectionActive。
    /// 匹配用描述字符串而不是数字类型码:两边都是系统原样给的,
    /// 且 MagSafe 与 USB-C 的口号会撞(各自从 1 数),描述能区分开。
    private func portConnectionActive(typeDescription: String, number: Int) -> Bool? {
        for cls in Self.portControllerClasses {
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(
                kIOMainPortDefault,
                IOServiceMatching(cls),
                &iterator
            ) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }

            while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
                defer { IOObjectRelease(service) }
                guard let desc = Self.property(service, "PortTypeDescription") as? String,
                      desc == typeDescription,
                      (Self.property(service, "PortNumber") as? NSNumber)?.intValue == number
                else { continue }
                return (Self.property(service, "ConnectionActive") as? NSNumber)?.boolValue
            }
        }
        return nil
    }

    // MARK: - 线缆芯片

    /// 读同一个口上线缆 e-marker(SOP' 应答)的身份。普通无芯片线没有这个
    /// 节点,返回 nil——那不是读取失败,是「线上没芯片」这个事实本身。
    private func readCableInfo(portType: Int, portNumber: Int) -> CableEmarkerInfo? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOPortTransportComponentCCUSBPDSOPp"),
            &iterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
            defer { IOObjectRelease(service) }
            guard (Self.property(service, "ParentBuiltInPortType") as? NSNumber)?.intValue == portType,
                  (Self.property(service, "ParentBuiltInPortNumber") as? NSNumber)?.intValue == portNumber
            else { continue }
            return Self.parseCable(read: { Self.property(service, $0) })
        }
        return nil
    }

    /// Metadata 里的 VDOs 是 4 字节小端 Data 数组;VID/PID 优先取 Metadata,
    /// 顶层键作后备(两处都有,以防哪代系统只填一处)。
    nonisolated static func parseCable(read: (String) -> Any?) -> CableEmarkerInfo? {
        let metadata = read("Metadata") as? [String: Any] ?? [:]
        let vdoData = (metadata["VDOs"] as? [Any])?.compactMap { $0 as? Data } ?? []
        let vdos = vdoData.compactMap { ChargeLinkVDODecoder.vdo(from: $0) }
        let vendorID = (metadata["Vendor ID"] as? NSNumber)?.intValue
            ?? (read("Vendor ID") as? NSNumber)?.intValue ?? 0
        let productID = (metadata["Product ID"] as? NSNumber)?.intValue
            ?? (read("Product ID") as? NSNumber)?.intValue ?? 0
        return ChargeLinkVDODecoder.cableInfo(vendorID: vendorID, productID: productID, vdos: vdos)
    }

    // MARK: - 工具

    private nonisolated static func property(_ service: io_service_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
    }
}
