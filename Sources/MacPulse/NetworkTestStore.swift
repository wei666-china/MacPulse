import CryptoKit
import Foundation
import MacPulseCore
import SwiftData

/// 一次测速的存档。
///
/// **永不落盘的东西**（这不是疏漏，是设计）：公网 IP（`cf-meta-ip`）、
/// 由 IP 推断的经纬度/城市/邮编、网关 MAC 原文、本机 IP、Wi-Fi 名称（压根不读）。
/// 只留 `serverColo` 这个三字母机场码。
@Model
final class NetworkTestRecord {
    @Attribute(.unique) var recordKey: String
    var startedAt: Date
    var durationSeconds: Double
    var tierRaw: String
    var completenessRaw: String
    var triggerRaw: String
    var connectivityRaw: String

    // 链路上下文
    var interfaceName: String?
    var interfaceKindRaw: String?
    var wifiGeneration: String?
    var wifiPHYMode: String?
    var linkRateMbps: Double?
    var isExpensive: Bool
    var isConstrained: Bool
    /// 加盐哈希，用来区分「家里」和「公司」而不存任何可还原的标识。
    var networkKeyHash: String?
    var networkLabel: String?

    // 延迟
    var latencyP50Ms: Double?
    var latencyP95Ms: Double?
    var latencyJitterMs: Double?
    var latencyServerMinRttMs: Double?
    var handshakeAttempts: Int
    var handshakeFailures: Int
    var bufferbloatMs: Double?

    // 握手分解
    var dnsMs: Double?
    var tcpMs: Double?
    var tlsMs: Double?
    var ttfbMs: Double?
    var dnsWasCached: Bool

    // 吞吐（每个数字都带误差区间）
    var downloadBitsPerSecond: Double?
    var downloadLowBitsPerSecond: Double?
    var downloadHighBitsPerSecond: Double?
    var downloadStreams: Int
    var downloadSamples: Int
    var singleStreamDownloadBitsPerSecond: Double?
    var uploadBitsPerSecond: Double?
    var uploadLowBitsPerSecond: Double?
    var uploadHighBitsPerSecond: Double?
    var uploadStreams: Int
    var uploadSamples: Int

    // 可达性与成本
    var ipv4Reachable: Bool?
    var ipv6Reachable: Bool?
    var serverColo: String?
    var bytesDownloaded: Int64
    var bytesUploaded: Int64
    var failureCode: String?

    init(result: NetworkTestResult, networkKeyHash: String?) {
        // 毫秒精度：秒级会让同一秒内的两次手动测速撞主键。
        recordKey = String(Int64((result.startedAt.timeIntervalSince1970 * 1_000).rounded()))
        startedAt = result.startedAt
        durationSeconds = result.durationSeconds
        tierRaw = result.tier.rawValue
        completenessRaw = result.completeness.rawValue
        triggerRaw = result.trigger.rawValue
        connectivityRaw = result.connectivity.rawValue

        interfaceName = result.link?.interfaceName
        interfaceKindRaw = result.link?.kind?.rawValue
        wifiGeneration = result.link?.generation
        wifiPHYMode = result.link?.phyMode
        linkRateMbps = result.link?.linkRateMbps
        isExpensive = result.path?.isExpensive ?? false
        isConstrained = result.path?.isConstrained ?? false
        self.networkKeyHash = networkKeyHash

        latencyP50Ms = result.latency?.p50Milliseconds
        latencyP95Ms = result.latency?.p95Milliseconds
        latencyJitterMs = result.latency?.jitterMilliseconds
        latencyServerMinRttMs = result.latency?.serverMinRttMilliseconds
        handshakeAttempts = result.latency?.attempts ?? 0
        handshakeFailures = result.latency?.failures ?? 0
        bufferbloatMs = result.bufferbloatMilliseconds

        dnsMs = result.dnsMilliseconds
        tcpMs = result.tcpMilliseconds
        tlsMs = result.tlsMilliseconds
        ttfbMs = result.timeToFirstByteMilliseconds
        dnsWasCached = result.dnsWasPossiblyCached

        downloadBitsPerSecond = result.download?.bitsPerSecond
        downloadLowBitsPerSecond = result.download?.lowBitsPerSecond
        downloadHighBitsPerSecond = result.download?.highBitsPerSecond
        downloadStreams = result.download?.streams ?? 0
        downloadSamples = result.download?.samples ?? 0
        singleStreamDownloadBitsPerSecond = result.singleStreamDownloadBitsPerSecond
        uploadBitsPerSecond = result.upload?.bitsPerSecond
        uploadLowBitsPerSecond = result.upload?.lowBitsPerSecond
        uploadHighBitsPerSecond = result.upload?.highBitsPerSecond
        uploadStreams = result.upload?.streams ?? 0
        uploadSamples = result.upload?.samples ?? 0

        ipv4Reachable = result.ipv4Reachable
        ipv6Reachable = result.ipv6Reachable
        serverColo = result.serverColo
        bytesDownloaded = result.bytesDownloaded
        bytesUploaded = result.bytesUploaded
        failureCode = result.failureCode
    }
}

