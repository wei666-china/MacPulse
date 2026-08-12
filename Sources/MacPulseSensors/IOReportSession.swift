import Foundation

// IOReport(/usr/lib/libIOReport.dylib)私有 C 接口的运行时绑定。
// 读取思路与通道匹配规则改编自 mactop(MIT,Copyright (c) 2024-2026
// Carsen Klock)的 ioreport.m,见 THIRD_PARTY_NOTICES.md。
//
// 用 dlsym 而不是链接期 -lIOReport:符号缺失时得到的是可判定的 nil,
// 而不是启动即崩;哪天苹果动了这个库,采集器能降级上报而不是拖死整条链。
//
// 内存纪律(mactop 的 PMP 路径泄漏就是教训):
// - Copy/Create 系返回 +1,一律 takeRetainedValue 交给 ARC;
// - Get 系返回借用引用,一律 takeUnretainedValue;
// - 通道字典必须保持**原生 CFDictionary**传递——IOReportChannelGetChannelName
//   会往字典里写缓存,桥接成 Swift 字典(不可变)当场抛 NSException(实测)。

private typealias FnCopyChannelsInGroup =
    @convention(c) (CFString, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
private typealias FnMergeChannels =
    @convention(c) (CFMutableDictionary, CFMutableDictionary, CFTypeRef?) -> Void
private typealias FnCreateSubscription =
    @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary,
                    UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?)
        -> Unmanaged<CFTypeRef>?
