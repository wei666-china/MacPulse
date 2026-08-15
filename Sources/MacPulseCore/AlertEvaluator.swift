import Foundation

/// 外设低电量提醒的判定(纯逻辑,离线可测)。
/// 冷却按**设备**记:AirPods 低电会持续几小时,同一设备反复轰炸等于没有提醒。
public struct PeripheralAlertCandidate: Sendable, Equatable {
    public let id: String
    public let name: String
    public let worstPercent: Int

    public init(id: String, name: String, worstPercent: Int) {
        self.id = id
        self.name = name
        self.worstPercent = worstPercent
    }
}

public enum PeripheralAlertPolicy {
    /// 同一设备两次提醒的最小间隔。低电状态是持续态,不是事件,
    /// 8 小时足够「今天提醒过了」而不至于跨天沉默。
    public static let perDeviceCooldown: TimeInterval = 8 * 3600

    public static func due(
        candidates: [PeripheralAlertCandidate],
        threshold: Int,
        lastSent: [String: Date],
        now: Date
    ) -> [PeripheralAlertCandidate] {
        candidates.filter { candidate in
            guard candidate.worstPercent <= threshold else { return false }
            if let last = lastSent[candidate.id],
               now.timeIntervalSince(last) < perDeviceCooldown {
                return false
            }
            return true
        }
    }
}
