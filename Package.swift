// swift-tools-version:5.9
import PackageDescription

// The SwiftUI app is macOS-only. On Linux the GNOME app (CairnGnome) takes its
// place, built with adwaita-swift; macOS never fetches or builds it.
#if os(macOS)
let appProducts: [Product] = [.executable(name: "CairnApp", targets: ["CairnApp"])]
let appTargets: [Target] = [.executableTarget(name: "CairnApp", dependencies: ["CairnCore"])]
let appDependencies: [Package.Dependency] = []
#else
let appProducts: [Product] = [.executable(name: "cairn-gnome", targets: ["CairnGnome"])]
let appTargets: [Target] = [.executableTarget(
    name: "CairnGnome",
    dependencies: ["CairnCore", .product(name: "Adwaita", package: "adwaita-swift")]
)]
let appDependencies: [Package.Dependency] = [
    // Pinned to a commit: adwaita-swift's own dependencies follow branches, which a
    // version requirement wouldn't allow.
    .package(url: "https://git.aparoksha.dev/aparoksha/adwaita-swift", revision: "af5598fbd6f2425841f426ad388d7a7edd6c90e6"),
]
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
    ] + appDependencies,
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
