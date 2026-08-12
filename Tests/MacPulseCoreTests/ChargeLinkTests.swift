import Foundation
import XCTest
@testable import MacPulseCore

/// 充电链路解码与判定。VDO 样本是真机抓的:M5 MacBook Air 上一根
/// 联想 e-marker 线(VID 0x17EF)+ 96W 充电器,ioreg 原始值:
/// VDOs = (<ef176018>, <00000000>, <000015a2>, <422e0a00>),小端。
final class ChargeLinkTests: XCTestCase {

    /// 真机线缆样本,解码后应为:被动线 / 5A / 240W(50V 钳到 48V)/ 10Gbps / EPR。
    private let lenovoCableVDOs: [UInt32] = [0x1860_17EF, 0x0000_0000, 0xA215_0000, 0x000A_2E42]

    func testVDOFromDataIsLittleEndian() {
        XCTAssertEqual(ChargeLinkVDODecoder.vdo(from: Data([0x42, 0x2E, 0x0A, 0x00])), 0x000A_2E42)
        XCTAssertEqual(ChargeLinkVDODecoder.vdo(from: Data([0xEF, 0x17, 0x60, 0x18])), 0x1860_17EF)
        XCTAssertNil(ChargeLinkVDODecoder.vdo(from: Data([0x01, 0x02])), "不足 4 字节不能硬解")
    }

    func testDecodesRealLenovoCable() throws {
        let cable = try XCTUnwrap(ChargeLinkVDODecoder.cableInfo(
            vendorID: 0x17EF,
            productID: 41493,
            vdos: lenovoCableVDOs
        ))
        XCTAssertFalse(cable.isActiveCable, "ID Header bits 29..27 = 3,被动线")
        XCTAssertEqual(cable.maxAmps, 5.0)
        XCTAssertEqual(cable.maxWatts, 240, "50V 是绝缘等级,按 PD 上限 48V 钳制:48×5=240,不是 250")
        XCTAssertEqual(cable.speedTier, 2, "10 Gbps")
        XCTAssertTrue(cable.eprCapable)
        XCTAssertFalse(cable.hasCertificationID, "XID 为 0:没送测,不是次品标记")
    }

    func testBasicCableDecodesTo60W() throws {
        // 手工构造:被动线 ID Header + Cable VDO(3A、20V、USB 2.0)。
        // bits 6..5 = 01(3A),bits 10..9 = 00(20V),bits 2..0 = 0(USB 2.0)。
        let header: UInt32 = 3 << 27
        let cableVDO: UInt32 = 0b01 << 5
        let cable = try XCTUnwrap(ChargeLinkVDODecoder.cableInfo(
            vendorID: 1, productID: 1,
            vdos: [header, 0, 0, cableVDO]
        ))
        XCTAssertEqual(cable.maxWatts, 60, "20V × 3A")
        XCTAssertEqual(cable.speedTier, 0)
        XCTAssertFalse(cable.eprCapable)
    }

    func testNonCableIdentityReturnsNil() {
        // ID Header 报的是 USB Hub(product type 1),不是线缆,不能硬解成线。
        let header: UInt32 = 1 << 27
        XCTAssertNil(ChargeLinkVDODecoder.cableInfo(vendorID: 1, productID: 1, vdos: [header, 0, 0, 0]))
        XCTAssertNil(ChargeLinkVDODecoder.cableInfo(vendorID: 1, productID: 1, vdos: []), "空 VDO 不解")
        XCTAssertNil(
            ChargeLinkVDODecoder.cableInfo(vendorID: 1, productID: 1, vdos: [3 << 27, 0]),
            "不足 4 个 VDO 拿不到 Cable VDO"
        )
    }

    // MARK: - 瓶颈判定

    private func snapshot(
        portDesc: String = "USB-C",
        chargerOptions: [PDPowerOption],
        negotiated: PDPowerOption?,
        cable: CableEmarkerInfo? = nil
    ) -> ChargeLinkSnapshot {
        ChargeLinkSnapshot(
            portTypeDescription: portDesc,
            portNumber: 2,
            chargerOptions: chargerOptions,
            negotiated: negotiated,
            cable: cable
        )
    }

