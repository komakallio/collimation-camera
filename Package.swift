// swift-tools-version: 6.0

import PackageDescription

// `#if os()` in a manifest is evaluated on the build host, which equals the
// target for the native builds this package does. SwiftPM has no per-platform
// target exclusion, so the macOS-only app target is added this way.
var targets: [Target] = [
    .target(
        name: "POACameraC",
        publicHeadersPath: "include"
    ),
    .target(
        name: "ASICameraC",
        publicHeadersPath: "include"
    ),
    .target(
        name: "CollimationKernels",
        publicHeadersPath: "include",
        cSettings: [
            .unsafeFlags(["-O3"], .when(configuration: .debug))
        ]
    ),
    .target(
        name: "CollimationCore",
        dependencies: ["POACameraC", "ASICameraC", "CollimationKernels"]
    ),
    // Platform-free UI model: commands, formatters, HUD scenes. Both apps
    // depend on it, and neither it nor CollimationCore imports a UI framework.
    .target(
        name: "CollimationUI",
        dependencies: ["CollimationCore"]
    ),
    .executableTarget(
        name: "CaptureCLI",
        dependencies: ["CollimationCore"]
    ),
    .executableTarget(
        name: "CoreTests",
        dependencies: ["CollimationCore", "CollimationUI"]
    ),
]

var products: [Product] = [
    .library(name: "CollimationCore", targets: ["CollimationCore"]),
    .library(name: "CollimationUI", targets: ["CollimationUI"]),
    .executable(name: "capture-cli", targets: ["CaptureCLI"]),
    .executable(name: "core-tests", targets: ["CoreTests"]),
]

#if os(macOS)
targets.append(
    .executableTarget(
        name: "CollimationApp",
        dependencies: ["CollimationCore", "CollimationUI"],
        linkerSettings: [
            .linkedFramework("SwiftUI"),
            .linkedFramework("AppKit"),
            .linkedFramework("Metal"),
            .linkedFramework("MetalKit"),
            .linkedFramework("QuartzCore")
        ]
    )
)
products.append(.executable(name: "CollimationApp", targets: ["CollimationApp"]))
#endif

let package = Package(
    name: "collimation-camera",
    // Observation raises the minimum from macOS 13 to 14.
    platforms: [
        .macOS(.v14)
    ],
    products: products,
    targets: targets
)
