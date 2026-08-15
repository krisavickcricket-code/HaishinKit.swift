// swift-tools-version:6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.
import PackageDescription

// Force Swift 5 language mode to avoid Swift 6 strict concurrency errors
// in RTMPConnection.swift and other files. The app uses SWIFT_STRICT_CONCURRENCY=minimal.
let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny")
]

let package = Package(
    name: "HaishinKit",
    platforms: [
        .iOS(.v13),
        .tvOS(.v13),
        .visionOS(.v1),
        .macOS(.v10_15),
        .macCatalyst(.v14)
    ],
    products: [
        .library(name: "HaishinKit", targets: ["HaishinKit"]),
        .library(name: "RTMPHaishinKit", targets: ["RTMPHaishinKit"]),
        .library(name: "SRTHaishinKit", targets: ["SRTHaishinKit"]),
        .library(name: "MoQTHaishinKit", targets: ["MoQTHaishinKit"]),
        .library(name: "RTCHaishinKit", targets: ["RTCHaishinKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.3"),
        .package(url: "https://github.com/shogo4405/Logboard.git", "2.5.0"..<"2.6.0")
    ],
    targets: [
        .binaryTarget(
            name: "libsrt",
            url: "https://github.com/HaishinKit/libsrt-xcframework/releases/download/v1.5.4/libsrt.xcframework.zip",
            checksum: "76879e2802e45ce043f52871a0a6764d57f833bdb729f2ba6663f4e31d658c4a"
        ),
        .binaryTarget(
            name: "libdatachannel",
            url: "https://github.com/HaishinKit/libdatachannel-xcframework/releases/download/v0.23.2/libdatachannel.xcframework.zip",
            checksum: "45ed389bfbc06034f8d4daaeddd412250089b0e89d25016008a391afe6bc0809"
        ),
        .target(
            name: "HaishinKit",
            dependencies: ["Logboard"],
            path: "HaishinKit/Sources",
            swiftSettings: swiftSettings,
            swiftLanguageMode: .v5
        ),
        .target(
            name: "RTMPHaishinKit",
            dependencies: ["HaishinKit"],
            path: "RTMPHaishinKit/Sources",
            swiftSettings: swiftSettings,
            swiftLanguageMode: .v5
        ),
        .target(
            name: "SRTHaishinKit",
            dependencies: ["libsrt", "HaishinKit"],
            path: "SRTHaishinKit/Sources",
            swiftSettings: swiftSettings,
            swiftLanguageMode: .v5
        ),
        .target(
            name: "MoQTHaishinKit",
            dependencies: ["HaishinKit"],
            path: "MoQTHaishinKit/Sources",
            swiftSettings: swiftSettings,
            swiftLanguageMode: .v5
        ),
        .target(
            name: "RTCHaishinKit",
            dependencies: ["libdatachannel", "HaishinKit"],
            path: "RTCHaishinKit/Sources",
            swiftSettings: swiftSettings,
            swiftLanguageMode: .v5
        ),
        .testTarget(
            name: "HaishinKitTests",
            dependencies: ["HaishinKit"],
            path: "HaishinKit/Tests",
            resources: [
                .process("Asset")
            ],
            swiftSettings: swiftSettings,
            swiftLanguageMode: .v5
        ),
        .testTarget(
            name: "RTMPHaishinKitTests",
            dependencies: ["RTMPHaishinKit"],
            path: "RTMPHaishinKit/Tests",
            swiftSettings: swiftSettings,
            swiftLanguageMode: .v5
        ),
        .testTarget(
            name: "SRTHaishinKitTests",
            dependencies: ["SRTHaishinKit"],
            path: "SRTHaishinKit/Tests",
            swiftSettings: swiftSettings,
            swiftLanguageMode: .v5
        ),
        .testTarget(
            name: "RTCHaishinKitTests",
            dependencies: ["RTCHaishinKit"],
            path: "RTCHaishinKit/Tests",
            swiftSettings: swiftSettings,
            swiftLanguageMode: .v5
        )
    ]
)
