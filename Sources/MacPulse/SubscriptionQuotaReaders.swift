import Foundation
import MacPulseCore
import Security

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

    static func loadToken() -> String? {
        // 钥匙串优先(Claude Code 正式存放处),文件兜底。
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data,
           let token = Self.extractToken(from: data) {
            return token
        }
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return Self.extractToken(from: data)
    }

    private static func extractToken(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any]
        else { return nil }
        return oauth["accessToken"] as? String
    }

    func fetch() async -> SubscriptionQuota? {
        guard let token = Self.loadToken() else { return nil }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("MacPulse", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return ClaudeSubscriptionParser.parse(data: data, now: .now)
    }
}
