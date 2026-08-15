import Foundation
import MacPulseCore
import Security

/// 额度快照的落盘。接口限流严、日志偶尔缺,所以最近一次好数据必须留住——
/// 界面显示「1 小时前的快照」远好过显示空白(空白让人以为功能坏了)。
enum QuotaSnapshotStore {
    private static func key(_ source: SubscriptionQuota.Source) -> String {
        "quotaSnapshot.\(source.rawValue)"
    }

    static func save(_ quota: SubscriptionQuota) {
        guard let data = try? JSONEncoder().encode(quota) else { return }
        UserDefaults.standard.set(data, forKey: key(quota.source))
    }

    static func load(_ source: SubscriptionQuota.Source) -> SubscriptionQuota? {
        guard let data = UserDefaults.standard.data(forKey: key(source)) else { return nil }
        return try? JSONDecoder().decode(SubscriptionQuota.self, from: data)
    }

    // MARK: - 历史(给趋势用)

    private static let historyKey = "quotaHistoryV1"
    /// 一天最多留 24 个点(每小时一个),7 天上限 168 × 3 家。
    private static let maxPoints = 520

    struct Point: Codable, Sendable, Equatable {
        var source: SubscriptionQuota.Source
        var label: String
        var remainingPercent: Double
        var at: Date
    }

    static func appendHistory(_ quota: SubscriptionQuota) {
        var points = loadHistory()
        let now = Date()
        for window in quota.windows {
            // 每小时最多记一个点:额度是慢变量,高频记录只是把存储撑爆。
            let recent = points.last { $0.source == quota.source && $0.label == window.label }
            if let recent, now.timeIntervalSince(recent.at) < 3_600 { continue }
            points.append(Point(
                source: quota.source, label: window.label,
                remainingPercent: window.remainingPercent, at: now
            ))
        }
        let cutoff = now.addingTimeInterval(-7 * 86_400)
        points = points.filter { $0.at >= cutoff }.suffix(maxPoints).map { $0 }
        if let data = try? JSONEncoder().encode(points) {
            UserDefaults.standard.set(data, forKey: historyKey)
        }
    }

    static func loadHistory() -> [Point] {
        guard let data = UserDefaults.standard.data(forKey: historyKey),
              let points = try? JSONDecoder().decode([Point].self, from: data)
        else { return [] }
        return points
    }
}

/// Codex 订阅额度:读最近的会话日志,取**最后一条** rate_limits 快照。
/// 零网络——Codex CLI 自己把额度写进 ~/.codex/sessions 的 rollout JSONL。
enum CodexQuotaReader {

    static func latestQuota(root: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/sessions")) -> SubscriptionQuota? {
        // 找最近 7 天内 mtime 最新的 rollout 文件——快照随会话推进更新,
        // 最新文件的最后一条就是当前额度。
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let cutoff = Date().addingTimeInterval(-7 * 86_400)
        var newest: (url: URL, modified: Date)?
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl", url.lastPathComponent.hasPrefix("rollout-") else { continue }
            guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate, modified >= cutoff else { continue }
            if newest == nil || modified > newest!.modified {
                newest = (url, modified)
            }
        }
        guard let newest, let reader = StreamingLineReader(url: newest.url) else { return nil }
        var latest: SubscriptionQuota?
        while let line = reader.nextLine() {
            if let quota = CodexRateLimitParser.parse(line: line, now: newest.modified) {
                latest = quota
            }
        }
        return latest
    }
}

