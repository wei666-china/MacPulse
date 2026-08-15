import Foundation

/// AI 服务商余额面板的核心类型。
///
/// 入选标准(2026-08-15 调研,接口清单参考 one-api 的 channel-billing.go,MIT):
/// **普通 API key 就能查**的官方接口才接——OpenAI/Anthropic 要组织管理员 key,
/// 智谱/百炼/Gemini 官方压根没有,一律不做逆向。
public enum AIProvider: String, CaseIterable, Codable, Sendable, Identifiable {
    case deepseek
    case openrouter
    case moonshot
    case siliconflow
    case xai

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .deepseek: "DeepSeek"
        case .openrouter: "OpenRouter"
        case .moonshot: "Moonshot (Kimi)"
        case .siliconflow: String(localized: "硅基流动")
        case .xai: "xAI (Grok)"
        }
    }

    /// 官方余额端点。只发 GET,只带 Bearer key,不发任何机器信息。
    public var balanceURL: URL {
        switch self {
        case .deepseek: URL(string: "https://api.deepseek.com/user/balance")!
        case .openrouter: URL(string: "https://openrouter.ai/api/v1/key")!
        case .moonshot: URL(string: "https://api.moonshot.cn/v1/users/me/balance")!
        case .siliconflow: URL(string: "https://api.siliconflow.cn/v1/user/info")!
        // xAI 官方没有余额端点(2026-08 调研);这个端点返回 key 的状态与
        // 权限,能答的是「这把 key 还能不能用、被封没有」——如实只报这个,
        // 不假装能查钱。控制台才有账单。
        case .xai: URL(string: "https://api.x.ai/v1/api-key")!
        }
    }
}

/// 一次成功的余额读数。
public struct AIBalanceReading: Sendable, Equatable, Identifiable {
    public var provider: AIProvider
    /// 主数字,带货币符号(如「¥110.00」「$8.77」)。
    public var primary: String
    /// 拆分说明(赠金/充值等);没有就不硬凑。
    public var detail: String?
    public var fetchedAt: Date

    public init(provider: AIProvider, primary: String, detail: String? = nil, fetchedAt: Date) {
        self.provider = provider
        self.primary = primary
        self.detail = detail
        self.fetchedAt = fetchedAt
    }

    public var id: String { provider.rawValue }
}

public enum AIBalanceParseError: Error, Equatable {
    case malformed
    case unexpectedShape(String)
}

/// 各家响应的解析,纯函数——错误形状抛错,绝不编一个 0 出来。
public enum AIBalanceParser {

    public static func parse(provider: AIProvider, data: Data, now: Date) throws -> AIBalanceReading {
        switch provider {
        case .deepseek: try parseDeepSeek(data, now: now)
        case .openrouter: try parseOpenRouter(data, now: now)
        case .moonshot: try parseMoonshot(data, now: now)
        case .siliconflow: try parseSiliconFlow(data, now: now)
        case .xai: try parseXAI(data, now: now)
        }
    }

    // DeepSeek: {"is_available":..,"balance_infos":[{"currency":"CNY","total_balance":"110.00",
    //            "granted_balance":"10.00","topped_up_balance":"100.00"}]}
    private static func parseDeepSeek(_ data: Data, now: Date) throws -> AIBalanceReading {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let infos = root["balance_infos"] as? [[String: Any]], !infos.isEmpty
        else { throw AIBalanceParseError.unexpectedShape("balance_infos") }
        // 优先人民币账户,没有就取第一个。
        let info = infos.first { ($0["currency"] as? String) == "CNY" } ?? infos[0]
        let currency = (info["currency"] as? String) == "USD" ? "$" : "¥"
        guard let total = info["total_balance"] as? String else {
            throw AIBalanceParseError.unexpectedShape("total_balance")
        }
        var detail: String?
        if let granted = info["granted_balance"] as? String,
           let topped = info["topped_up_balance"] as? String {
            detail = String(
                format: String(localized: "充值 %@ · 赠金 %@"),
                currency + topped, currency + granted
            )
        }
        return AIBalanceReading(provider: .deepseek, primary: currency + total, detail: detail, fetchedAt: now)
    }

