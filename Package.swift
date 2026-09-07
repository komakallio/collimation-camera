// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "collimation-camera",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "CollimationCore", targets: ["CollimationCore"]),
        .executable(name: "CollimationApp", targets: ["CollimationApp"]),
        .executable(name: "capture-cli", targets: ["CaptureCLI"]),
        .executable(name: "core-tests", targets: ["CoreTests"])
    ],
    targets: [
        .target(
            name: "POACameraC",
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
            dependencies: ["POACameraC", "CollimationKernels"],
            linkerSettings: [
                .linkedFramework("Accelerate"),
                .linkedLibrary("dl")
            ]
        ),
        .executableTarget(
            name: "CaptureCLI",
            dependencies: ["CollimationCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ImageIO")
            ]
        ),
        .executableTarget(
            name: "CollimationApp",
            dependencies: ["CollimationCore"],
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore")
            ]
        ),
        .executableTarget(
            name: "CoreTests",
            dependencies: ["CollimationCore"]
        )
    ]
)
