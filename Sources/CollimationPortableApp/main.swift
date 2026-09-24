import CImGui
import CSDL3
import CollimationCore
import CollimationUI
import Foundation

// Top-level code rather than @main: it sidesteps the @main and
// -parse-as-library interaction on every platform, and top-level code is
// main-actor isolated in Swift 6, which is what SDL wants — SDL_Init must run
// on the main thread.

SDL_SetAppMetadata("Collimation Camera", "1.0", "local.collimation-camera")

// Before SDL_Init, so a failure in SDL itself is already being recorded.
Diagnostics.start()
Diagnostics.routeSDLLog()

guard SDL_Init(SDL_INIT_VIDEO) else {
    Diagnostics.fail("SDL_Init")
}
Log.info("SDL \(SDL_GetVersion())")

// `--check` reports what this machine can do and exits, without showing a
// window: the first thing to run on a new machine, and the only way to get an
// answer over a remote desktop session where a message box is in the way.
let selfChecking = SelfCheck.isRequested(CommandLine.arguments)

// `--snapshot <file.png>` renders one frame offscreen and writes it out, so it
// needs no visible window either — which is the point: it works on a machine
// reached over remote desktop, or one whose display has gone to sleep.
let snapshotPath = Snapshot.requestedPath(CommandLine.arguments)

let displayScale = Double(SDL_GetDisplayContentScale(SDL_GetPrimaryDisplay()))
let initialScale = displayScale > 0 ? displayScale : 1
var windowFlags = SDL_WINDOW_RESIZABLE | SDL_WINDOW_HIGH_PIXEL_DENSITY
if selfChecking || snapshotPath != nil { windowFlags |= SDL_WINDOW_HIDDEN }
guard let window = SDL_CreateWindow(
    "Collimation Camera",
    Int32(1280 * initialScale),
    Int32(820 * initialScale),
    windowFlags
) else {
    Diagnostics.fail("SDL_CreateWindow")
}
AppWindow.applyIcon(to: window)

// Below this the HUD panels in the bottom-right corner no longer fit beside
// the 300-point sidebar and start drawing over each other. SwiftUI derives the
// same kind of floor on macOS from the sidebar's minWidth.
SDL_SetWindowMinimumSize(window, Int32(800 * initialScale), Int32(600 * initialScale))

if let size = Snapshot.requestedWindowSize(CommandLine.arguments) {
    SDL_SetWindowSize(
        window,
        Int32(Double(size.width) * initialScale),
        Int32(Double(size.height) * initialScale)
    )
}

// DXBC on Windows, MSL on macOS. The fewer-resource-slots property admits
// tier 1 Intel iGPUs; this renderer binds one storage texture, far under the
// 8-resource limit that property imposes.
guard let deviceProperties = SDL_CreateProperties() as SDL_PropertiesID?,
      deviceProperties != 0 else {
    Diagnostics.fail("SDL_CreateProperties")
}
#if os(Windows)
SDL_SetBooleanProperty(deviceProperties, SDL_PROP_GPU_DEVICE_CREATE_SHADERS_DXBC_BOOLEAN, true)
#else
SDL_SetBooleanProperty(deviceProperties, SDL_PROP_GPU_DEVICE_CREATE_SHADERS_MSL_BOOLEAN, true)
#endif
SDL_SetBooleanProperty(
    deviceProperties,
    SDL_PROP_GPU_DEVICE_CREATE_D3D12_ALLOW_FEWER_RESOURCE_SLOTS_BOOLEAN,
    true
)
#if DEBUG
SDL_SetBooleanProperty(deviceProperties, SDL_PROP_GPU_DEVICE_CREATE_DEBUGMODE_BOOLEAN, true)
#endif

guard let device = SDL_CreateGPUDeviceWithProperties(deviceProperties) else {
    Diagnostics.fail("SDL_CreateGPUDevice")
}
SDL_DestroyProperties(deviceProperties)

