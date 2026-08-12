import Foundation

/// 一段放电的结束原因。
public enum SessionEndReason: String, Codable, Sendable {
    case plugged
    case sleep
    case shutdown
    case unknown
}

/// 一次预测与它后来的实际结果。
public struct PredictionCheckpoint: Codable, Sendable, Equatable {
    public var at: Date
    public var predictedMinutes: Int
    public var socPercent: Double

    public init(at: Date, predictedMinutes: Int, socPercent: Double) {
        self.at = at
        self.predictedMinutes = predictedMinutes
        self.socPercent = socPercent
    }
}

public struct DischargeSession: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var startedAt: Date
    public var endedAt: Date?
    public var startSoc: Double
    public var endSoc: Double?
    public var energyWattHours: Double
    public var activeSeconds: Double
    /// 睡眠断档累计秒数。跨越睡眠的预测不参与评分。
    public var sleepSeconds: Double
    public var endReason: SessionEndReason
    public var checkpoints: [PredictionCheckpoint]

    public init(
        id: UUID = UUID(),
        startedAt: Date,
        startSoc: Double
    ) {
        self.id = id
        self.startedAt = startedAt
        endedAt = nil
        self.startSoc = startSoc
        endSoc = nil
        energyWattHours = 0
        activeSeconds = 0
        sleepSeconds = 0
        endReason = .unknown
        checkpoints = []
    }

    /// 未删失 = 一路跑到低电量或直接关机。
    ///
    /// 这是「诚实数字」和「好看数字」的分界：如果会话是因为用户在 40% 时
    /// 插了电而结束，真实的到空时间比观测到的更长，拿它算误差会让分数虚高。
    public var isUncensored: Bool {
        endReason == .shutdown || (endSoc ?? 100) <= 8
    }

    public var wattHoursPerPercent: Double? {
        guard let endSoc else { return nil }
        let drop = startSoc - endSoc
        guard drop >= 10, energyWattHours > 0 else { return nil }
        return energyWattHours / drop
    }
}

/// 放电段切分与自我评分。
///
/// 纯值类型、无 IOKit、无 MainActor —— 因此回测和 App 用的是同一份实现。
public struct PowerSessionTracker: Sendable {
    /// 连续两次采样都确认在放电才开段。适配器重协商会产生瞬时的状态抖动，
    /// 不去抖就会切出一堆假会话。
    public static let confirmationSamples = 2
    /// 超过这个间隔视为睡眠断档。
    public static let sleepGapSeconds: TimeInterval = 180
    /// 单步积分的时间上限。实测数据里有 982.9 分钟（16.4 小时）的断档，
    /// 不钳制的话按 P×Δt 积分会凭空造出约 100Wh —— 比整块电池还大。
    public static let maximumIntegrationStep: TimeInterval = 180
    /// 只评估剩余 ≥ 这么多分钟时做出的预测。最后 20 分钟太容易猜，
    /// 算进去只会美化分数。
    public static let minimumScorableMinutes = 20.0
    /// 检查点最小间隔。ingest 每 2 秒来一次，不节流的话放电 5 小时就是
    /// 9000 条检查点，还会随学习档案每分钟整体序列化一次 JSON。
    /// 评分按分钟粒度就够了。
    public static let checkpointInterval: TimeInterval = 55
    /// 单段上限，兜住任何异常长的会话。
    public static let maximumCheckpointsPerSession = 2_000

    public private(set) var current: DischargeSession?
    public private(set) var completed: [DischargeSession]

    private var dischargingStreak = 0
    private var lastSampleAt: Date?

    public init(completed: [DischargeSession] = []) {
        self.completed = completed
    }

    public struct Sample: Sendable {
        public var date: Date
        public var socPercent: Double
        public var netPowerWatts: Double?
        public var isDischarging: Bool
        public var predictedMinutes: Int?

        public init(
            date: Date,
            socPercent: Double,
            netPowerWatts: Double?,
            isDischarging: Bool,
            predictedMinutes: Int? = nil
        ) {
            self.date = date
            self.socPercent = socPercent
            self.netPowerWatts = netPowerWatts
            self.isDischarging = isDischarging
            self.predictedMinutes = predictedMinutes
        }
    }

