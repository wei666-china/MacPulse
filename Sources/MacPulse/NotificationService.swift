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
