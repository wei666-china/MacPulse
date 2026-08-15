import Foundation

public enum ProcessCategory: String, Codable, Sendable, CaseIterable {
    case application
    case background
    case system

    public var title: String {
        switch self {
        case .application: String(localized: "应用")
        case .background: String(localized: "后台")
        case .system: String(localized: "系统")
        }
    }
}

public enum ProcessMetricKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case cpu
    case memory
    case gpu
    case disk
    case energy

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: String(localized: "内存")
        case .gpu: "GPU"
        case .disk: String(localized: "磁盘")
        case .energy: String(localized: "能耗")
        }
    }

    /// 需要额外说明口径的指标，在列表上方显示一行注脚。
    public var caption: String? {
        switch self {
        case .gpu:
            // 这是 Metal 命令缓冲时间，各进程之和不等于系统 GPU 活跃度：
            // 合成器和驱动自身的开销落在别处。所以只报 ms/s，不报百分比。
            String(localized: "GPU 时间是各 App 提交的 Metal 命令耗时，加起来不等于系统 GPU 占用率。")
        case .memory:
            String(localized: "各 App 物理内存之和大于「已使用」，因为共享内存会被重复计入。")
        default:
            nil
        }
    }
}

public enum EnergyImpactLevel: String, Codable, Sendable, Comparable {
    case unavailable
    case low
    case medium
    case high

    public var title: String {
        switch self {
        case .unavailable: String(localized: "不可用")
        case .low: String(localized: "低")
        case .medium: String(localized: "中")
        case .high: String(localized: "高")
        }
    }

    public static func < (lhs: EnergyImpactLevel, rhs: EnergyImpactLevel) -> Bool {
        let order: [EnergyImpactLevel] = [.unavailable, .low, .medium, .high]
        return (order.firstIndex(of: lhs) ?? 0) < (order.firstIndex(of: rhs) ?? 0)
    }
}

public struct ProcessCounters: Sendable, Equatable {
    public var pid: Int32
    public var parentPID: Int32
    public var userID: UInt32
    public var startAbstime: UInt64
    public var timestamp: Date
    public var launchDate: Date?
    public var userTimeNanoseconds: UInt64
    public var systemTimeNanoseconds: UInt64
    public var physicalFootprintBytes: UInt64?
    public var diskReadBytes: UInt64?
    public var diskWriteBytes: UInt64?
    public var wakeups: UInt64?
    public var energyNanojoules: UInt64?
    /// 累计 GPU 时间（纳秒），来自 IORegistry 的 AGXDeviceUserClient。
    /// 单调累计量，与其它计数器一样靠差分求速率。
    ///
    /// 刻意不用采集器里现成的 `gpu_ms_per_sec`：那个值只覆盖 CPU 前 20 名、
    /// 是重标定过的估计而非测量、且与进程采样节奏不同源。详见 GPUProcessReader。
    public var gpuTimeNanoseconds: UInt64?
    public var threadCount: Int?
    public var displayName: String
    public var executablePath: String?
    public var bundleIdentifier: String?
    public var isRegularApplication: Bool
    public var isPermissionLimited: Bool

