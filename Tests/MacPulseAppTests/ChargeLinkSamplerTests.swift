import XCTest
@testable import MacPulse
@testable import MacPulseCore

/// 充电链路采样器:解析纯函数用假数据拍,真机部分对 `ioreg` 文本对账
/// (不许自己对自己:采样器走 IOKit API,真值走 shell 出去的 ioreg 文本)。
final class ChargeLinkSamplerTests: XCTestCase {
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
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - 解析纯函数

    func testParseOptionsAcceptsSetAndSortsByPower() {
        // PowerSourceOptions 的 CF 真身是 Set(ioreg 显示成数组是假象),两种都要接。
        let a: [String: Any] = ["Voltage (mV)": 5000, "Max Current (mA)": 3000, "Max Power (mW)": 15000]
        let b: [String: Any] = ["Voltage (mV)": 20000, "Max Current (mA)": 4800, "Max Power (mW)": 96000]
        let fromSet = ChargeLinkSampler.parseOptions(NSSet(array: [a, b]))
        XCTAssertEqual(fromSet.map(\.maxPowerMW), [96000, 15000], "按功率从高到低")
        let fromArray = ChargeLinkSampler.parseOptions(NSArray(array: [a, b]))
        XCTAssertEqual(fromArray.map(\.maxPowerMW), [96000, 15000])
    }

    func testParseOptionComputesMissingPower() {
        let option = ChargeLinkSampler.parseOption(
            ["Voltage (mV)": 9000, "Max Current (mA)": 3000] as [String: Any]
        )
        XCTAssertEqual(option?.maxPowerMW, 27000, "缺 Max Power 时用 V×I 补")
        XCTAssertNil(
            ChargeLinkSampler.parseOption(["Voltage (mV)": 0] as [String: Any]),
            "电压为 0 的档位是占位,不收"
        )
    }

    func testPreferredSourceFavorsContractHolderOverNamePriority() {
        let contract = PDPowerOption(voltageMV: 5000, maxCurrentMA: 3000, maxPowerMW: 15000)
        let brickIdle = ChargeLinkSampler.RawPowerSource(
            name: "Brick ID", portType: 2, portNumber: 1,
            portTypeDescription: "USB-C", options: [], winning: nil
        )
        let typeCCharging = ChargeLinkSampler.RawPowerSource(
            name: "TypeC", portType: 2, portNumber: 1,
            portTypeDescription: "USB-C", options: [contract], winning: contract
        )
        // 名次高但没合同的 Brick ID 不能把真在供电的 TypeC 顶掉。
        XCTAssertEqual(
            ChargeLinkSampler.preferredSource(in: [brickIdle, typeCCharging])?.name,
            "TypeC"
        )
        // 都没合同时才按名次。
        XCTAssertEqual(
            ChargeLinkSampler.preferredSource(in: [brickIdle])?.name,
            "Brick ID"
        )
        XCTAssertNil(ChargeLinkSampler.preferredSource(in: []))
    }

    func testParseSourceReadsParentPortKeys() {
        let props: [String: Any] = [
            "PowerSourceName": "USB-PD",
            "ParentBuiltInPortType": 2,
            "ParentBuiltInPortNumber": 2,
            "ParentBuiltInPortTypeDescription": "USB-C",
            "WinningPowerSourceOption": [
                "Voltage (mV)": 20000, "Max Current (mA)": 4800, "Max Power (mW)": 96000
            ] as [String: Any]
        ]
        let source = ChargeLinkSampler.parseSource(read: { props[$0] })
        XCTAssertEqual(source?.portType, 2)
        XCTAssertEqual(source?.portNumber, 2)
        XCTAssertEqual(source?.winning?.maxPowerMW, 96000)
    }

    // MARK: - 真机对账

    /// 采样器读出的协商合同,必须能在 ioreg 的 WinningPowerSourceOption
    /// 文本里找到同样的毫瓦数。没插电就跳过。
    func testNegotiatedContractAgreesWithIoreg() async throws {
        let sampler = ChargeLinkSampler()
        guard let link = await sampler.sample() else {
            throw XCTSkip("本机当前没有活跃的充电链路(没插电或口状态门闸未过)")
        }
        guard let negotiated = link.negotiated else {
            throw XCTSkip("协商还没完成,没有合同可对账")
        }

        let text = shell("ioreg -c IOPortFeaturePowerSource -r -d 1")
        let winningLines = text.split(separator: "\n").filter { $0.contains("WinningPowerSourceOption") }
        guard !winningLines.isEmpty else {
            throw XCTSkip("ioreg 里没有 WinningPowerSourceOption,无从对账")
        }
        let groundTruthMW: Set<Int> = Set(winningLines.compactMap { line in
            guard let range = line.range(of: #""Max Power \(mW\)"=([0-9]+)"#, options: .regularExpression) else {
                return nil
            }
            return Int(line[range].filter(\.isNumber))
        })
        XCTAssertTrue(
            groundTruthMW.contains(negotiated.maxPowerMW),
            "采样器读到 \(negotiated.maxPowerMW) mW,但 ioreg 的合同集合是 \(groundTruthMW)"
        )
    }

    /// 线缆芯片的厂商号对 ioreg 的 SOP' 文本。没有 e-marker 线就跳过。
    func testCableVendorAgreesWithIoreg() async throws {
        let sampler = ChargeLinkSampler()
        guard let cable = await sampler.sample()?.cable else {
            throw XCTSkip("当前链路上没有 e-marker 线缆应答")
        }
        let text = shell("ioreg -c IOPortTransportComponentCCUSBPDSOPp -r -d 1")
        // 顶层键 `"Vendor ID" = 6127`(十进制)。Metadata 里还有一份,格式不同,不取。
        let vendors: Set<Int> = Set(
            text.split(separator: "\n").compactMap { line -> Int? in
                guard line.contains("\"Vendor ID\" = ") else { return nil }
                return Int(line.split(separator: "=").last?.trimmingCharacters(in: .whitespaces) ?? "")
            }
        )
        guard !vendors.isEmpty else {
            throw XCTSkip("ioreg 里没有 SOP' 节点,无从对账")
        }
        XCTAssertTrue(
            vendors.contains(cable.vendorID),
            "采样器读到厂商 \(cable.vendorID),但 ioreg 给的是 \(vendors)"
        )
    }
}