    public mutating func ingest(_ sample: Sample) {
        defer { lastSampleAt = sample.date }
        let gap = lastSampleAt.map { sample.date.timeIntervalSince($0) } ?? 0

        guard sample.isDischarging else {
            dischargingStreak = 0
            close(reason: .plugged, at: sample.date, soc: sample.socPercent)
            return
        }

        // 睡眠之后另起一段：8 小时待机和连续使用不是同一个物理过程。
        if gap > Self.sleepGapSeconds, current != nil {
            close(reason: .sleep, at: sample.date, soc: sample.socPercent)
            dischargingStreak = 0
        }

        dischargingStreak += 1
        guard dischargingStreak >= Self.confirmationSamples else { return }

        if current == nil {
            current = DischargeSession(startedAt: sample.date, startSoc: sample.socPercent)
        }

        guard var session = current else { return }

        // 能量积分：步长必须钳住，钳制只写在这一个地方。
        if gap > 0, let watts = sample.netPowerWatts {
            let step = min(gap, Self.maximumIntegrationStep)
            session.energyWattHours += abs(watts) * step / 3_600
            session.activeSeconds += step
            if gap > step {
                // 超出的部分记为睡眠，贡献零能量。
                session.sleepSeconds += gap - step
            }
        }

        if let predicted = sample.predictedMinutes, predicted > 0,
           session.checkpoints.count < Self.maximumCheckpointsPerSession,
           session.checkpoints.last.map({ sample.date.timeIntervalSince($0.at) >= Self.checkpointInterval }) ?? true {
            session.checkpoints.append(
                PredictionCheckpoint(at: sample.date, predictedMinutes: predicted, socPercent: sample.socPercent)
            )
        }
        current = session
    }

    public mutating func close(reason: SessionEndReason, at date: Date, soc: Double) {
        guard var session = current else { return }
        session.endedAt = date
        session.endSoc = soc
        session.endReason = reason
        current = nil
        dischargingStreak = 0
        // 太短的段没有信息量。
        guard date.timeIntervalSince(session.startedAt) > 300 else { return }
        completed.append(session)
        // 只留最近 40 段，够算准确度也够学 Wh/%。
        if completed.count > 40 {
            completed.removeFirst(completed.count - 40)
        }
    }

    // MARK: - 自我评分

    public struct Accuracy: Sendable, Equatable {
        /// 参与统计的未删失会话数。
        public var sessionCount: Int
        public var checkpointCount: Int
        /// 平均绝对误差（分钟）。
        public var meanAbsoluteErrorMinutes: Double
        /// 有多少次是「预告了没发生的死亡」——这类错误对用户伤害更大。
        public var underestimateCount: Int

        public init(
            sessionCount: Int = 0,
            checkpointCount: Int = 0,
            meanAbsoluteErrorMinutes: Double = 0,
            underestimateCount: Int = 0
        ) {
            self.sessionCount = sessionCount
            self.checkpointCount = checkpointCount
            self.meanAbsoluteErrorMinutes = meanAbsoluteErrorMinutes
            self.underestimateCount = underestimateCount
        }

        public var summary: String {
            guard sessionCount > 0, checkpointCount > 0 else {
                return "还在积累实测样本（已完成 \(sessionCount) 次完整放电）"
            }
            return "最近 \(sessionCount) 次实测平均误差 \(Int(meanAbsoluteErrorMinutes.rounded())) 分钟"
        }
    }

    /// 只用未删失会话算头条。
    ///
    /// 插电结束的高电量会话做单边检查：只有「预测比实际短」才计误差，
    /// 因为真实的到空时间必然更长，反方向的偏差无法判定。
    public func accuracy(recentSessions limit: Int = 10) -> Accuracy {
        let uncensored = completed.filter(\.isUncensored).suffix(limit)
        guard !uncensored.isEmpty else {
            return Accuracy(
                sessionCount: 0,
                checkpointCount: 0,
                meanAbsoluteErrorMinutes: 0,
                underestimateCount: 0
            )
        }

        var errors: [Double] = []
        var underestimates = 0

        for session in uncensored {
            guard let endedAt = session.endedAt else { continue }
            // 跨越睡眠的会话不参与评分：22:00 的预测不能拿去跟随后睡了
            // 8 小时的电池对账。
            guard session.sleepSeconds < 60 else { continue }
            for checkpoint in session.checkpoints {
                let actual = endedAt.timeIntervalSince(checkpoint.at) / 60
                guard actual >= Self.minimumScorableMinutes else { continue }
                let error = Double(checkpoint.predictedMinutes) - actual
                errors.append(abs(error))
                if error < 0 { underestimates += 1 }
            }
        }

        guard !errors.isEmpty else {
            return Accuracy(
                sessionCount: uncensored.count,
                checkpointCount: 0,
                meanAbsoluteErrorMinutes: 0,
                underestimateCount: 0
            )
        }

        return Accuracy(
            sessionCount: uncensored.count,
            checkpointCount: errors.count,
            meanAbsoluteErrorMinutes: errors.reduce(0, +) / Double(errors.count),
            underestimateCount: underestimates
        )
    }

    /// 从已完成的会话里提取 Wh/%，供能量模型学习。
    public func measuredWattHoursPerPercent() -> [Double] {
        completed.compactMap(\.wattHoursPerPercent)
    }
}
