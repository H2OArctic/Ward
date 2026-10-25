// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Ward",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "WardCore", path: "Sources/WardCore"),
        .executableTarget(name: "Ward", dependencies: ["WardCore"], path: "Sources/Ward"),
        .executableTarget(name: "WardBrowserHost", dependencies: ["WardCore"], path: "Sources/WardBrowserHost"),
        .executableTarget(name: "WardCLI", dependencies: ["WardCore"], path: "Sources/WardCLI"),
        .testTarget(name: "WardCoreTests", dependencies: ["WardCore"], path: "Tests/WardCoreTests",
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "WardAppTests", dependencies: ["Ward", "WardCore"], path: "Tests/WardAppTests"),
    ],
    swiftLanguageModes: [.v5]
)
