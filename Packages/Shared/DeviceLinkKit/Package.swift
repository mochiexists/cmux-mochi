// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DeviceLinkKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "DeviceLinkKit",
            targets: ["DeviceLinkKit"]
        ),
    ],
    targets: [
        .target(
            name: "DeviceLinkKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DeviceLinkKitTests",
            dependencies: ["DeviceLinkKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
