import XCTest
@testable import MacPulse

/// 外设电量:解析用还原真机结构的样本(字段名与真机 system_profiler 输出
/// 一致,地址虚构),真机部分对 ioreg 文本对账。
final class PeripheralBatteryTests: XCTestCase {

    // MARK: - 纯解析

    /// 结构还原自本机 macOS 26 的 `system_profiler SPBluetoothDataType -json`:
    /// device_connected 是「设备名 → 属性」的字典数组,电量是 "73" 或 "73%" 字符串。
    private let profileFixture = """
    {
      "SPBluetoothDataType": [
        {
          "controller_properties": { "controller_state": "attrib_on" },
          "device_connected": [
            {
              "AirPods": {
                "device_address": "AA:BB:CC:DD:EE:01",
                "device_batteryLevelLeft": "73%",
                "device_batteryLevelRight": "71%",
                "device_batteryLevelCase": "80%",
                "device_minorType": "Headphones"
              }
            },
            {
              "Magic Trackpad": {
                "device_address": "AA-BB-CC-DD-EE-02",
                "device_batteryLevelMain": "65"
              }
            },
            {
              "iPhone": {
                "device_address": "AA:BB:CC:DD:EE:03",
                "device_minorType": "Phone"
              }
            }
          ],
          "device_not_connected": []
        }
      ]
    }
    """

    func testParsesRealProfileStructure() throws {
        let devices = PeripheralBatteryReader.parseBluetoothProfile(Data(profileFixture.utf8))
        XCTAssertEqual(devices.count, 2, "iPhone 没有电量分量,不该进列表")

        let airpods = try XCTUnwrap(devices.first { $0.name == "AirPods" })
        XCTAssertEqual(airpods.percentLeft, 73)
        XCTAssertEqual(airpods.percentRight, 71)
        XCTAssertEqual(airpods.percentCase, 80)
        XCTAssertNil(airpods.percentMain)
        XCTAssertEqual(airpods.worstPercent, 71, "按最缺电的组件提醒")

        let trackpad = try XCTUnwrap(devices.first { $0.name == "Magic Trackpad" })
        XCTAssertEqual(trackpad.percentMain, 65)
        XCTAssertEqual(trackpad.id, "aa:bb:cc:dd:ee:02", "横杠地址规范化成冒号小写")
    }

    func testPercentParsingIsStrict() {
        XCTAssertEqual(PeripheralBatteryReader.percentValue("73%"), 73)
        XCTAssertEqual(PeripheralBatteryReader.percentValue("100"), 100)
        XCTAssertEqual(PeripheralBatteryReader.percentValue(NSNumber(value: 5)), 5)
        XCTAssertNil(PeripheralBatteryReader.percentValue("charging"), "解不出数字绝不当 0")
        XCTAssertNil(PeripheralBatteryReader.percentValue("120%"), "超界值不可信")
        XCTAssertNil(PeripheralBatteryReader.percentValue(nil))
    }

    func testGarbageJSONYieldsEmpty() {
        XCTAssertEqual(PeripheralBatteryReader.parseBluetoothProfile(Data("not json".utf8)), [])
        XCTAssertEqual(PeripheralBatteryReader.parseBluetoothProfile(Data("{}".utf8)), [])
    }

    // MARK: - 真机对账

    /// HID 快路读到的每台设备,ioreg 文本里必须有对应的 BatteryPercent 值。
    func testHIDBatteriesAgreeWithIoreg() throws {
        let devices = PeripheralBatteryReader.readHIDBatteries()
        guard !devices.isEmpty else {
            throw XCTSkip("当前没有走 HID 上报电量的蓝牙外设")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "ioreg -c AppleDeviceManagementHIDEventService -r -d 1 | grep BatteryPercent"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()

        let ioregPercents = Set(text.split(separator: "\n").compactMap { line -> Int? in
            Int(line.split(separator: "=").last?.trimmingCharacters(in: .whitespaces) ?? "")
        })
        for device in devices {
            let percent = try XCTUnwrap(device.percentMain)
            XCTAssertTrue(
                ioregPercents.contains(percent),
                "\(device.name) 的 \(percent)% 在 ioreg 里找不到,读数集合 \(ioregPercents)"
            )
        }
    }
}
