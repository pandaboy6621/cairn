// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Cairn",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CairnCore", targets: ["CairnCore"]),
        .executable(name: "cairn", targets: ["cairn"]),
        .executable(name: "CairnApp", targets: ["CairnApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "CairnCore",
            dependencies: ["Yams"]
        ),
        .executableTarget(
            name: "cairn",
            dependencies: [
                "CairnCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "CairnApp",
            dependencies: ["CairnCore"]
        ),
        .testTarget(
            name: "CairnCoreTests",
            dependencies: ["CairnCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: [
                // With only the Command Line Tools selected, SwiftPM doesn't find the
                // Swift Testing macro plugin on its own. Harmless when Xcode is selected.
                .unsafeFlags([
                    "-plugin-path",
                    "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing",
                ]),
            ]
        ),
    ]
)
