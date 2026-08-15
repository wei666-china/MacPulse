import Foundation
import XCTest
@testable import MacPulseCore

/// 四家余额响应的解析。夹具照官方文档/one-api(MIT)的响应形状造。
final class AIBalanceParserTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func parse(_ provider: AIProvider, _ json: String) throws -> AIBalanceReading {
        try AIBalanceParser.parse(provider: provider, data: Data(json.utf8), now: now)
    }

    func testDeepSeekPrefersCNY() throws {
        let json = """
        {"is_available":true,"balance_infos":[
          {"currency":"USD","total_balance":"2.00","granted_balance":"0.00","topped_up_balance":"2.00"},
          {"currency":"CNY","total_balance":"110.00","granted_balance":"10.00","topped_up_balance":"100.00"}]}
        """
        let reading = try parse(.deepseek, json)
        XCTAssertEqual(reading.primary, "¥110.00")
        XCTAssertTrue(reading.detail?.contains("¥100.00") == true, "充值/赠金拆分要在 detail 里")
    }

    func testOpenRouterWithLimit() throws {
        let json = #"{"data":{"label":"key","usage":1.23,"limit":10.0,"limit_remaining":8.77,"is_free_tier":false}}"#
        let reading = try parse(.openrouter, json)
        XCTAssertEqual(reading.primary, "$8.77")
    }

    func testOpenRouterUnlimitedKeyIsHonest() throws {
        // limit 为 null:查不到余额就说「已用」,不编余额。
        let json = #"{"data":{"label":"key","usage":4.20,"limit":null,"limit_remaining":null}}"#
        let reading = try parse(.openrouter, json)
        XCTAssertTrue(reading.primary.contains("4.20"))
        XCTAssertTrue(reading.detail?.contains("查不到余额") == true)
    }

    func testMoonshot() throws {
        let json = #"{"code":0,"data":{"available_balance":49.58,"voucher_balance":46.58,"cash_balance":3.00},"scode":"0x0","status":true}"#
        let reading = try parse(.moonshot, json)
        XCTAssertEqual(reading.primary, "¥49.58")
        XCTAssertTrue(reading.detail?.contains("¥3.00") == true)
    }

    func testSiliconFlow() throws {
        let json = #"{"code":20000,"message":"OK","status":true,"data":{"id":"u","balance":"0.88","chargeBalance":"7.00","totalBalance":"7.88"}}"#
        let reading = try parse(.siliconflow, json)
        XCTAssertEqual(reading.primary, "¥7.88")
    }

    func testMalformedResponseThrows() {
        // 形状不对必须抛错,绝不编一个 0 出来(项目第一铁律)。
        for provider in AIProvider.allCases {
            XCTAssertThrowsError(try parse(provider, #"{"error":"unauthorized"}"#),
                                 "\(provider) 的坏响应必须抛错")
            XCTAssertThrowsError(try parse(provider, "not json at all"))
        }
    }
}

/// Claude Code 本地用量的逐行解析。
final class ClaudeCodeUsageParserTests: XCTestCase {
    private let since = ISO8601DateFormatter.shared.date(from: "2026-08-15T00:00:00Z")!

    private func line(id: String, stamp: String, input: Int, output: Int) -> String {
        #"{"type":"assistant","timestamp":"\#(stamp)","message":{"id":"\#(id)","usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_read_input_tokens":5,"cache_creation_input_tokens":2}}}"#
    }

    func testAccumulatesAndDeduplicates() {
        var usage = ClaudeCodeUsage()
        var seen = Set<String>()
        ClaudeCodeUsageParser.accumulate(
            line: line(id: "m1", stamp: "2026-08-15T10:00:00Z", input: 100, output: 50),
            since: since, seenMessageIDs: &seen, into: &usage
        )
        // 同一 message.id 重复落行(流式/重试),只记一次。
        ClaudeCodeUsageParser.accumulate(
            line: line(id: "m1", stamp: "2026-08-15T10:00:01Z", input: 100, output: 50),
            since: since, seenMessageIDs: &seen, into: &usage
        )
        ClaudeCodeUsageParser.accumulate(
            line: line(id: "m2", stamp: "2026-08-15T11:00:00Z", input: 30, output: 20),
            since: since, seenMessageIDs: &seen, into: &usage
        )
        XCTAssertEqual(usage.inputTokens, 130)
        XCTAssertEqual(usage.outputTokens, 70)
        XCTAssertEqual(usage.cacheReadTokens, 10)
    }

    func testOldEntriesAreFiltered() {
        var usage = ClaudeCodeUsage()
        var seen = Set<String>()
        ClaudeCodeUsageParser.accumulate(
            line: line(id: "old", stamp: "2026-08-14T23:59:00Z", input: 999, output: 999),
            since: since, seenMessageIDs: &seen, into: &usage
        )
        XCTAssertTrue(usage.isEmpty, "窗口之前的用量不计")
    }

