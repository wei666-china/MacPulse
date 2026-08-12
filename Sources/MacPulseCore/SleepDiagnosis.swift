import Foundation

/// 一段完整的睡眠(合盖到再次打开)。数据来自系统电源日志,
/// 每条睡眠/唤醒事件都自带电量百分比,所以掉电量是**实测差值**,不是估算。
public struct SleepSession: Codable, Sendable, Equatable, Identifiable {
    public var id: Date { start }
    public var start: Date
    public var end: Date
    /// 入睡与醒来时的电量百分比。
    public var startPercent: Int
    public var endPercent: Int
    /// 睡眠期间被唤醒的次数(暗唤醒:屏幕不亮但芯片在跑)。
    public var darkWakeCount: Int
    /// 唤醒原因分类计数。
    public var wakeReasons: [String: Int]
    /// 这段睡眠是否在电池上(接电时掉电无意义)。
    public var onBattery: Bool

    public var hours: Double { max(0.01, end.timeIntervalSince(start) / 3600) }
    public var droppedPercent: Int { startPercent - endPercent }
    /// 每小时掉电百分比。接电或充电时为负,调用方应忽略。
    public var drainPerHour: Double { Double(droppedPercent) / hours }
    /// 平均每小时被吵醒几次。
    public var wakesPerHour: Double { Double(darkWakeCount) / hours }

    public init(
        start: Date, end: Date, startPercent: Int, endPercent: Int,
        darkWakeCount: Int, wakeReasons: [String: Int], onBattery: Bool
    ) {
        self.start = start
        self.end = end
        self.startPercent = startPercent
        self.endPercent = endPercent
        self.darkWakeCount = darkWakeCount
        self.wakeReasons = wakeReasons
        self.onBattery = onBattery
    }
}

/// 「合上盖子放一晚,为什么掉了三十个点」的答案。
public struct SleepDiagnosis: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// 掉电正常,睡得安稳。
        case healthy
        /// 掉电偏快,且唤醒次数明显异常——两者一起才敢归因。
        case tooManyWakes
        /// 掉电偏快但唤醒不多:耗电在别处(外设供电、后台任务写盘等)。
        case fastDrain
        /// 接电睡的,掉电数据无意义。
        case onPower
    }

    public var kind: Kind
    public var summary: String
    public var detail: String
    public var isWarning: Bool { kind == .tooManyWakes || kind == .fastDrain }

    public init(kind: Kind, summary: String, detail: String) {
        self.kind = kind
        self.summary = summary
        self.detail = detail
    }

    /// 判据阈值。
    /// - 健康掉电 ≤1.5%/小时:现代 Apple Silicon 待机一夜掉个位数是常态。
    /// - 唤醒偏多 >6 次/小时:正常机器靠系统维护窗口每小时唤醒一两次;
    ///   超过这个数说明有东西在反复把它叫起来。
    public static let healthyDrainPerHour: Double = 1.5
    public static let noisyWakesPerHour: Double = 6

    public static func diagnose(_ session: SleepSession) -> SleepDiagnosis {
        guard session.onBattery else {
            return SleepDiagnosis(
                kind: .onPower,
                summary: "接电睡眠",
                detail: "这段睡眠一直接着电源,掉电数据不反映待机耗电。要看待机表现,请在纯电池状态下合盖。"
            )
        }

        let drain = session.drainPerHour
        let wakes = session.wakesPerHour
        let hoursText = String(format: "%.1f", session.hours)
        let drainText = String(format: "%.1f", drain)

        guard drain > healthyDrainPerHour else {
            return SleepDiagnosis(
                kind: .healthy,
                summary: "待机正常",
                detail: "睡了 \(hoursText) 小时掉 \(session.droppedPercent)%(每小时 \(drainText)%),属于正常范围。"
            )
        }

        if wakes > noisyWakesPerHour {
            let top = session.wakeReasons.max { $0.value < $1.value }
            let culprit = top.map { "\($0.key)(\($0.value) 次)" } ?? "多个来源"
            return SleepDiagnosis(
                kind: .tooManyWakes,
                summary: "被频繁唤醒,待机掉电偏快",
                detail: "睡了 \(hoursText) 小时掉 \(session.droppedPercent)%(每小时 \(drainText)%),期间被唤醒 \(session.darkWakeCount) 次,最多的是\(culprit)。合盖后仍被反复叫醒会持续耗电——可在「系统设置 → 电池 → 选项」里关掉唤醒网络访问试试。"
            )
        }

        return SleepDiagnosis(
            kind: .fastDrain,
            summary: "待机掉电偏快",
            detail: "睡了 \(hoursText) 小时掉 \(session.droppedPercent)%(每小时 \(drainText)%),但唤醒只有 \(session.darkWakeCount) 次——耗电多半不在唤醒上,常见于外接设备持续取电,或睡前有任务没跑完。"
        )
    }
}

