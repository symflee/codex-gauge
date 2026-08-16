// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodexGauge",
    defaultLocalization: "ko",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "CodexGaugeAppKit",
            targets: ["CodexGaugeAppKit"]
        ),
        .executable(
            name: "codex-gauge-dev",
            targets: ["CodexGaugeExecutable"]
        ),
        .executable(
            name: "codex-gauge-tests",
            targets: ["CodexGaugeTests"]
        ),
        .executable(
            name: "codex-gauge-smoke",
            targets: ["CodexGaugeSmokeExecutable"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "CodexGaugeCore"
        ),
        .target(
            name: "CodexGaugeProtocol",
            dependencies: ["CodexGaugeCore"]
        ),
        .target(
            name: "CodexGaugeRefresh",
            dependencies: [
                "CodexGaugeCore",
                "CodexGaugeProtocol"
            ]
        ),
        .target(
            name: "CodexGaugeSettings",
            dependencies: [
                "CodexGaugeCore",
                "CodexGaugeProtocol",
                "CodexGaugeRefresh"
            ]
        ),
        .target(
            name: "CodexGaugeAppKit",
            dependencies: [
                "CodexGaugeCore",
                "CodexGaugeProtocol",
                "CodexGaugeRefresh",
                "CodexGaugeSettings"
            ],
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .executableTarget(
            name: "CodexGaugeExecutable",
            dependencies: ["CodexGaugeAppKit"],
            path: "App/CodexGauge",
            exclude: [
                "Assets.xcassets",
                "Info.plist"
            ]
        ),
        .executableTarget(
            name: "CodexGaugeTests",
            dependencies: [
                "CodexGaugeCore",
                "CodexGaugeProtocol",
                "CodexGaugeRefresh",
                "CodexGaugeSettings",
                "CodexGaugeAppKit"
            ],
            path: "Tests/CodexGaugeTests"
        ),
        .executableTarget(
            name: "CodexGaugeSmokeExecutable",
            dependencies: ["CodexGaugeProtocol"]
        ),
        .testTarget(
            name: "CodexGaugeStandardTests",
            dependencies: [
                "CodexGaugeCore",
                "CodexGaugeProtocol",
                "CodexGaugeSettings"
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