@MainActor
final class NetworkTestStore {
    /// 90 天而不是 7 天：这个功能的意义就是纵向对比（「我家网是不是变慢了」），
    /// 7 天根本答不了。按每天几次估算约 360 行、100KB 左右。
    static let retentionDays = 90
    static let maximumRecords = 2_000

    private let container: ModelContainer
    private let context: ModelContext

    init(inMemory: Bool = false) throws {
        let schema = Schema([NetworkTestRecord.self])
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(
                "MacPulseNetworkTestsTests",
                schema: schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )
        } else {
            let directory = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("MacPulse", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            configuration = ModelConfiguration(
                "MacPulseNetworkTests",
                schema: schema,
                url: directory.appendingPathComponent("network.store"),
                allowsSave: true,
                cloudKitDatabase: .none
            )
        }
        container = try ModelContainer(for: schema, configurations: [configuration])
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    func save(_ result: NetworkTestResult, networkKeyHash: String?) throws {
        context.insert(NetworkTestRecord(result: result, networkKeyHash: networkKeyHash))
        try context.save()
    }

    func loadRecent(days: Int = retentionDays) throws -> [NetworkTestRecord] {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        return try context.fetch(
            FetchDescriptor<NetworkTestRecord>(
                predicate: #Predicate { $0.startedAt >= cutoff },
                sortBy: [SortDescriptor(\.startedAt)]
            )
        )
    }

    func prune(days: Int = retentionDays, maximum: Int = maximumRecords) throws {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let expired = try context.fetch(
            FetchDescriptor<NetworkTestRecord>(predicate: #Predicate { $0.startedAt < cutoff })
        )
        expired.forEach(context.delete)

        // 条数上限兜住「反复手动重测」的用户。
        let all = try context.fetch(
            FetchDescriptor<NetworkTestRecord>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        )
        if all.count > maximum {
            all.dropFirst(maximum).forEach(context.delete)
        }
        if !expired.isEmpty || all.count > maximum {
            try context.save()
        }
    }
}

/// 网络身份哈希。
///
/// 用来区分不同地点的网络而**不碰 SSID**（读 SSID 需要定位权限）。
/// 网关 MAC 无需权限即可读；加一个只存在本机的随机盐，防止这个哈希变成
/// 一个全局可彩虹表反查的 MAC 摘要。
enum NetworkIdentity {
    private static let saltKey = "MacPulse.networkKeySalt"

    /// 读默认网关的 MAC 地址。
    ///
    /// 走路由 socket 的 sysctl（`NET_RT_FLAGS | RTF_LLINFO`），也就是 `arp -a`
    /// 用的同一条路径。无需任何权限。
    ///
    /// 为什么用网关 MAC 而不是别的：SSID 和 BSSID 都要定位权限；网关 IP 太容易
    /// 撞车（到处都是 192.168.1.1）；而网关 MAC 在同一个地点稳定、跨地点几乎必然
    /// 不同，且加盐哈希之后不可反查。
    static func currentGatewayMAC() -> String? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_LLINFO]
        var length = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: length)
        guard buffer.withUnsafeMutableBytes({ raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            return sysctl(&mib, u_int(mib.count), base, &length, nil, 0) == 0
        }) else { return nil }

        let gatewayAddress = defaultGatewayIPv4()
        var best: String?

