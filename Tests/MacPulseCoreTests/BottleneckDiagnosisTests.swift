import Foundation
import XCTest
@testable import MacPulseCore

/// 「为什么卡」瓶颈判定。场景 fixtures 覆盖:旗舰组合(GPU+换页)、纯换页、
/// 热降频、单核钉死、磁盘忙、低电量、全余量、采集器掉线、缺输入、阈值边界。
final class BottleneckDiagnosisTests: XCTestCase {

    private let mb: Double = 1_048_576
    private let gb: UInt64 = 1_073_741_824

    private func rates(
        swapin: Double = 0, swapout: Double = 0,
        compression: Double = 0, decompression: Double = 0
    ) -> MemoryRates {
        .init(
            pageinBytesPerSecond: 0, pageoutBytesPerSecond: 0,
            swapinBytesPerSecond: swapin, swapoutBytesPerSecond: swapout,
            compressionBytesPerSecond: compression, decompressionBytesPerSecond: decompression
        )
    }

    private func tick(
        cpu: Double? = 20,
        perCore: [Double] = [15, 20, 25, 18],
        gpu: Double? = 10,
        memRates: MemoryRates? = nil,
        pressure: MemoryPressureLevel = .normal,
        diskRead: Double? = 5_000_000, diskWrite: Double? = 5_000_000,
        hotspot: Double? = 55,
        collectorLive: Bool = true
    ) -> BottleneckProbeWindow.Tick {
        .init(
            cpuUsagePercent: cpu, perCoreUsage: perCore, gpuUsagePercent: gpu,
            memoryRates: memRates ?? rates(), memoryPressure: pressure,
            diskReadBytesPerSecond: diskRead, diskWriteBytesPerSecond: diskWrite,
            hotspotTemperature: hotspot, collectorLive: collectorLive
        )
    }

    private func input(
        ticks: [BottleneckProbeWindow.Tick],
        processes: [BottleneckProcessCandidate] = [],
        cores: Int = 10,
        physicalMemory: UInt64 = 24 * 1_073_741_824,
        lowPower: Bool = false,
        aneHolders: [String]? = nil,
        aneWatts: Double? = nil,
        throttle: ThrottleDiagnosis? = nil
    ) -> BottleneckDiagnosis.Input {
        .init(
            window: .init(ticks: ticks), processes: processes,
            activeProcessorCount: cores, physicalMemoryBytes: physicalMemory,
            lowPowerModeEnabled: lowPower, aneHolderNames: aneHolders,
            anePowerWatts: aneWatts, throttle: throttle
        )
    }

    // MARK: 旗舰场景:AI 推理(GPU 饱和 + 换页)

    func testGPUSaturationWithThrashIsFlagshipVerdict() throws {
        let thrash = rates(swapin: 18 * mb, swapout: 26 * mb)
        let lmStudio = BottleneckProcessCandidate(
            name: "LM Studio", rawCPUPercent: 120,
            gpuNanosecondsPerSecond: 9.4e8, memoryFootprintBytes: 30 * gb
        )
        let verdict = try XCTUnwrap(BottleneckDiagnosis.diagnose(input(
            ticks: [
                tick(cpu: 35, gpu: 96, memRates: thrash, pressure: .warning),
                tick(cpu: 38, gpu: 94, memRates: thrash, pressure: .warning),
                tick(cpu: 33, gpu: 97, memRates: thrash, pressure: .warning),
            ],
            processes: [lmStudio],
            physicalMemory: 48 * gb
        )))
        XCTAssertEqual(verdict.kind, .gpuSaturatedMemoryThrash)
        XCTAssertTrue(verdict.isWarning)
        XCTAssertTrue(verdict.summary.contains("LM Studio"), "点得出名就要点名")
        XCTAssertTrue(verdict.summary.contains("换页"), "配对模板要同含 GPU 与换页两个分句")
        // findings 是两条原子结论,组合 case 只在总体 kind。
        XCTAssertEqual(verdict.findings.count, 2)
        XCTAssertTrue(verdict.findings.contains { $0.kind == .gpuSaturated })
        XCTAssertTrue(verdict.findings.contains { $0.kind == .memoryThrash })
        // 诚实红线:进程 GPU 证据只报 ms/s,绝不出现「占 GPU x%」。
        let gpuEvidence = verdict.findings.first { $0.kind == .gpuSaturated }!.evidence.joined()
        XCTAssertTrue(gpuEvidence.contains("ms/s"))
        XCTAssertTrue(gpuEvidence.contains("940"), "9.4e8 ns/s = 940 ms/s")
    }

