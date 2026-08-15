import AppKit
import Combine
import Foundation
import MacPulseCore
import UserNotifications

/// 面板的展示来源。`RootView` 会被实例化两次（菜单栏弹窗 + 独立窗口），
/// 用具名来源而不是计数器，注册与注销才是幂等的。
enum PresentationSource: String, Hashable, Sendable {
    case menuBar
    case window
}

/// 「性能」标签下的子页。采样成本按当前可见的子页门控：
/// 昂贵的原生遍历（进程级 GPU、ANE 持有者）只在需要它们的子页可见时才跑。
enum PerformancePane: String, CaseIterable, Identifiable, Sendable {
    case soc = "芯片"
    case memory = "内存"
    case disk = "磁盘"
    case startup = "启动项"
    case thermal = "温度"
    case processes = "进程"

    var id: String { rawValue }
}

/// 「为什么卡」取样状态。取样寄生在 refresh() 的 2 秒节奏里,不另起管线。
enum BottleneckProbePhase: Equatable {
    case idle
    case sampling(collected: Int, required: Int)
    case done(BottleneckDiagnosis, at: Date)
}

/// 总览卡「查看 →」的跳转请求。section 与子页选择都是视图私有 @State,
/// 只能走 model 这条广播通道;两个 RootView(弹窗+独立窗口)都会响应,
/// 同一用户视角下可接受。
struct NavigationRequest: Equatable {
    var section: AppSection
    var pane: PerformancePane?
}

@MainActor
final class DashboardModel: ObservableObject {
    static let shared = DashboardModel()

    @Published private(set) var current = MetricSnapshot()
    @Published private(set) var history: [HistoryPoint] = []
    @Published private(set) var liveHistory: [HistoryPoint] = []
    @Published private(set) var isLoading = true
    @Published private(set) var lastCollectorUpdate: Date?
    @Published private(set) var collectorStatus = CollectorStatus()
    @Published private(set) var sampleInterval: TimeInterval = 10
    @Published private(set) var historyStoreStatus = String(localized: "正在准备历史数据")
    /// 升级前备份的结果。nil 表示无需备份（全新安装），不显示这一行。
    @Published private(set) var historyBackupStatus: String?
    /// 统一内存分项。本机直接读取，与采集器状态无关。
    @Published private(set) var memory: MemoryBreakdown?
    /// 每个逻辑核的占用率，按硬件索引排列（能效核在前）。首次采样前为空。
    @Published private(set) var perCoreUsage: [Double] = []
    /// 续航估算。三个来源并排展示，系统值只作对照。
    @Published private(set) var runtimeEstimate = RuntimeEstimate()
    /// 当前背光读数，用于耗电分档与「亮度调低能多用多久」。
    @Published private(set) var backlight: BacklightSample?
    /// 充电链路快照（充电器 → 线缆 → 协商结果）。
    /// nil 与「不显示」同义：没插电、读不到协商节点、或口状态门闸没过。
    @Published private(set) var chargeLink: ChargeLinkSnapshot?
    /// 磁盘面板快照(卷容量 + 开机累计读写)。只在磁盘子页可见时刷新。
    @Published private(set) var diskOverview: DiskOverview?
    /// 蓝牙外设电量。空数组 = 确实没有带电量上报的外设(如实隐藏卡片)。
    @Published private(set) var peripheralBatteries: [PeripheralBattery] = []
    /// 开机/登录自启的后台项。只在启动项子页可见时刷新。
    @Published private(set) var backgroundItems: [BackgroundItem] = []
    /// 最近的睡眠会话(新→旧)。只在电池页可见时读,读取器自带 10 分钟节流。
    @Published private(set) var sleepSessions: [SleepSession] = []
    /// 内存吃紧判据的额外原料(swap 与系统压力等级)。
    @Published private(set) var memoryExtras = MemorySnapshotExtras()
    /// 换页/交换/压缩的瞬时速率。nil = 尚无基线(首拍)或该拍读取失败。
    /// 判「正在疯狂换页」只能靠它——swap 用量是历史遗迹,速率才是现在时。
    @Published private(set) var memoryRates: MemoryRates?
    /// GPU 设备利用率(活动监视器同源)。芯片页「占用」与瓶颈诊断共用这一个,
    /// 评审抓获的口径分裂:此前芯片页读 GPUPH 驻留,诊断读设备利用率,
    /// 用户从诊断跳到芯片页看到的是另一个定义的数字(48% 对 95%)。
    @Published private(set) var gpuDeviceUtilizationPercent: Double?
    /// AI 余额读数(已配置的服务商)。
    @Published private(set) var aiBalances: [AIBalanceReading] = []
    /// 取数失败的服务商与人话原因——失败要摆出来,不许静默变旧数据。
    @Published private(set) var aiBalanceErrors: [AIProvider: String] = [:]
    @Published private(set) var aiConfiguredProviders: [AIProvider] = []
    /// Claude Code 今日本地用量(零网络,~/.claude 日志统计)。
    @Published private(set) var claudeCodeUsage: ClaudeCodeUsage?
    @Published private(set) var aiBalanceRefreshedAt: Date?
    /// Codex 订阅额度(本地日志快照,零网络)。
    @Published private(set) var codexQuota: SubscriptionQuota?
    /// Claude 订阅额度(未文档化接口,设置里明确开启才请求)。
    @Published private(set) var claudeQuota: SubscriptionQuota?
    private let claudeSubscriptionReader = ClaudeSubscriptionReader()
    private let aiBalanceService = AIBalanceService()
    private var aiBalanceRefreshInFlight = false

    /// 「为什么卡」取样状态,总览卡直接 switch 它渲染三态。
    @Published private(set) var bottleneckProbe: BottleneckProbePhase = .idle
    /// 总览卡发出的跳转请求;RootView/PerformanceView 消费后置 nil。
    @Published private(set) var navigationRequest: NavigationRequest?
    /// 最近一次瓶颈诊断,供体检报告读取。重新诊断覆盖,面板关闭不清。
    private(set) var lastBottleneck: (diagnosis: BottleneckDiagnosis, at: Date)?
    private var probeWindow = BottleneckProbeWindow()
    private var probeStartedAt: Date?
    /// 窗口攒满后进入「结账」等待:再触发一次进程采样并等它落账,
    /// 归因才有完整差分(新进程首拍没有基线,算不出 CPU%)。
    private var probeSettling = false
    /// 进程数据的代号,processGroups 每次落账 +1。结账要等到「本代」数据,
    /// 不能固定睡 2 秒赌它到了——评审抓获:慢机上会拿旧榜单归因。
    private var processGeneration = 0
    private var probeWaitingSinceGeneration = 0
    /// 当前接着的屏幕。只在芯片子页可见时刷新。
    @Published private(set) var displays: [DisplayInfo] = []
    /// 近 7 天热降频事件的时间戳。瞬时诊断攒成历史才看得出规律。
    @Published private(set) var throttleEvents: [Date] = []
    /// 估算器对自己历史预测的准确度自述。
    @Published private(set) var estimateAccuracy = PowerSessionTracker.Accuracy()
    /// 系统网络路径快照。零流量读数，与是否开启测速无关。
    @Published private(set) var networkPath = NetworkPathSnapshot()
    /// 最近一次测速结果。
    @Published private(set) var networkResult: NetworkTestResult?
    /// 测速当前阶段（「测量下载」之类）。nil 表示没在跑。
    @Published private(set) var networkPhase: String?
    /// 这次为什么没测。必须显示出来——静默跳过等于让人以为测过了。
    @Published private(set) var networkSkipReason: NetworkSkipReason?
    /// 完整测速被降级的原因（比如在热点上）。
    @Published private(set) var networkDowngradeReason: NetworkSkipReason?
    /// 历次测速，供趋势图使用。保留 90 天。
    @Published private(set) var networkHistory: [NetworkTestRecord] = []
    /// 当前持有神经引擎会话的进程 pid。
    ///
    /// nil 与空集合含义不同，界面必须区别对待：
    /// nil = 读不到（隐藏整张卡）；[] = 确实没人在用（如实显示）。
    @Published private(set) var aneHolderPIDs: Set<pid_t>?
    @Published private(set) var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var processGroups: [ProcessGroupSnapshot] = []
    @Published private(set) var processMonitorStatus = ProcessMonitorStatus()
    @Published private(set) var processHistoryStatus = String(localized: "正在准备进程历史")
    @Published private(set) var processHistoryCache: [String: [ProcessHistoryPoint]] = [:]