    public init(
        pid: Int32,
        parentPID: Int32 = 0,
        userID: UInt32 = 0,
        startAbstime: UInt64,
        timestamp: Date,
        launchDate: Date? = nil,
        userTimeNanoseconds: UInt64 = 0,
        systemTimeNanoseconds: UInt64 = 0,
        physicalFootprintBytes: UInt64? = nil,
        diskReadBytes: UInt64? = nil,
        diskWriteBytes: UInt64? = nil,
        wakeups: UInt64? = nil,
        energyNanojoules: UInt64? = nil,
        gpuTimeNanoseconds: UInt64? = nil,
        threadCount: Int? = nil,
        displayName: String,
        executablePath: String? = nil,
        bundleIdentifier: String? = nil,
        isRegularApplication: Bool = false,
        isPermissionLimited: Bool = false
    ) {
        self.pid = pid
        self.parentPID = parentPID
        self.userID = userID
        self.startAbstime = startAbstime
        self.timestamp = timestamp
        self.launchDate = launchDate
        self.userTimeNanoseconds = userTimeNanoseconds
        self.systemTimeNanoseconds = systemTimeNanoseconds
        self.physicalFootprintBytes = physicalFootprintBytes
        self.diskReadBytes = diskReadBytes
        self.diskWriteBytes = diskWriteBytes
        self.wakeups = wakeups
        self.energyNanojoules = energyNanojoules
        self.gpuTimeNanoseconds = gpuTimeNanoseconds
        self.threadCount = threadCount
        self.displayName = displayName
        self.executablePath = executablePath
        self.bundleIdentifier = bundleIdentifier
        self.isRegularApplication = isRegularApplication
        self.isPermissionLimited = isPermissionLimited
    }
}

public struct ProcessSnapshot: Sendable, Equatable, Identifiable {
    public var id: Int32 { pid }
    public var pid: Int32
    public var parentPID: Int32
    public var startAbstime: UInt64
    public var stableIdentifier: String
    public var displayName: String
    public var bundleIdentifier: String?
    public var executablePath: String?
    public var launchDate: Date?
    public var category: ProcessCategory
    public var cpuPercent: Double?
    public var smoothedCPUPercent: Double?
    public var physicalFootprintBytes: UInt64?
    public var diskReadBytesPerSecond: Double?
    public var diskWriteBytesPerSecond: Double?
    public var wakeupsPerSecond: Double?
    public var energyNanojoulesPerSecond: Double?
    /// 每秒消耗的 GPU 时间（纳秒/秒）。界面按 ms/s 展示。
    public var gpuNanosecondsPerSecond: Double?
    public var threadCount: Int?
    public var isEstablishingBaseline: Bool
    public var isPermissionLimited: Bool

    public init(
        pid: Int32,
        parentPID: Int32,
        startAbstime: UInt64,
        stableIdentifier: String,
        displayName: String,
        bundleIdentifier: String?,
        executablePath: String?,
        launchDate: Date?,
        category: ProcessCategory,
        cpuPercent: Double?,
        smoothedCPUPercent: Double?,
        physicalFootprintBytes: UInt64?,
        diskReadBytesPerSecond: Double?,
        diskWriteBytesPerSecond: Double?,
        wakeupsPerSecond: Double?,
        energyNanojoulesPerSecond: Double?,
        gpuNanosecondsPerSecond: Double? = nil,
        threadCount: Int?,
        isEstablishingBaseline: Bool,
        isPermissionLimited: Bool
    ) {
        self.pid = pid
        self.parentPID = parentPID
        self.startAbstime = startAbstime
        self.stableIdentifier = stableIdentifier
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        self.executablePath = executablePath
        self.launchDate = launchDate
        self.category = category
        self.cpuPercent = cpuPercent
        self.smoothedCPUPercent = smoothedCPUPercent
        self.physicalFootprintBytes = physicalFootprintBytes
        self.diskReadBytesPerSecond = diskReadBytesPerSecond
        self.diskWriteBytesPerSecond = diskWriteBytesPerSecond
        self.wakeupsPerSecond = wakeupsPerSecond
        self.energyNanojoulesPerSecond = energyNanojoulesPerSecond
        self.gpuNanosecondsPerSecond = gpuNanosecondsPerSecond
        self.threadCount = threadCount
        self.isEstablishingBaseline = isEstablishingBaseline
        self.isPermissionLimited = isPermissionLimited
    }
}