    // OpenRouter /api/v1/key: {"data":{"usage":1.23,"limit":10.0,"limit_remaining":8.77,
    //                          "is_free_tier":false,...}}  limit 可为 null(不限额)。
    private static func parseOpenRouter(_ data: Data, now: Date) throws -> AIBalanceReading {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any]
        else { throw AIBalanceParseError.unexpectedShape("data") }
        let usage = (payload["usage"] as? NSNumber)?.doubleValue
        let remaining = (payload["limit_remaining"] as? NSNumber)?.doubleValue
        if let remaining {
            return AIBalanceReading(
                provider: .openrouter,
                primary: String(format: "$%.2f", remaining),
                detail: usage.map { String(format: String(localized: "已用 $%.2f"), $0) },
                fetchedAt: now
            )
        }
        // 不限额的 key:只有累计用量可报,如实说「已用」而不是编余额。
        guard let usage else { throw AIBalanceParseError.unexpectedShape("usage") }
        return AIBalanceReading(
            provider: .openrouter,
            primary: String(format: String(localized: "已用 $%.2f"), usage),
            detail: String(localized: "此 key 未设限额,查不到余额"),
            fetchedAt: now
        )
    }

    // Moonshot: {"code":0,"data":{"available_balance":49.58,"voucher_balance":46.58,
    //            "cash_balance":3.00},"status":true}
    private static func parseMoonshot(_ data: Data, now: Date) throws -> AIBalanceReading {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any],
              let available = (payload["available_balance"] as? NSNumber)?.doubleValue
        else { throw AIBalanceParseError.unexpectedShape("available_balance") }
        var detail: String?
        if let voucher = (payload["voucher_balance"] as? NSNumber)?.doubleValue,
           let cash = (payload["cash_balance"] as? NSNumber)?.doubleValue {
            detail = String(
                format: String(localized: "现金 ¥%.2f · 代金券 ¥%.2f"),
                cash, voucher
            )
        }
        return AIBalanceReading(
            provider: .moonshot,
            primary: String(format: "¥%.2f", available),
            detail: detail,
            fetchedAt: now
        )
    }

    // SiliconFlow: {"code":20000,"status":true,"data":{"balance":"0.88",
    //               "chargeBalance":"7.00","totalBalance":"7.88",...}}
    private static func parseSiliconFlow(_ data: Data, now: Date) throws -> AIBalanceReading {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any],
              let total = payload["totalBalance"] as? String
        else { throw AIBalanceParseError.unexpectedShape("totalBalance") }
        var detail: String?
        if let gift = payload["balance"] as? String,
           let charged = payload["chargeBalance"] as? String {
            detail = String(
                format: String(localized: "充值 ¥%@ · 赠送 ¥%@"),
                charged, gift
            )
        }
        return AIBalanceReading(
            provider: .siliconflow,
            primary: "¥" + total,
            detail: detail,
            fetchedAt: now
        )
    }
}

extension AIBalanceParser {
    // xAI /v1/api-key: {"redacted_api_key":"xa..7f","name":"key",
    //   "api_key_blocked":false,"api_key_disabled":false,"team_blocked":false,
    //   "acls":["api-key:model:*"],...}
    // 官方无余额字段——只报可用状态,并在 detail 里说明去哪看钱。
    static func parseXAI(_ data: Data, now: Date) throws -> AIBalanceReading {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["redacted_api_key"] != nil || root["api_key_id"] != nil
        else { throw AIBalanceParseError.unexpectedShape("redacted_api_key") }
        let blocked = (root["api_key_blocked"] as? Bool ?? false)
            || (root["api_key_disabled"] as? Bool ?? false)
            || (root["team_blocked"] as? Bool ?? false)
        return AIBalanceReading(
            provider: .xai,
            primary: blocked ? String(localized: "已停用") : String(localized: "可用"),
            detail: String(localized: "xAI 未提供余额接口,金额请看 console.x.ai"),
            fetchedAt: now
        )
    }
}

/// Claude Code 本地用量汇总(零网络、零配置——思路致谢 ccusage,MIT)。
/// 只统计 token,不估算费用:价格表会过期,过期的估价是编数据。
public struct ClaudeCodeUsage: Sendable, Equatable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheCreationTokens: Int
    public var sessionCount: Int

    public init(
        inputTokens: Int = 0, outputTokens: Int = 0,
        cacheReadTokens: Int = 0, cacheCreationTokens: Int = 0,
        sessionCount: Int = 0
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.sessionCount = sessionCount
    }

    public var isEmpty: Bool { inputTokens == 0 && outputTokens == 0 && sessionCount == 0 }
}

/// 会话 JSONL 的逐行解析(纯函数)。行格式:
/// {"type":"assistant","timestamp":"…","message":{"id":"msg_x","usage":{
///   "input_tokens":n,"output_tokens":n,"cache_read_input_tokens":n,
///   "cache_creation_input_tokens":n}}}
/// 同一 message.id 只记一次(流式/重试会重复落行,ccusage 同款去重)。
public enum ClaudeCodeUsageParser {

