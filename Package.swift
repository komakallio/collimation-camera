// swift-tools-version: 6.0

import PackageDescription
import Foundation

// SDL3 is located differently per platform: Homebrew's pkg-config on macOS, an
// unpacked SDL3-devel-VC zip on Windows. `#if os()` in a manifest is evaluated
// on the build host, which equals the target for the native builds this
// package does. SwiftPM has no per-platform target exclusion, so the
// macOS-only app target is added the same way.
let sdlInclude = "\(Context.packageDirectory)/Vendor/SDL3/include"
let sdlLib = "\(Context.packageDirectory)/Vendor/SDL3/lib/x64"

#if os(Windows)
let csdl3: Target = .systemLibrary(name: "CSDL3", path: "Sources/CSDL3")
let sdlCSettings: [CSetting] = [.unsafeFlags(["-I", sdlInclude])]
let sdlCxxSettings: [CXXSetting] = [.unsafeFlags(["-I", sdlInclude])]
let sdlSwiftSettings: [SwiftSetting] = [.unsafeFlags(["-Xcc", "-I", "-Xcc", sdlInclude])]
let sdlLinkerSettings: [LinkerSetting] = [.unsafeFlags(["-L", sdlLib])]

// A release build is a GUI app: no console window behind it, and the entry
// point moves because the subsystem changed. Debug builds keep the console,
// which is where `swift run` prints.
//
// The .res carries the application icon Explorer and Start read out of the PE
// image. scripts\fetch-sdk.ps1 compiles it and .gitignore keeps it out of the
// repository, so it may be absent; without it the build still links, just with
// the default executable icon.
var portableLinkerSettings: [LinkerSetting] = [
    .unsafeFlags(["-Xlinker", "/SUBSYSTEM:WINDOWS", "-Xlinker", "/ENTRY:mainCRTStartup"], .when(configuration: .release))
]
let iconResource = "\(Context.packageDirectory)/Resources/CollimationCamera.res"
if FileManager.default.fileExists(atPath: iconResource) {
    portableLinkerSettings.append(
        .unsafeFlags(["-Xlinker", iconResource], .when(configuration: .release))
    )
}
#else
let csdl3: Target = .systemLibrary(
    name: "CSDL3",
    path: "Sources/CSDL3",
    pkgConfig: "sdl3",
    providers: [.brew(["sdl3"])]
)
let sdlCSettings: [CSetting] = []
let sdlCxxSettings: [CXXSetting] = []
let sdlSwiftSettings: [SwiftSetting] = []
let sdlLinkerSettings: [LinkerSetting] = []
let portableLinkerSettings: [LinkerSetting] = []
#endif

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
    csdl3,
    // Never define CIMGUI_DEFINE_ENUMS_AND_STRUCTS or CIMGUI_USE_SDL3 here:
    // these C++ files include imgui.h before cimgui.h, and with those macros
    // set cimgui.h redeclares ImVec2, ImGuiIO and every flag enum as C types in
    // the same translation unit. They live in include/CImGui.h instead, which
    // is the header Swift imports (§9.3).
    .target(
        name: "CImGui",
        dependencies: ["CSDL3"],
        path: "Sources/CImGui",
        publicHeadersPath: "include",
        cSettings: sdlCSettings,
        cxxSettings: sdlCxxSettings + [
            .headerSearchPath("vendor"),
            .headerSearchPath("vendor/imgui"),
            .headerSearchPath("vendor/imgui/backends"),
            .define("IMGUI_DISABLE_OBSOLETE_FUNCTIONS"),
            .define("IMGUI_IMPL_API", to: "extern \"C\""),
            .define("CIMGUI_NO_EXPORT"),
        ]
    ),
    .executableTarget(
        name: "CaptureCLI",
        dependencies: ["CollimationCore"]
    ),
    .executableTarget(
        name: "CoreTests",
        // ASICameraC so `asi error mapping` can name the ZWO error constants.
        dependencies: ["CollimationCore", "CollimationUI", "ASICameraC"]
    ),
    // Milestone 0 spike. Answers the rendering and timing questions that gate
    // the portable app; nothing here ships.
    .executableTarget(
        name: "SDLSpike",
        dependencies: ["CollimationCore", "CImGui", "CSDL3"],
        swiftSettings: sdlSwiftSettings,
        linkerSettings: sdlLinkerSettings + [.linkedLibrary("SDL3")]
    ),
    // The portable app: the Windows release build, and a parity build on macOS.
    .executableTarget(
        name: "CollimationPortableApp",
        dependencies: ["CollimationCore", "CollimationUI", "CImGui", "CSDL3"],
        swiftSettings: sdlSwiftSettings,
        linkerSettings: sdlLinkerSettings + portableLinkerSettings + [.linkedLibrary("SDL3")]
    ),
]

var products: [Product] = [
    .library(name: "CollimationCore", targets: ["CollimationCore"]),
    .library(name: "CollimationUI", targets: ["CollimationUI"]),
    .executable(name: "capture-cli", targets: ["CaptureCLI"]),
    .executable(name: "core-tests", targets: ["CoreTests"]),
    .executable(name: "sdl-spike", targets: ["SDLSpike"]),
    .executable(name: "CollimationCamera", targets: ["CollimationPortableApp"]),
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
    targets: targets,
    cxxLanguageStandard: .cxx17
)