public struct ProcessGroupSnapshot: Sendable, Equatable, Identifiable {
    public var id: String { stableIdentifier }
    public var stableIdentifier: String
    public var displayName: String
    public var bundleIdentifier: String?
    public var executablePath: String?
    public var category: ProcessCategory
    public var primaryPID: Int32
    public var children: [ProcessSnapshot]
    public var cpuPercent: Double?
    public var smoothedCPUPercent: Double?
    public var physicalFootprintBytes: UInt64?
    public var diskReadBytesPerSecond: Double?
    public var diskWriteBytesPerSecond: Double?
    public var wakeupsPerSecond: Double?
    public var energyNanojoulesPerSecond: Double?
    /// 组内各进程 GPU 时间之和（纳秒/秒）。
    public var gpuNanosecondsPerSecond: Double?
    public var energyImpact: EnergyImpactLevel
    public var compositeScore: Double
    public var isMacPulse: Bool
    public var isEstablishingBaseline: Bool
    public var isPermissionLimited: Bool

    public init(
        stableIdentifier: String,
        displayName: String,
        bundleIdentifier: String? = nil,
        executablePath: String? = nil,
        category: ProcessCategory,
        primaryPID: Int32,
        children: [ProcessSnapshot],
        cpuPercent: Double?,
        smoothedCPUPercent: Double?,
        physicalFootprintBytes: UInt64?,
        diskReadBytesPerSecond: Double?,
        diskWriteBytesPerSecond: Double?,
        wakeupsPerSecond: Double?,
        energyNanojoulesPerSecond: Double?,
        gpuNanosecondsPerSecond: Double? = nil,
        energyImpact: EnergyImpactLevel = .unavailable,
        compositeScore: Double = 0,
        isMacPulse: Bool = false,
        isEstablishingBaseline: Bool = false,
        isPermissionLimited: Bool = false
    ) {
        self.stableIdentifier = stableIdentifier
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        self.executablePath = executablePath
        self.category = category
        self.primaryPID = primaryPID
        self.children = children
        self.cpuPercent = cpuPercent
        self.smoothedCPUPercent = smoothedCPUPercent
        self.physicalFootprintBytes = physicalFootprintBytes
        self.diskReadBytesPerSecond = diskReadBytesPerSecond
        self.diskWriteBytesPerSecond = diskWriteBytesPerSecond
        self.wakeupsPerSecond = wakeupsPerSecond
        self.energyNanojoulesPerSecond = energyNanojoulesPerSecond
        self.gpuNanosecondsPerSecond = gpuNanosecondsPerSecond
        self.energyImpact = energyImpact
        self.compositeScore = compositeScore
        self.isMacPulse = isMacPulse
        self.isEstablishingBaseline = isEstablishingBaseline
        self.isPermissionLimited = isPermissionLimited
    }
}

public enum ProcessDeltaMath {
    public static func rate(
        previous: UInt64?,
        current: UInt64?,
        elapsed: TimeInterval
    ) -> Double? {
        guard
            elapsed > 0,
            let previous,
            let current,
            current >= previous
        else {
            return nil
        }
        return Double(current - previous) / elapsed
    }

    public static func cpuPercent(
        previousUser: UInt64,
        previousSystem: UInt64,
        currentUser: UInt64,
        currentSystem: UInt64,
        elapsed: TimeInterval
    ) -> Double? {
        guard
            elapsed > 0,
            currentUser >= previousUser,
            currentSystem >= previousSystem
        else {
            return nil
        }
        let usedNanoseconds = (currentUser - previousUser) + (currentSystem - previousSystem)
        let result = Double(usedNanoseconds) / (elapsed * 1_000_000_000) * 100
        return result.isFinite ? max(0, result) : nil
    }

    public static func smooth(
        previous: Double?,
        current: Double?,
        elapsed: TimeInterval,
        window: TimeInterval = 10
    ) -> Double? {
        guard let current, current.isFinite else { return previous }
        guard let previous, previous.isFinite, window > 0 else { return current }
        let alpha = 1 - exp(-max(0, elapsed) / window)
        return previous + alpha * (current - previous)
    }
}

public enum ProcessAggregation {
    public static let macPulseIdentifier = "com.local.MacPulse"

