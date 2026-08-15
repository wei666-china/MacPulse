import AppKit
import Foundation
import MacPulseCore
import UserNotifications

@MainActor
final class NotificationService {
    private let center = UNUserNotificationCenter.current()
    private var evaluator: AlertEvaluator
    private var authorizationStatus: UNAuthorizationStatus = .notDetermined

    init() {
        let defaults = UserDefaults.standard
        var restored: [String: Date] = [:]
        for key in ["temperature", "thermal", "health"] {
            let value = defaults.double(forKey: "alertLastSent.\(key)")
            if value > 0 {
                restored[key] = Date(timeIntervalSince1970: value)
            }
        }
        evaluator = AlertEvaluator(lastSent: restored)
    }

    func refreshAuthorizationStatus() async -> UNAuthorizationStatus {
        let settings = await center.notificationSettings()
        authorizationStatus = settings.authorizationStatus
        return settings.authorizationStatus
    }

    func requestAuthorization() async throws -> Bool {
        let granted = try await center.requestAuthorization(options: [.alert, .sound])
        _ = await refreshAuthorizationStatus()
        return granted
    }

    func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func evaluate(_ snapshot: MetricSnapshot) {
        let defaults = UserDefaults.standard
        guard
            defaults.object(forKey: "notificationsEnabled") as? Bool ?? true,
            authorizationStatus == .authorized || authorizationStatus == .provisional
        else {
            return
        }

        let threshold = defaults.object(forKey: "temperatureThreshold") as? Double ?? 40
        let cooldownMinutes = defaults.object(forKey: "alertCooldownMinutes") as? Double ?? 60
        let alerts = evaluator.evaluate(
            snapshot: snapshot,
            now: .now,
            temperatureThreshold: threshold,
            cooldown: max(15, cooldownMinutes) * 60,
            temperatureEnabled: defaults.object(forKey: "temperatureAlertsEnabled") as? Bool ?? true,
            thermalEnabled: defaults.object(forKey: "thermalAlertsEnabled") as? Bool ?? true,
            healthEnabled: defaults.object(forKey: "healthAlertsEnabled") as? Bool ?? true
        )
        for alert in alerts {
            if let date = evaluator.lastSent[alert] {
                defaults.set(date.timeIntervalSince1970, forKey: "alertLastSent.\(alert)")
            }
            send(alert, snapshot: snapshot)
        }
    }

    /// 外设低电量。按设备冷却(8 小时),阈值用户可调。
    private var peripheralLastSent: [String: Date] = {
        (UserDefaults.standard.dictionary(forKey: "peripheralAlertLastSent") as? [String: Double])?
            .mapValues { Date(timeIntervalSince1970: $0) } ?? [:]
    }()

    func evaluatePeripherals(_ batteries: [PeripheralBattery]) {
        let defaults = UserDefaults.standard
        guard
            defaults.object(forKey: "notificationsEnabled") as? Bool ?? true,
            defaults.object(forKey: "peripheralAlertsEnabled") as? Bool ?? true,
            authorizationStatus == .authorized || authorizationStatus == .provisional
        else { return }

        let threshold = defaults.object(forKey: "peripheralAlertThreshold") as? Int ?? 20
        let due = PeripheralAlertPolicy.due(
            candidates: batteries.compactMap { battery in
                battery.worstPercent.map {
                    PeripheralAlertCandidate(id: battery.id, name: battery.name, worstPercent: $0)
                }
            },
            threshold: threshold,
            lastSent: peripheralLastSent,
            now: .now
        )
        guard !due.isEmpty else { return }
        for candidate in due {
            peripheralLastSent[candidate.id] = .now
            let content = UNMutableNotificationContent()
            content.title = String(localized: "外设电量提醒")
            content.body = String(
                format: String(localized: "「%@」只剩 %@%%,该充电了。"),
                candidate.name, String(describing: candidate.worstPercent)
            )
            // 与温度/健康度提醒同规格:静默横幅在离屏时等于没提醒,
            // 而 8 小时冷却保证不会再响第二次。
            content.sound = .default
            center.add(UNNotificationRequest(
                identifier: "peripheral.\(candidate.id).\(Int(Date().timeIntervalSince1970))",
                content: content,
                trigger: nil
            ))
        }
        defaults.set(
            peripheralLastSent.mapValues { $0.timeIntervalSince1970 },
            forKey: "peripheralAlertLastSent"
        )
    }

    private func send(_ alert: String, snapshot: MetricSnapshot) {
        let content = UNMutableNotificationContent()
        content.sound = .default

        switch alert {
        case "temperature":
            content.title = String(localized: "电池温度偏高")
            content.body = String(localized: "电池温度已持续高于设定阈值，建议暂停高负载任务并改善散热。")
        case "thermal":
            content.title = String(localized: "Mac 正在承受较高热压力")
            content.body = String(format: String(localized: "系统热状态为%@，性能可能受到限制。"), String(describing: snapshot.deep.thermalLevel.title))
        case "health":
            content.title = String(localized: "电池健康度需要关注")
            content.body = String(localized: "当前估算健康度低于 80%，可在系统设置中进一步检查电池状态。")
        default:
            return
        }

        let request = UNNotificationRequest(
            identifier: "com.macpulse.\(alert).\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        center.add(request)
    }
}