    // MARK: 纯换页

    func testPureThrashWithoutBigProcessDoesNotAccuse() throws {
        let thrash = rates(swapin: 20 * mb, swapout: 20 * mb)
        let small = BottleneckProcessCandidate(name: "Safari", memoryFootprintBytes: 3 * gb)
        let verdict = try XCTUnwrap(BottleneckDiagnosis.diagnose(input(
            ticks: [
                tick(gpu: 12, memRates: thrash, pressure: .critical),
                tick(gpu: 10, memRates: thrash, pressure: .critical),
                tick(gpu: 11, memRates: thrash, pressure: .critical),
            ],
            processes: [small]
        )))
        XCTAssertEqual(verdict.kind, .memoryThrash)
        XCTAssertTrue(verdict.isWarning)
        // 3GB / 24GB < 25%:证据不足不点名——换页是全局现象,点名要谨慎。
        XCTAssertNil(verdict.findings.first { $0.kind == .memoryThrash }?.culpritName)
    }

    func testOneWayEvictionIsNotThrash() {
        // 单向大换出只是驱逐,双向门槛拦住它。
        let evict = rates(swapin: 1 * mb, swapout: 60 * mb)
        let verdict = BottleneckDiagnosis.diagnose(input(
            ticks: [tick(memRates: evict), tick(memRates: evict), tick(memRates: evict)]
        ))
        XCTAssertEqual(verdict?.kind, .noBottleneck, "单向驱逐不能定罪 thrash")
    }

    // MARK: 热降频压住一切

    func testThermalThrottleBeatsCPUSaturation() throws {
        let throttle = try XCTUnwrap(ThrottleDiagnosis.diagnose(.init(
            clusterActivePercent: 92, clusterFreqMHz: 2280, clusterMaxFreqMHz: 3808,
            hotspotTemperature: 96, thermalLevel: .serious,
            lowPowerModeEnabled: false, onBattery: false
        )))
        XCTAssertEqual(throttle.kind, .thermal, "前提:节流诊断本身判热降频")
        let verdict = try XCTUnwrap(BottleneckDiagnosis.diagnose(input(
            ticks: [tick(cpu: 92, hotspot: 96), tick(cpu: 90, hotspot: 96), tick(cpu: 93, hotspot: 95)],
            throttle: throttle
        )))
        XCTAssertEqual(verdict.kind, .thermalThrottle, "硬件级限速解释一切,必须是头条")
        XCTAssertTrue(verdict.isWarning)
        XCTAssertTrue(verdict.findings.contains { $0.kind == .cpuSaturated }, "CPU 饱和仍在 findings 里,不吞")
    }

    // MARK: 单核钉死

    func testSingleCorePinnedWhileMachineIdle() throws {
        let stuck = BottleneckProcessCandidate(name: "BadApp", rawCPUPercent: 99)
        let verdict = try XCTUnwrap(BottleneckDiagnosis.diagnose(input(
            ticks: [
                tick(cpu: 18, perCore: [97, 12, 8, 10, 6, 5, 9, 7, 4, 3]),
                tick(cpu: 16, perCore: [96, 10, 9, 8, 7, 6, 5, 4, 3, 2]),
                tick(cpu: 19, perCore: [98, 14, 7, 9, 5, 4, 8, 6, 3, 2]),
            ],
            processes: [stuck]
        )))
        XCTAssertEqual(verdict.kind, .singleCoreBound)
        XCTAssertFalse(verdict.isWarning, "是那个 App 卡,不是系统故障")
        XCTAssertEqual(verdict.findings.first?.culpritName, "BadApp")
        XCTAssertFalse(verdict.findings.contains { $0.kind == .cpuSaturated }, "与 cpuSaturated 互斥")
    }

