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

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .deepseek: "DeepSeek"
        case .openrouter: "OpenRouter"
        case .moonshot: "Moonshot (Kimi)"
        case .siliconflow: String(localized: "硅基流动")
        }
    }

    /// 官方余额端点。只发 GET,只带 Bearer key,不发任何机器信息。
    public var balanceURL: URL {
        switch self {
        case .deepseek: URL(string: "https://api.deepseek.com/user/balance")!
        case .openrouter: URL(string: "https://openrouter.ai/api/v1/key")!
        case .moonshot: URL(string: "https://api.moonshot.cn/v1/users/me/balance")!
        case .siliconflow: URL(string: "https://api.siliconflow.cn/v1/user/info")!
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
