import Foundation

/// 一个开机/登录时自动拉起的后台项。
struct BackgroundItem: Identifiable, Sendable, Equatable {
    enum Scope: String, Sendable {
        /// 用户级(~/Library/LaunchAgents):你自己装的,随登录启动。
        case userAgent = "登录时启动"
        /// 系统级 Agent(/Library/LaunchAgents):所有用户登录时启动。
        case systemAgent = "所有用户登录时"
        /// 守护进程(/Library/LaunchDaemons):开机即启,不需要登录。
        case daemon = "开机时启动"
    }

    let id: String
    /// launchd 标签,如 com.microsoft.teams2.agent。
    let label: String
    /// 从标签推出的可读名称。
    let displayName: String
    let scope: Scope
    /// 当前是否真的在运行(launchctl 报到了 PID)。
    var isRunning: Bool
    var pid: Int32?
    /// 关联进程的实时资源占用,和进程采样器对账后填充;对不上时为 nil。
    var cpuPercent: Double?
    var memoryBytes: UInt64?
}

/// 启动项扫描。只读 plist 文件名与 launchctl 清单,不解析 plist 内容、
/// 不动任何配置——诊断工具的本分是告诉你有什么,不是替你删东西。
enum LoginItemsReader {
    private static let scopes: [(path: String, scope: BackgroundItem.Scope)] = [
        ("\(NSHomeDirectory())/Library/LaunchAgents", .userAgent),
        ("/Library/LaunchAgents", .systemAgent),
        ("/Library/LaunchDaemons", .daemon)
    ]

    static func read() -> [BackgroundItem] {
        let running = runningLabels()
        var items: [BackgroundItem] = []

        for (path, scope) in scopes {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
            for name in names where name.hasSuffix(".plist") {
                let label = String(name.dropLast(6))
                // 苹果自家的系统组件不列:用户对它们既不好奇也动不了,
                // 混在里面只会淹没真正值得看的第三方项。
                guard !label.hasPrefix("com.apple.") else { continue }
                let pid = running[label]
                items.append(BackgroundItem(
                    id: "\(scope.rawValue)/\(label)",
                    label: label,
                    displayName: friendlyName(from: label),
                    scope: scope,
                    isRunning: pid != nil,
                    pid: pid
                ))
            }
        }
        return items.sorted {
            if $0.isRunning != $1.isRunning { return $0.isRunning }
            return $0.displayName.localizedCompare($1.displayName) == .orderedAscending
        }
    }

    /// launchctl 的 PID 清单。第三列是标签,第一列是 PID(未运行时是 "-")。
    private static func runningLabels() -> [String: Int32] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["list"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [:] }

        var result: [String: Int32] = [:]
        for line in text.split(separator: "\n").dropFirst() {
            let columns = line.split(separator: "\t")
            guard columns.count >= 3 else { continue }
            let label = String(columns[2])
            if let pid = Int32(columns[0]) { result[label] = pid }
        }
        return result
    }

    /// com.microsoft.teams2.agent → Teams2 Agent。推不出好名字就用原标签,
    /// 不硬造。
    static func friendlyName(from label: String) -> String {
        let parts = label.split(separator: ".")
        guard parts.count >= 3 else { return label }
        let tail = parts.dropFirst(2)
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
        return tail.isEmpty ? label : tail
    }
}