    public static func accumulate(
        line: String,
        since: Date,
        seenMessageIDs: inout Set<String>,
        into usage: inout ClaudeCodeUsage
    ) {
        guard line.contains("\"usage\""), line.contains("\"assistant\""),
              let data = line.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["type"] as? String) == "assistant",
              let message = root["message"] as? [String: Any],
              let tokenUsage = message["usage"] as? [String: Any]
        else { return }

        // 时间过滤:没有可解析时间戳的行不计入(宁可少算不编造)。
        guard let stamp = root["timestamp"] as? String,
              let date = ISO8601DateFormatter.shared.date(from: stamp)
                ?? ISO8601DateFormatter.sharedFractional.date(from: stamp),
              date >= since
        else { return }

        if let id = message["id"] as? String {
            guard seenMessageIDs.insert(id).inserted else { return }
        }
        usage.inputTokens += (tokenUsage["input_tokens"] as? NSNumber)?.intValue ?? 0
        usage.outputTokens += (tokenUsage["output_tokens"] as? NSNumber)?.intValue ?? 0
        usage.cacheReadTokens += (tokenUsage["cache_read_input_tokens"] as? NSNumber)?.intValue ?? 0
        usage.cacheCreationTokens += (tokenUsage["cache_creation_input_tokens"] as? NSNumber)?.intValue ?? 0
    }
}

extension ISO8601DateFormatter {
    /// 复用格式器:每行建一个的开销在几十万行日志上是真实成本。
    /// nonisolated(unsafe) 的依据:ISO8601DateFormatter 的 date(from:)
    /// 在 Apple 文档中是线程安全的(NSISO8601DateFormatter 线程安全),
    /// 这里也只读不改配置。
    nonisolated(unsafe) static let shared: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    nonisolated(unsafe) static let sharedFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

// MARK: - 订阅额度(Claude / Codex)

/// 一个订阅限额窗口(如「5 小时窗」「每周」)。
/// 存 used,显示层算 remaining——Wei 的要求:主角是「还剩多少」。
public struct QuotaWindow: Sendable, Equatable, Identifiable, Codable {
    public var label: String
    public var usedPercent: Double
    public var resetsAt: Date?

    public init(label: String, usedPercent: Double, resetsAt: Date?) {
        self.label = label
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }

    /// ID 带上数值:同名窗口(如 Codex 的两个窗都是 10080 分钟)
    /// 会撞 ID,SwiftUI 的 ForEach 遇到重复 ID 行为未定义。
    public var id: String { "\(label)#\(usedPercent)" }
    public var remainingPercent: Double { max(0, 100 - usedPercent) }
}

public struct SubscriptionQuota: Sendable, Equatable, Codable {
    public enum Source: String, Sendable, Codable {
        case claude
        case codex
        case grok
    }

    public var source: Source
    public var windows: [QuotaWindow]
    public var planType: String?
    public var fetchedAt: Date

    public init(source: Source, windows: [QuotaWindow], planType: String? = nil, fetchedAt: Date) {
        self.source = source
        self.windows = windows
        self.planType = planType
        self.fetchedAt = fetchedAt
    }
}

/// Codex 会话日志里的 rate_limits 快照解析(纯函数)。
/// 行形状(实测本机 2026-08-15):
/// …"rate_limits":{"primary":{"used_percent":30.0,"window_minutes":10080,
///   "resets_at":1787385898},"secondary":…,"plan_type":"plus"…}
/// 零网络零逆向——Codex CLI 自己把额度写进了本地日志。
public enum CodexRateLimitParser {

    /// 从一行 JSONL 提取快照;不是 rate_limits 行返回 nil。
    public static func parse(line: String, now: Date) -> SubscriptionQuota? {
        guard line.contains("\"rate_limits\""),
              let data = line.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        // rate_limits 可能嵌在 payload 里,递归找第一个。
        guard let limits = findRateLimits(in: root) else { return nil }

        var windows: [QuotaWindow] = []
        for key in ["primary", "secondary"] {
            guard let window = limits[key] as? [String: Any],
                  let used = (window["used_percent"] as? NSNumber)?.doubleValue
            else { continue }
            let minutes = (window["window_minutes"] as? NSNumber)?.intValue
            let resets = (window["resets_at"] as? NSNumber).map {
                Date(timeIntervalSince1970: $0.doubleValue)
            }
            windows.append(QuotaWindow(
                label: Self.windowLabel(minutes: minutes),
                usedPercent: used,
                resetsAt: resets
            ))
        }
        guard !windows.isEmpty else { return nil }
        return SubscriptionQuota(
            source: .codex,
            windows: windows,
            planType: limits["plan_type"] as? String,
            fetchedAt: now
        )
    }