        buffer.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset + MemoryLayout<rt_msghdr2>.size <= length {
                let header = base.advanced(by: offset).assumingMemoryBound(to: rt_msghdr2.self).pointee
                let messageLength = Int(header.rtm_msglen)
                guard messageLength > 0, offset + messageLength <= length else { break }
                defer { offset += messageLength }

                // sockaddr 序列紧跟在头部之后：先 dst（inet），再 gateway（link）。
                let payload = base.advanced(by: offset + MemoryLayout<rt_msghdr2>.size)
                let destination = payload.assumingMemoryBound(to: sockaddr_inarp.self).pointee
                guard destination.sin_family == UInt8(AF_INET) else { continue }

                let dstBytes = withUnsafeBytes(of: destination.sin_addr) { Array($0) }
                let dstText = dstBytes.map(String.init).joined(separator: ".")

                let linkOffset = Int(roundUpToNextWord(destination.sin_len))
                let link = payload.advanced(by: linkOffset).assumingMemoryBound(to: sockaddr_dl.self).pointee
                guard link.sdl_alen == 6 else { continue }

                let mac = withUnsafeBytes(of: link.sdl_data) { raw -> String? in
                    let start = Int(link.sdl_nlen)
                    guard start + 6 <= raw.count else { return nil }
                    return (0..<6)
                        .map { String(format: "%02x", raw[start + $0]) }
                        .joined(separator: ":")
                }
                guard let mac else { continue }

                if let gatewayAddress, dstText == gatewayAddress {
                    best = mac
                    break
                }
                // 找不到默认网关时，退而记住第一个邻居——总比没有强，
                // 但优先级低于精确匹配。
                if best == nil { best = mac }
            }
        }
        return best
    }

    /// 默认路由的下一跳地址。
    private static func defaultGatewayIPv4() -> String? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_DUMP, 0]
        var length = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard buffer.withUnsafeMutableBytes({ raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            return sysctl(&mib, u_int(mib.count), base, &length, nil, 0) == 0
        }) else { return nil }

        var result: String?
        buffer.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset + MemoryLayout<rt_msghdr>.size <= length {
                let header = base.advanced(by: offset).assumingMemoryBound(to: rt_msghdr.self).pointee
                let messageLength = Int(header.rtm_msglen)
                guard messageLength > 0, offset + messageLength <= length else { break }
                defer { offset += messageLength }

                // 默认路由：目的地址全零且带网关。
                guard header.rtm_flags & RTF_GATEWAY != 0,
                      header.rtm_addrs & RTA_DST != 0,
                      header.rtm_addrs & RTA_GATEWAY != 0
                else { continue }

                let payload = base.advanced(by: offset + MemoryLayout<rt_msghdr>.size)
                let destination = payload.assumingMemoryBound(to: sockaddr_in.self).pointee
                guard destination.sin_family == UInt8(AF_INET), destination.sin_addr.s_addr == 0 else { continue }

                let gatewayOffset = Int(roundUpToNextWord(destination.sin_len))
                let gateway = payload.advanced(by: gatewayOffset).assumingMemoryBound(to: sockaddr_in.self).pointee
                guard gateway.sin_family == UInt8(AF_INET) else { continue }
                result = withUnsafeBytes(of: gateway.sin_addr) { Array($0) }
                    .map(String.init)
                    .joined(separator: ".")
                break
            }
        }
        return result
    }

    /// 路由消息里的 sockaddr 按 4 字节对齐排列。
    private static func roundUpToNextWord(_ length: UInt8) -> Int {
        let value = Int(length)
        guard value > 0 else { return 4 }
        return (value + 3) & ~3
    }

    static func hash(gatewayMAC: String?, interfaceName: String?) -> String? {
        guard let gatewayMAC, !gatewayMAC.isEmpty else { return nil }
        var hasher = SHA256()
        hasher.update(data: Data(salt().utf8))
        hasher.update(data: Data(gatewayMAC.utf8))
        hasher.update(data: Data((interfaceName ?? "").utf8))
        return hasher.finalize().compactMap { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    private static func salt() -> String {
        if let existing = UserDefaults.standard.string(forKey: saltKey) { return existing }
        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: saltKey)
        return generated
    }
}