    func testNonAssistantAndGarbageIgnored() {
        var usage = ClaudeCodeUsage()
        var seen = Set<String>()
        for junk in [
            #"{"type":"user","timestamp":"2026-08-15T10:00:00Z","message":{"usage":{"input_tokens":5}}}"#,
            "not json", "",
            #"{"type":"assistant","message":{"usage":{"input_tokens":5}}}"#,  // 无时间戳:宁可少算
        ] {
            ClaudeCodeUsageParser.accumulate(line: junk, since: since, seenMessageIDs: &seen, into: &usage)
        }
        XCTAssertTrue(usage.isEmpty)
    }

    func testFractionalTimestampAccepted() {
        var usage = ClaudeCodeUsage()
        var seen = Set<String>()
        ClaudeCodeUsageParser.accumulate(
            line: line(id: "f", stamp: "2026-08-15T10:00:00.123Z", input: 10, output: 5),
            since: since, seenMessageIDs: &seen, into: &usage
        )
        XCTAssertEqual(usage.inputTokens, 10, "带毫秒的时间戳也要认(真实日志两种都有)")
    }
}

/// Codex 本地日志的 rate_limits 快照解析。
/// 夹具是本机实测行(2026-08-15,数值原样),这是真值锚。
final class CodexRateLimitParserTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testRealMachineSnapshot() throws {
        let line = #"{"timestamp":"2026-08-15T18:04:20Z","type":"event","payload":{"rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":30.0,"window_minutes":10080,"resets_at":1787385898},"secondary":null,"credits":{"has_credits":false,"unlimited":false,"balance":"0"},"individual_limit":null,"spend_control_reached":null,"plan_type":"plus","rate_limit_reached_type":null}}}"#
        let quota = try XCTUnwrap(CodexRateLimitParser.parse(line: line, now: now))
        XCTAssertEqual(quota.source, .codex)
        XCTAssertEqual(quota.planType, "plus")
        XCTAssertEqual(quota.windows.count, 1)
        XCTAssertEqual(quota.windows[0].usedPercent, 30.0)
        XCTAssertEqual(quota.windows[0].remainingPercent, 70.0, "主角是剩余")
        XCTAssertEqual(quota.windows[0].label, "每周", "10080 分钟 = 每周")
        XCTAssertEqual(quota.windows[0].resetsAt, Date(timeIntervalSince1970: 1_787_385_898))
    }

    func testNonRateLimitLinesIgnored() {
        XCTAssertNil(CodexRateLimitParser.parse(line: #"{"type":"message","text":"hi"}"#, now: now))
        XCTAssertNil(CodexRateLimitParser.parse(line: "garbage", now: now))
    }

    func testPrimaryAndSecondaryWindows() throws {
        let line = #"{"rate_limits":{"primary":{"used_percent":39.0,"window_minutes":300,"resets_at":1787300000},"secondary":{"used_percent":74.0,"window_minutes":10080,"resets_at":1787385898},"plan_type":"pro"}}"#
        let quota = try XCTUnwrap(CodexRateLimitParser.parse(line: line, now: now))
        XCTAssertEqual(quota.windows.count, 2)
        XCTAssertEqual(quota.windows[0].label, "5 小时窗")
        XCTAssertEqual(quota.windows[1].remainingPercent, 26.0)
    }
}

/// Claude 订阅用量响应解析(未文档化接口,形状按社区文档,键名多候选防漂移)。
final class ClaudeSubscriptionParserTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testCommunityDocumentedShape() throws {
        let json = #"{"five_hour":{"utilization":39,"resets_at":"2026-08-15T12:00:00Z"},"seven_day":{"utilization":74,"resets_at":"2026-08-16T09:00:00Z"},"seven_day_opus":{"utilization":93,"resets_at":"2026-08-16T09:00:00Z"}}"#
        let quota = try XCTUnwrap(ClaudeSubscriptionParser.parse(data: Data(json.utf8), now: now))
        XCTAssertEqual(quota.windows.count, 3)
        XCTAssertEqual(quota.windows[0].usedPercent, 39)
        XCTAssertEqual(quota.windows[1].remainingPercent, 26)
        XCTAssertEqual(quota.windows[2].remainingPercent, 7)
    }

    func testUnknownShapeYieldsNilNotZeros() {
        XCTAssertNil(ClaudeSubscriptionParser.parse(data: Data(#"{"whatever":1}"#.utf8), now: now),
                     "形状对不上就 nil,绝不编 0%")
        XCTAssertNil(ClaudeSubscriptionParser.parse(data: Data("junk".utf8), now: now))
    }
}
