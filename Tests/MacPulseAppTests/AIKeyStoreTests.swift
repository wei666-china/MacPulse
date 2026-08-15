import Foundation
import XCTest
@testable import MacPulse
@testable import MacPulseCore

/// 钥匙串回环:存→读→删。用真实钥匙串(本机测试),测完必须清理干净。
final class AIKeyStoreTests: XCTestCase {
    override func tearDown() {
        AIKeyStore.delete(for: .deepseek)
        super.tearDown()
    }

    func testRoundTrip() {
        AIKeyStore.save("sk-test-abc123", for: .deepseek)
        XCTAssertEqual(AIKeyStore.load(for: .deepseek), "sk-test-abc123")
        XCTAssertTrue(AIKeyStore.configuredProviders.contains(.deepseek))
        AIKeyStore.delete(for: .deepseek)
        XCTAssertNil(AIKeyStore.load(for: .deepseek))
    }

    func testSaveTrimsWhitespace() {
        AIKeyStore.save("  sk-test-xyz \n", for: .deepseek)
        XCTAssertEqual(AIKeyStore.load(for: .deepseek), "sk-test-xyz", "粘贴常带换行,存前必须裁掉")
    }

    func testEmptyKeyIsNotStored() {
        AIKeyStore.save("   ", for: .deepseek)
        XCTAssertNil(AIKeyStore.load(for: .deepseek))
    }
}

/// 本地用量读取器活体:对着真实的 ~/.claude/projects 跑一遍。
/// 这台机器天天用 Claude Code,理应有今日数据;没有则跳过(别的机器属预期)。
final class ClaudeCodeUsageReaderLiveTests: XCTestCase {
    func testTodayUsageOnRealLogs() throws {
        guard let usage = ClaudeCodeUsageReader.todayUsage() else {
            throw XCTSkip("本机今日无 Claude Code 日志(其他机器属预期)")
        }
        XCTAssertGreaterThan(usage.outputTokens, 0)
        XCTAssertGreaterThan(usage.sessionCount, 0)
        XCTAssertLessThan(usage.outputTokens, 1_000_000_000, "量级失真,多半是重复计数")
    }
}