    /// 实测回归(2026-08-15,M5/10 核):单个 yes 进程在核间迁移,
    /// 每核视图没有任何核持续 ≥95,但进程 raw≈100、整机 29%——
    /// 进程侧证据必须独立成立,否则单线程钉死全部漏报。
    func testSingleThreadMigratingAcrossCoresStillDetected() throws {
        let yes = BottleneckProcessCandidate(name: "yes", rawCPUPercent: 99)
        let verdict = try XCTUnwrap(BottleneckDiagnosis.diagnose(input(
            ticks: [
                tick(cpu: 29, perCore: [62, 55, 20, 12, 8, 6, 30, 24, 10, 7]),
                tick(cpu: 27, perCore: [40, 70, 25, 10, 6, 5, 28, 20, 8, 6]),
                tick(cpu: 30, perCore: [55, 48, 30, 14, 9, 7, 26, 22, 12, 8]),
            ],
            processes: [yes]
        )))
        XCTAssertEqual(verdict.kind, .singleCoreBound)
        XCTAssertEqual(verdict.findings.first?.culpritName, "yes")
    }

    func testParallelProcessOnIdleMachineIsNotSingleCoreBound() throws {
        // raw 300% 的并行负载在空闲机器上:不是单核形状,不许误报。
        let parallel = BottleneckProcessCandidate(name: "ffmpeg", rawCPUPercent: 300)
        let verdict = try XCTUnwrap(BottleneckDiagnosis.diagnose(input(
            ticks: [
                tick(cpu: 32, perCore: [40, 38, 35, 30, 28, 25, 33, 31, 29, 27]),
                tick(cpu: 30, perCore: [38, 36, 33, 31, 27, 24, 30, 29, 28, 26]),
                tick(cpu: 31, perCore: [39, 37, 34, 30, 26, 25, 31, 30, 27, 25]),
            ],
            processes: [parallel]
        )))
        XCTAssertEqual(verdict.kind, .noBottleneck)
    }

    func testSingleCoreNotTriggeredWhenWholeMachineBusy() throws {
        // 总负载 ≥50 时单核判据让位——那只是并行重活的一部分。
        let verdict = try XCTUnwrap(BottleneckDiagnosis.diagnose(input(
            ticks: [
                tick(cpu: 88, perCore: [97, 90, 85, 88, 80, 82, 91, 87, 84, 86]),
                tick(cpu: 90, perCore: [98, 92, 88, 85, 83, 84, 90, 89, 86, 85]),
                tick(cpu: 87, perCore: [96, 89, 87, 84, 82, 85, 88, 90, 83, 84]),
            ]
        )))
        XCTAssertEqual(verdict.kind, .cpuSaturated)
    }

    // MARK: 磁盘忙(证据弱,措辞必须诚实)

    func testDiskBusyIsHonestAboutCausality() throws {
        let verdict = try XCTUnwrap(BottleneckDiagnosis.diagnose(input(
            ticks: [
                tick(diskRead: 350 * mb, diskWrite: 250 * mb),
                tick(diskRead: 400 * mb, diskWrite: 200 * mb),
                tick(diskRead: 380 * mb, diskWrite: 240 * mb),
            ]
        )))
        XCTAssertEqual(verdict.kind, .diskBusy)
        XCTAssertFalse(verdict.isWarning)
        let evidence = verdict.findings.first { $0.kind == .diskBusy }!.evidence.joined()
        XCTAssertTrue(evidence.contains("不一定"), "没有延迟数据就不许断言因果")
    }

    // MARK: 低电量模式

