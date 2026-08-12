import Foundation
import MacPulseCore
import Network
import Synchronization

/// 观察系统网络路径状态。**不发任何网络请求**——`NWPathMonitor` 读的是本机路由表
/// 与接口状态，属于零流量读数。
///
/// `NWPath` 本身不是 `Sendable`，绝不能跨隔离域传递。这里在回调内部就地抽成
/// `NetworkPathSnapshot` 这个纯值类型再往外送。
final class NetworkPathObserver: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.local.MacPulse.path")
    private let storage = Mutex<NetworkPathSnapshot>(NetworkPathSnapshot())
    private let onChange: @Sendable (NetworkPathSnapshot) -> Void

    /// 当前快照。同步可读，供策略判断使用。
    var current: NetworkPathSnapshot {
        storage.withLock { $0 }
    }

    init(onChange: @escaping @Sendable (NetworkPathSnapshot) -> Void) {
        self.onChange = onChange
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let snapshot = Self.snapshot(from: path)
            let changed = self.storage.withLock { stored -> Bool in
                guard stored != snapshot else { return false }
                stored = snapshot
                return true
            }
            if changed { self.onChange(snapshot) }
        }
    }

    func start() {
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
    }

    private static func snapshot(from path: NWPath) -> NetworkPathSnapshot {
        let interfaces = path.availableInterfaces
        let primary = interfaces.first

        return NetworkPathSnapshot(
            isSatisfied: path.status == .satisfied,
            // 手机热点、蜂窝：完整测速在这类链路上永不自动进行。
            isExpensive: path.isExpensive,
            // 用户开启了「低数据模式」。
            isConstrained: path.isConstrained,
            supportsIPv4: path.supportsIPv4,
            supportsIPv6: path.supportsIPv6,
            // 只看主接口:availableInterfaces 会把 iCloud 私有中继、接力等
            // 系统自带的 utun 全数列出,按「存在即 VPN」判,没装 VPN 的机器
            // 也常年挂着 VPN 徽章。主接口是 utun 才是流量真走隧道。
            usesVPN: primary.map { $0.name.hasPrefix("utun") || $0.name.hasPrefix("ipsec") } ?? false,
            primaryInterfaceName: primary?.name,
            primaryInterfaceKind: primary.map { Self.kind(for: $0.type) }
        )
    }

    private static func kind(for type: NWInterface.InterfaceType) -> NetworkInterfaceKind {
        switch type {
        case .wifi: .wifi
        case .wiredEthernet: .ethernet
        case .cellular: .cellular
        case .loopback: .loopback
        case .other: .other
        @unknown default: .other
        }
    }
}
