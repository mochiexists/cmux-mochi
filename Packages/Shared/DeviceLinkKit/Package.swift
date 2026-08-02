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
    dependencies: [
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "DeviceLinkKit",
            dependencies: [
                .product(name: "X509", package: "swift-certificates"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DeviceLinkKitTests",
            dependencies: ["DeviceLinkKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
