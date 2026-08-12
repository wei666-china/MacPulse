import Foundation

// 充电链路:充电器 → 线缆 → Mac 三段各自的上限与实际协商结果。
//
// PD 位解码与瓶颈判定改编自 WhatCable(MIT License,Copyright (c) 2026
// Darryl Morley),见 THIRD_PARTY_NOTICES.md。数据来源全部是 IORegistry
// 公开节点(AppleHPMInterface*、IOPortFeaturePowerSource、CC/SOP' 身份),
// 无私有 API;读取侧在 app target 的 ChargeLinkReader。

// MARK: - PDO(功率档位)

/// 充电器广告或协商出的一个功率档位(Power Data Object)。
public struct PDPowerOption: Codable, Sendable, Equatable {
    public var voltageMV: Int
    public var maxCurrentMA: Int
    public var maxPowerMW: Int

    public init(voltageMV: Int, maxCurrentMA: Int, maxPowerMW: Int) {
        self.voltageMV = voltageMV
        self.maxCurrentMA = maxCurrentMA
        self.maxPowerMW = maxPowerMW
    }

    public var watts: Double { Double(maxPowerMW) / 1000 }
    public var wattsLabel: String { String(format: "%.0fW", watts) }
    public var voltsLabel: String { String(format: "%.0fV", Double(voltageMV) / 1000) }
    public var voltsAmpsLabel: String {
        String(format: "%.0fV × %.1fA", Double(voltageMV) / 1000, Double(maxCurrentMA) / 1000)
    }
}

// MARK: - 线缆 e-marker

/// 从线缆芯片(e-marker,SOP' 应答)解码出的线缆身份。
/// 没有芯片的普通线(常见 USB 2.0 充电线)不会出现这个结构,
/// 此时 PD 协议把线按 3A 上限对待——判定逻辑靠这一点推断「疑似线缆瓶颈」。
public struct CableEmarkerInfo: Codable, Sendable, Equatable {
    /// USB-IF 厂商号(如 0x17EF = 联想)。只展示十六进制,不带厂商名数据库。
    public var vendorID: Int
    public var productID: Int
    /// 主动线内置信号芯片(长线/光纤线);被动线就是纯铜线。
    public var isActiveCable: Bool
    /// 数据速度档:0=USB 2.0,1=5Gbps,2=10Gbps,3=40Gbps,4=80Gbps。
    public var speedTier: Int
    /// 电流上限,安培(3 或 5)。
    public var maxAmps: Double
    /// 可承载功率上限(瓦)。50V 绝缘等级按 PD 实际上限 48V 钳制后 × 电流,
    /// 所以 5A EPR 线是 240W 而不是字面的 250W。
    public var maxWatts: Int
    /// 是否声明支持 EPR(48V 扩展功率,140W 以上必需)。
    public var eprCapable: Bool
    /// USB-IF 认证 ID(XID)非零。0 只说明没送测,不代表是次品。
    public var hasCertificationID: Bool

    public init(
        vendorID: Int,
        productID: Int,
        isActiveCable: Bool,
        speedTier: Int,
        maxAmps: Double,
        maxWatts: Int,
        eprCapable: Bool,
        hasCertificationID: Bool
    ) {
        self.vendorID = vendorID
        self.productID = productID
        self.isActiveCable = isActiveCable
        self.speedTier = speedTier
        self.maxAmps = maxAmps
        self.maxWatts = maxWatts
        self.eprCapable = eprCapable
        self.hasCertificationID = hasCertificationID
    }

    public var speedLabel: String {
        switch speedTier {
        case 0: return "USB 2.0(480 Mbps)"
        case 1: return "5 Gbps"
        case 2: return "10 Gbps"
        case 3: return "40 Gbps"
        case 4: return "80 Gbps"
        default: return "未知速度档(\(speedTier))"
        }
    }

    public var typeLabel: String { isActiveCable ? "主动线" : "被动线" }
}

/// PD Discover Identity 的 VDO 位解码。只解我们展示的字段,
/// 布局参照 USB PD R3.2 Table 6.34 / 6.42 / 6.43。
public enum ChargeLinkVDODecoder {
    /// IOKit 里 VDO 是 4 字节小端 Data。
    public static func vdo(from data: Data) -> UInt32? {
        guard data.count >= 4 else { return nil }
        return data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
    }