    func testLowPowerModeOnlyReportedUnderDemand() throws {
        // 有需求被压着 → 报。
        let capped = try XCTUnwrap(BottleneckDiagnosis.diagnose(input(
            ticks: [tick(cpu: 65), tick(cpu: 68), tick(cpu: 66)],
            lowPower: true
        )))
        XCTAssertEqual(capped.kind, .lowPowerCapped)
        XCTAssertFalse(capped.isWarning, "用户主动省电不是警告")
        // 空闲 + LPM → 不报。
        let idle = try XCTUnwrap(BottleneckDiagnosis.diagnose(input(
            ticks: [tick(cpu: 10), tick(cpu: 12), tick(cpu: 8)],
            lowPower: true
        )))
        XCTAssertEqual(idle.kind, .noBottleneck)
    }

    // MARK: 全余量(「没瓶颈」是有内容的结论)

    func testNoBottleneckGivesMarginsAndMainThreadHint() throws {
        let verdict = try XCTUnwrap(BottleneckDiagnosis.diagnose(input(
            ticks: [tick(), tick(), tick()]
        )))
        XCTAssertEqual(verdict.kind, .noBottleneck)
        XCTAssertFalse(verdict.isWarning)
        XCTAssertTrue(verdict.detail.contains("余量"), "必须给余量数字")
        XCTAssertTrue(verdict.detail.contains("主线程"), "每核在场且单核未触发时给主线程提示")
        XCTAssertTrue(verdict.findings.isEmpty)
    }

    func testNoBottleneckWithoutPerCoreOmitsMainThreadHint() throws {
        let verdict = try XCTUnwrap(BottleneckDiagnosis.diagnose(input(
            ticks: [tick(perCore: []), tick(perCore: []), tick(perCore: [])]
        )))
        XCTAssertEqual(verdict.kind, .noBottleneck)
        XCTAssertFalse(verdict.detail.contains("主线程"), "每核数据缺席就不敢把矛头指向 App")
        XCTAssertTrue(verdict.unobserved.contains { $0.contains("每核") })
    }

    // MARK: 采集器掉线(降级与诚实)

    func testCollectorOfflineWithQuietCPUIsInsufficientEvidence() throws {
        let offline = tick(cpu: 30, gpu: nil, diskRead: nil, diskWrite: nil, hotspot: nil, collectorLive: false)
        let verdict = try XCTUnwrap(BottleneckDiagnosis.diagnose(input(
            ticks: [offline, offline, offline]
        )))
        XCTAssertEqual(verdict.kind, .insufficientEvidence)
        XCTAssertEqual(verdict.unobserved.count, 3, "GPU、磁盘、芯片温度三项都要列出来")
        XCTAssertTrue(verdict.detail.contains("没看到"))
    }

    func testCollectorOfflineStillConvictsCPU() throws {
        let offline = tick(cpu: 92, gpu: nil, diskRead: nil, diskWrite: nil, hotspot: nil, collectorLive: false)
        let verdict = try XCTUnwrap(BottleneckDiagnosis.diagnose(input(
            ticks: [offline, offline, offline]
        )))
        XCTAssertEqual(verdict.kind, .cpuSaturated, "可见证据足以定罪时照常定罪")
        XCTAssertFalse(verdict.unobserved.isEmpty, "但没看到的仍要列出")
    }

    func testSingleTickFromCollectorCannotCarryVerdict() throws {
        // 采集器中途上线:只有一拍 GPU 数据,不足以「被观测到」(≥2 拍)。
        let verdict = try XCTUnwrap(BottleneckDiagnosis.diagnose(input(
            ticks: [
                tick(gpu: nil, collectorLive: false),
                tick(gpu: nil, collectorLive: false),
                tick(gpu: 99),
            ]
        )))
        XCTAssertNotEqual(verdict.kind, .gpuSaturated, "单拍数据不许撑起一个结论")
    }

    // MARK: 缺必需输入

    func testEmptyWindowYieldsNil() {
        XCTAssertNil(BottleneckDiagnosis.diagnose(input(ticks: [])))
    }