    private let fallback = SystemFallbackReader()
    private let collector = DeepCollectorClient()
    private let processSampler = ProcessSampler()
    private let historyStore: HistoryStore?
    private let processHistoryStore: ProcessHistoryStore?
    private let notifications = NotificationService()
    private var latestDeep = DeepMetrics()
    private var samplerTask: Task<Void, Never>?
    private var processSamplerTask: Task<Void, Never>?
    private var aggregator = MinuteAggregator()
    private var processAggregator = ProcessMinuteAggregator()
    private var started = false
    /// 当前正在展示面板的来源集合。
    ///
    /// 之前这里是个计数器，结果计数减不回 0：独立窗口的 `isReleasedWhenClosed = false`
    /// 让「关闭」只是 order out，SwiftUI 的 `onDisappear` 不一定触发，于是 +1 之后
    /// 永远没有对应的 -1。采样率被永久钉在 2 秒 —— 实测 mactop 连跑 20 小时、
    /// 14.2% CPU。改成按来源去重的集合后，重复的 appear 不再累加，漏掉的
    /// disappear 最多只留下一个陈旧条目，且 AppDelegate 会用窗口通知把它清掉。
    private var activePresentationSources: Set<PresentationSource> = []
    private var activePresentations: Int { activePresentationSources.count }
    private var processPageActive = false
    private var visiblePane: PerformancePane?
    private let aneReader = ANEClientReader()
    private let backlightReader = DisplayBacklightReader()
    private let batterySampler = BatterySampler()
    private let chargeLinkSampler = ChargeLinkSampler()
    private let peripheralReader = PeripheralBatteryReader()
    private let sleepReader = SleepLogReader()
    private var batteryPageActive = false
    private var overviewActive = false
    private var isRefreshing = false
    private var runtimeEstimator = RuntimeEstimator()
    private var drainProfile = DrainProfile.shippingPrior()
    private var sessionTracker = PowerSessionTracker()
    /// 本次放电段的近期电量轨迹，喂给「观测斜率一致性」钳制。
    private var recentSocTrail: [(date: Date, soc: Double)] = []
    private var lastChargeState: ChargeState?
    private var pathObserver: NetworkPathObserver?
    private let networkProbe = NetworkProbe()
    private var networkTestTask: Task<Void, Never>?
    private var networkTriggerTask: Task<Void, Never>?
    private var lastNetworkTestAt: Date?
    private var lastNetworkKeyHash: String?
    private let networkTestStore: NetworkTestStore?
    private var suspended = false

    private init() {
        var openedStore: HistoryStore?
        do {
            let store = try HistoryStore()
            openedStore = store
            history = try store.loadRecent()
            try store.prune()
            historyStoreStatus = store.migratedRecordCount > 0
                ? String(format: String(localized: "已安全迁移 %@ 条旧历史数据"), String(describing: store.migratedRecordCount))
                : String(localized: "历史数据正常")
            historyBackupStatus = Self.describe(store.backupState)
        } catch {
            historyStoreStatus = String(format: String(localized: "历史数据不可用：%@"), String(describing: error.localizedDescription))
        }
        historyStore = openedStore

        var openedProcessStore: ProcessHistoryStore?
        do {
            let store = try ProcessHistoryStore()
            try store.wipeOnceForCPUScaleFix()
            try store.prune()
            openedProcessStore = store
            processHistoryStatus = String(localized: "重点进程历史正常")
        } catch {
            processHistoryStatus = String(format: String(localized: "进程历史不可用：%@"), String(describing: error.localizedDescription))
        }
        processHistoryStore = openedProcessStore

        var openedNetworkStore: NetworkTestStore?
        do {
            let store = try NetworkTestStore()
            try store.prune()
            openedNetworkStore = store
        } catch {
            // 测速历史存不下不影响测速本身，静默降级即可。
            openedNetworkStore = nil
        }
        networkTestStore = openedNetworkStore
        networkHistory = (try? openedNetworkStore?.loadRecent()) ?? []
        // 启动回填:最近一条历史当作当前结果展示(带时效标注,过期会置灰)。
        networkResult = networkHistory.last?.asResult()
        loadDrainProfile()
        backfillDrainProfileIfNeeded()
        estimateAccuracy = sessionTracker.accuracy()
    }

    /// 首次运行时用现有历史回填耗电档案。
    ///
    /// 历史里有 `cpuUsagePercent` 和 `batteryPowerWatts`，覆盖率接近 100%；
    /// **没有亮度**——所以回填只写 T1/T2 两级。这恰好是正确的做法：
    /// 只学数据里真实存在的东西，不为缺失的维度编造。
    /// 效果是第一次打开就有成熟档案，而不是等一周。
    private func backfillDrainProfileIfNeeded() {
        // v2：v1 的回填结果曾因 chargeProfile 解码失败被静默丢弃（见
        // DrainProfile.init(from:) 的注释）。换 key 触发一次重新回填即可
        // 自愈——EWMA 不是求和，重复喂同一段历史不会双计，只会收敛到尾部。
        let key = "MacPulse.drainProfileBackfilled.v2"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        defer { UserDefaults.standard.set(true, forKey: key) }

        let discharging = history.filter { ($0.batteryPowerWatts ?? 0) < -0.05 }
        guard discharging.count > 60 else { return }

        for point in discharging {
            guard let watts = point.batteryPowerWatts else { continue }
            let context = UsageContext(
                cpuPercent: point.cpuUsagePercent,
                backlightMicroAmps: nil,
                lowPowerMode: false
            )
            drainProfile.record(watts: abs(watts), context: context, at: point.timestamp)
        }
        saveDrainProfile()
    }

    // MARK: - 续航估算

    /// 学习状态：耗电档案 + 已完成的放电段。
    ///
    /// 一起存成 JSON，**刻意不进 SwiftData**。这样完全避开了给 `HistoryRecord`
    /// 加列的迁移风险——那 6899 条历史比这份档案珍贵得多，不值得为了存
    /// 几十个浮点数去动它的 schema。
    private struct LearningState: Codable {
        var profile: DrainProfile
        var sessions: [DischargeSession]
    }

    private static var drainProfileURL: URL? {
        try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("MacPulse", isDirectory: true)
        .appendingPathComponent("drain-profile.json")
    }

    private func loadDrainProfile() {
        guard let url = Self.drainProfileURL, let data = try? Data(contentsOf: url) else { return }
        if let state = try? JSONDecoder().decode(LearningState.self, from: data) {
            // 出厂先验只在没有真实档案时使用；一旦学过就完全以学到的为准。
            drainProfile = state.profile
            sessionTracker = PowerSessionTracker(completed: state.sessions)
        } else if let legacy = try? JSONDecoder().decode(DrainProfile.self, from: data) {
            // 早期版本只存了档案本身，兼容读入。
            drainProfile = legacy
        }
    }

    private func saveDrainProfile() {
        guard let url = Self.drainProfileURL,
              let data = try? JSONEncoder().encode(
                  LearningState(profile: drainProfile, sessions: sessionTracker.completed)
              )
        else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }

    /// 每分钟持久化时学一次，不是每次采样。
    private func learnFromMinute(_ point: HistoryPoint) {
        // 充电时学分段速率。80% 以上电流会衰减，必须按段分开学，
        // 否则用低电量段的速率外推会把充满时间算得过于乐观。
        if let watts = point.batteryPowerWatts, watts > 0.05 {
            drainProfile.chargeProfile.record(
                wattHoursPerMinute: watts / 60,
                soc: point.batteryPercent,
                adapterRatedWatts: current.battery.adapterRatedWatts,
                at: point.timestamp
            )
            saveDrainProfile()
            return
        }
        guard let watts = point.batteryPowerWatts, watts < -0.05 else { return }
        let context = UsageContext(
            cpuPercent: point.cpuUsagePercent,
            backlightMicroAmps: backlight?.microAmps,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
        drainProfile.record(watts: abs(watts), context: context, at: point.timestamp)
        if point.batteryPercent > 0, point.batteryPercent < (drainProfile.observedFloorPercent ?? 100) {
            drainProfile.observedFloorPercent = max(1, min(5, point.batteryPercent))
        }
        saveDrainProfile()
    }

    private func updateRuntimeEstimate(_ snapshot: MetricSnapshot) {
        backlight = backlightReader.read()

        let state = snapshot.battery.state
        // 充放电切换是物理状态突变，EMA 与电量轨迹都必须重来。
        if state != lastChargeState {
            runtimeEstimator.reset()
            recentSocTrail.removeAll()
            lastChargeState = state
        }

        let charging = state == .charging
        // 电量统一用系统显示的百分比，**不用 AppleRawCurrentCapacity/AppleRawMaxCapacity
        // 的比值**。
        //
        // 那个比值和显示值并不是同一把尺子，实测四个时刻：98% vs 93.18、
        // 82% vs 81.0、40% vs 36.6、34% vs 33.14——既不是固定偏移也不是固定比例，
        // 而且 rawMax 本身还在漂（5582→5600→5625）。电量计有自己的换算，
        // 两端都留了余量。
        //
        // 更关键的是 Wh/% = 67.3 这个标定是拿历史里的**显示百分比**积分出来的。
        // 把 raw 比值喂进同一个公式等于两把尺子混用，实测会凭空差 5%。
        // 整数百分比带来的台阶（7W 下约 6 分钟）由显示层的变化率限制吸收。
        let socFine = snapshot.battery.percentage
        trackSocTrail(socFine, at: snapshot.timestamp, charging: charging)

        let context = UsageContext(
            cpuPercent: snapshot.deep.cpuUsagePercent,
            backlightMicroAmps: backlight?.microAmps,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
        )

        let (drop, window) = socTrailDelta()
        let input = RuntimeEstimatorInput(
            socFinePercent: socFine,
            wattHoursPerPercent: wattHoursPerPercent(snapshot.battery),
            reserveFloorPercent: drainProfile.observedFloorPercent ?? 3,
            netPowerWatts: snapshot.battery.netPowerWatts,
            gaugeMinutes: charging
                ? snapshot.battery.gaugeMinutesToFull
                : snapshot.battery.gaugeMinutesToEmpty,
            systemEstimateMinutes: snapshot.battery.timeRemainingMinutes,
            context: context,
            isCharging: charging,
            now: snapshot.timestamp,
            sampleInterval: sampleInterval,
            recentSocDropPercent: drop,
            recentWindowMinutes: window,
            adapterRatedWatts: snapshot.battery.adapterRatedWatts
        )

        runtimeEstimate = runtimeEstimator.update(input, profile: drainProfile)

        // 记录预测供日后对账。段结束时才算分——这样算出来的是真实误差，
        // 不是自我感觉。
        let before = sessionTracker.completed.count
        sessionTracker.ingest(
            PowerSessionTracker.Sample(
                date: snapshot.timestamp,
                socPercent: socFine,
                netPowerWatts: snapshot.battery.netPowerWatts,
                isDischarging: state == .discharging || state == .pluggedDischarging,
                predictedMinutes: runtimeEstimate.minutes
            )
        )
        if sessionTracker.completed.count != before {
            finalizeCompletedSessions()
        }
    }

    /// 一段放电结束：更新准确度自述，并把实测的 Wh/% 喂回能量模型。
    private func finalizeCompletedSessions() {
        estimateAccuracy = sessionTracker.accuracy()

        let nameplate = current.battery.maxCapacityMAh.map { Double($0) * 11.4 / 100_000 }
        if let latest = sessionTracker.completed.last?.wattHoursPerPercent {
            drainProfile.recordWattHoursPerPercent(latest, nameplate: nameplate)
        }
        if let floor = sessionTracker.completed.last?.endSoc, floor > 0, floor < 8 {
            drainProfile.observedFloorPercent = max(1, min(5, floor))
        }
        saveDrainProfile()
    }

    /// 学到的 Wh/%；没学到就用铭牌推算。
    ///
    /// 铭牌用**设计标称电压 11.4V** 而不是瞬时 `Voltage`：后者会随电量下垂，
    /// 在低电量时把可用能量系统性低估约 6%。
    private func wattHoursPerPercent(_ battery: BatteryMetrics) -> Double {
        if let learned = drainProfile.learnedWattHoursPerPercent, learned > 0 {
            return learned
        }
        if let maxCapacity = battery.maxCapacityMAh, maxCapacity > 200 {
            return Double(maxCapacity) * 11.4 / 100_000
        }
        if let design = battery.designCapacityMAh, design > 200 {
            let health = (battery.healthPercent ?? 100) / 100
            return Double(design) * health * 11.4 / 100_000
        }
        return 0.631
    }

    private func trackSocTrail(_ soc: Double, at date: Date, charging: Bool) {
        guard !charging else { return }
        recentSocTrail.append((date: date, soc: soc))
        // 只留最近 15 分钟。
        let cutoff = date.addingTimeInterval(-900)
        recentSocTrail.removeAll { $0.date < cutoff }
    }

    private func socTrailDelta() -> (Double?, Double?) {
        guard let first = recentSocTrail.first, let last = recentSocTrail.last else { return (nil, nil) }
        let drop = first.soc - last.soc
        let minutes = last.date.timeIntervalSince(first.date) / 60
        guard drop > 0, minutes >= 3 else { return (nil, nil) }
        return (drop, minutes)
    }

    // MARK: - 网络测速

    private var networkConsent: NetworkConsent {
        NetworkConsent(rawValue: UserDefaults.standard.string(forKey: "networkTestConsent") ?? "")
            ?? .notDetermined
    }

    private var networkAutoRunEnabled: Bool {
        UserDefaults.standard.object(forKey: "networkAutoRun") as? Bool ?? true
    }

    private var networkPreferredTier: NetworkTestTier {
        NetworkTestTier(rawValue: UserDefaults.standard.string(forKey: "networkTestTier") ?? "")
            ?? .standard
    }

    private var networkMinimumInterval: TimeInterval {
        let stored = UserDefaults.standard.object(forKey: "networkMinimumInterval") as? Double
        return stored ?? NetworkTestPolicy.defaultMinimumInterval
    }

    var isNetworkTestRunning: Bool { networkPhase != nil }

    private func reloadNetworkHistory() {
        networkHistory = (try? networkTestStore?.loadRecent()) ?? []
    }

    /// 面板打开时触发。加 1.5 秒去抖：开了立刻关不该发出任何请求。
    private func scheduleNetworkTest(trigger: NetworkTestTrigger) {
        networkTriggerTask?.cancel()
        networkTriggerTask = Task { [weak self] in
            if trigger != .manual {
                try? await Task.sleep(for: .milliseconds(1_500))
                guard !Task.isCancelled else { return }
            }
            await self?.runNetworkTest(trigger: trigger)
        }
    }

    func requestManualNetworkTest() {
        scheduleNetworkTest(trigger: .manual)
    }

    /// 优雅停止:让探针跑完当前块就收尾,半程数据按 partial 返回。
    /// 用户主动点停止走这条路——已经花掉的流量不该白花。
    /// 硬取消(cancelNetworkTest)留给睡眠与切网:跨睡眠的测量是垃圾。
    func stopNetworkTestGracefully() {
        Task { await networkProbe.requestGracefulStop() }
    }

    func cancelNetworkTest() {
        networkTriggerTask?.cancel()
        networkTriggerTask = nil
        networkTestTask?.cancel()
        networkTestTask = nil
        Task { await networkProbe.cancel() }
        networkPhase = nil
    }

    private func runNetworkTest(trigger: NetworkTestTrigger) async {
        guard activePresentations > 0 || trigger == .manual else { return }

        let keyHash = NetworkIdentity.hash(
            gatewayMAC: NetworkIdentity.currentGatewayMAC(),
            interfaceName: networkPath.primaryInterfaceName
        )
        let input = NetworkTestPolicy.Input(
            trigger: trigger,
            consent: networkConsent,
            autoRunEnabled: networkAutoRunEnabled,
            preferredTier: networkPreferredTier,
            path: networkPath,
            now: .now,
            lastCompletedAt: lastNetworkTestAt,
            lastTier: networkResult?.tier,
            networkKeyChanged: keyHash != nil && keyHash != lastNetworkKeyHash,
            minimumInterval: networkMinimumInterval,
            batteryPercent: current.battery.percentage,
            isDischarging: current.battery.state == .discharging,
            thermalUnderPressure: [.serious, .critical].contains(current.deep.thermalLevel),
            isRunning: isNetworkTestRunning
        )

        switch NetworkTestPolicy.decide(input) {
        case let .skip(reason):
            networkSkipReason = reason
            return
        case let .run(tier):
            networkSkipReason = nil
            networkDowngradeReason = NetworkTestPolicy.downgradeReason(input)
            await performNetworkTest(tier: tier, trigger: trigger, keyHash: keyHash)
        }
    }

    private func performNetworkTest(tier: NetworkTestTier, trigger: NetworkTestTrigger, keyHash: String?) async {
        let link = current.deep.networkLink
        let path = networkPath
        networkPhase = String(localized: "准备中")

        // 进度回调单独提出来，避免在已经捕获了 weak self 的闭包里再嵌一层捕获。
        let reportPhase: @Sendable (NetworkProbe.Progress) -> Void = { [weak self] progress in
            guard case let .phase(name) = progress else { return }
            Task { @MainActor in
                self?.networkPhase = name
            }
        }

        let task = Task<Void, Never> { [weak self, networkProbe] in
            let result = try? await networkProbe.run(
                plan: .forTier(tier),
                trigger: trigger,
                link: link,
                path: path,
                onProgress: reportPhase
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.networkPhase = nil
                guard let result else { return }
                self.networkResult = result
                self.lastNetworkTestAt = result.startedAt
                self.lastNetworkKeyHash = keyHash
                self.reloadNetworkHistory()
                // 部分结果也存：配更宽的误差区间它依然是诚实数据，
                // 重测反而浪费用户的流量。
                try? self.networkTestStore?.save(result, networkKeyHash: keyHash)
            }
        }
        networkTestTask = task
        await task.value
    }

    /// 自选指标组合的菜单栏文本。读不到的指标段直接跳过(不显示「—」占位),
    /// 全都读不到才给一个兜底短横;紧凑模式只取选择里的第一项。
    func menuBarTitle(metrics: [MenuBarMetric], compact: Bool) -> String {
        let picked = compact ? Array(metrics.prefix(1)) : metrics
        let segments = picked.compactMap(menuBarSegment)
        if !segments.isEmpty { return segments.joined(separator: " · ") }
        // 选的都读不到时如实显示短横。旧版会静默换一个别的指标顶上——
        // 同样是「x.x W」,用户以为看的还是自己选的那个,更糟。
        return "—"
    }

    private func menuBarSegment(_ metric: MenuBarMetric) -> String? {
        switch metric {
        case .netPower:
            // 带符号:+ 在充、− 在放。取绝对值的旧版让「插电还在掉电」
            // 和「插电待机」在菜单栏里长得一模一样。
            return current.battery.netPowerWatts.map { String(format: "%+.1f W", $0) }
        case .hotspotTemperature:
            // 只认芯片热点,不悄悄换成电池温度——菜单栏标着热点显示 31°,
            // 面板里热点却「不可用」,两处打架。
            return current.deep.hotspotTemperature.map { String(format: "%.0f°", $0) }
        case .batteryPercent:
            return String(format: "%.0f%%", current.battery.percentage)
        case .socPower:
            return current.deep.systemPowerWatts.map { String(format: "%.1f W", $0) }
        case .memoryPercent:
            return memory?.usedFraction.map { String(format: String(localized: "内存 %.0f%%"), $0 * 100) }
        }
    }

    var menuBarAccessibilityLabel: String {
        let metrics = MenuBarMetric.parse(
            UserDefaults.standard.string(forKey: "menuBarMetrics") ?? MenuBarMetric.defaultStorage
        )
        return "MacPulse，\(current.battery.state.title)，\(menuBarTitle(metrics: metrics, compact: false))"
    }

    var menuBarSymbol: String {
        current.battery.state.symbol
    }

    func start() {
        guard !started else { return }
        started = true

        // 调试钩子:带 -MacPulseAutoProbe 启动时,6 秒后自动触发一次瓶颈诊断。
        // 无辅助功能权限的自动化验收(截图自查)靠它;正常启动无此参数,零影响。
        if UserDefaults.standard.bool(forKey: "MacPulseAutoProbe") {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                self?.startBottleneckProbe()
            }
        }

        // 路径监听是零流量的本机读数，与是否开启测速无关，始终运行。
        let observer = NetworkPathObserver { [weak self] snapshot in
            Task { @MainActor [weak self] in
                self?.networkPath = snapshot
            }
        }
        observer.start()
        pathObserver = observer

        collector.start(sampleInterval: sampleInterval) { [weak self] deep, status in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.collectorStatus = status
                switch status.phase {
                case .live, .degraded:
                    self.latestDeep = deep
                    self.lastCollectorUpdate = .now
                case .reconnecting, .unavailable, .sleeping:
                    self.latestDeep = DeepMetrics()
                case .starting:
                    break
                }
            }
        }
        Task {
            notificationAuthorizationStatus = await notifications.refreshAuthorizationStatus()
        }
        restartSampler()
        restartProcessSampler(resetBaseline: true)
    }

    func stop() {
        samplerTask?.cancel()
        samplerTask = nil
        processSamplerTask?.cancel()
        processSamplerTask = nil
        collector.stop()
        Task { await processSampler.reset() }
        pathObserver?.stop()
        pathObserver = nil
        started = false
    }

    func presentationDidAppear(_ source: PresentationSource) {
        guard activePresentationSources.insert(source).inserted else { return }
        updateSamplingMode()
        restartProcessSampler()
        scheduleNetworkTest(trigger: .panelOpen)
        refreshAIBalances()
    }

    func presentationDidDisappear(_ source: PresentationSource) {
        guard activePresentationSources.remove(source) != nil else { return }
        // 只有在最后一个面板也收起时才清进程页标记。原先无条件清零，
        // 会让「关掉菜单栏弹窗」误伤仍开在进程页的独立窗口的采样节奏。
        if activePresentationSources.isEmpty {
            processPageActive = false
            cancelBottleneckProbeIfSampling()
            networkTriggerTask?.cancel()
            networkTriggerTask = nil
            // 已经在跑的测量走优雅停止：跑完当前块就收尾并存下来。
            Task { await networkProbe.requestGracefulStop() }
        }
        updateSamplingMode()
        restartProcessSampler()
    }

    func suspend() {
        guard !suspended else { return }
        suspended = true
        // 跨越睡眠的测量是垃圾，硬取消而不是优雅停止。
        cancelNetworkTest()
        cancelBottleneckProbeIfSampling()
        // 睡眠前收段：唤醒后另起一段，不把待机时间算进使用时间。
        sessionTracker.close(reason: .sleep, at: .now, soc: current.battery.socFinePercent ?? current.battery.percentage)
        finalizeCompletedSessions()
        if let point = aggregator.flush() {
            persist(point)
        }
        persistProcessPoints(processAggregator.flush())
        samplerTask?.cancel()
        samplerTask = nil
        processSamplerTask?.cancel()
        processSamplerTask = nil
        collector.stop()
        collectorStatus = CollectorStatus(phase: .sleeping)
        processMonitorStatus.phase = .sleeping
        Task { await processSampler.reset() }
    }

    func resume() {
        guard suspended else { return }
        suspended = false
        collector.start(sampleInterval: sampleInterval) { [weak self] deep, status in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.collectorStatus = status
                if [.live, .degraded].contains(status.phase) {
                    self.latestDeep = deep
                    self.lastCollectorUpdate = .now
                } else if [.reconnecting, .unavailable, .sleeping].contains(status.phase) {
                    self.latestDeep = DeepMetrics()
                }
            }
        }
        restartSampler()
        restartProcessSampler(resetBaseline: true)
    }

    func requestNotificationAuthorization() {
        Task {
            do {
                _ = try await notifications.requestAuthorization()
                notificationAuthorizationStatus = await notifications.refreshAuthorizationStatus()
            } catch {
                notificationAuthorizationStatus = await notifications.refreshAuthorizationStatus()
            }
        }
    }

    func openNotificationSettings() {
        notifications.openSystemSettings()
    }

    func performancePaneChanged(_ pane: PerformancePane?) {
        guard visiblePane != pane else { return }
        visiblePane = pane
        processPageActive = pane == .processes
        // ANE 持有者名单只在芯片页可见时才扫；离开就立刻清空，
        // 免得界面显示一份不再刷新的陈旧名单。
        if pane != .soc {
            aneHolderPIDs = nil
        }
        // 磁盘子页刚打开先补一次,不等下个采样 tick;卷容量是 statfs 级读取,便宜。
        if pane == .disk {
            diskOverview = DiskStatsReader.read()
        }
        if pane == .startup {
            Task { [weak self] in
                guard let self else { return }
                let items = await LoginItemsReader.read()
                self.backgroundItems = self.enrich(items)
            }
        }
        restartProcessSampler()
    }

    /// 电池页出现/消失时由 BatteryView 上报。充电链路采样只在有人看时跑；
    /// 页面刚打开先补采一次，不让卡片干等下一个 2–10 秒的 tick。
    /// 离开页面保留旧快照不清空：下次进来先显示上次结果，随即被补采覆盖，
    /// 比闪一下空卡片体验好——陈旧窗口最多一个采样周期。
    /// RootView 的主分区切换上报。目前只有总览页需要感知(充电结论卡的采样门闸)。
    func sectionChanged(_ section: AppSection?) {
        let nowActive = section == .overview
        guard overviewActive != nowActive else { return }
        overviewActive = nowActive
        guard nowActive else { return }
        Task { [weak self] in
            guard let self else { return }
            self.chargeLink = await self.chargeLinkSampler.sample()
        }
    }

    /// 当前充电链路的判定结论。电池页与总览共用同一份推导,
    /// 电池状态两个布尔的映射规则只此一处。
    var chargeLinkDiagnosis: ChargeLinkDiagnosis? {
        guard let chargeLink else { return nil }
        let state = current.battery.state
        // pluggedDischarging(接电但电池仍在放)传 nil:既不是在充也不是被暂停,
        // 让判定只陈述瓦数事实,不去猜暂停原因。
        let isCharging: Bool? = switch state {
        case .charging: true
        case .pluggedDischarging, .unknown: nil
        default: false
        }
        return ChargeLinkDiagnosis.diagnose(
            snapshot: chargeLink,
            batteryFullyCharged: state == .full,
            batteryIsCharging: isCharging
        )
    }

    func batteryPageChanged(_ visible: Bool) {
        guard batteryPageActive != visible else { return }
        batteryPageActive = visible
        guard visible else { return }
        Task { [weak self] in
            guard let self else { return }
            self.chargeLink = await self.chargeLinkSampler.sample()
            self.peripheralBatteries = await self.peripheralReader.sample()
            self.notifications.evaluatePeripherals(self.peripheralBatteries)
        }
        refreshSleepSessions()
    }

    func setProcessMonitoringEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "processMonitoringEnabled")
        if enabled {
            restartProcessSampler(resetBaseline: true)
        } else {
            processSamplerTask?.cancel()
            processSamplerTask = nil
            processGroups = []
            processMonitorStatus = ProcessMonitorStatus(phase: .disabled)
            Task { await processSampler.reset() }
        }
    }

    func setProcessHistoryEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "processHistoryEnabled")
        if !enabled {
            processHistoryCache.removeAll()
            processAggregator = ProcessMinuteAggregator()
        }
    }

    func loadProcessHistory(for stableIdentifier: String) {
        guard
            processHistoryCache[stableIdentifier] == nil,
            processHistoryEnabled,
            let processHistoryStore
        else {
            return
        }
        do {
            processHistoryCache[stableIdentifier] = try processHistoryStore.loadRecent(
                stableIdentifier: stableIdentifier
            )
            processHistoryStatus = String(localized: "重点进程历史正常")
        } catch {
            processHistoryStatus = String(format: String(localized: "进程历史读取失败：%@"), String(describing: error.localizedDescription))
        }
    }

    func processHistory(for stableIdentifier: String) -> [ProcessHistoryPoint] {
        processHistoryCache[stableIdentifier] ?? []
    }

    /// 当前持有神经引擎会话的 App 名称。
    ///
    /// 返回 nil 表示读不到（界面隐藏整张卡）；返回空数组表示确实没人在用。
    /// 注意这**不是用量排行**——macOS 不提供按进程的 ANE 用量，只提供谁开着会话。
    var aneHolderNames: [String]? {
        guard let pids = aneHolderPIDs else { return nil }
        return resolveNames(for: pids)
    }

    /// pid → 显示名。ANE 持有者卡与瓶颈诊断共用。
    private func resolveNames(for pids: Set<pid_t>) -> [String] {
        let names = pids.compactMap { pid -> String? in
            if let app = NSRunningApplication(processIdentifier: pid) {
                return app.localizedName ?? app.bundleIdentifier
            }
            // 非 App 的守护进程不在 NSRunningApplication 里，回退到进程采样的结果。
            if let group = processGroups.first(where: { group in
                group.primaryPID == pid || group.children.contains { $0.pid == pid }
            }) {
                return group.displayName
            }
            return "pid \(pid)"
        }
        return Array(Set(names)).sorted()
    }

    /// 真正的整机功耗，只在电池供电时可知。
    ///
    /// 接电时 `netPowerWatts` 是充进电芯的电流，`adapterRatedWatts` 是协商上限，
    /// 两者都不是整机在耗多少电。与其拿一个错答案填上去，不如直说测不了——
    /// 这正是「虚假报数」的反面。
    /// 整机功耗,按供电状态分四路取数,每一路都是完整账:
    /// - 纯电池:|净功率| 就是整机
    /// - 接电但电池仍在供电:整机 = 电源输入 + 电池放电(审计抓出的关键 bug:
    ///   旧版只算电池那份,把充电器同时供的整个丢了,必然小于 SoC)
    /// - 插电不充:电源输入(PDTR)= 整机,电池不进不出
    /// - 充电中:整机 = 输入 − 充入电池的部分(两个都是测得的,不是「不可测」)
    var wholeMachineWatts: Double? {
        let battery = current.battery
        let dcInput = current.deep.dcInputWatts
        switch battery.state {
        case .discharging:
            guard let net = battery.netPowerWatts, net < 0 else { return nil }
            return abs(net)
        case .pluggedDischarging:
            guard let net = battery.netPowerWatts, net < 0 else { return nil }
            return abs(net) + (dcInput ?? 0)
        case .full, .pluggedNotCharging:
            guard let input = dcInput, input > 0 else { return nil }
            return input
        case .charging:
            guard let input = dcInput, input > 0,
                  let net = battery.netPowerWatts, net > 0, input > net else { return nil }
            return input - net
        case .unknown:
            return nil
        }
    }

    var wholeMachineWattsText: String {
        guard let watts = wholeMachineWatts else { return String(localized: "不可用") }
        // 整机比它自己的子集(SoC 封装)还小,必是不同源瞬时打架:
        // 宁可不报,不报一个物理上不可能的数。
        if let package = current.deep.socPower?.packageWatts, watts < package {
            return String(localized: "不可用")
        }
        return MetricFormat.watts(watts)
    }

    /// 整机功耗减去 SoC 总功耗，即屏幕与外设的开销。倒挂时返回 nil 而不是负数。
    var nonSoCWatts: Double? {
        guard let whole = wholeMachineWatts,
              let package = current.deep.socPower?.packageWatts,
              whole >= package
        else { return nil }
        return whole - package
    }

    /// 内存够不够的结论。原料齐了才给,读不到就没有。
    var memoryDiagnosis: MemoryDiagnosis? {
        guard let memory else { return nil }
        return MemoryDiagnosis.diagnose(breakdown: memory, extras: memoryExtras)
    }

    /// 节流结论。芯片页卡片与降频事件记录共用同一份推导,
    /// Input 的构造只此一处——此前它在 UI 层和这里各写了一份,已合并。
    var throttleDiagnosis: ThrottleDiagnosis? {
        ThrottleDiagnosis.diagnose(.init(
            clusterActivePercent: current.deep.socCompute?.pClusterActivePercent,
            clusterFreqMHz: current.deep.socCompute?.pClusterFreqMHz,
            clusterMaxFreqMHz: current.deep.socCompute?.pClusterMaxFreqMHz,
            hotspotTemperature: current.deep.hotspotTemperature,
            thermalLevel: current.deep.thermalLevel,
            lowPowerModeEnabled: current.deep.lowPowerModeEnabled ?? false,
            onBattery: current.battery.powerSource == .battery
        ))
    }

    // MARK: - 「为什么卡」取样

    /// 点按入口卡开始取样。顺手重启进程采样循环:它的首拍就是一次即时采样,
    /// 等于零成本把归因数据刷新到 6 秒内(否则最坏 15 秒一拍)。
    func startBottleneckProbe() {
        if case .sampling = bottleneckProbe { return }
        probeWindow = BottleneckProbeWindow()
        probeStartedAt = .now
        bottleneckProbe = .sampling(collected: 0, required: BottleneckProbeWindow.requiredTicks)
        restartProcessSampler()
    }

    /// 跨睡眠/面板全关时丢弃半截窗口——跨睡眠的测量是垃圾,
    /// 面板关了「约 5 秒」的承诺也兑现不了(采样率回落到 10 秒)。
    private func cancelBottleneckProbeIfSampling() {
        if case .sampling = bottleneckProbe { bottleneckProbe = .idle }
        probeStartedAt = nil
        probeSettling = false
    }

    /// 每拍采证。必须在 current 更新之后调(与热事件记录同一条教训:
    /// 放在前面读到的是上一拍的旧快照)。收拍与结账裁决在 Core 的 capture 里:
    /// 超时也先收下当前拍再结案,collected 由 Core 保证等于真实拍数。
    private func captureBottleneckTickIfNeeded() {
        guard case .sampling = bottleneckProbe, !probeSettling else { return }
        let tick = BottleneckProbeWindow.Tick(
            timestamp: .now,
            cpuUsagePercent: current.deep.cpuUsagePercent,
            perCoreUsage: perCoreUsage,
            // 饱和判定用设备利用率(活动监视器同源),不用 GPUPH 驻留——
            // 驻留占比在放视频的机器上趋近 100%,会喊冤案(见 GPUUtilizationReader)。
            gpuUsagePercent: GPUUtilizationReader.read(),
            memoryRates: memoryRates,
            memoryPressure: memory?.pressureLevel ?? .unknown,
            swapUsedBytes: memoryExtras.swapUsedBytes,
            diskReadBytesPerSecond: current.deep.diskReadBytesPerSecond,
            diskWriteBytesPerSecond: current.deep.diskWriteBytesPerSecond,
            hotspotTemperature: current.deep.hotspotTemperature,
            thermalLevel: current.deep.thermalLevel,
            collectorLive: collectorStatus.phase == .live,
            pClusterActivePercent: current.deep.socCompute?.pClusterActivePercent,
            pClusterFreqMHz: current.deep.socCompute?.pClusterFreqMHz,
            pClusterMaxFreqMHz: current.deep.socCompute?.pClusterMaxFreqMHz,
            lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
        let elapsed = probeStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        switch probeWindow.capture(tick, elapsed: elapsed) {
        case .sampling(let collected):
            bottleneckProbe = .sampling(
                collected: collected,
                required: BottleneckProbeWindow.requiredTicks
            )
        case .settle(let collected):
            finishBottleneckProbe(collected: collected)
        }
    }

    /// 窗口攒满:先触发「结账」进程采样,与开场那次构成跨越整个窗口的
    /// 差分区间——探针启动后才出现的进程(实测:取样前 3 秒启动的 yes)
    /// 首拍没有基线,不等这一步它就进不了归因候选。
    private func finishBottleneckProbe(collected: Int) {
        guard !probeSettling else { return }
        probeSettling = true
        // collected 来自 Core 的 capture,== 真实拍数;超时早收工时 UI 如实
        // 显示 1/3、2/3,不再谎报 3/3(评审抓获的旧行为)。
        bottleneckProbe = .sampling(
            collected: collected,
            required: BottleneckProbeWindow.requiredTicks
        )
        probeWaitingSinceGeneration = processGeneration
        restartProcessSampler()
        Task { @MainActor [weak self] in
            // 等「本代」进程数据落账(重启采样后的那一拍),上限 6 秒。
            // 到点没等到就用现有榜单诚实降级——归因可能滞后,但不装新鲜。
            for _ in 0..<12 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self else { return }
                if self.processGeneration > self.probeWaitingSinceGeneration { break }
                if !self.probeSettling { return }   // 已被取消
            }
            self?.completeBottleneckProbe()
        }
    }

    private func completeBottleneckProbe() {
        // 结账等待期间可能被 suspend/关面板取消(phase 已回 idle)。
        guard probeSettling, case .sampling = bottleneckProbe else {
            probeSettling = false
            return
        }
        probeSettling = false
        defer { probeStartedAt = nil }
        guard !probeWindow.ticks.isEmpty else {
            bottleneckProbe = .idle
            return
        }
        let candidates = Self.bottleneckCandidates(from: processGroups)
        // ANE 按需直读,绕开「仅芯片子页刷新」的门控——诊断多在总览页触发。
        //(bottleneckCandidates 的定义在本函数下方)
        let aneNames: [String]? = aneReader.activeClientPIDs().map { resolveNames(for: $0) }
        let diagnosis = BottleneckDiagnosis.diagnose(.init(
            window: probeWindow,
            processes: Array(candidates),
            activeProcessorCount: ProcessInfo.processInfo.activeProcessorCount,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            // 直读本机,不走采集器——采集器掉线时这个证据不能跟着消失。
            lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            aneHolderNames: aneNames,
            anePowerWatts: current.deep.anePowerWatts,
            throttle: windowThrottleDiagnosis()
        ))
        if let diagnosis {
            lastBottleneck = (diagnosis, .now)
            bottleneckProbe = .done(diagnosis, at: .now)
        } else {
            // CPU 都读不到的机器,取样只会一直空转;回 idle 由入口卡重试。
            bottleneckProbe = .idle
        }
    }

    /// 节流结论按**取样窗口**推导,不用结账瞬时值——窗口内降频过、结账时
    /// 恢复了,漏报;反之污染。原料每拍都采在 Tick 里,这里聚合后喂现有判定。
    private func windowThrottleDiagnosis() -> ThrottleDiagnosis? {
        let ticks = probeWindow.ticks
        guard !ticks.isEmpty else { return throttleDiagnosis }
        func mean(_ values: [Double?]) -> Double? {
            let xs = values.compactMap { $0 }
            return xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count)
        }
        let severity: [ThermalLevel: Int] = [.nominal: 0, .unknown: 0, .fair: 1, .serious: 2, .critical: 3]
        let worstThermal = ticks.map(\.thermalLevel).max { (severity[$0] ?? 0) < (severity[$1] ?? 0) } ?? .nominal
        return ThrottleDiagnosis.diagnose(.init(
            clusterActivePercent: mean(ticks.map(\.pClusterActivePercent)),
            clusterFreqMHz: mean(ticks.map { $0.pClusterFreqMHz.map(Double.init) }).map(Int.init),
            clusterMaxFreqMHz: ticks.compactMap(\.pClusterMaxFreqMHz).max(),
            hotspotTemperature: mean(ticks.map(\.hotspotTemperature)),
            thermalLevel: worstThermal,
            lowPowerModeEnabled: ticks.contains { $0.lowPowerModeEnabled },
            onBattery: current.battery.powerSource == .battery
        ))
    }

    /// 诊断的进程候选榜。综合负载前十 + **GPU 最重的过线进程**——
    /// 评审抓获:compositeScore 无 GPU 维(CPU45+内存30+磁盘15+能耗10),
    /// CPU 轻、GPU 重的进程(跑推理的典型形状)进不了前十,GPU 饱和照报
    /// 但点不出名。GPUProcessReader 开头的注释早骂过同款错误,这次自己犯了。
    static func bottleneckCandidates(from groups: [ProcessGroupSnapshot]) -> [BottleneckProcessCandidate] {
        func candidate(_ group: ProcessGroupSnapshot) -> BottleneckProcessCandidate {
            BottleneckProcessCandidate(
                name: group.displayName,
                rawCPUPercent: group.smoothedCPUPercent ?? group.cpuPercent,
                gpuNanosecondsPerSecond: group.gpuNanosecondsPerSecond,
                diskReadBytesPerSecond: group.diskReadBytesPerSecond,
                diskWriteBytesPerSecond: group.diskWriteBytesPerSecond,
                memoryFootprintBytes: group.physicalFootprintBytes
            )
        }
        let others = groups.filter { !$0.isMacPulse }
        var result = others.prefix(10).map(candidate)
        let gpuHeavy = others
            .filter { ($0.gpuNanosecondsPerSecond ?? 0) >= BottleneckDiagnosis.gpuCulpritNanoseconds }
            .max { ($0.gpuNanosecondsPerSecond ?? 0) < ($1.gpuNanosecondsPerSecond ?? 0) }
        if let gpuHeavy, !result.contains(where: { $0.name == gpuHeavy.displayName }) {
            result.append(candidate(gpuHeavy))
        }
        return Array(result)
    }

    /// 收起结果卡。只收 UI 态,lastBottleneck 保留——体检报告的 60 分钟
    /// 窗口不受影响,用户手滑收掉也不丢外发素材。
    func dismissBottleneckResult() {
        if case .done = bottleneckProbe { bottleneckProbe = .idle }
    }

    // MARK: - AI 余额

    func reloadAIProviders() {
        aiConfiguredProviders = AIKeyStore.configuredProviders
    }

    /// 刷新余额与本地用量。非强制时 15 分钟节流——余额不是秒级数据,
    /// 高频轮询只是在骚扰服务商和费电。
    func refreshAIBalances(force: Bool = false) {
        reloadAIProviders()
        if !force, let last = aiBalanceRefreshedAt,
           Date().timeIntervalSince(last) < 900 { return }
        guard !aiBalanceRefreshInFlight else { return }
        guard !aiConfiguredProviders.isEmpty || claudeCodeUsage == nil else {
            // 没配任何服务商时只刷本地用量。
            refreshClaudeCodeUsageOnly()
            return
        }
        aiBalanceRefreshInFlight = true
        let providers = aiConfiguredProviders
        Task { [weak self] in
            guard let self else { return }
            var readings: [AIBalanceReading] = []
            var errors: [AIProvider: String] = [:]
            for provider in providers {
                guard let key = AIKeyStore.load(for: provider) else { continue }
                switch await self.aiBalanceService.fetch(provider: provider, key: key) {
                case .success(let reading): readings.append(reading)
                case .failure(let error): errors[provider] = error.message
                }
            }
            let usage = await Task.detached(priority: .utility) {
                ClaudeCodeUsageReader.todayUsage()
            }.value
            let codex = await Task.detached(priority: .utility) {
                CodexQuotaReader.latestQuota()
            }.value
            var claude: SubscriptionQuota?
            if UserDefaults.standard.bool(forKey: "claudeSubscriptionEnabled") {
                claude = await self.claudeSubscriptionReader.fetch()
            }
            self.aiBalances = readings
            self.aiBalanceErrors = errors
            self.claudeCodeUsage = usage
            self.codexQuota = codex
            // 429 等瞬时失败时保留上一次的好数据(带时间戳),不闪没。
            if let claude { self.claudeQuota = claude }
            self.aiBalanceRefreshedAt = .now
            self.aiBalanceRefreshInFlight = false
        }
    }

    private func refreshClaudeCodeUsageOnly() {
        Task { [weak self] in
            let usage = await Task.detached(priority: .utility) {
                ClaudeCodeUsageReader.todayUsage()
            }.value
            self?.claudeCodeUsage = usage
            self?.aiBalanceRefreshedAt = .now
        }
    }

    // MARK: - 跳转通道

    func requestNavigation(section: AppSection, pane: PerformancePane? = nil) {
        navigationRequest = NavigationRequest(section: section, pane: pane)
    }

    func consumeNavigationRequest() {
        navigationRequest = nil
    }

    /// 记录一次热降频事件。同一次持续降频只记开头——
    /// 每 2 秒记一条会把「一次长时间过热」灌成几百条,规律反而看不见。
    private func recordThrottleEventIfNeeded() {
        guard throttleDiagnosis?.kind == .thermal else { return }
        let now = Date()
        // 5 分钟内算同一次事件。
        if let last = throttleEvents.last, now.timeIntervalSince(last) < 300 { return }
        throttleEvents.append(now)
        let cutoff = now.addingTimeInterval(-7 * 86_400)
        throttleEvents.removeAll { $0 < cutoff }
    }

    /// 汇总全 App 的诊断结论,生成一页可外发的体检报告。
    /// 各页的判定逻辑都不在这里重写——这里只做收集与排序,
    /// 任何一条结论变了,报告自动跟着变。
    func buildHealthReport() -> HealthReport {
        var items: [HealthReport.Item] = []
        var missing: [String] = []
        let battery = current.battery
        let deep = current.deep

        // 电池健康
        if let health = battery.healthPercent {
            let cycles = battery.cycleCount.map { String(format: String(localized: ",循环 %@ 次"), String(describing: $0)) } ?? ""
            items.append(.init(
                level: health < 80 ? .warning : .ok,
                category: String(localized: "电池健康"),
                summary: "\(Int(health.rounded()))%\(cycles)",
                detail: health < 80 ? String(localized: "低于 80% 通常意味着该考虑更换电池了。") : nil
            ))
        } else {
            missing.append(String(localized: "电池健康度"))
        }

        // 充电链路
        if let verdict = chargeLinkDiagnosis {
            items.append(.init(
                level: verdict.isWarning ? .warning : .ok,
                category: String(localized: "充电链路"),
                summary: verdict.summary,
                detail: verdict.isWarning ? verdict.detail : nil
            ))
        }

        // 内存
        if let verdict = memoryDiagnosis {
            items.append(.init(
                level: verdict.isWarning ? .warning : (verdict.kind == .comfortable ? .ok : .notice),
                category: String(localized: "内存"),
                summary: verdict.summary,
                detail: verdict.kind == .comfortable ? nil : verdict.detail
            ))
        } else {
            missing.append(String(localized: "内存分项"))
        }

        // 热与降频
        if let hotspot = deep.hotspotTemperature {
            let recent = throttleEvents.count
            items.append(.init(
                level: recent > 0 ? .notice : .ok,
                category: String(localized: "温度"),
                summary: recent > 0
                    ? String(format: String(localized: "当前 %.0f°C,本次运行期间热降频 %d 次"), hotspot, recent)
                    : String(format: String(localized: "当前 %.0f°C,未见热降频"), hotspot),
                detail: recent > 2 ? String(localized: "频繁降频会持续拖慢性能,改善散热或减少同时运行的重负载可缓解。") : nil
            ))
        } else {
            missing.append(String(localized: "芯片温度"))
        }

        // 瞬时瓶颈。报告的用途是外发求助,「我的机器为什么卡」正是求助的
        // 第一句话——这是全 App 唯一能点名回答它的结论。60 分钟新鲜度门:
        // 过期的瞬时结论比没有更误导,按缺失处理并教用户去哪重新生成。
        if let last = lastBottleneck, Date().timeIntervalSince(last.at) < 3_600 {
            let age = Date().timeIntervalSince(last.at)
            // 与总览卡同一把尺:不到 90 秒叫「刚刚」,不吹成「1 分钟前」。
            let stamp = age < 90
                ? String(localized: "刚刚")
                : String(format: String(localized: "%@ 分钟前"), String(describing: Int(age / 60)))
            items.append(.init(
                level: last.diagnosis.isWarning ? .warning
                    : (last.diagnosis.kind == .noBottleneck ? .ok : .notice),
                category: String(localized: "瞬时瓶颈"),
                summary: String(
                    format: String(localized: "%@(诊断于%@)"),
                    last.diagnosis.summary, stamp
                ),
                detail: last.diagnosis.isWarning ? last.diagnosis.detail : nil
            ))
        } else {
            missing.append(String(localized: "瞬时瓶颈(在总览页点「为什么卡」后重新生成)"))
        }

        // 睡眠掉电
        if let session = sleepSessions.first(where: { $0.onBattery }) {
            let verdict = SleepDiagnosis.diagnose(session)
            items.append(.init(
                level: verdict.isWarning ? .warning : .ok,
                category: String(localized: "睡眠掉电"),
                summary: verdict.summary,
                detail: verdict.isWarning ? verdict.detail : nil
            ))
        } else {
            missing.append(String(localized: "睡眠掉电(近期没有电池睡眠记录)"))
        }

        // 存储。没逛过磁盘页时数据是空的——必须说出来,
        // 否则读者会把「报告里没提存储」当成「存储没问题」。
        if diskOverview == nil { missing.append(String(localized: "存储(打开性能→磁盘页后重新生成)")) }
        if let root = diskOverview?.volumes.first(where: \.isRoot) {
            let freeRatio = Double(root.availableBytes) / Double(max(1, root.totalBytes))
            items.append(.init(
                level: freeRatio < 0.1 ? .warning : .ok,
                category: String(localized: "存储"),
                summary: String(format: String(localized: "启动卷剩余 %@ / 共 %@"), String(describing: MetricFormat.storageBytes(UInt64(root.availableBytes))), String(describing: MetricFormat.storageBytes(UInt64(root.totalBytes)))),
                detail: freeRatio < 0.1 ? String(localized: "可用空间低于一成,系统与 App 都会受影响。") : nil
            ))
        }

        // 自启项。同上:没逛过启动项页就没有数据。
        if backgroundItems.isEmpty { missing.append(String(localized: "开机自启(打开性能→启动项页后重新生成)")) }
        if !backgroundItems.isEmpty {
            let running = backgroundItems.filter(\.isRunning).count
            items.append(.init(
                level: running > 8 ? .notice : .ok,
                category: String(localized: "开机自启"),
                summary: String(format: String(localized: "%@ 项第三方自启,%@ 项正在运行"), String(describing: backgroundItems.count), String(describing: running)),
                detail: running > 8 ? String(localized: "自启项越多,开机越慢、后台常驻耗电越多。") : nil
            ))
        }

        // 显示器。外接屏跑不满才是问题,内置屏自适应刷新不算。
        if displays.isEmpty { missing.append(String(localized: "显示器(打开性能→芯片页后重新生成)")) }
        if let limited = displays.first(where: \.isBelowMaxRefresh), let max = limited.maxRefreshHz {
            items.append(.init(
                level: .notice,
                category: String(localized: "显示器"),
                summary: String(format: String(localized: "「%@」跑在 %@Hz,低于它支持的 %@Hz"), String(describing: limited.name), String(describing: Int(limited.refreshHz ?? 0)), String(describing: Int(max))),
                detail: String(localized: "外接屏跑不满通常是线材或转接头带宽不够。")
            ))
        }

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return HealthReport(
            machine: deep.chip?.name ?? "Mac",
            systemVersion: "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            appVersion: version,
            generatedAt: .now,
            items: items,
            unavailable: missing
        )
    }

    /// 睡眠记录后台刷新。读取器内部按 10 分钟节流,这里只管发起,不等结果。
    private func refreshSleepSessions() {
        Task { [weak self] in
            guard let self else { return }
            let sessions = await self.sleepReader.sessions()
            self.sleepSessions = sessions
        }
    }

    /// 把启动项与进程采样结果对账:能配上 PID 的填真实占用,
    /// 配不上的留空——「在跑」和「吃多少」是两件事,不硬凑。
    private func enrich(_ items: [BackgroundItem]) -> [BackgroundItem] {
        var byPID: [Int32: ProcessGroupSnapshot] = [:]
        for group in processGroups {
            byPID[group.primaryPID] = group
            for child in group.children { byPID[child.pid] = group }
        }
        return items.map { item in
            var copy = item
            if let pid = item.pid, let group = byPID[pid] {
                copy.cpuPercent = group.smoothedCPUPercent ?? group.cpuPercent
                copy.memoryBytes = group.physicalFootprintBytes
            }
            return copy
        }
    }

    /// 设置页出现或 App 回到前台时重查通知权限。
    /// 旧版只在启动时查一次:用户去系统设置授了权回来,App 还显示「已关闭」,
    /// 且提醒因为同一个陈旧缓存被静默丢弃——绿灯坏灯都可能是假的。
    func refreshNotificationAuthorization() async {
        notificationAuthorizationStatus = await notifications.refreshAuthorizationStatus()
    }

    private static func describe(_ state: UpgradeBackupState) -> String? {
        switch state {
        case let .created(url, bytes):
            let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            return String(format: String(localized: "已保留升级前备份（%@）：%@"), String(describing: size), String(describing: url.lastPathComponent))
        case let .alreadyExists(url):
            return String(format: String(localized: "已保留升级前备份：%@"), String(describing: url.lastPathComponent))
        case .notNeeded:
            return nil
        case let .failed(reason):
            return String(format: String(localized: "升级前备份失败：%@"), String(describing: reason))
        }
    }

    private func updateSamplingMode() {
        let desired: TimeInterval = activePresentations > 0 ? 2 : 10
        guard desired != sampleInterval else { return }
        sampleInterval = desired
        collector.setSampleInterval(desired)
        restartSampler()
    }

    private var processMonitoringEnabled: Bool {
        UserDefaults.standard.object(forKey: "processMonitoringEnabled") as? Bool ?? true
    }

    private var processHistoryEnabled: Bool {
        UserDefaults.standard.object(forKey: "processHistoryEnabled") as? Bool ?? true
    }

    private var processSampleInterval: TimeInterval {
        if processPageActive, activePresentations > 0 { return 5 }
        if activePresentations > 0 { return 15 }
        return 30
    }

    private func restartSampler() {
        guard started, !suspended else { return }
        samplerTask?.cancel()
        let interval = sampleInterval
        samplerTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    private func restartProcessSampler(resetBaseline: Bool = false) {
        processSamplerTask?.cancel()
        processSamplerTask = nil
        guard started, !suspended, processMonitoringEnabled else {
            if !processMonitoringEnabled {
                processMonitorStatus = ProcessMonitorStatus(phase: .disabled)
            }
            return
        }

        let interval = processSampleInterval
        processMonitorStatus.phase = processGroups.isEmpty ? .starting : processMonitorStatus.phase
        processSamplerTask = Task { [weak self] in
            guard let self else { return }
            if resetBaseline {
                await processSampler.reset()
            }
            while !Task.isCancelled {
                let result = await processSampler.sample()
                guard !Task.isCancelled else { return }
                receiveProcessSample(result)
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    return
                }
            }
        }
    }

    private func receiveProcessSample(_ result: ProcessSamplingResult) {
        processGroups = result.groups
        processGeneration += 1
        processMonitorStatus = result.status
        guard processHistoryEnabled, let timestamp = result.status.lastUpdated else { return }
        if let completed = processAggregator.append(
            timestamp: timestamp,
            groups: result.groups
        ) {
            persistProcessPoints(completed)
        }
    }

    private func refresh() async {
        // refresh 现在有 await，中途会让出 MainActor。采样循环本身是串行的，
        // 但 restartSampler / resume 可能在旧任务刚过取消检查、正挂在 actor 上时
        // 起一个新循环——那样两次 refresh 会交错修改 current / liveHistory /
        // aggregator。用一个重入闸把它挡掉。
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        // 电池读取搬到 actor 上：IORegistry 全树 dump 不再阻塞主线程。
        // actor 返回的是 Sendable 值类型，CF/NS 类型不跨隔离边界。
        // 拿不到时退回旧的整树读法，保证任何机型上都不会读不出电池。
        let battery = await batterySampler.sample() ?? BatteryReader.read()
        let publicMetrics = fallback.read()
        var deep = latestDeep
        let staleAfter = max(12, sampleInterval * 3)

        if let lastCollectorUpdate, Date().timeIntervalSince(lastCollectorUpdate) > staleAfter {
            latestDeep = DeepMetrics()
            deep = DeepMetrics()
            collectorStatus.phase = .reconnecting
            collectorStatus.lastErrorCode = "collector_stale"
        }

        if deep.cpuUsagePercent == nil { deep.cpuUsagePercent = publicMetrics.cpuUsagePercent }
        if deep.thermalLevel == .unknown { deep.thermalLevel = publicMetrics.thermalLevel }
        deep.collectorAvailable = [.live, .degraded].contains(collectorStatus.phase)

        // 内存与每核占用一律走本机读数，不再和采集器的口径混用。
        // 原先 mactop 的 `total − (free + inactive)` 与本地的 `active + wired + compressor`
        // 会随采集器上下线互相顶替，同一时刻的「已用内存」相差约 0.7GB，
        // 界面上表现为重连一次就跳一次。现在只有一个口径。
        memory = fallback.memoryBreakdown()
        memoryExtras = fallback.memoryExtras()
        memoryRates = fallback.memoryRates()
        gpuDeviceUtilizationPercent = GPUUtilizationReader.read()
        if let cores = fallback.perCoreUsage() { perCoreUsage = cores }
        // 只在芯片页可见时扫 ANE 持有者——这是一次 IORegistry 子树遍历，
        // 没人看的时候没有理由跑。
        if visiblePane == .soc {
            aneHolderPIDs = aneReader.activeClientPIDs()
        }
        // 充电链路同理：PD 节点遍历只在电池页或总览可见时跑(总览的
        // 「充电结论」卡也要它)。外设电量只属于电池页。
        if batteryPageActive || overviewActive {
            chargeLink = await chargeLinkSampler.sample()
        }
        if batteryPageActive {
            peripheralBatteries = await peripheralReader.sample()
            notifications.evaluatePeripherals(peripheralBatteries)
            // 睡眠日志绝不能在这里 await:pmset 光是吐 13 万行就要 6 秒,
            // 而 refresh 全程持着重入闸——等它等于让所有实时数字冻住六到九秒。
            // 甩给独立任务,读取器自带 10 分钟节流,不会重复触发。
            refreshSleepSessions()
        }
        // 磁盘面板同理:只在磁盘子页可见时刷新。
        if visiblePane == .disk {
            diskOverview = DiskStatsReader.read()
        }
        // 屏幕信息是 CoreGraphics 直读,便宜,跟着芯片页刷新即可。
        if visiblePane == .soc {
            displays = DisplayReader.read()
        }
        // 启动项:launchctl 是子进程,读取走后台线程,主线程不等它。
        if visiblePane == .startup {
            backgroundItems = enrich(await LoginItemsReader.read())
        }

        let snapshot = MetricSnapshot(timestamp: .now, battery: battery, deep: deep)
        current = snapshot
        // 必须在 current 更新之后判:放在前面读到的是上一拍的旧快照。
        recordThrottleEventIfNeeded()
        captureBottleneckTickIfNeeded()
        updateRuntimeEstimate(snapshot)
        isLoading = false
        notifications.evaluate(snapshot)
        if let completedMinute = aggregator.append(snapshot) {
            persist(completedMinute)
        }

        liveHistory.append(HistoryPoint(snapshot: snapshot))
        let liveCutoff = Date().addingTimeInterval(-600)
        liveHistory.removeAll { $0.timestamp < liveCutoff }

    }

    private func persist(_ point: HistoryPoint) {
        // 学习走分钟均值这条路，绝不用 chartPoints——那里把磁盘分钟均值和
        // 2–10 秒的实时点串在一起，拿去学会把最近 10 分钟加权约 30 倍。
        learnFromMinute(point)
        guard let historyStore else { return }
        do {
            try historyStore.save(point)
            history.append(point)
            let cutoff = Date().addingTimeInterval(-7 * 86_400)
            history.removeAll { $0.timestamp < cutoff }
            try historyStore.prune()
            if !historyStoreStatus.hasPrefix(String(localized: "已安全迁移")) {
                historyStoreStatus = String(localized: "历史数据正常")
            }
        } catch {
            historyStoreStatus = String(format: String(localized: "历史数据写入失败：%@"), String(describing: error.localizedDescription))
        }
    }

    private func persistProcessPoints(_ points: [ProcessHistoryPoint]) {
        guard processHistoryEnabled, !points.isEmpty, let processHistoryStore else { return }
        do {
            try processHistoryStore.save(points)
            try processHistoryStore.prune()
            for point in points where processHistoryCache[point.stableIdentifier] != nil {
                processHistoryCache[point.stableIdentifier, default: []].append(point)
                let cutoff = Date().addingTimeInterval(-7 * 86_400)
                processHistoryCache[point.stableIdentifier]?.removeAll {
                    $0.timestamp < cutoff
                }
            }
            processHistoryStatus = String(localized: "重点进程历史正常")
        } catch {
            processHistoryStatus = String(format: String(localized: "进程历史写入失败：%@"), String(describing: error.localizedDescription))
        }
    }
}
