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

    /// 异步:内部要等 launchctl 子进程,绝不能在主线程上跑。
    /// (今天下午刚给外设电量修过同款问题,这里一次到位。)
    static func read() async -> [BackgroundItem] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: readSynchronously())
            }
        }
    }

    private static func readSynchronously() -> [BackgroundItem] {
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

    /// 反向域名标签 → 人话。规则:去掉顶级域段(com/org/net…),
    /// 丢掉纯数字段,首字母大写,相邻重复词合并。
    ///
    /// 初版只取第三段之后,实测把 `com.deskin.session` 变成「Session」——
    /// 丢了厂商名等于没说;中文标签(闪电说.plist)也要原样保留。
    static func friendlyName(from label: String) -> String {
        let tlds: Set<String> = ["com", "org", "net", "io", "dev", "co", "me", "application"]
        var parts = label.split(separator: ".").map(String.init)
        while let first = parts.first, tlds.contains(first.lowercased()) {
            parts.removeFirst()
        }
        // 纯数字段是进程实例号,不是名字的一部分。
        parts.removeAll { $0.allSatisfy(\.isNumber) }
        guard !parts.isEmpty else { return label }

        var words: [String] = []
        for part in parts {
            let word = part.prefix(1).uppercased() + part.dropFirst()
            // 「Google GoogleUpdater」这类相邻重复只留一个。
            if let last = words.last,
               word.lowercased().hasPrefix(last.lowercased()) || last.lowercased().hasPrefix(word.lowercased()) {
                if word.count > last.count { words[words.count - 1] = word }
                continue
            }
            words.append(word)
        }
        return words.joined(separator: " ")
    }
}
