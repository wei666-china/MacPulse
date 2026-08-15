import AppKit
import Darwin
import Foundation
import MacPulseCore

enum ProcessMonitorPhase: String, Sendable {
    case disabled
    case starting
    case live
    case partial
    case unavailable
    case sleeping
}

struct ProcessMonitorStatus: Sendable, Equatable {
    var phase: ProcessMonitorPhase = .starting
    var sampledProcessCount = 0
    var limitedProcessCount = 0
    var samplingDuration: TimeInterval = 0
    var lastUpdated: Date?
    var errorMessage: String?
}

struct ProcessSamplingResult: Sendable {
    var groups: [ProcessGroupSnapshot]
    var status: ProcessMonitorStatus
}

actor ProcessSampler {
    /// GPU 归因走原生 IORegistry，不用采集器那份按 CPU 取前 20、且被重标定过的估计值。
    private let gpuReader = GPUProcessReader()
    private var previousCounters: [Int32: ProcessCounters] = [:]
    private var smoothedCPU: [Int32: Double] = [:]

    func reset() {
        previousCounters.removeAll()
        smoothedCPU.removeAll()
    }

    func sample() -> ProcessSamplingResult {
        let startedAt = Date()
        let now = Date()
        let currentUID = getuid()
        let collection = collectCounters(at: now)

        guard !collection.counters.isEmpty else {
            return ProcessSamplingResult(
                groups: [],
                status: ProcessMonitorStatus(
                    phase: .unavailable,
                    sampledProcessCount: 0,
                    limitedProcessCount: collection.limitedCount,
                    samplingDuration: Date().timeIntervalSince(startedAt),
                    lastUpdated: now,
                    errorMessage: String(localized: "无法读取当前进程列表")
                )
            )
        }

        var snapshots: [ProcessSnapshot] = []
        snapshots.reserveCapacity(collection.counters.count)
        var nextSmoothed: [Int32: Double] = [:]

        for counter in collection.counters {
            let snapshot = ProcessAggregation.makeSnapshot(
                current: counter,
                previous: previousCounters[counter.pid],
                previousSmoothedCPU: smoothedCPU[counter.pid],
                currentUserID: currentUID
            )
            snapshots.append(snapshot)
            if let value = snapshot.smoothedCPUPercent {
                nextSmoothed[counter.pid] = value
            }
        }

        previousCounters = Dictionary(
            collection.counters.map { ($0.pid, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        smoothedCPU = nextSmoothed

        let groups = Array(ProcessAggregation.group(snapshots).prefix(50))
        return ProcessSamplingResult(
            groups: groups,
            status: ProcessMonitorStatus(
                phase: collection.limitedCount > 0 ? .partial : .live,
                sampledProcessCount: collection.counters.count,
                limitedProcessCount: collection.limitedCount,
                samplingDuration: Date().timeIntervalSince(startedAt),
                lastUpdated: now,
                errorMessage: nil
            )
        )
    }

    private func collectCounters(at timestamp: Date) -> (
        counters: [ProcessCounters],
        limitedCount: Int
    ) {
        let requestedCount = max(256, Int(proc_listallpids(nil, 0)) + 64)
        var pids = [pid_t](repeating: 0, count: requestedCount)
        let returnedCount = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard returnedCount > 0 else { return ([], 0) }

        // 正在退出的 App 会把 processIdentifier 报成 -1，同时有两个退出就会撞出重复键。
        // uniqueKeysWithValues 遇到重复键直接 trap，因此这里必须显式去重。
        let runningApps = NSWorkspace.shared.runningApplications
        let appsByPID = Dictionary(
            runningApps.lazy.compactMap { app -> (pid_t, RunningAppMetadata)? in
                let pid = app.processIdentifier
                guard pid > 0 else { return nil }
                return (pid, RunningAppMetadata(application: app))
            },
            uniquingKeysWith: { first, _ in first }
        )

        // 在 pid 循环之前一次性取回全部 GPU 累计时间，而不是每个进程查一次
        // IORegistry。整个 AGXAccelerator 子树只遍历一趟（实测约 0.4ms）。
        let gpuTimeByPID = gpuReader.accumulatedGPUTimeByPID()

        var counters: [ProcessCounters] = []
        counters.reserveCapacity(Int(returnedCount))
        var limitedCount = 0

        for pid in pids.prefix(Int(returnedCount)) where pid > 0 {
            if let value = readProcess(
                pid: pid,
                timestamp: timestamp,
                app: appsByPID[pid],
                gpuTimeNanoseconds: gpuTimeByPID?[pid]
            ) {
                counters.append(value)
                if value.isPermissionLimited {
                    limitedCount += 1
                }
            }
        }
        return (counters, limitedCount)
    }

    /// mach 时基缓存。timebase 是进程生命周期常量,取一次。
    private static let machTimebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(max(1, info.denom)))
    }()

    private static func machTicksToNanoseconds(_ ticks: UInt64) -> UInt64 {
        // 先除后乘会丢精度,先乘后除 64 位内可能溢出——
        // 拆成商与余数两段算,既不溢出也不丢精度。
        let (numer, denom) = machTimebase
        let quotient = ticks / denom
        let remainder = ticks % denom
        return quotient * numer + remainder * numer / denom
    }

    private func readProcess(
        pid: pid_t,
        timestamp: Date,
        app: RunningAppMetadata?,
        gpuTimeNanoseconds: UInt64?
    ) -> ProcessCounters? {
        var bsdInfo = proc_bsdinfo()
        let bsdSize = MemoryLayout<proc_bsdinfo>.size
        let bsdResult = withUnsafeMutablePointer(to: &bsdInfo) {
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, Int32(bsdSize))
        }

        var usage = rusage_info_v6()
        let usageResult = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
            }
        }

        let executablePath = processPath(pid: pid) ?? app?.executablePath
        let name = app?.localizedName
            ?? processName(pid: pid)
            ?? executablePath.map { URL(fileURLWithPath: $0).lastPathComponent }
        guard let name, !name.isEmpty else { return nil }

        var taskInfo = proc_taskinfo()
        let taskSize = MemoryLayout<proc_taskinfo>.size
        let taskResult = withUnsafeMutablePointer(to: &taskInfo) {
            proc_pidinfo(pid, PROC_PIDTASKINFO, 0, $0, Int32(taskSize))
        }

        let permissionLimited = usageResult != 0
        let start = usageResult == 0
            ? usage.ri_proc_start_abstime
            : (bsdResult == bsdSize ? UInt64(max(0, bsdInfo.pbi_start_tvsec)) : UInt64(pid))
        let parentPID = bsdResult == bsdSize ? Int32(bitPattern: bsdInfo.pbi_ppid) : 0
        let userID = bsdResult == bsdSize ? bsdInfo.pbi_uid : UInt32.max
        let wakeups = usageResult == 0
            ? usage.ri_pkg_idle_wkups &+ usage.ri_interrupt_wkups
            : nil

        return ProcessCounters(
            pid: pid,
            parentPID: parentPID,
            userID: userID,
            startAbstime: start,
            timestamp: timestamp,
            launchDate: bsdResult == bsdSize && bsdInfo.pbi_start_tvsec > 0
                ? Date(timeIntervalSince1970: TimeInterval(bsdInfo.pbi_start_tvsec))
                : app?.launchDate,
            // ri_*_time 是 mach 时基单位,不是纳秒——Apple Silicon 上 1 tick =
            // 125/3 ≈ 41.67ns。不换算,全 App 的按进程 CPU% 会集体低 41 倍,
            // 而「其余由小进程分摊」的长尾说明恰好把亏空藏住(实测抓获:
            // yes 烧机进程原始差分 45ms/2s=2.3%,换算后 95%,后者才对)。
            // Intel 时基 1/1,同一算式两边通用。
            userTimeNanoseconds: usageResult == 0 ? Self.machTicksToNanoseconds(usage.ri_user_time) : 0,
            systemTimeNanoseconds: usageResult == 0 ? Self.machTicksToNanoseconds(usage.ri_system_time) : 0,
            physicalFootprintBytes: usageResult == 0 ? usage.ri_phys_footprint : nil,
            diskReadBytes: usageResult == 0 ? usage.ri_diskio_bytesread : nil,
            diskWriteBytes: usageResult == 0 ? usage.ri_diskio_byteswritten : nil,
            wakeups: wakeups,
            energyNanojoules: usageResult == 0 ? usage.ri_energy_nj : nil,
            gpuTimeNanoseconds: gpuTimeNanoseconds,
            threadCount: taskResult == taskSize ? Int(taskInfo.pti_threadnum) : nil,
            displayName: name,
            executablePath: executablePath,
            bundleIdentifier: app?.bundleIdentifier,
            isRegularApplication: app?.isRegularApplication ?? false,
            isPermissionLimited: permissionLimited
        )
    }

    private func processName(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return decodeCString(buffer)
    }

    private func processPath(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return decodeCString(buffer)
    }

    private func decodeCString(_ buffer: [CChar]) -> String {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

private struct RunningAppMetadata {
    var localizedName: String?
    var bundleIdentifier: String?
    var executablePath: String?
    var launchDate: Date?
    var isRegularApplication: Bool

    init(application: NSRunningApplication) {
        localizedName = application.localizedName
        bundleIdentifier = application.bundleIdentifier
        executablePath = application.executableURL?.path
        launchDate = application.launchDate
        isRegularApplication = application.activationPolicy == .regular
    }
}
