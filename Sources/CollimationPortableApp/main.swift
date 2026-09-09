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

let displayScale = Double(SDL_GetDisplayContentScale(SDL_GetPrimaryDisplay()))
let initialScale = displayScale > 0 ? displayScale : 1
let windowFlags = SDL_WINDOW_RESIZABLE | SDL_WINDOW_HIGH_PIXEL_DENSITY
guard let window = SDL_CreateWindow(
    "Collimation Camera",
    Int32(1280 * initialScale),
    Int32(820 * initialScale),
    windowFlags
) else {
    Diagnostics.fail("SDL_CreateWindow")
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
Log.info("R16_UINT storage read supported: \(GPULiveRenderer.supportsR16UInt(device: device))")

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

guard let imguiContext = igCreateContext(nil) else {
    Diagnostics.fail("igCreateContext", detail: "ImGui context could not be created")
}
guard let io = igGetIO_Nil() else {
    Diagnostics.fail("igGetIO", detail: "ImGui IO unavailable")
}
io.pointee.IniFilename = nil   // no imgui.ini beside the executable

// Fonts before the backend init: the first face loaded becomes the default.
if !Fonts.load(io: io) {
    Log.info("Some fonts are missing; ImGui will fall back and non-ASCII glyphs may show as '?'.")
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
    Diagnostics.fail("GPULiveRenderer", detail: "stretch pipeline could not be created")
}

let engine = CollimationEngine()
let host = PortableUIHost()
// Same as ContentView.onAppear on macOS.
engine.connect()

let loop = MainLoop(
    window: window,
    device: device,
    engine: engine,
    host: host,
    renderer: renderer
)
loop.run()

// Shutdown in the ImGui example's order, and stop capture before the GPU goes
// away so the capture thread is not inside an SDK call.
engine.shutdown()
SDL_WaitForGPUIdle(device)
cimgui_sdlgpu3_shutdown()
ImGui_ImplSDL3_Shutdown()
igDestroyContext(imguiContext)
SDL_ReleaseWindowFromGPUDevice(device, window)
SDL_DestroyGPUDevice(device)
SDL_DestroyWindow(window)
SDL_Quit()
Log.info("clean exit")
Diagnostics.stop()
