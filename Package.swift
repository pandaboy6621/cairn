// swift-tools-version:5.9
import PackageDescription

// The SwiftUI app is macOS-only; Linux builds CairnCore and the `cairn` CLI.
#if os(macOS)
let appProducts: [Product] = [.executable(name: "CairnApp", targets: ["CairnApp"])]
let appTargets: [Target] = [.executableTarget(name: "CairnApp", dependencies: ["CairnCore"])]
#else
let appProducts: [Product] = []
let appTargets: [Target] = []
#endif

let package = Package(
    name: "Cairn",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CairnCore", targets: ["CairnCore"]),
        .executable(name: "cairn", targets: ["cairn"]),
    ] + appProducts,
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        // Linux only: CryptoKit's API for Linux (macOS uses CryptoKit itself).
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
    ],
    targets: [
        .target(
            name: "CairnCore",
            dependencies: [
                "Yams",
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
                .product(name: "CryptoExtras", package: "swift-crypto", condition: .when(platforms: [.linux])),
            ]
        ),
        .executableTarget(
            name: "cairn",
            dependencies: [
                "CairnCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
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
    ] + appTargets
)