    /// 真机 96W 充电器的四档广告。
    private let realChargerOptions = [
        PDPowerOption(voltageMV: 20000, maxCurrentMA: 4800, maxPowerMW: 96000),
        PDPowerOption(voltageMV: 15000, maxCurrentMA: 3000, maxPowerMW: 45000),
        PDPowerOption(voltageMV: 9000, maxCurrentMA: 3000, maxPowerMW: 27000),
        PDPowerOption(voltageMV: 5000, maxCurrentMA: 3000, maxPowerMW: 15000)
    ]
    private let contract96W = PDPowerOption(voltageMV: 20000, maxCurrentMA: 4800, maxPowerMW: 96000)

    private func lowRatedCable(watts: Int) -> CableEmarkerInfo {
        CableEmarkerInfo(
            vendorID: 1, productID: 1, isActiveCable: false,
            speedTier: 0, maxAmps: 3, maxWatts: watts,
            eprCapable: false, hasCertificationID: false
        )
    }

    func testCableBelowChargerIsTheOnlyWarning() throws {
        let diagnosis = try XCTUnwrap(ChargeLinkDiagnosis.diagnose(
            snapshot: snapshot(
                chargerOptions: realChargerOptions,
                negotiated: PDPowerOption(voltageMV: 20000, maxCurrentMA: 3000, maxPowerMW: 60000),
                cable: lowRatedCable(watts: 60)
            ),
            batteryFullyCharged: false,
            batteryIsCharging: true
        ))
        XCTAssertEqual(diagnosis.kind, .cableLimit)
        XCTAssertTrue(diagnosis.isWarning)
    }

    func testFullSpeedNegotiationIsFine() throws {
        let diagnosis = try XCTUnwrap(ChargeLinkDiagnosis.diagnose(
            snapshot: snapshot(chargerOptions: realChargerOptions, negotiated: contract96W),
            batteryFullyCharged: false,
            batteryIsCharging: true
        ))
        XCTAssertEqual(diagnosis.kind, .fine)
        XCTAssertFalse(diagnosis.isWarning)
    }

    func testMarginToleratesSmallGap() throws {
        // 协商 92W vs 上限 96W:差距在 max(5, 9.6)W 容差内,不算 Mac 自限。
        let diagnosis = try XCTUnwrap(ChargeLinkDiagnosis.diagnose(
            snapshot: snapshot(
                chargerOptions: realChargerOptions,
                negotiated: PDPowerOption(voltageMV: 20000, maxCurrentMA: 4600, maxPowerMW: 92000)
            ),
            batteryFullyCharged: false,
            batteryIsCharging: true
        ))
        XCTAssertEqual(diagnosis.kind, .fine)
    }

    func testBatteryFullWinsOverMacLimit() throws {
        let diagnosis = try XCTUnwrap(ChargeLinkDiagnosis.diagnose(
            snapshot: snapshot(
                chargerOptions: realChargerOptions,
                negotiated: PDPowerOption(voltageMV: 5000, maxCurrentMA: 400, maxPowerMW: 2000)
            ),
            batteryFullyCharged: true,
            batteryIsCharging: false
        ))
        XCTAssertEqual(diagnosis.kind, .batteryFull)
    }

    func testPausedChargingReadsAsOnHold() throws {
        let diagnosis = try XCTUnwrap(ChargeLinkDiagnosis.diagnose(
            snapshot: snapshot(
                chargerOptions: realChargerOptions,
                negotiated: PDPowerOption(voltageMV: 20000, maxCurrentMA: 1000, maxPowerMW: 20000)
            ),
            batteryFullyCharged: false,
            batteryIsCharging: false
        ))
        XCTAssertEqual(diagnosis.kind, .onHold)
    }