if let driver = SDL_GetGPUDeviceDriver(device) {
    Log.info("GPU driver: \(String(cString: driver))")
}
// The live view is an R16_UINT storage-read texture and nothing else. §13
// sketches a fallback chain — R16_UNORM with a sampler, then R32_FLOAT — and
// none of it is written. Without this check the texture simply fails to be
// created, `drawImage` returns early, and the app runs perfectly with a black
// live region and no clue why. Say so instead.
let storageReadSupported = GPULiveRenderer.supportsR16UInt(device: device)
Log.info("R16_UINT storage read supported: \(storageReadSupported)")
if !storageReadSupported {
    Diagnostics.fail(
        "Checking the live-view texture format",
        detail: """
            This GPU cannot sample a 16-bit unsigned integer texture \
            (R16_UINT with GRAPHICS_STORAGE_READ), which is the only format \
            the live view uses. The fallback formats in the plan are not \
            implemented. Try a machine with a newer GPU, or a different \
            driver: SDL reports the driver as \
            \(SDL_GetGPUDeviceDriver(device).map { String(cString: $0) } ?? "unknown").
            """
    )
}

guard SDL_ClaimWindowForGPUDevice(device, window) else {
    Diagnostics.fail("SDL_ClaimWindowForGPUDevice")
}
_ = SDL_SetGPUSwapchainParameters(
    device,
    window,
    SDL_GPU_SWAPCHAINCOMPOSITION_SDR,
    SDL_GPU_PRESENTMODE_VSYNC
)
let swapchainFormat = SDL_GetGPUSwapchainTextureFormat(device, window)

if selfChecking {
    SelfCheck.run(window: window, device: device)
}

guard let imguiContext = igCreateContext(nil) else {
    Diagnostics.fail("igCreateContext", detail: "ImGui context could not be created")
}
guard let io = igGetIO_Nil() else {
    Diagnostics.fail("igGetIO", detail: "ImGui IO unavailable")
}
io.pointee.IniFilename = nil   // no imgui.ini beside the executable

// Fonts before the backend init: the first face loaded becomes the default.
// A missing face is fatal, like every other startup step (§9.5): ImGui would
// fall back to a Latin-1 face and §9.8 forbids a "?" anywhere in the UI, so
// silently rendering a broken window is worse than saying why.
if !Fonts.load(io: io) {
    Diagnostics.fail(
        "Loading fonts",
        detail: "Resources/Fonts is missing or unreadable. Searched: "
            + AppPaths.resourceRoots.map(\.path).joined(separator: ", ")
    )
}
Fonts.verifyGlyphs()

guard ImGui_ImplSDL3_InitForSDLGPU(window) else {
    Diagnostics.fail("ImGui_ImplSDL3_InitForSDLGPU", detail: "ImGui SDL3 backend init failed")
}
guard cimgui_sdlgpu3_init(device, swapchainFormat) else {
    Diagnostics.fail("cimgui_sdlgpu3_init", detail: "ImGui SDLGPU3 backend init failed")
}
Log.info("ImGui \(String(cString: igGetVersion()))")

guard let renderer = GPULiveRenderer(device: device, colorFormat: swapchainFormat) else {
    // The shader compiler's own diagnostic if there is one: it names the line
    // and the mistake, which a bare "could not be created" does not.
    Diagnostics.fail(
        "Building the stretch pipeline",
        detail: GPULiveRenderer.shaderError ?? Diagnostics.sdlError()
    )
}

let engine = CollimationEngine()
let host = PortableUIHost(window: window)
// Same as ContentView.onAppear on macOS.
engine.connect()

let loop = MainLoop(
    window: window,
    device: device,
    engine: engine,
    host: host,
    renderer: renderer,
    swapchainFormat: swapchainFormat,
    snapshotPath: snapshotPath,
    snapshotAfter: Snapshot.settleSeconds(CommandLine.arguments)
)
loop.run()

// Shutdown in the ImGui example's order, and stop capture before the GPU goes
// away so the capture thread is not inside an SDK call.
//
// Every step here can block on hardware or on a driver, and the window is
// already gone by now, so a step that never returns leaves a process nobody
// can see and nothing can close. The watchdog ends it, and the step timings
// say in the log which call was the slow one.
Diagnostics.armShutdownWatchdog()
Diagnostics.step("engine") { engine.shutdown() }
Diagnostics.step("GPU idle") { SDL_WaitForGPUIdle(device) }
cimgui_sdlgpu3_shutdown()
ImGui_ImplSDL3_Shutdown()
igDestroyContext(imguiContext)
SDL_ReleaseWindowFromGPUDevice(device, window)
Diagnostics.step("GPU device") { SDL_DestroyGPUDevice(device) }
SDL_DestroyWindow(window)
Diagnostics.step("SDL_Quit") { SDL_Quit() }
Log.info("clean exit")
Diagnostics.stop()

// Only `--snapshot` can end with a non-zero status; a normal quit is 0.
if loop.exitStatus != 0 {
    exit(loop.exitStatus)
}
