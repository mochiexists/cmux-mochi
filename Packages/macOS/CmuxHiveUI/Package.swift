// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxHiveUI",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CmuxHiveUI", targets: ["CmuxHiveUI"]),
    ],
    dependencies: [
        .package(path: "../CmuxHive"),
        .package(path: "../../iOS/CmuxMobilePairedMac"),
        .package(path: "../../iOS/CmuxMobileShellModel"),
    ],
    targets: [
        .target(
            name: "CmuxHiveUI",
            dependencies: ["CmuxHive", "CmuxMobilePairedMac", "CmuxMobileShellModel"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxHiveUITests",
            dependencies: ["CmuxHiveUI", "CmuxMobileShellModel"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