    func testMacAskingLessIsInformationalNotWarning() throws {
        let diagnosis = try XCTUnwrap(ChargeLinkDiagnosis.diagnose(
            snapshot: snapshot(
                chargerOptions: realChargerOptions,
                negotiated: PDPowerOption(voltageMV: 15000, maxCurrentMA: 3000, maxPowerMW: 45000)
            ),
            batteryFullyCharged: false,
            batteryIsCharging: true
        ))
        XCTAssertEqual(diagnosis.kind, .macLimit)
        XCTAssertFalse(diagnosis.isWarning)
    }

    func testChipLessCableStuckAt3AIsSuspected() throws {
        // USB-C、无 e-marker、协商压在 20V/3A、充电器明明有 96W 档 → 疑似线缆。
        let diagnosis = try XCTUnwrap(ChargeLinkDiagnosis.diagnose(
            snapshot: snapshot(
                chargerOptions: realChargerOptions,
                negotiated: PDPowerOption(voltageMV: 20000, maxCurrentMA: 3000, maxPowerMW: 60000),
                cable: nil
            ),
            batteryFullyCharged: false,
            batteryIsCharging: true
        ))
        XCTAssertEqual(diagnosis.kind, .cableLimitSuspected)
        XCTAssertTrue(diagnosis.isWarning)
    }

    func testMagSafeNeverSuspectsCable() throws {
        // MagSafe 线不走 SOP' 应答,cable 为 nil 是常态,不能据此怀疑线。
        // 同样的瓦数关系在 MagSafe 上应归为 Mac 自限,而非疑似线缆。
        let diagnosis = try XCTUnwrap(ChargeLinkDiagnosis.diagnose(
            snapshot: snapshot(
                portDesc: "MagSafe 3",
                chargerOptions: realChargerOptions,
                negotiated: PDPowerOption(voltageMV: 20000, maxCurrentMA: 3000, maxPowerMW: 60000),
                cable: nil
            ),
            batteryFullyCharged: false,
            batteryIsCharging: true
        ))
        XCTAssertEqual(diagnosis.kind, .macLimit)
        XCTAssertFalse(diagnosis.isWarning)
    }

    func testSuspicionNeedsCurrentPinnedAtTopVoltage() throws {
        // 无芯片线的怀疑必须四证齐全。协商在最高档 20V 但电流 4.8A(没被钉在
        // 3A)→ 不怀疑;协商钉在 3A 但电压是降档的 9V(主动涓流)→ 也不怀疑。
        let fullCurrent = try XCTUnwrap(ChargeLinkDiagnosis.diagnose(
            snapshot: snapshot(chargerOptions: realChargerOptions, negotiated: contract96W, cable: nil),
            batteryFullyCharged: false,
            batteryIsCharging: true
        ))
        XCTAssertEqual(fullCurrent.kind, .fine, "满电流合同不该被怀疑")

        let lowTier = try XCTUnwrap(ChargeLinkDiagnosis.diagnose(
            snapshot: snapshot(
                chargerOptions: realChargerOptions,
                negotiated: PDPowerOption(voltageMV: 9000, maxCurrentMA: 3000, maxPowerMW: 27000),
                cable: nil
            ),
            batteryFullyCharged: false,
            batteryIsCharging: true
        ))
        XCTAssertEqual(lowTier.kind, .macLimit, "低电压档涓流是 Mac 自己选的,与线无关")
    }

    func testNoContractYetShowsChargerCeiling() throws {
        let diagnosis = try XCTUnwrap(ChargeLinkDiagnosis.diagnose(
            snapshot: snapshot(chargerOptions: realChargerOptions, negotiated: nil),
            batteryFullyCharged: false,
            batteryIsCharging: true
        ))
        XCTAssertEqual(diagnosis.kind, .chargerCeiling)
    }

    func testNoChargerDataMeansNoDiagnosis() {
        XCTAssertNil(ChargeLinkDiagnosis.diagnose(
            snapshot: snapshot(chargerOptions: [], negotiated: nil),
            batteryFullyCharged: false,
            batteryIsCharging: true
        ), "没有任何充电器数据就别下结论")
    }
}
