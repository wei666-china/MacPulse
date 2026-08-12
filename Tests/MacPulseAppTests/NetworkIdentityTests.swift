import CryptoKit
import XCTest
@testable import MacPulse

/// 网关 MAC 读取是裸 sysctl 路由表解析，编译通过说明不了任何事。
/// 这里拿系统工具的输出做交叉验证。
final class NetworkIdentityTests: XCTestCase {
    private func shell(_ command: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func testGatewayMACMatchesSystemArpTable() throws {
        // 系统给的答案：默认路由的下一跳，再到 ARP 表里查它的 MAC。
        let gatewayIP = shell("route -n get default 2>/dev/null | awk '/gateway:/{print $2}'")
        guard !gatewayIP.isEmpty else { throw XCTSkip("当前没有默认路由") }

        let expected = shell("arp -n \(gatewayIP) 2>/dev/null | awk '{print $4}'")
        guard !expected.isEmpty, expected.contains(":") else {
            throw XCTSkip("ARP 表里还没有网关条目")
        }

        let actual = try XCTUnwrap(NetworkIdentity.currentGatewayMAC(), "应当读得到网关 MAC")

        // arp 输出的是 d0:32:c3:30:2d:62 这种形式，但单字节可能不补零（如 0:32:...），
        // 归一化后再比。
        func normalize(_ mac: String) -> String {
            mac.split(separator: ":")
                .map { String(format: "%02x", UInt8($0, radix: 16) ?? 0) }
                .joined(separator: ":")
        }
        XCTAssertEqual(normalize(actual), normalize(expected), "读出来的网关 MAC 必须和 arp 一致")
    }

    /// 哈希必须稳定（同一网络同一结果）且不可反查（含只存本机的随机盐）。
    func testHashIsStableAndDoesNotLeakTheMAC() throws {
        let mac = "d0:32:c3:30:2d:62"
        let first = try XCTUnwrap(NetworkIdentity.hash(gatewayMAC: mac, interfaceName: "en0"))
        let second = try XCTUnwrap(NetworkIdentity.hash(gatewayMAC: mac, interfaceName: "en0"))
        XCTAssertEqual(first, second, "同一网络必须得到同一个键")
        XCTAssertEqual(first.count, 16)

        // 不同网络必须区分开——这正是「家里 vs 公司」能分色的依据。
        let other = try XCTUnwrap(NetworkIdentity.hash(gatewayMAC: "aa:bb:cc:dd:ee:ff", interfaceName: "en0"))
        XCTAssertNotEqual(first, other)

        // 不能是 MAC 的明文或裸摘要。
        //
        // 注意不能断言「哈希里不出现 MAC 的任何两字符片段」——16 位十六进制串里
        // 随机撞上某个两字符片段的概率约 30%，那条断言会随机失败，且它证明不了
        // 任何东西。真正要保证的性质是**加了只存在本机的盐**：否则这个哈希就是
        // 一个全网可彩虹表反查的 MAC 摘要。
        XCTAssertFalse(first.contains(":"))
        XCTAssertFalse(first.contains(mac.replacingOccurrences(of: ":", with: "")))

        let unsalted = SHA256.hash(data: Data((mac + "en0").utf8))
            .compactMap { String(format: "%02x", $0) }
            .joined()
            .prefix(16)
        XCTAssertNotEqual(first, String(unsalted), "必须加盐，否则等同于可反查的 MAC 摘要")
    }

    func testMissingGatewayYieldsNilRatherThanAConstantKey() {
        XCTAssertNil(NetworkIdentity.hash(gatewayMAC: nil, interfaceName: "en0"))
        XCTAssertNil(NetworkIdentity.hash(gatewayMAC: "", interfaceName: "en0"))
    }

    func testRepeatedReadsDoNotCrashOrLeak() throws {
        guard NetworkIdentity.currentGatewayMAC() != nil else {
            throw XCTSkip("当前读不到网关")
        }
        for _ in 0..<200 {
            _ = NetworkIdentity.currentGatewayMAC()
        }
        XCTAssertNotNil(NetworkIdentity.currentGatewayMAC())
    }
}
