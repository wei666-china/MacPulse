import Darwin
import Foundation
import MacPulseCore

/// 不依赖采集器的本机读数。
///
/// 这里的每一项都用系统公开 API 直接读取，采集器在不在线都一样准。内存、每核 CPU
/// 原先要么走 mactop、要么用一套和活动监视器对不上的口径，现在统一收到这里。
final class SystemFallbackReader {
    private var previousTicks: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)?
    private var previousCoreTicks: [(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)]?
    /// 换页速率差分的基线。跨睡眠不重置:唤醒后第一拍 elapsed 巨大、速率被摊薄,
    /// 但瓶颈诊断的取样窗口整个都在唤醒之后,不受影响。
    private var previousVMCounters: (counters: VMCumulativeCounters, date: Date)?

    /// VM 统计的计数单位是内核页。
    ///
    /// 不能用 `getpagesize()`（用户态页大小，概念不同；一旦与内核页不一致，
    /// 所有内存数字会整体差 4 倍），也不能直接读全局变量 `vm_kernel_page_size`
    /// ——它在 C 里是可变全局量，Swift 6 严格并发会拒绝。用函数式的
    /// `host_page_size` 取一次并缓存。
    private let pageSize: UInt64 = {
        var size: vm_size_t = 0
        guard host_page_size(mach_host_self(), &size) == KERN_SUCCESS, size > 0 else {
            return UInt64(getpagesize())
        }
        return UInt64(size)
    }()

    func read() -> DeepMetrics {
        DeepMetrics(
            cpuUsagePercent: cpuUsage(),
            thermalLevel: thermalLevel(),
            collectorAvailable: false
        )
    }

    private func cpuUsage() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let current = (
            user: info.cpu_ticks.0,
            system: info.cpu_ticks.1,
            idle: info.cpu_ticks.2,
            nice: info.cpu_ticks.3
        )
        defer { previousTicks = current }
        guard let previousTicks else { return nil }
        return MetricMath.cpuUsagePercent(previous: previousTicks, current: current)
    }

    /// 每个逻辑核的占用率，按硬件索引排列（能效核在前，性能核在后）。
    ///
    /// 首次调用返回 nil —— 没有基线就没有差分，宁可显示「不可用」也不要凭空给 0。
    func perCoreUsage() -> [Double]? {
        var coreCount: natural_t = 0
        var infoArray: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &coreCount,
            &infoArray,
            &infoCount
        )
        guard result == KERN_SUCCESS, let infoArray, coreCount > 0 else { return nil }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(bitPattern: infoArray),
                vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            )
        }

        let stride = Int(CPU_STATE_MAX)
        var current: [(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)] = []
        current.reserveCapacity(Int(coreCount))
        for core in 0..<Int(coreCount) {
            let base = core * stride
            current.append((
                user: UInt32(bitPattern: infoArray[base + Int(CPU_STATE_USER)]),
                system: UInt32(bitPattern: infoArray[base + Int(CPU_STATE_SYSTEM)]),
                idle: UInt32(bitPattern: infoArray[base + Int(CPU_STATE_IDLE)]),
                nice: UInt32(bitPattern: infoArray[base + Int(CPU_STATE_NICE)])
            ))
        }

        defer { previousCoreTicks = current }
        // 核数变化（理论上不会，但别为此崩）时丢弃旧基线重新开始。
        guard let previous = previousCoreTicks, previous.count == current.count else { return nil }

        return zip(previous, current).map { MetricMath.cpuUsagePercent(previous: $0, current: $1) ?? 0 }
    }

    /// 统一内存分项。口径见 `MemoryBreakdown`。
    /// 内存吃紧的三个硬信号里,swap 与压力等级要单独从 sysctl 读。
    /// 全是公开只读接口,无权限要求。
    func memoryExtras() -> MemorySnapshotExtras {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        var swapUsed: UInt64?
        var swapTotal: UInt64?
        if sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 {
            swapUsed = usage.xsu_used
            swapTotal = usage.xsu_total
        }

        var level: Int32 = 0
        var levelSize = MemoryLayout<Int32>.size
        let pressure = sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0) == 0
            ? Int(level) : nil

        return MemorySnapshotExtras(
            swapUsedBytes: swapUsed,
            swapTotalBytes: swapTotal,
            pressureLevel: pressure
        )
    }

    /// 换页/交换/压缩的瞬时速率。首次调用返回 nil——没有基线就没有差分,
    /// 宁可「不可用」也不凭空给 0(与 perCoreUsage 同一条规矩)。
    ///
    /// 为什么独立做一次 host_statistics64 而不搭 memoryBreakdown 的车:
    /// 差分需要稳定的时间戳配对,揉进别人的调用路径,哪天那边加了门控
    /// 或换了节奏,这边的速率就悄悄失真。µs 级 syscall,独立跑不心疼。
    func memoryRates() -> MemoryRates? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let current = VMCumulativeCounters(
            pageins: UInt64(stats.pageins),
            pageouts: UInt64(stats.pageouts),
            swapins: UInt64(stats.swapins),
            swapouts: UInt64(stats.swapouts),
            compressions: UInt64(stats.compressions),
            decompressions: UInt64(stats.decompressions)
        )
        let now = Date()
        defer { previousVMCounters = (current, now) }
        guard let previous = previousVMCounters else { return nil }
        return MemoryRates.compute(
            previous: previous.counters,
            current: current,
            elapsed: now.timeIntervalSince(previous.date),
            pageSize: pageSize
        )
    }

    func memoryBreakdown() -> MemoryBreakdown? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let counts = VMPageCounts(
            free: UInt64(stats.free_count),
            active: UInt64(stats.active_count),
            inactive: UInt64(stats.inactive_count),
            speculative: UInt64(stats.speculative_count),
            wired: UInt64(stats.wire_count),
            purgeable: UInt64(stats.purgeable_count),
            anonymous: UInt64(stats.internal_page_count),
            fileBacked: UInt64(stats.external_page_count),
            compressorOccupied: UInt64(stats.compressor_page_count),
            uncompressedInCompressor: UInt64(stats.total_uncompressed_pages_in_compressor)
        )

        let swap = swapUsage()
        return MemoryBreakdown(
            counts: counts,
            pageSize: pageSize,
            totalBytes: ProcessInfo.processInfo.physicalMemory,
            swapTotalBytes: swap?.total,
            swapUsedBytes: swap?.used,
            pressureLevel: memoryPressureLevel()
        )
    }

    private func swapUsage() -> (total: UInt64, used: UInt64)? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return (total: usage.xsu_total, used: usage.xsu_used)
    }

    private func memoryPressureLevel() -> MemoryPressureLevel {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else {
            return .unknown
        }
        return MemoryPressureLevel(rawValue: Int(level)) ?? .unknown
    }

    private func thermalLevel() -> ThermalLevel {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .unknown
        }
    }
}