    /// 从 SOP' 的 VDO 数组解出线缆身份。vdos[0] = ID Header,
    /// vdos[1] = 认证 XID,vdos[3] = Cable VDO。数组不足或不是线缆时返回 nil。
    public static func cableInfo(vendorID: Int, productID: Int, vdos: [UInt32]) -> CableEmarkerInfo? {
        guard let header = vdos.first, vdos.count > 3 else { return nil }
        // ID Header bits 29..27:3 = 被动线,4 = 主动线;其余不是线缆。
        let productType = Int((header >> 27) & 0b111)
        guard productType == 3 || productType == 4 else { return nil }
        let isActive = productType == 4

        let cableVDO = vdos[3]
        let speedTier = Int(cableVDO & 0b111)
        // bits 6..5:1 = 3A,2 = 5A;0 是「默认」,线缆侧默认即 3A。
        let amps: Double = ((cableVDO >> 5) & 0b11) == 2 ? 5.0 : 3.0
        // bits 10..9:编码 3 = 50V,其余(含两个废弃编码)一律 20V。
        // 50V 是绝缘等级不是供电电压,PD 实际上限 48V,先钳制再算瓦数,
        // 否则 5A 线会虚报 250W(真实上限 48V × 5A = 240W)。
        let ratedVolts = ((cableVDO >> 9) & 0b11) == 3 ? 50.0 : 20.0
        let watts = Int((min(ratedVolts, 48) * amps).rounded())
        let epr = (cableVDO >> 17) & 1 == 1
        let xid = vdos.count > 1 ? vdos[1] : 0

        return CableEmarkerInfo(
            vendorID: vendorID,
            productID: productID,
            isActiveCable: isActive,
            speedTier: speedTier,
            maxAmps: amps,
            maxWatts: watts,
            eprCapable: epr,
            hasCertificationID: xid != 0
        )
    }
}

// MARK: - 链路快照

/// 一次采样看到的完整充电链路。只描述「当前在供电的那个口」;
/// 没插电或读不到协商节点时整个快照为 nil,由上层决定不显示面板。
public struct ChargeLinkSnapshot: Codable, Sendable, Equatable {
    /// 供电口的类型描述,"USB-C" 或 "MagSafe 3"。
    public var portTypeDescription: String
    public var portNumber: Int
    /// 充电器广告的所有功率档位,从高到低。上限取最大档。
    public var chargerOptions: [PDPowerOption]
    /// 当前协商生效的档位。刚插上未协商完时可能为 nil。
    public var negotiated: PDPowerOption?
    /// 线缆芯片身份;普通无芯片线为 nil。
    public var cable: CableEmarkerInfo?
    /// 同机是否还有另一个口插着充电器待命(macOS 一次只从一个口取电)。
    public var standbyChargerPresent: Bool

    public init(
        portTypeDescription: String,
        portNumber: Int,
        chargerOptions: [PDPowerOption],
        negotiated: PDPowerOption?,
        cable: CableEmarkerInfo?,
        standbyChargerPresent: Bool = false
    ) {
        self.portTypeDescription = portTypeDescription
        self.portNumber = portNumber
        self.chargerOptions = chargerOptions
        self.negotiated = negotiated
        self.cable = cable
        self.standbyChargerPresent = standbyChargerPresent
    }

    /// 充电器能给的上限(最大广告档),瓦。
    public var chargerMaxWatts: Int? {
        chargerOptions.map { Int(($0.watts).rounded()) }.max()
    }

    public var negotiatedWatts: Int? {
        negotiated.map { Int($0.watts.rounded()) }
    }
}

// MARK: - 瓶颈判定