/// Claude 订阅额度:用 Claude Code 已登录的 OAuth token 调它自己的用量接口。
///
/// 诚实声明:这是**未文档化接口**(Claude Code 的 /usage 面板内部同款),
/// 随时可能失效;失效就显示不可用,不猜不编。token 只在内存中转手,
/// 不落盘不打印不进报告。默认关闭,设置页明确开启才请求。
actor ClaudeSubscriptionReader {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        session = URLSession(configuration: config)
    }

    /// 取 token 的结果。「被钥匙串拒绝」必须与「没登录」分开——
    /// 前者是一次授权就能解决的,后者要装 Claude Code,给用户的话完全不同。
    enum TokenState: Sendable, Equatable {
        case token(String)
        /// 钥匙串里有,但本 App 没被授权读(系统会弹一次授权框)。
        case keychainDenied
        /// 本机压根没有 Claude Code 的登录态。
        case missing
    }

    static func tokenState() -> TokenState {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data,
           let token = Self.extractToken(from: data) {
            return .token(token)
        }
        // 文件兜底(部分安装形态把凭证放文件里)。
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: url), let token = Self.extractToken(from: data) {
            return .token(token)
        }
        // 条目存在但读不了(用户点了拒绝、或尚未授权):不是「没登录」。
        if status == errSecInteractionNotAllowed || status == errSecAuthFailed
            || status == errSecUserCanceled {
            return .keychainDenied
        }
        return .missing
    }

    static func loadToken() -> String? {
        if case .token(let token) = tokenState() { return token }
        return nil
    }

    private static func extractToken(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any]
        else { return nil }
        return oauth["accessToken"] as? String
    }

    /// 上次被限流时服务端要求的最早重试时刻。这个接口限流极严
    /// (实测 429 带 retry-after 2410 秒),不尊重它就是自找永远 429。
    private var retryAfter: Date?

    /// 距离可以再试还有多久;nil 表示现在就能试。
    func retryDelay(now: Date = .now) -> TimeInterval? {
        guard let retryAfter, retryAfter > now else { return nil }
        return retryAfter.timeIntervalSince(now)
    }

    func fetch() async -> SubscriptionQuota? {
        if let retryAfter, retryAfter > Date() { return nil }
        guard let token = Self.loadToken() else { return nil }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("MacPulse", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse
        else { return nil }
        if http.statusCode == 429 {
            // 服务端说了等多久就等多久,再加 60 秒缓冲。
            let seconds = (http.value(forHTTPHeaderField: "retry-after")
                .flatMap(Double.init)) ?? 1800
            retryAfter = Date().addingTimeInterval(seconds + 60)
            return nil
        }
        guard http.statusCode == 200 else { return nil }
        retryAfter = nil
        return ClaudeSubscriptionParser.parse(data: data, now: .now)
    }
}

/// Grok 订阅额度:复用 Grok CLI 已有的登录态(~/.grok/auth.json),
/// 调它自己的计费端点。不碰浏览器 cookie。默认关闭,设置里开启才请求。
actor GrokQuotaReader {
    private let session: URLSession
    private var retryAfter: Date?

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        session = URLSession(configuration: config)
    }

    /// CLI 的凭证文件:按 scope 分组,取第一条带 key 的。
    /// token 只在内存中转手,不落盘不打印不进报告。
    static func loadToken(
        path: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok/auth.json")
    ) -> String? {
        guard let data = try? Data(contentsOf: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        for value in root.values {
            if let entry = value as? [String: Any],
               let key = entry["key"] as? String, !key.isEmpty {
                return key
            }
        }
        return nil
    }

    static var isAvailable: Bool { loadToken() != nil }

    func fetch() async -> SubscriptionQuota? {
        if let retryAfter, retryAfter > Date() { return nil }
        guard let token = Self.loadToken() else { return nil }
        var request = URLRequest(
            url: URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
        )
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "x-xai-token-auth")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse
        else { return nil }
        if http.statusCode == 429 {
            let seconds = (http.value(forHTTPHeaderField: "retry-after").flatMap(Double.init)) ?? 900
            retryAfter = Date().addingTimeInterval(seconds + 30)
            return nil
        }
        guard http.statusCode == 200 else { return nil }
        retryAfter = nil
        return GrokQuotaParser.parse(data: data, now: .now)
    }
}