    func testAllCPUMissingYieldsNil() {
        XCTAssertNil(BottleneckDiagnosis.diagnose(input(
            ticks: [tick(cpu: nil), tick(cpu: nil), tick(cpu: nil)]
        )), "CPU 是唯一无条件可得的信号,连它都没有就什么都别说")
    }

    // MARK: 阈值边界

    func testGPUMeanBoundary() throws {
        // 均值恰 90 触发;89.9 不触发。
        let at = try XCTUnwrap(BottleneckDiagnosis.diagnose(input(
            ticks: [tick(gpu: 90), tick(gpu: 90), tick(gpu: 90)]
        )))
        XCTAssertEqual(at.kind, .gpuSaturated)
        let below = try XCTUnwrap(BottleneckDiagnosis.diagnose(input(
            ticks: [tick(gpu: 89.9), tick(gpu: 89.9), tick(gpu: 89.9)]
        )))
        XCTAssertEqual(below.kind, .noBottleneck)
    }

    func testGPUTickFloorRejectsSpikes() throws {
        // 均值 93 但有一拍 79:低于每拍下限 80,不许放行。
        let verdict = try XCTUnwrap(BottleneckDiagnosis.diagnose(input(
            ticks: [tick(gpu: 100), tick(gpu: 100), tick(gpu: 79)]
        )))
        XCTAssertNotEqual(verdict.kind, .gpuSaturated, "一拍尖峰拉高的均值不算持续饱和")
    }

    func testSingleCoreTotalCeilingBoundary() throws {
        // 总负载恰 50:不触发单核判据(要求 <50)。
        let verdict = try XCTUnwrap(BottleneckDiagnosis.diagnose(input(
            ticks: [
                tick(cpu: 50, perCore: [97, 40, 45, 42]),
                tick(cpu: 50, perCore: [96, 44, 41, 43]),
                tick(cpu: 50, perCore: [98, 42, 40, 44]),
            ]
        )))
        XCTAssertEqual(verdict.kind, .noBottleneck)
    }

    // MARK: 交叉评审回归(2026-08-15,另一 AI 构造的反例)

    /// 评审反例:四个核各 100%、总负载 40%、进程 raw 400%——旧判据照样报
    /// 「一个核被跑满,其余大多空闲」且点不出名。并行负载不是单核瓶颈,
    /// 核视图证据现在要求平均热核数 ≤1.5。
    func testFourBusyCoresAreNotSingleCoreBound() throws {
        let parallel = BottleneckProcessCandidate(name: "make", rawCPUPercent: 400)
        let cores: [Double] = [100, 100, 100, 100, 5, 4, 6, 3, 2, 4]
        let verdict = try XCTUnwrap(BottleneckDiagnosis.diagnose(input(
            ticks: [tick(cpu: 40, perCore: cores), tick(cpu: 41, perCore: cores), tick(cpu: 39, perCore: cores)],
            processes: [parallel]
        )))
        XCTAssertNotEqual(verdict.kind, .singleCoreBound, "四个热核不是「一个核被跑满」")
        XCTAssertEqual(verdict.kind, .noBottleneck)
    }

    /// 评审反例:单拍 GPU=100 曾能直接定罪「GPU 已被吃满」——超时只剩 1 拍时
    /// observedFloor 被 min(2,count) 降到 1。现在门槛无条件为 2:
    /// 单拍窗口连 CPU 都算未观测,diagnose 返回 nil,宁可没有结论。
    func testSingleTickWindowYieldsNoVerdict() {
        XCTAssertNil(BottleneckDiagnosis.diagnose(input(
            ticks: [tick(cpu: 30, gpu: 100)]
        )), "单拍不许出任何结论")
    }