/// 系统电源日志解析。**纯函数**:吃日志文本行,吐睡眠会话,
/// 不碰进程、不碰文件,因此可以拿固定样本离线测试。
public enum SleepLogParser {
    /// 唤醒原因关键词 → 人话分类。日志里的原文形如
    /// `due to smc.sysState.Wake(0x70070000) wifibt SMC.OutboxNotEmpty`,
    /// 直接展示等于没说,按关键词归成用户能行动的几类。
    static let reasonMap: [(keyword: String, label: String)] = [
        ("HID Activity", "你的操作"),
        ("USB-C_plug", "USB-C 插拔"),
        ("Clamshell", "开合盖"),
        ("wifibt", "网络与蓝牙"),
        ("TCPKeepAlive", "网络保活"),
        ("dasd", "系统维护任务"),
        ("RTC", "定时唤醒"),
        ("PMU", "电源管理"),
        ("SPMI", "硬件传感器")
    ]

    static func classifyReason(_ description: String) -> String {
        for entry in reasonMap where description.contains(entry.keyword) {
            return entry.label
        }
        return "其他"
    }

    /// 从日志行还原睡眠会话。只收满 30 分钟以上的段——
    /// 几分钟的小憩掉电数据噪声太大,拿出来说没有意义。
    public static func parse(lines: [String], minimumMinutes: Double = 30) -> [SleepSession] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")

        var sessions: [SleepSession] = []
        var pending: (start: Date, percent: Int, onBattery: Bool, wakes: Int, reasons: [String: Int])?

        for line in lines {
            guard line.count > 26, let date = formatter.date(from: String(line.prefix(19))) else { continue }
            // 事件类型在时间戳与制表符之间(定宽列),描述在制表符之后。
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let type = parts[0].dropFirst(26).trimmingCharacters(in: .whitespaces)
            let description = String(parts[1])
            let percent = percentValue(in: description)

            switch type {
            case "Sleep" where description.contains("Entering Sleep state"):
                if pending == nil, let percent {
                    pending = (date, percent, description.contains("Using Batt"), 0, [:])
                }
            case "DarkWake":
                if pending != nil {
                    pending!.wakes += 1
                    let label = classifyReason(description)
                    pending!.reasons[label, default: 0] += 1
                }
            case "Wake":
                guard let session = pending else { continue }
                pending = nil
                let minutes = date.timeIntervalSince(session.start) / 60
                guard minutes >= minimumMinutes, let endPercent = percent else { continue }
                sessions.append(SleepSession(
                    start: session.start,
                    end: date,
                    startPercent: session.percent,
                    endPercent: endPercent,
                    darkWakeCount: session.wakes,
                    wakeReasons: session.reasons,
                    onBattery: session.onBattery
                ))
            default:
                continue
            }
        }
        return sessions
    }

    static func percentValue(in description: String) -> Int? {
        guard let range = description.range(of: #"Charge:\s*\d+%"#, options: .regularExpression) else {
            return nil
        }
        return Int(description[range].filter(\.isNumber))
    }
}
