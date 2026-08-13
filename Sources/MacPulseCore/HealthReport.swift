import Foundation

/// 一键体检报告:把散在各页的结论汇成一页可复制的文本。
///
/// **隐私是这个功能的设计前提**——报告天生是拿去外发的(贴 issue、发论坛、
/// 问朋友),所以生成时就不收集任何标识信息:
/// 不含序列号、不含 Wi-Fi 名称、不含 IP、不含用户名与路径、不含进程完整命令行。
/// 出现的只有型号、聚合读数与结论。这条是硬约束,加字段前先想清楚。
public struct HealthReport: Sendable {
    /// 一个诊断条目。level 决定排序与图标,不同页的结论在这里统一格式。
    public struct Item: Sendable, Equatable {
        public enum Level: Int, Sendable, Comparable {
            case warning = 0
            case notice = 1
            case ok = 2
            public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
        }
        public let level: Level
        public let category: String
        public let summary: String
        public let detail: String?

        public init(level: Level, category: String, summary: String, detail: String? = nil) {
            self.level = level
            self.category = category
            self.summary = summary
            self.detail = detail
        }
    }

    public var machine: String
    public var systemVersion: String
    public var appVersion: String
    public var generatedAt: Date
    public var items: [Item]
    /// 本机读不到的数据源。报告里必须写清楚,否则读者会把「没提到」当成「没问题」。
    public var unavailable: [String]

    public init(
        machine: String,
        systemVersion: String,
        appVersion: String,
        generatedAt: Date,
        items: [Item],
        unavailable: [String]
    ) {
        self.machine = machine
        self.systemVersion = systemVersion
        self.appVersion = appVersion
        self.generatedAt = generatedAt
        self.items = items
        self.unavailable = unavailable
    }

    /// 有问题的条目在前,同级按类别稳定排序。
    public var sortedItems: [Item] {
        items.enumerated()
            .sorted { ($0.element.level, $0.offset) < ($1.element.level, $1.offset) }
            .map(\.element)
    }

    public var warningCount: Int { items.filter { $0.level == .warning }.count }

    /// Markdown 文本。贴到 GitHub issue 里能直接成型,贴到微信里也还能读。
    public func markdown() -> String {
        let stamp = generatedAt.formatted(.dateTime.year().month().day().hour().minute())
        var lines: [String] = []
        lines.append(String(localized: "## MacPulse 体检报告"))
        lines.append("")
        lines.append(String(format: String(localized: "- 机型:%@"), String(describing: machine)))
        lines.append(String(format: String(localized: "- 系统:%@"), String(describing: systemVersion)))
        lines.append("- MacPulse:\(appVersion)")
        lines.append(String(format: String(localized: "- 生成时间:%@"), String(describing: stamp)))
        lines.append("")
        lines.append(warningCount > 0 ? String(format: String(localized: "**发现 %@ 项需要注意。**"), String(describing: warningCount)) : String(localized: "**未发现异常。**"))
        lines.append("")

        for item in sortedItems {
            let mark = switch item.level {
            case .warning: "⚠️"
            case .notice: "•"
            case .ok: "✅"
            }
            lines.append("\(mark) **\(item.category)**:\(item.summary)")
            if let detail = item.detail, !detail.isEmpty {
                lines.append("  \(detail)")
            }
        }

        if !unavailable.isEmpty {
            lines.append("")
            lines.append(String(
                format: String(localized: "_本机读不到:%@——这些项目未参与体检,不代表没有问题。_"),
                unavailable.joined(separator: String(localized: "、"))
            ))
        }
        lines.append("")
        lines.append(String(localized: "_报告不含序列号、网络名称、IP、用户名或文件路径。_"))
        return lines.joined(separator: "\n")
    }
}