    public static func makeSnapshot(
        current: ProcessCounters,
        previous: ProcessCounters?,
        previousSmoothedCPU: Double?,
        currentUserID: UInt32
    ) -> ProcessSnapshot {
        let canUsePrevious = previous?.startAbstime == current.startAbstime
            && previous?.isPermissionLimited == false
            && !current.isPermissionLimited
        let elapsed = canUsePrevious
            ? current.timestamp.timeIntervalSince(previous?.timestamp ?? current.timestamp)
            : 0
        let cpu = canUsePrevious
            ? ProcessDeltaMath.cpuPercent(
                previousUser: previous?.userTimeNanoseconds ?? 0,
                previousSystem: previous?.systemTimeNanoseconds ?? 0,
                currentUser: current.userTimeNanoseconds,
                currentSystem: current.systemTimeNanoseconds,
                elapsed: elapsed
            )
            : nil
        let category: ProcessCategory = current.userID == 0
            ? .system
            : (current.isRegularApplication ? .application : .background)

        return ProcessSnapshot(
            pid: current.pid,
            parentPID: current.parentPID,
            startAbstime: current.startAbstime,
            stableIdentifier: current.bundleIdentifier
                ?? current.executablePath
                ?? "pid:\(current.pid):\(current.startAbstime)",
            displayName: current.displayName,
            bundleIdentifier: current.bundleIdentifier,
            executablePath: current.executablePath,
            launchDate: current.launchDate,
            category: current.userID == currentUserID ? category : .system,
            cpuPercent: cpu,
            smoothedCPUPercent: ProcessDeltaMath.smooth(
                previous: canUsePrevious ? previousSmoothedCPU : nil,
                current: cpu,
                elapsed: elapsed
            ),
            physicalFootprintBytes: current.physicalFootprintBytes,
            diskReadBytesPerSecond: canUsePrevious
                ? ProcessDeltaMath.rate(
                    previous: previous?.diskReadBytes,
                    current: current.diskReadBytes,
                    elapsed: elapsed
                )
                : nil,
            diskWriteBytesPerSecond: canUsePrevious
                ? ProcessDeltaMath.rate(
                    previous: previous?.diskWriteBytes,
                    current: current.diskWriteBytes,
                    elapsed: elapsed
                )
                : nil,
            wakeupsPerSecond: canUsePrevious
                ? ProcessDeltaMath.rate(
                    previous: previous?.wakeups,
                    current: current.wakeups,
                    elapsed: elapsed
                )
                : nil,
            energyNanojoulesPerSecond: canUsePrevious
                ? ProcessDeltaMath.rate(
                    previous: previous?.energyNanojoules,
                    current: current.energyNanojoules,
                    elapsed: elapsed
                )
                : nil,
            // 复用同一套差分：其中的单调计数器守卫（current >= previous）
            // 与 startAbstime 守卫已经免费处理了 pid 复用的情况。
            gpuNanosecondsPerSecond: canUsePrevious
                ? ProcessDeltaMath.rate(
                    previous: previous?.gpuTimeNanoseconds,
                    current: current.gpuTimeNanoseconds,
                    elapsed: elapsed
                )
                : nil,
            threadCount: current.threadCount,
            isEstablishingBaseline: !canUsePrevious,
            isPermissionLimited: current.isPermissionLimited
        )
    }

    /// 榜单截断的并集规则。单一综合分截 top-N 会把「GPU 重、其他都轻」的
    /// 进程(本地跑推理的典型形状)整个扔掉——评审构造 55 个普通进程 +
    /// 1 个 GPU-only,后者 rank 56,在采样层就消失,诊断层再怎么找都点不到名。
    /// 解法:综合分前 limit 名之外,GPU 时间过线者按 GPU 序补进(至多 gpuExtra 名)。
    public static func topGroups(
        _ groups: [ProcessGroupSnapshot],
        limit: Int = 50,
        gpuFloorNanoseconds: Double = 2e8,
        gpuExtra: Int = 5
    ) -> [ProcessGroupSnapshot] {
        var result = Array(groups.prefix(limit))
        let kept = Set(result.map(\.stableIdentifier))
        let gpuHeavy = groups.dropFirst(limit)
            .filter { ($0.gpuNanosecondsPerSecond ?? 0) >= gpuFloorNanoseconds }
            .sorted { ($0.gpuNanosecondsPerSecond ?? 0) > ($1.gpuNanosecondsPerSecond ?? 0) }
            .prefix(gpuExtra)
        for group in gpuHeavy where !kept.contains(group.stableIdentifier) {
            result.append(group)
        }
        return result
    }

