import Foundation
import XCTest
@testable import MacPulseCore

final class HealthReportTests: XCTestCase {

    private func report(items: [HealthReport.Item], unavailable: [String] = []) -> HealthReport {
        HealthReport(
            machine: "Apple M5",
            systemVersion: "macOS 26.0.0",
            appVersion: "3.0.0-beta.1",
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            items: items,
            unavailable: unavailable
        )
    }

    func testWarningsSortFirstAndKeepStableOrder() {
        let r = report(items: [
            .init(level: .ok, category: "存储", summary: "充裕"),
            .init(level: .warning, category: "电池", summary: "健康度 72%"),
            .init(level: .notice, category: "内存", summary: "偶尔吃紧"),
            .init(level: .warning, category: "充电", summary: "线缆限速")
        ])
        XCTAssertEqual(r.sortedItems.map(\.category), ["电池", "充电", "内存", "存储"])
        XCTAssertEqual(r.warningCount, 2)
    }

    func testMarkdownStatesProblemCount() {
        let clean = report(items: [.init(level: .ok, category: "电池", summary: "99%")])
        XCTAssertTrue(clean.markdown().contains("未发现异常"))
        let dirty = report(items: [.init(level: .warning, category: "电池", summary: "72%")])
        XCTAssertTrue(dirty.markdown().contains("发现 1 项需要注意"))
    }

    /// 读不到的项必须写进报告。否则读者会把「报告里没提」当成「这项没问题」——
    /// 这正是本 App 最忌讳的那种沉默。
    func testUnavailableSourcesAreDisclosed() {
        let r = report(
            items: [.init(level: .ok, category: "电池", summary: "99%")],
            unavailable: ["芯片温度", "睡眠掉电"]
        )
        let text = r.markdown()
        XCTAssertTrue(text.contains("芯片温度"))
        XCTAssertTrue(text.contains("不代表没有问题"))
    }

    /// 隐私红线:报告是拿去外发的,任何标识信息都不许出现。
    /// 这条测试是给未来加字段的人设的路障。
    func testReportCarriesNoIdentifiers() {
        let r = report(
            items: [
                .init(level: .warning, category: "电池", summary: "健康度 72%", detail: "建议更换"),
                .init(level: .ok, category: "网络", summary: "Wi-Fi 6 已连接")
            ],
            unavailable: ["风扇"]
        )
        let text = r.markdown()
        // 典型的标识信息形态:序列号、IP、家目录路径、用户名。
        XCTAssertNil(text.range(of: #"\b[A-Z0-9]{10,12}\b"#, options: .regularExpression), "疑似序列号")
        XCTAssertNil(text.range(of: #"\b\d{1,3}(\.\d{1,3}){3}\b"#, options: .regularExpression), "疑似 IP")
        XCTAssertFalse(text.contains("/Users/"), "不得包含用户路径")
        XCTAssertFalse(text.contains(NSUserName()), "不得包含用户名")
        XCTAssertTrue(text.contains("不含序列号"), "隐私声明本身要在报告里")
    }

    func testMarkdownIncludesEnvironmentHeader() {
        let text = report(items: []).markdown()
        XCTAssertTrue(text.contains("Apple M5"))
        XCTAssertTrue(text.contains("macOS 26.0.0"))
        XCTAssertTrue(text.contains("3.0.0-beta.1"), "版本号要在,便于对照 issue")
    }
}