private typealias FnCreateSamples =
    @convention(c) (CFTypeRef, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
private typealias FnCreateSamplesDelta =
    @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
private typealias FnChannelGetString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
private typealias FnChannelGetFormat = @convention(c) (CFDictionary) -> Int32
private typealias FnSimpleGetInteger = @convention(c) (CFDictionary, Int32) -> Int64
private typealias FnStateGetCount = @convention(c) (CFDictionary) -> Int32
private typealias FnStateGetName = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?
private typealias FnStateGetResidency = @convention(c) (CFDictionary, Int32) -> Int64

/// 一条通道在一个采样窗口里的读数。
public struct IOReportReading: Sendable {
    public let group: String
    public let subgroup: String
    public let channel: String
    /// 单位标签(能耗通道:"mJ"/"uJ"/"nJ")。尾部空格已剥。
    public let unit: String?
    /// 简单计数通道(format 1)的增量值。
    public let simpleValue: Int64?
    /// 状态驻留通道(format 2):各状态名与窗口内驻留量。
    public let states: [(name: String, residency: Int64)]?
}

/// 一次采样窗口的结果。
public struct IOReportWindow: Sendable {
    public let readings: [IOReportReading]
    /// 实测窗口时长(纳秒)。锚点在 CreateSamples 返回**之后**,
    /// 把采样调用本身的几十毫秒开销从分母里消掉,否则速率类读数会低报一到两成。
    public let elapsedNanoseconds: UInt64
}

public final class IOReportSession: @unchecked Sendable {
    private let copyChannels: FnCopyChannelsInGroup
    private let createSamples: FnCreateSamples
    private let createDelta: FnCreateSamplesDelta
    private let getGroup: FnChannelGetString
    private let getSubgroup: FnChannelGetString
    private let getName: FnChannelGetString
    private let getUnit: FnChannelGetString
    private let getFormat: FnChannelGetFormat
    private let simpleValue: FnSimpleGetInteger
    private let stateCount: FnStateGetCount
    private let stateName: FnStateGetName
    private let stateResidency: FnStateGetResidency

    private let channels: CFMutableDictionary
    private let subscription: CFTypeRef
    private var timebase = mach_timebase_info_data_t()

    /// groups:要订阅的通道组。找不到任何一组时整体失败(返回 nil),
    /// 找到部分时按找到的走——芯片代际差异是常态。
    public init?(groups: [String]) {
        guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return nil }
        func sym<T>(_ name: String, _ type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: T.self)
        }
        guard
            let copyChannels = sym("IOReportCopyChannelsInGroup", FnCopyChannelsInGroup.self),
            let merge = sym("IOReportMergeChannels", FnMergeChannels.self),
            let createSubscription = sym("IOReportCreateSubscription", FnCreateSubscription.self),
            let createSamples = sym("IOReportCreateSamples", FnCreateSamples.self),
            let createDelta = sym("IOReportCreateSamplesDelta", FnCreateSamplesDelta.self),
            let getGroup = sym("IOReportChannelGetGroup", FnChannelGetString.self),
            let getSubgroup = sym("IOReportChannelGetSubGroup", FnChannelGetString.self),
            let getName = sym("IOReportChannelGetChannelName", FnChannelGetString.self),
            let getUnit = sym("IOReportChannelGetUnitLabel", FnChannelGetString.self),
            let getFormat = sym("IOReportChannelGetFormat", FnChannelGetFormat.self),
            let simpleValue = sym("IOReportSimpleGetIntegerValue", FnSimpleGetInteger.self),
            let stateCount = sym("IOReportStateGetCount", FnStateGetCount.self),
            let stateName = sym("IOReportStateGetNameForIndex", FnStateGetName.self),
            let stateResidency = sym("IOReportStateGetResidency", FnStateGetResidency.self)
        else { return nil }

        self.copyChannels = copyChannels
        self.createSamples = createSamples
        self.createDelta = createDelta
        self.getGroup = getGroup
        self.getSubgroup = getSubgroup
        self.getName = getName
        self.getUnit = getUnit
        self.getFormat = getFormat
        self.simpleValue = simpleValue
        self.stateCount = stateCount
        self.stateName = stateName
        self.stateResidency = stateResidency

        var merged: CFMutableDictionary?
        for group in groups {
            guard let dict = copyChannels(group as CFString, nil, 0, 0, 0)?.takeRetainedValue() else {
                continue
            }
            if let target = merged {
                merge(target, dict, nil)
            } else {
                merged = dict
            }
        }
        guard let channels = merged else { return nil }

        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let subscription = createSubscription(nil, channels, &subscribed, 0, nil)?
            .takeRetainedValue() else { return nil }
        // subscribed 字典我们不用,但它是 +1 出参,不接住就漏。
        _ = subscribed?.takeRetainedValue()

        self.channels = channels
        self.subscription = subscription
        mach_timebase_info(&timebase)
    }

    /// 阻塞采样:取样→睡满窗口→再取样→算差。窗口内这条线程只归它用,
    /// 调用方(采集器)本来就是专职进程,和 mactop headless 的节奏一致。
    public func sample(windowSeconds: Double) -> IOReportWindow? {
        guard let first = createSamples(subscription, channels, nil)?.takeRetainedValue() else {
            return nil
        }
        let start = mach_absolute_time()
        usleep(UInt32(max(0.05, windowSeconds) * 1_000_000))
        guard let second = createSamples(subscription, channels, nil)?.takeRetainedValue() else {
            return nil
        }
        let end = mach_absolute_time()
        guard let delta = createDelta(first, second, nil)?.takeRetainedValue() else { return nil }

        let elapsedNs = (end - start) * UInt64(timebase.numer) / UInt64(timebase.denom)
        return IOReportWindow(readings: readings(from: delta), elapsedNanoseconds: elapsedNs)
    }

    private func readings(from delta: CFDictionary) -> [IOReportReading] {
        let key = "IOReportChannels" as CFString
        guard let raw = CFDictionaryGetValue(delta, Unmanaged.passUnretained(key).toOpaque()) else {
            return []
        }
        let array = unsafeBitCast(raw, to: CFArray.self)
        let count = CFArrayGetCount(array)
        var result: [IOReportReading] = []
        result.reserveCapacity(count)

        for index in 0..<count {
            guard let pointer = CFArrayGetValueAtIndex(array, index) else { continue }
            let channel = unsafeBitCast(pointer, to: CFDictionary.self)
            let group = getGroup(channel)?.takeUnretainedValue() as String? ?? ""
            let subgroup = getSubgroup(channel)?.takeUnretainedValue() as String? ?? ""
            let name = getName(channel)?.takeUnretainedValue() as String? ?? ""
            var unit = getUnit(channel)?.takeUnretainedValue() as String?
            unit = unit.map { $0.trimmingCharacters(in: .whitespaces) }

            switch getFormat(channel) {
            case 1: // simple
                result.append(IOReportReading(
                    group: group, subgroup: subgroup, channel: name, unit: unit,
                    simpleValue: simpleValue(channel, 0), states: nil
                ))
            case 2: // state residency
                let stateTotal = stateCount(channel)
                guard stateTotal > 0 else { continue }
                var states: [(String, Int64)] = []
                states.reserveCapacity(Int(stateTotal))
                for stateIndex in 0..<stateTotal {
                    let label = stateName(channel, stateIndex)?.takeUnretainedValue() as String? ?? ""
                    states.append((label, stateResidency(channel, stateIndex)))
                }
                result.append(IOReportReading(
                    group: group, subgroup: subgroup, channel: name, unit: unit,
                    simpleValue: nil, states: states
                ))
            default:
                // 直方图等格式本期不消费,跳过而不是硬解。
                continue
            }
        }
        return result
    }
}