    public static func group(_ snapshots: [ProcessSnapshot]) -> [ProcessGroupSnapshot] {
        let byPID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.pid, $0) })
        var buckets: [String: [ProcessSnapshot]] = [:]
        var identities: [String: GroupIdentity] = [:]

        for snapshot in snapshots {
            let identity = groupIdentity(for: snapshot, byPID: byPID)
            buckets[identity.identifier, default: []].append(snapshot)
            identities[identity.identifier] = identity
        }

        var groups = buckets.compactMap { identifier, children -> ProcessGroupSnapshot? in
            guard let identity = identities[identifier], !children.isEmpty else { return nil }
            let sortedChildren = children.sorted {
                ($0.smoothedCPUPercent ?? 0, $0.physicalFootprintBytes ?? 0)
                    > ($1.smoothedCPUPercent ?? 0, $1.physicalFootprintBytes ?? 0)
            }
            let primary = sortedChildren.first(where: { $0.bundleIdentifier != nil })
                ?? sortedChildren.first
            guard let primary else { return nil }
            let category: ProcessCategory = children.contains(where: { $0.category == .application })
                ? .application
                : (children.allSatisfy { $0.category == .system } ? .system : .background)

            return ProcessGroupSnapshot(
                stableIdentifier: identifier,
                displayName: identity.displayName,
                bundleIdentifier: identity.bundleIdentifier,
                executablePath: identity.executablePath ?? primary.executablePath,
                category: category,
                primaryPID: primary.pid,
                children: sortedChildren,
                cpuPercent: sum(children.map(\.cpuPercent)),
                smoothedCPUPercent: sum(children.map(\.smoothedCPUPercent)),
                physicalFootprintBytes: sumIntegers(children.map(\.physicalFootprintBytes)),
                diskReadBytesPerSecond: sum(children.map(\.diskReadBytesPerSecond)),
                diskWriteBytesPerSecond: sum(children.map(\.diskWriteBytesPerSecond)),
                wakeupsPerSecond: sum(children.map(\.wakeupsPerSecond)),
                energyNanojoulesPerSecond: sum(children.map(\.energyNanojoulesPerSecond)),
                gpuNanosecondsPerSecond: sum(children.map(\.gpuNanosecondsPerSecond)),
                isMacPulse: identifier == macPulseIdentifier,
                isEstablishingBaseline: children.allSatisfy(\.isEstablishingBaseline),
                isPermissionLimited: children.contains(where: \.isPermissionLimited)
            )
        }

        applyEnergyLevelsAndScores(to: &groups)
        return groups.sorted {
            if $0.isMacPulse != $1.isMacPulse { return $0.isMacPulse }
            return $0.compositeScore > $1.compositeScore
        }
    }

    private struct GroupIdentity {
        var identifier: String
        var displayName: String
        var bundleIdentifier: String?
        var executablePath: String?
    }

    private static func groupIdentity(
        for snapshot: ProcessSnapshot,
        byPID: [Int32: ProcessSnapshot]
    ) -> GroupIdentity {
        var candidate = snapshot
        var visited = Set<Int32>()
        var appFallback: GroupIdentity?

        for _ in 0..<16 {
            if isMacPulse(candidate) {
                return GroupIdentity(
                    identifier: macPulseIdentifier,
                    displayName: "MacPulse",
                    bundleIdentifier: macPulseIdentifier,
                    executablePath: outermostAppPath(candidate.executablePath)
                )
            }
            if
                let bundleIdentifier = candidate.bundleIdentifier,
                candidate.category == .application
            {
                return GroupIdentity(
                    identifier: bundleIdentifier,
                    displayName: appDisplayName(candidate) ?? candidate.displayName,
                    bundleIdentifier: bundleIdentifier,
                    executablePath: outermostAppPath(candidate.executablePath) ?? candidate.executablePath
                )
            }
            if appFallback == nil, let appPath = outermostAppPath(candidate.executablePath) {
                appFallback = GroupIdentity(
                    identifier: "app:\(appPath)",
                    displayName: URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent,
                    bundleIdentifier: nil,
                    executablePath: appPath
                )
            }
            if appFallback == nil, let bundleIdentifier = candidate.bundleIdentifier {
                appFallback = GroupIdentity(
                    identifier: bundleIdentifier,
                    displayName: candidate.displayName,
                    bundleIdentifier: bundleIdentifier,
                    executablePath: candidate.executablePath
                )
            }
            guard
                candidate.parentPID > 0,
                visited.insert(candidate.pid).inserted,
                let parent = byPID[candidate.parentPID]
            else {
                break
            }
            candidate = parent
        }

        if let appFallback {
            return appFallback
        }
        let path = snapshot.executablePath
        return GroupIdentity(
            identifier: path.map { "executable:\($0)" }
                ?? "process:\(snapshot.displayName)",
            displayName: snapshot.displayName,
            bundleIdentifier: nil,
            executablePath: path
        )
    }

    private static func isMacPulse(_ snapshot: ProcessSnapshot) -> Bool {
        snapshot.bundleIdentifier == macPulseIdentifier
            || snapshot.executablePath?.contains("/MacPulse.app/") == true
            || ["MacPulse", "MacPulseCollector", "mactop"].contains(snapshot.displayName)
    }

    private static func appDisplayName(_ snapshot: ProcessSnapshot) -> String? {
        outermostAppPath(snapshot.executablePath).map {
            URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent
        }
    }

    public static func outermostAppPath(_ executablePath: String?) -> String? {
        guard let executablePath else { return nil }
        let components = URL(fileURLWithPath: executablePath).pathComponents
        guard let index = components.firstIndex(where: { $0.hasSuffix(".app") }) else {
            return nil
        }
        return NSString.path(withComponents: Array(components.prefix(through: index)))
    }

    private static func applyEnergyLevelsAndScores(to groups: inout [ProcessGroupSnapshot]) {
        let energyGroups = groups
            .filter { ($0.energyNanojoulesPerSecond ?? 0) > 0 }
            .sorted { ($0.energyNanojoulesPerSecond ?? 0) > ($1.energyNanojoulesPerSecond ?? 0) }
        let energyRank = Dictionary(uniqueKeysWithValues: energyGroups.enumerated().map {
            ($0.element.stableIdentifier, Double($0.offset) / Double(max(1, energyGroups.count)))
        })

        let maxCPU = groups.compactMap(\.smoothedCPUPercent).max() ?? 0
        let maxMemory = groups.compactMap(\.physicalFootprintBytes).max() ?? 0
        let maxDisk = groups.compactMap {
            optionalSum($0.diskReadBytesPerSecond, $0.diskWriteBytesPerSecond)
        }.max() ?? 0
        let maxEnergy = groups.compactMap(\.energyNanojoulesPerSecond).max() ?? 0

        for index in groups.indices {
            let energy = groups[index].energyNanojoulesPerSecond
            if let energy, energy > 0, let rank = energyRank[groups[index].stableIdentifier] {
                groups[index].energyImpact = rank < 0.1 ? .high : (rank < 0.4 ? .medium : .low)
            } else {
                groups[index].energyImpact = .unavailable
            }

            let components: [(Double, Double, Bool)] = [
                ((groups[index].smoothedCPUPercent ?? 0) / max(1, maxCPU), 0.45, groups[index].smoothedCPUPercent != nil),
                (Double(groups[index].physicalFootprintBytes ?? 0) / Double(max(1, maxMemory)), 0.30, groups[index].physicalFootprintBytes != nil),
                ((optionalSum(groups[index].diskReadBytesPerSecond, groups[index].diskWriteBytesPerSecond) ?? 0) / max(1, maxDisk), 0.15, groups[index].diskReadBytesPerSecond != nil || groups[index].diskWriteBytesPerSecond != nil),
                ((energy ?? 0) / max(1, maxEnergy), 0.10, energy != nil)
            ]
            let availableWeight = components.filter(\.2).reduce(0) { $0 + $1.1 }
            groups[index].compositeScore = availableWeight > 0
                ? components.filter(\.2).reduce(0) { $0 + $1.0 * $1.1 } / availableWeight
                : 0
        }
    }

    private static func sum(_ values: [Double?]) -> Double? {
        let available = values.compactMap { $0?.isFinite == true ? $0 : nil }
        return available.isEmpty ? nil : available.reduce(0, +)
    }

    private static func sumIntegers(_ values: [UInt64?]) -> UInt64? {
        let available = values.compactMap { $0 }
        return available.isEmpty ? nil : available.reduce(0, &+)
    }

    private static func optionalSum(_ lhs: Double?, _ rhs: Double?) -> Double? {
        if lhs == nil, rhs == nil { return nil }
        return (lhs ?? 0) + (rhs ?? 0)
    }
}

