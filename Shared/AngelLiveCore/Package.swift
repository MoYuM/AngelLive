// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "AngelLiveCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v15),
        .tvOS(.v17)
    ],
    products: [
        .library(
            name: "AngelLiveCore",
            targets: ["AngelLiveCore"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/Alamofire/Alamofire.git", from: "5.10.2"),
        .package(url: "https://github.com/daltoniam/Starscream", from: "4.0.6"),
        .package(url: "https://github.com/tsolomko/SWCompression", from: "4.8.6"),
        .package(url: "https://github.com/apple/swift-protobuf", from: "1.28.1"),
        .package(url: "https://github.com/hyperoslo/Cache", from: "7.4.0"),
        .package(name: "SharedAssets", path: "../SharedAssets")
    ],
    targets: [
        .target(
            name: "AngelLiveCore",
            dependencies: [
                "Alamofire",
                "Starscream",
                .product(name: "SWCompression", package: "SWCompression"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "Cache", package: "Cache"),
                .product(name: "SharedAssets", package: "SharedAssets", condition: .when(platforms: [.iOS, .tvOS]))
            ],
            path: "Sources",
            linkerSettings: [
                .linkedFramework("JavaScriptCore")
            ]
        ),
        .testTarget(
            name: "AngelLiveCoreTests",
            dependencies: ["AngelLiveCore"],
            path: "Tests"
        ),
    ]
)