/// 「为什么充得慢」的答案。判定顺序与文案分支改编自 WhatCable
/// 的 ChargingDiagnostic,阈值原样保留:低于上限一成(至少 5W)才算受限,
/// 避免把正常的涓流浮动判成瓶颈。
public struct ChargeLinkDiagnosis: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// 线缆芯片额定低于充电器,换线能更快 —— 唯一值得警告的情况。
        case cableLimit
        /// 无芯片线被按 3A 上限压住,且充电器明明有更高档 —— 疑似线缆瓶颈。
        case cableLimitSuspected
        /// Mac 自己要得少(电池接近满、系统空闲),正常状态。
        case macLimit
        /// 满速协商,一切正常。
        case fine
        /// 充电器只有这么大,链路没问题。
        case chargerCeiling
        /// 电池已充满,不取电。
        case batteryFull
        /// 系统暂停充电(充电上限/优化充电),不是故障。
        case onHold
    }

    public var kind: Kind
    /// 一句话结论,直接上卡片标题位。
    public var summary: String
    /// 展开解释,放卡片副文本。
    public var detail: String
    public var isWarning: Bool {
        kind == .cableLimit || kind == .cableLimitSuspected
    }

    public init(kind: Kind, summary: String, detail: String) {
        self.kind = kind
        self.summary = summary
        self.detail = detail
    }

    /// 判定顺序,一步比一步证据弱:
    /// 1. 线缆额定 < 充电器(e-marker 铁证)→ 线缆瓶颈
    /// 2. 电池已满 / 系统暂停 —— 协商值低的无辜解释,必须排在任何怀疑之前,
    ///    否则满电涓流全会被误判成「线不行」
    /// 3. 无芯片线且证据组合齐全 → 疑似线缆限速
    /// 4. 协商明显低于上限 → Mac 自限(正常)
    /// 5. 其余 → 满速 / 充电器天花板
    public static func diagnose(
        snapshot: ChargeLinkSnapshot,
        batteryFullyCharged: Bool?,
        batteryIsCharging: Bool?
    ) -> ChargeLinkDiagnosis? {
        guard let chargerW = snapshot.chargerMaxWatts, chargerW > 0 else { return nil }
        let negotiatedW = snapshot.negotiatedWatts

        // 1. 有芯片线:额定低于充电器,实打实的硬件不匹配。不看电池状态——
        //    即使现在没在充,「这套组合永远跑不满」也值得知道。
        if let cable = snapshot.cable, cable.maxWatts < chargerW {
            return ChargeLinkDiagnosis(
                kind: .cableLimit,
                summary: "线缆在拖慢充电",
                detail: "充电器能给 \(chargerW)W,这根线额定只有 \(cable.maxWatts)W。换根线能充更快。"
            )
        }

        // 2. 电池状态先行:满电/暂停时协商值天然低,轮不到怀疑线缆。
        if batteryFullyCharged == true {
            return ChargeLinkDiagnosis(
                kind: .batteryFull,
                summary: "电池已满,不在取电",
                detail: "充电器和线都没问题。需要时 Mac 最高可以取 \(chargerW)W。"
            )
        }
        if batteryIsCharging == false, negotiatedW != nil {
            return ChargeLinkDiagnosis(
                kind: .onHold,
                summary: "已插电,充电暂停中",
                detail: "充电器和线都没问题。macOS 暂停了充电(通常是充电上限或优化充电),整机仍从充电器取电。"
            )
        }

        // 3. 无芯片线:PD 规定没有 e-marker 就按 3A 封顶。只在证据组合齐全时
        //    才怀疑——必须正在充电、协商电压已经是充电器最高档(排除主动降档的
        //    涓流)、电流恰好钉在 3A 上限、且同电压档明明还有更大电流可给。
        //    仅限 USB-C:MagSafe 线不走 SOP' 应答,没有芯片节点是常态。
        if snapshot.portTypeDescription == "USB-C",
           snapshot.cable == nil,
           batteryIsCharging == true,
           let n = snapshot.negotiated,
           let top = snapshot.chargerOptions.first,
           n.voltageMV == top.voltageMV,
           (2900...3100).contains(n.maxCurrentMA),
           top.maxCurrentMA >= n.maxCurrentMA + 500 {
            return ChargeLinkDiagnosis(
                kind: .cableLimitSuspected,
                summary: "疑似线缆在限速",
                detail: "这根线没有身份芯片,按协议只能按 3A 走。充电器在 \(top.voltsLabel) 档还能给更多电流,若想跑满建议换带芯片的线。"
            )
        }

        let margin = max(5, chargerW / 10)

        // 4. 协商明显低于充电器上限:Mac 当前要得少,正常状态。
        if let n = negotiatedW, n < chargerW - margin {
            return ChargeLinkDiagnosis(
                kind: .macLimit,
                summary: "正在以 \(n)W 充电(充电器上限 \(chargerW)W)",
                detail: "充电器和线都有余量,是 Mac 当前要得少。电池快满或系统空闲时这是正常现象。"
            )
        }

        // 5. 协商到位,或还没协商完。
        if let n = negotiatedW {
            return ChargeLinkDiagnosis(
                kind: .fine,
                summary: "满速协商 · 最高 \(n)W",
                detail: "充电器和线缆匹配良好,Mac 按需取电,上限就是这个数。"
            )
        }

        return ChargeLinkDiagnosis(
            kind: .chargerCeiling,
            summary: "充电器上限 \(chargerW)W",
            detail: "协商还没完成,稍等片刻再看。"
        )
    }
}
