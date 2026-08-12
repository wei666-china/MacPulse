import Foundation
import MacPulseCore

/// 系统电源日志读取。`pmset -g log` 是子进程且输出可达十万行,
/// **必须异步**,而且要节流——今天已经在外设电量和启动项上各踩过一次
/// 「主线程干等子进程」,这里一次到位。
actor SleepLogReader {
    private var cached: [SleepSession] = []
    private var lastReadAt: Date = .distantPast
    /// 睡眠记录以小时计变化,10 分钟刷一次绰绰有余。
    private static let refreshInterval: TimeInterval = 600

    /// 返回最近的睡眠会话(新→旧)。缓存未过期直接给,过期则后台重读。
    /// 首次调用会等一次真实读取(否则界面永远空着),之后一律走缓存。
    func sessions() async -> [SleepSession] {
        if Date().timeIntervalSince(lastReadAt) > Self.refreshInterval {
            lastReadAt = .now
            cached = await Self.readSessions()
        }
        return cached
    }

    private static func readSessions() async -> [SleepSession] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: parseLog())
            }
        }
    }

    private static func parseLog() -> [SleepSession] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "log"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [] }

        // 只保留最近 14 天:更早的记录对「我的机器现在怎么样」没有参考价值,
        // 也省得把十万行全喂给解析器。
        let cutoff = Date().addingTimeInterval(-14 * 86_400)
        let sessions = SleepLogParser.parse(lines: text.components(separatedBy: "\n"))
        return sessions.filter { $0.start >= cutoff }.sorted { $0.start > $1.start }
    }
}