public struct ProcessHistoryPoint: Sendable, Equatable, Identifiable {
    public var id: String { "\(stableIdentifier):\(timestamp.timeIntervalSince1970)" }
    public var timestamp: Date
    public var stableIdentifier: String
    public var displayName: String
    public var bundleIdentifier: String?
    public var cpuAveragePercent: Double?
    public var cpuPeakPercent: Double?
    public var physicalFootprintAverageBytes: UInt64?
    public var physicalFootprintPeakBytes: UInt64?
    public var diskReadBytesPerSecond: Double?
    public var diskWriteBytesPerSecond: Double?
    public var energyNanojoulesPerSecond: Double?
    public var compositeScore: Double
    public var isMacPulse: Bool

    public init(
        timestamp: Date,
        stableIdentifier: String,
        displayName: String,
        bundleIdentifier: String?,
        cpuAveragePercent: Double?,
        cpuPeakPercent: Double?,
        physicalFootprintAverageBytes: UInt64?,
        physicalFootprintPeakBytes: UInt64?,
        diskReadBytesPerSecond: Double?,
        diskWriteBytesPerSecond: Double?,
        energyNanojoulesPerSecond: Double?,
        compositeScore: Double,
        isMacPulse: Bool
    ) {
        self.timestamp = timestamp
        self.stableIdentifier = stableIdentifier
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        self.cpuAveragePercent = cpuAveragePercent
        self.cpuPeakPercent = cpuPeakPercent
        self.physicalFootprintAverageBytes = physicalFootprintAverageBytes
        self.physicalFootprintPeakBytes = physicalFootprintPeakBytes
        self.diskReadBytesPerSecond = diskReadBytesPerSecond
        self.diskWriteBytesPerSecond = diskWriteBytesPerSecond
        self.energyNanojoulesPerSecond = energyNanojoulesPerSecond
        self.compositeScore = compositeScore
        self.isMacPulse = isMacPulse
    }
}

