import Darwin
import Foundation
import MacPulseCore

final class DeepCollectorClient: @unchecked Sendable {
    typealias Update = @Sendable (DeepMetrics, CollectorStatus) -> Void

    private let stateQueue = DispatchQueue(label: "com.macpulse.collector.state", qos: .utility)
    private let readerQueue = DispatchQueue(label: "com.macpulse.collector.reader", qos: .utility)
    private var process: Process?
    private var restartWorkItem: DispatchWorkItem?
    private var stopped = true
    private var sampleIntervalMilliseconds = 2_000
    private var backoffIndex = 0
    private var intervalRestartRequested = false
    private var update: Update?
    private var lastStandardError = ""

    func start(
        sampleInterval: TimeInterval = 2,
        update: @escaping Update
    ) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.update = update
            self.sampleIntervalMilliseconds = Self.milliseconds(for: sampleInterval)
            self.stopped = false
            self.backoffIndex = 0
            self.intervalRestartRequested = false
            self.launch()
        }
    }

    func setSampleInterval(_ interval: TimeInterval) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            let milliseconds = Self.milliseconds(for: interval)
            guard milliseconds != self.sampleIntervalMilliseconds else { return }
            self.sampleIntervalMilliseconds = milliseconds
            guard !self.stopped else { return }
            let plan = CollectorLifecyclePolicy.intervalChange(
                processIsRunning: self.process != nil
            )
            self.restartWorkItem?.cancel()
            self.restartWorkItem = nil
            if plan.terminateRunningProcess {
                self.intervalRestartRequested = true
                self.process?.terminate()
            } else if plan.launchImmediately {
                self.backoffIndex = 0
                self.launch()
            }
        }
    }

    func stop() {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.restartWorkItem?.cancel()
            self.restartWorkItem = nil
            self.intervalRestartRequested = false
            self.process?.terminate()
            self.process = nil
            self.publish(
                DeepMetrics(),
                status: CollectorStatus(phase: .sleeping)
            )
        }
    }

    private func launch() {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        guard !stopped, process == nil else { return }
        sweepOrphanedMactopProcesses()
        guard let executable = collectorURL() else {
            publish(
                DeepMetrics(),
                status: CollectorStatus(
                    phase: .unavailable,
                    lastErrorCode: "collector_not_found"
                )
            )
            scheduleRestart()
            return
        }

        let process = Process()
        let output = Pipe()
        let errorOutput = Pipe()
        var environment = ProcessInfo.processInfo.environment
        environment["MACPULSE_INTERVAL_MS"] = String(sampleIntervalMilliseconds)
        environment["MACPULSE_PARENT_PID"] = String(getpid())
        process.executableURL = executable
        process.environment = environment
        process.standardOutput = output
        process.standardError = errorOutput
        lastStandardError = ""

        errorOutput.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.stateQueue.async { [weak self] in
                guard let self else { return }
                self.lastStandardError = String((self.lastStandardError + text).suffix(4_096))
            }
        }

        process.terminationHandler = { [weak self, weak process] _ in
            self?.stateQueue.async { [weak self, weak process] in
                guard let self else { return }
                errorOutput.fileHandleForReading.readabilityHandler = nil
                if self.process === process {
                    self.process = nil
                }
                guard !self.stopped else { return }
                if self.intervalRestartRequested {
                    self.intervalRestartRequested = false
                    self.backoffIndex = 0
                    self.launch()
                    return
                }
                let suffix = self.lastStandardError
                    .split(separator: "\n")
                    .last
                    .map(String.init)
                self.publish(
                    DeepMetrics(),
                    status: CollectorStatus(
                        phase: .reconnecting,
                        lastErrorCode: suffix?.isEmpty == false ? "collector_exited: \(suffix!)" : "collector_exited"
                    )
                )
                self.scheduleRestart()
            }
        }

        do {
            publish(DeepMetrics(), status: CollectorStatus(phase: .starting))
            try process.run()
            self.process = process
            read(output: output, from: process)
        } catch {
            errorOutput.fileHandleForReading.readabilityHandler = nil
            publish(
                DeepMetrics(),
                status: CollectorStatus(
                    phase: .reconnecting,
                    lastErrorCode: "collector_launch_failed"
                )
            )
            scheduleRestart()
        }
    }

    private func read(output: Pipe, from process: Process) {
        readerQueue.async { [weak self, weak process] in
            guard let self, let process else { return }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var buffer = Data()
            var invalidLines = 0

            func consume(_ line: Data) {
                guard !line.isEmpty else { return }
                if let frame = try? decoder.decode(CollectorFrameV2.self, from: line),
                   frame.schemaVersion == 2 {
                    invalidLines = 0
                    self.stateQueue.async { [weak self] in
                        guard let self, !self.stopped, self.process === process else { return }
                        self.backoffIndex = 0
                        let phase: CollectorPhase = frame.warnings.isEmpty ? .live : .degraded
                        self.publish(
                            frame.metrics,
                            status: CollectorStatus(
                                phase: phase,
                                lastSampleAt: frame.timestamp,
                                warnings: frame.warnings
                            )
                        )
                    }
                    return
                }

                if let snapshot = try? decoder.decode(MetricSnapshot.self, from: line),
                   snapshot.schemaVersion == 1 {
                    invalidLines = 0
                    self.stateQueue.async { [weak self] in
                        guard let self, !self.stopped, self.process === process else { return }
                        self.backoffIndex = 0
                        self.publish(
                            snapshot.deep,
                            status: CollectorStatus(
                                phase: .live,
                                lastSampleAt: snapshot.timestamp
                            )
                        )
                    }
                    return
                }

                invalidLines += 1
                if invalidLines == 1 || invalidLines.isMultiple(of: 20) {
                    self.stateQueue.async { [weak self] in
                        guard let self, !self.stopped, self.process === process else { return }
                        self.publish(
                            DeepMetrics(),
                            status: CollectorStatus(
                                phase: .degraded,
                                lastErrorCode: "invalid_ndjson"
                            )
                        )
                    }
                }
            }

            while process.isRunning {
                let chunk = output.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstRange(of: Data([0x0A])) {
                    let line = buffer.subdata(in: buffer.startIndex..<newline.lowerBound)
                    buffer.removeSubrange(buffer.startIndex...newline.lowerBound)
                    consume(line)
                }
            }
            consume(buffer)
        }
    }

    private func scheduleRestart() {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        guard !stopped else { return }
        let delays: [TimeInterval] = [2, 5, 15, 30]
        let delay = delays[min(backoffIndex, delays.count - 1)]
        backoffIndex = min(backoffIndex + 1, delays.count - 1)
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.restartWorkItem = nil
            self.launch()
        }
        restartWorkItem?.cancel()
        restartWorkItem = workItem
        stateQueue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func publish(_ metrics: DeepMetrics, status: CollectorStatus) {
        update?(metrics, status)
    }

    /// 清理上一轮遗留的 mactop 孤儿进程。
    ///
    /// Collector 收到 SIGTERM 时已经会主动带走 mactop，但它自己被 SIGKILL 或崩溃时
    /// 执行不到任何收尾代码，mactop 就会被 launchd 收养并继续满频轮询 SMC。
    /// 判定条件是「可执行文件正是本 App 内置的那个 mactop」且「父进程已经是 launchd」，
    /// 因此不会误伤用户自行安装的 mactop。
    private func sweepOrphanedMactopProcesses() {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        guard let bundledMactopPath = collectorURL()?
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .appendingPathComponent("mactop")
            .path
        else { return }

        let requestedCount = max(256, Int(proc_listallpids(nil, 0)) + 64)
        var pids = [pid_t](repeating: 0, count: requestedCount)
        let returnedCount = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard returnedCount > 0 else { return }

        for pid in pids.prefix(Int(returnedCount)) where pid > 0 {
            var info = proc_bsdinfo()
            let infoSize = MemoryLayout<proc_bsdinfo>.size
            let readSize = withUnsafeMutablePointer(to: &info) {
                proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, Int32(infoSize))
            }
            guard readSize == infoSize, info.pbi_ppid == 1 else { continue }

            var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
            guard proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 else { continue }
            let path = String(
                decoding: pathBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                as: UTF8.self
            )
            guard path == bundledMactopPath else { continue }
            kill(pid, SIGTERM)
        }
    }

    private func collectorURL() -> URL? {
        if let override = ProcessInfo.processInfo.environment["MACPULSE_COLLECTOR_PATH"],
           FileManager.default.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }

        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/MacPulseCollector")
        if FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }

        let sibling = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .appendingPathComponent("MacPulseCollector")
        return FileManager.default.isExecutableFile(atPath: sibling.path) ? sibling : nil
    }

    private static func milliseconds(for interval: TimeInterval) -> Int {
        min(30_000, max(1_000, Int(interval * 1_000)))
    }
}
