import AppKit
import Foundation
import ServiceManagement

enum LoginItemStatus {
    case enabled
    case disabled
    case requiresApproval
    case unavailable

    var title: String {
        switch self {
        case .enabled: "已启用"
        case .disabled: "未启用"
        case .requiresApproval: "等待在系统设置中允许"
        case .unavailable: "当前不可用"
        }
    }
}

@MainActor
enum LoginItemService {
    static var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .notRegistered: .disabled
        case .requiresApproval: .requiresApproval
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
    }

    static var isEnabled: Bool {
        status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            guard SMAppService.mainApp.status != .enabled else { return }
            try SMAppService.mainApp.register()
        } else {
            guard SMAppService.mainApp.status != .notRegistered else { return }
            try SMAppService.mainApp.unregister()
        }
    }

    static func openSystemSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