public struct ProcessMinuteAggregator: Sendable {
    private var minuteStart: Date?
    private var samples: [String: Accumulator] = [:]
    public var topLimit: Int

    public init(topLimit: Int = 5) {
        self.topLimit = topLimit
    }

    public mutating func append(
        timestamp: Date,
        groups: [ProcessGroupSnapshot]
    ) -> [ProcessHistoryPoint]? {
        let bucket = Self.minuteBucket(for: timestamp)
        var completed: [ProcessHistoryPoint]?
        if let minuteStart, minuteStart != bucket {
            completed = finish(timestamp: minuteStart)
            samples.removeAll(keepingCapacity: true)
        }
        minuteStart = bucket
        for group in groups {
            samples[group.stableIdentifier, default: Accumulator(group: group)]
                .append(group)
        }
        return completed
    }

    public mutating func flush() -> [ProcessHistoryPoint] {
        guard let minuteStart else { return [] }
        let points = finish(timestamp: minuteStart)
        self.minuteStart = nil
        samples.removeAll()
        return points
    }

    private func finish(timestamp: Date) -> [ProcessHistoryPoint] {
        let points = samples.values.map { $0.point(timestamp: timestamp) }
        let selfPoints = points.filter(\.isMacPulse)
        let top = points
            .filter { !$0.isMacPulse }
            .sorted { $0.compositeScore > $1.compositeScore }
            .prefix(topLimit)
        return (selfPoints + top).sorted { $0.isMacPulse && !$1.isMacPulse }
    }

