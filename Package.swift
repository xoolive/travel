// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Travel",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/facebook/zstd", from: "1.5.6")
    ],
    targets: [
        .executableTarget(
            name: "Travel",
            dependencies: [.product(name: "libzstd", package: "zstd")],
            path: "Sources/Travel",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