    private static func findRateLimits(in object: Any, depth: Int = 0) -> [String: Any]? {
        guard depth < 6, let dict = object as? [String: Any] else { return nil }
        if let limits = dict["rate_limits"] as? [String: Any] { return limits }
        for value in dict.values {
            if let found = findRateLimits(in: value, depth: depth + 1) { return found }
        }
        return nil
    }

    static func windowLabel(minutes: Int?) -> String {
        switch minutes {
        case .some(10080): String(localized: "每周")
        case .some(let m) where m >= 60 && m % 60 == 0 && m < 10080:
            String(format: String(localized: "%@ 小时窗"), String(describing: m / 60))
        case .some(let m): String(format: String(localized: "%@ 分钟窗"), String(describing: m))
        case .none: String(localized: "额度窗")
        }
    }
}

/// Claude 订阅用量响应解析(api.anthropic.com/api/oauth/usage,未文档化接口)。
/// 防御式:形状是「若干窗口对象,各带 utilization(0-100)与 resets_at」,
/// 键名容错;完全对不上就返回 nil,绝不编数字。
public enum ClaudeSubscriptionParser {

    public static func parse(data: Data, now: Date) -> SubscriptionQuota? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var windows: [QuotaWindow] = []

        let known: [(keys: [String], label: String)] = [
            (["five_hour", "fiveHour", "session"], String(localized: "5 小时窗")),
            (["seven_day", "sevenDay", "weekly", "seven_day_all_models"], String(localized: "每周·全模型")),
            (["seven_day_opus", "seven_day_sonnet", "weekly_opus", "seven_day_oauth_apps"], String(localized: "每周·高阶模型")),
        ]
        for entry in known {
            for key in entry.keys {
                guard let window = root[key] as? [String: Any] else { continue }
                guard let used = numeric(window["utilization"]) ?? numeric(window["used_percent"]) else { continue }
                let resets = numeric(window["resets_at"]).map { Date(timeIntervalSince1970: $0) }
                    ?? (window["resets_at"] as? String).flatMap {
                        ISO8601DateFormatter.shared.date(from: $0)
                            ?? ISO8601DateFormatter.sharedFractional.date(from: $0)
                    }
                windows.append(QuotaWindow(label: entry.label, usedPercent: used, resetsAt: resets))
                break
            }
        }
        guard !windows.isEmpty else { return nil }
        return SubscriptionQuota(source: .claude, windows: windows, fetchedAt: now)
    }

    private static func numeric(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }
}

/// Grok(xAI)订阅额度解析。数据来自 Grok CLI 自己的计费端点,
/// 用的是 CLI 已有的登录态——与 CodexBar / openusage 同一条路,
/// 不碰浏览器 cookie(grok.com 的 gRPC-web 路已被 WKE keypair 挡死,
/// 且那属于逆向,本项目不做)。
/// 实测响应(2026-08-15):{"config":{"creditUsagePercent":16.0,
///   "currentPeriod":{"end":"…"},"productUsage":[{"product":"GrokBuild",
///   "usagePercent":8.0},…],"onDemandCap":{"val":0},"prepaidBalance":{"val":0}}}
public enum GrokQuotaParser {

    public static func parse(data: Data, now: Date) -> SubscriptionQuota? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let config = (root["config"] as? [String: Any]) ?? root
        guard let used = (config["creditUsagePercent"] as? NSNumber)?.doubleValue else { return nil }

        let resets = (config["currentPeriod"] as? [String: Any])?["end"] as? String
            ?? config["billingPeriodEnd"] as? String
        let resetDate = resets.flatMap {
            ISO8601DateFormatter.sharedFractional.date(from: $0)
                ?? ISO8601DateFormatter.shared.date(from: $0)
        }

        var windows = [QuotaWindow(
            label: String(localized: "每周额度"),
            usedPercent: used,
            resetsAt: resetDate
        )]
        // 分产品用量(Grok Build / Grok Chat 各自占比),有就列出来。
        if let products = config["productUsage"] as? [[String: Any]] {
            for product in products {
                guard let name = product["product"] as? String,
                      let percent = (product["usagePercent"] as? NSNumber)?.doubleValue
                else { continue }
                windows.append(QuotaWindow(
                    label: displayName(for: name),
                    usedPercent: percent,
                    resetsAt: resetDate
                ))
            }
        }
        return SubscriptionQuota(source: .grok, windows: windows, planType: nil, fetchedAt: now)
    }

    static func displayName(for product: String) -> String {
        switch product {
        case "GrokBuild": String(localized: "Grok Build(编码)")
        case "GrokChat": String(localized: "Grok Chat(对话)")
        default: product
        }
    }
}