    private static func minuteBucket(for date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 60) * 60)
    }

    private struct Accumulator: Sendable {
        var stableIdentifier: String
        var displayName: String
        var bundleIdentifier: String?
        var isMacPulse: Bool
        var count = 0
        var cpuSum = 0.0
        var cpuCount = 0
        var cpuPeak: Double?
        var memorySum: UInt64 = 0
        var memoryCount: UInt64 = 0
        var memoryPeak: UInt64?
        var diskReadSum = 0.0
        var diskReadCount = 0
        var diskWriteSum = 0.0
        var diskWriteCount = 0
        var energySum = 0.0
        var energyCount = 0
        var scoreSum = 0.0

        init(group: ProcessGroupSnapshot) {
            stableIdentifier = group.stableIdentifier
            displayName = group.displayName
            bundleIdentifier = group.bundleIdentifier
            isMacPulse = group.isMacPulse
        }

        mutating func append(_ group: ProcessGroupSnapshot) {
            count += 1
            displayName = group.displayName
            bundleIdentifier = group.bundleIdentifier ?? bundleIdentifier
            scoreSum += group.compositeScore
            if let value = group.smoothedCPUPercent {
                cpuSum += value
                cpuCount += 1
                cpuPeak = max(cpuPeak ?? value, value)
            }
            if let value = group.physicalFootprintBytes {
                memorySum = memorySum &+ value
                memoryCount += 1
                memoryPeak = max(memoryPeak ?? value, value)
            }
            if let value = group.diskReadBytesPerSecond {
                diskReadSum += value
                diskReadCount += 1
            }
            if let value = group.diskWriteBytesPerSecond {
                diskWriteSum += value
                diskWriteCount += 1
            }
            if let value = group.energyNanojoulesPerSecond {
                energySum += value
                energyCount += 1
            }
        }

        func point(timestamp: Date) -> ProcessHistoryPoint {
            ProcessHistoryPoint(
                timestamp: timestamp,
                stableIdentifier: stableIdentifier,
                displayName: displayName,
                bundleIdentifier: bundleIdentifier,
                cpuAveragePercent: cpuCount > 0 ? cpuSum / Double(cpuCount) : nil,
                cpuPeakPercent: cpuPeak,
                physicalFootprintAverageBytes: memoryCount > 0 ? memorySum / memoryCount : nil,
                physicalFootprintPeakBytes: memoryPeak,
                diskReadBytesPerSecond: diskReadCount > 0 ? diskReadSum / Double(diskReadCount) : nil,
                diskWriteBytesPerSecond: diskWriteCount > 0 ? diskWriteSum / Double(diskWriteCount) : nil,
                energyNanojoulesPerSecond: energyCount > 0 ? energySum / Double(energyCount) : nil,
                compositeScore: count > 0 ? scoreSum / Double(count) : 0,
                isMacPulse: isMacPulse
            )
        }
    }
}
