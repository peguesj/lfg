// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "LFG",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "lfg-cli", targets: ["lfg-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "LFGApp",
            dependencies: ["LFGKit"],
            path: "Sources/LFGApp",
            exclude: ["LFGInfo.plist", "LFG.entitlements"]
        ),
        .target(
            name: "LFGKit",
            path: "Sources/LFGKit"
        ),
        .executableTarget(
            name: "lfg-cli",
            dependencies: [
                "LFGKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/lfg-cli"
        ),
        .testTarget(
            name: "LFGKitTests",
            dependencies: ["LFGKit"],
            path: "Tests/LFGKitTests"
        ),
    ]
)