    /// capture 契约:超时也先收拍再结案,collected 恒等于真实拍数——
    /// 旧状态机超时先 return 丢拍,再把 UI 谎报成 3/3。
    func testCaptureCollectsTickOnTimeoutAndNeverLies() {
        var window = BottleneckProbeWindow()
        // 正常两拍
        XCTAssertEqual(window.capture(tick(), elapsed: 2), .sampling(collected: 1))
        XCTAssertEqual(window.capture(tick(), elapsed: 4), .sampling(collected: 2))
        // 第三拍超时:仍要收下,结案时报真实数 3
        XCTAssertEqual(window.capture(tick(), elapsed: 25), .settle(collected: 3))
        XCTAssertEqual(window.ticks.count, 3)
        // 超时早收工:1 拍就结案,collected 如实为 1(下游 diagnose 会拒绝定罪)
        var short = BottleneckProbeWindow()
        XCTAssertEqual(short.capture(tick(), elapsed: 30), .settle(collected: 1))
        XCTAssertEqual(short.ticks.count, 1)
    }

    /// 攒满三拍正常结案。
    func testCaptureSettlesWhenComplete() {
        var window = BottleneckProbeWindow()
        _ = window.capture(tick(), elapsed: 2)
        _ = window.capture(tick(), elapsed: 4)
        XCTAssertEqual(window.capture(tick(), elapsed: 6), .settle(collected: 3))
    }

    /// 评审反例:节流原料按窗口采(Tick 新字段)。窗口内三拍都在降频形状,
    /// 结账瞬时值已恢复——用窗口聚合喂 ThrottleDiagnosis 必须报热降频。
    func testThrottleInputsTravelWithTicks() throws {
        let hotTick = tick(cpu: 92, hotspot: 96)
        var withThrottle = hotTick
        withThrottle.pClusterActivePercent = 92
        withThrottle.pClusterFreqMHz = 2280
        withThrottle.pClusterMaxFreqMHz = 3808
        let ticks = [withThrottle, withThrottle, withThrottle]
        // 模拟模型侧的窗口聚合(windowThrottleDiagnosis 的算法)
        let throttle = ThrottleDiagnosis.diagnose(.init(
            clusterActivePercent: 92, clusterFreqMHz: 2280, clusterMaxFreqMHz: 3808,
            hotspotTemperature: 96, thermalLevel: .nominal,
            lowPowerModeEnabled: false, onBattery: false
        ))
        XCTAssertEqual(throttle?.kind, .thermal, "窗口证据成立就要报,不看结账瞬时值")
        let verdict = try XCTUnwrap(BottleneckDiagnosis.diagnose(input(ticks: ticks, throttle: throttle)))
        XCTAssertEqual(verdict.kind, .thermalThrottle)
    }

    // MARK: 实测回归(2026-08-15,本机 M5,Metal 计算烧机器)

    /// 真机样本:GPU 饱和场景实测。Device Utilization 均值 98(峰 100),
    /// 烧机进程组提交 8.71e8 ns/s;同机安静但放着视频时仅 45–48。
    /// 阈值 90/80 恰好把两种状态分开——这个样本定住这组判据。
    func testRealGPUBurnSampleRegression() throws {
        let burner = BottleneckProcessCandidate(
            name: "Claude", rawCPUPercent: 45, gpuNanosecondsPerSecond: 8.71e8
        )
        let verdict = try XCTUnwrap(BottleneckDiagnosis.diagnose(input(
            ticks: [tick(cpu: 20, gpu: 96), tick(cpu: 22, gpu: 98), tick(cpu: 19, gpu: 100)],
            processes: [burner]
        )))
        XCTAssertEqual(verdict.kind, .gpuSaturated)
        XCTAssertEqual(verdict.findings.first?.culpritName, "Claude")
        // 同机对照:视频播放态的利用率绝不能触发。
        let watching = try XCTUnwrap(BottleneckDiagnosis.diagnose(input(
            ticks: [tick(cpu: 25, gpu: 47), tick(cpu: 27, gpu: 48), tick(cpu: 26, gpu: 45)]
        )))
        XCTAssertEqual(watching.kind, .noBottleneck)
    }
}
