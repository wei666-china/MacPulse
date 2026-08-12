// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MacPulse",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MacPulseCore", targets: ["MacPulseCore"]),
        .library(name: "MacPulseSensors", targets: ["MacPulseSensors"]),
        .executable(name: "MacPulse", targets: ["MacPulse"]),
        .executable(name: "MacPulseCollector", targets: ["MacPulseCollector"])
    ],
    targets: [
        .target(
            name: "MacPulseCore",
            linkerSettings: [
                .linkedFramework("IOKit")
            ]
        ),
        // 原生传感器读取:SMC、IOReport、pmgr 频率表、网络/磁盘速率。
        // 单独立库是为了采集器和 App 都能用(第二期传感器面板复用)。
        // 全部走公开可调用的系统接口,无需 root、无需 entitlement。
        .target(
            name: "MacPulseSensors",
            dependencies: ["MacPulseCore"],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreWLAN")
            ]
        ),
        .executableTarget(
            name: "MacPulse",
            dependencies: ["MacPulseCore", "MacPulseSensors"],
            linkerSettings: [
                .linkedFramework("Charts"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("SwiftData"),
                .linkedFramework("UserNotifications")
            ]
        ),
        .executableTarget(
            name: "MacPulseCollector",
            dependencies: ["MacPulseCore", "MacPulseSensors"]
        ),
        .testTarget(
            name: "MacPulseCoreTests",
            dependencies: ["MacPulseCore"],
            // 回测用的真实历史样本（仅时间戳与数值列，无标识信息）。
            resources: [.process("Fixtures")]
        ),
        .testTarget(
            name: "MacPulseAppTests",
            dependencies: ["MacPulse", "MacPulseCore", "MacPulseSensors"]
        )
    ]
)
