import CImGui
import CSDL3
import CollimationCore
import Foundation

#if os(Windows)
import WinSDK
#endif

/// Milestone 0 spike. Nothing here ships.
///
/// It answers the questions §6.2 gates milestone 3 on:
///   1. Does SDL3 + cimgui + the SDLGPU3 backend build and run from Swift?
///   2. Does the GPU support an R16_UINT storage-read texture, which is how
///      the live view carries 16-bit ADU without losing precision?
///   3. Can a 2048×2048 texture be re-uploaded every frame at 60 fps?
///   4. What are the real sleep durations on Windows, before and after
///      SDL_Init and with a high-resolution waitable timer?
///
/// Run it with `--report` for the format checks and timer numbers without
/// opening a window, which is what CI can do.
@main
struct SDLSpike {
    static func main() {
        let arguments = Set(CommandLine.arguments.dropFirst())
        let headless = arguments.contains("--report")

        Log.info("=== Milestone 0 spike ===")
        Log.info("Swift target: \(targetDescription)")
        reportTimerResolution(stage: "before SDL_Init")

        guard SDL_Init(SDL_INIT_VIDEO) else {
            Log.info("FAIL SDL_Init: \(lastSDLError())")
            exit(1)
        }
        defer { SDL_Quit() }
        Log.info("SDL version: \(SDL_GetVersion())")
        reportTimerResolution(stage: "after SDL_Init")

        guard let device = SDL_CreateGPUDevice(
            SDL_GPU_SHADERFORMAT_SPIRV | SDL_GPU_SHADERFORMAT_DXIL | SDL_GPU_SHADERFORMAT_MSL,
            true,
            nil
        ) else {
            Log.info("FAIL SDL_CreateGPUDevice: \(lastSDLError())")
            Log.info("  §13: on old hardware this is where D3D12 feature level or")
            Log.info("  Shader Model 6 support runs out.")
            exit(1)
        }
        defer { SDL_DestroyGPUDevice(device) }

        if let driver = SDL_GetGPUDeviceDriver(device) {
            Log.info("GPU driver: \(String(cString: driver))")
        }
        Log.info("Shader formats: \(shaderFormatNames(SDL_GetGPUShaderFormats(device)))")

        reportTextureFormats(device: device)

        if headless {
            Log.info("\n--report: skipping the window and the render loop.")
            return
        }

        runWindow(device: device)
    }

    // MARK: - Texture format support (§6.2 gate)

    static func reportTextureFormats(device: OpaquePointer) {
        Log.info("\n--- Texture format support ---")
        let candidates: [(String, SDL_GPUTextureFormat, SDL_GPUTextureUsageFlags)] = [
            ("R16_UINT  + GRAPHICS_STORAGE_READ", SDL_GPU_TEXTUREFORMAT_R16_UINT, SDL_GPU_TEXTUREUSAGE_GRAPHICS_STORAGE_READ),
            ("R16_UNORM + SAMPLER", SDL_GPU_TEXTUREFORMAT_R16_UNORM, SDL_GPU_TEXTUREUSAGE_SAMPLER),
            ("R32_FLOAT + GRAPHICS_STORAGE_READ", SDL_GPU_TEXTUREFORMAT_R32_FLOAT, SDL_GPU_TEXTUREUSAGE_GRAPHICS_STORAGE_READ),
            ("R32_FLOAT + SAMPLER", SDL_GPU_TEXTUREFORMAT_R32_FLOAT, SDL_GPU_TEXTUREUSAGE_SAMPLER),
        ]
        for (label, format, usage) in candidates {
            let supported = SDL_GPUTextureSupportsFormat(
                device,
                format,
                SDL_GPU_TEXTURETYPE_2D,
                usage
            )
            Log.info("  \(supported ? "yes" : "NO ")  \(label)")
        }
        Log.info("  §6.2 fallback order if the first is NO: R16_UNORM + nearest")
        Log.info("  sampler recovering ADU with round(v * 65535), then R32_FLOAT.")
    }

    // MARK: - Timer resolution (§6.1 task 6)

    static func reportTimerResolution(stage: String) {
        Log.info("\n--- Sleep accuracy \(stage) ---")
        for requested in [0.0002, 0.0333] {
            let measured = measure { Thread.sleep(forTimeInterval: requested) }
            Log.info(String(
                format: "  Thread.sleep(%.4f s) took %7.3f ms",
                requested,
                measured * 1000
            ))
        }
        for microseconds in [200, 33_333] {
            let measured = measure { preciseSleep(microseconds: microseconds) }
            Log.info(String(
                format: "  preciseSleep(%6d µs)  took %7.3f ms",
                microseconds,
                measured * 1000
            ))
        }
    }

    /// Median of five, so one scheduling hiccup does not set the number.
    static func measure(_ body: () -> Void) -> TimeInterval {
        var samples: [TimeInterval] = []
        for _ in 0..<5 {
            let start = Date()
            body()
            samples.append(-start.timeIntervalSinceNow)
        }
        samples.sort()
        return samples[samples.count / 2]
    }

    // MARK: - Window, ImGui, and the upload loop

    static func runWindow(device: OpaquePointer) {
        let flags = SDL_WINDOW_RESIZABLE | SDL_WINDOW_HIGH_PIXEL_DENSITY
        guard let window = SDL_CreateWindow("Collimation spike", 1280, 800, flags) else {
            Log.info("FAIL SDL_CreateWindow: \(lastSDLError())")
            return
        }
        defer { SDL_DestroyWindow(window) }

        guard SDL_ClaimWindowForGPUDevice(device, window) else {
            Log.info("FAIL SDL_ClaimWindowForGPUDevice: \(lastSDLError())")
            return
        }
        _ = SDL_SetGPUSwapchainParameters(
            device,
            window,
            SDL_GPU_SWAPCHAINCOMPOSITION_SDR,
            SDL_GPU_PRESENTMODE_VSYNC
        )
        let colorFormat = SDL_GetGPUSwapchainTextureFormat(device, window)

        // --- ImGui ---
        guard let context = igCreateContext(nil) else {
            Log.info("FAIL igCreateContext")
            return
        }
        defer { igDestroyContext(context) }
        igStyleColorsDark(nil)

        guard ImGui_ImplSDL3_InitForSDLGPU(window) else {
            Log.info("FAIL ImGui_ImplSDL3_InitForSDLGPU")
            return
        }
        defer { ImGui_ImplSDL3_Shutdown() }

        guard cimgui_sdlgpu3_init(device, colorFormat) else {
            Log.info("FAIL cimgui_sdlgpu3_init")
            return
        }
        defer { cimgui_sdlgpu3_shutdown() }
        Log.info("\nImGui \(String(cString: igGetVersion())) initialized on the SDLGPU3 backend.")

        // --- The 2048² upload the live view needs ---
        let side = 2048
        let byteCount = side * side * MemoryLayout<UInt16>.size
        let texture = makeStorageTexture(device: device, side: side)
        var transferInfo = SDL_GPUTransferBufferCreateInfo()
        transferInfo.usage = SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD
        transferInfo.size = UInt32(byteCount)
        let transfer = SDL_CreateGPUTransferBuffer(device, &transferInfo)
        defer {
            if let transfer { SDL_ReleaseGPUTransferBuffer(device, transfer) }
            if let texture { SDL_ReleaseGPUTexture(device, texture) }
        }
        var pixels = [UInt16](repeating: 0, count: side * side)

        Log.info("Running. Close the window to finish; the fps line is the answer to §6.1 task 3.\n")

        var frame = 0
        var running = true
        var lastReport = Date()
        var uploadTotal: TimeInterval = 0
        var frameTotal: TimeInterval = 0
        var framesSinceReport = 0

        while running {
            var event = SDL_Event()
            while SDL_PollEvent(&event) {
                _ = ImGui_ImplSDL3_ProcessEvent(&event)
                if event.type == SDL_EVENT_QUIT.rawValue { running = false }
                if event.type == SDL_EVENT_WINDOW_CLOSE_REQUESTED.rawValue { running = false }
                // §6.1 task 4: the input pieces the portable app needs.
                if event.type == SDL_EVENT_MOUSE_WHEEL.rawValue {
                    Log.info(String(format: "wheel dx=%.3f dy=%.3f", event.wheel.x, event.wheel.y))
                }
                if event.type == SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED.rawValue {
                    Log.info("display scale now \(SDL_GetWindowDisplayScale(window))")
                }
            }

            let frameStart = Date()

            // A moving pattern, so a stale upload would be visible.
            let phase = Double(frame) * 0.05
            for y in stride(from: 0, to: side, by: 1) {
                let row = y * side
                let value = UInt16(truncatingIfNeeded: Int((sin(Double(y) * 0.01 + phase) * 0.5 + 0.5) * 65535))
                for x in stride(from: 0, to: side, by: 64) {
                    pixels[row + x] = value
                }
            }

            let uploadStart = Date()
            if let texture, let transfer {
                upload(device: device, texture: texture, transfer: transfer, pixels: &pixels, side: side)
            }
            uploadTotal += -uploadStart.timeIntervalSinceNow

            ImGui_ImplSDL3_NewFrame()
            cimgui_sdlgpu3_new_frame()
            igNewFrame()
            igShowDemoWindow(nil)
            drawSpikeWindow(frame: frame, side: side)
            igRender()

            if let commandBuffer = SDL_AcquireGPUCommandBuffer(device) {
                var swapchain: OpaquePointer?
                var width: UInt32 = 0
                var height: UInt32 = 0
                if SDL_WaitAndAcquireGPUSwapchainTexture(commandBuffer, window, &swapchain, &width, &height),
                   let swapchain,
                   let drawData = igGetDrawData() {
                    cimgui_sdlgpu3_prepare_draw_data(drawData, commandBuffer)
                    var target = SDL_GPUColorTargetInfo()
                    target.texture = swapchain
                    target.clear_color = SDL_FColor(r: 0.04, g: 0.045, b: 0.055, a: 1)
                    target.load_op = SDL_GPU_LOADOP_CLEAR
                    target.store_op = SDL_GPU_STOREOP_STORE
                    if let pass = SDL_BeginGPURenderPass(commandBuffer, &target, 1, nil) {
                        cimgui_sdlgpu3_render_draw_data(drawData, commandBuffer, pass)
                        SDL_EndGPURenderPass(pass)
                    }
                }
                _ = SDL_SubmitGPUCommandBuffer(commandBuffer)
            }

            frameTotal += -frameStart.timeIntervalSinceNow
            frame += 1
            framesSinceReport += 1

            if -lastReport.timeIntervalSinceNow >= 1 {
                let elapsed = -lastReport.timeIntervalSinceNow
                Log.info(String(
                    format: "%5.1f fps   frame %.2f ms   upload %.2f ms",
                    Double(framesSinceReport) / elapsed,
                    frameTotal / Double(framesSinceReport) * 1000,
                    uploadTotal / Double(framesSinceReport) * 1000
                ))
                lastReport = Date()
                uploadTotal = 0
                frameTotal = 0
                framesSinceReport = 0
            }
        }
    }

    static func makeStorageTexture(device: OpaquePointer, side: Int) -> OpaquePointer? {
        var info = SDL_GPUTextureCreateInfo()
        info.type = SDL_GPU_TEXTURETYPE_2D
        info.format = SDL_GPU_TEXTUREFORMAT_R16_UINT
        info.usage = SDL_GPU_TEXTUREUSAGE_GRAPHICS_STORAGE_READ
        info.width = UInt32(side)
        info.height = UInt32(side)
        info.layer_count_or_depth = 1
        info.num_levels = 1
        info.sample_count = SDL_GPU_SAMPLECOUNT_1
        guard let texture = SDL_CreateGPUTexture(device, &info) else {
            Log.info("FAIL SDL_CreateGPUTexture R16_UINT: \(lastSDLError())")
            return nil
        }
        return texture
    }

    static func upload(
        device: OpaquePointer,
        texture: OpaquePointer,
        transfer: OpaquePointer,
        pixels: inout [UInt16],
        side: Int
    ) {
        // cycle: true hands back a fresh allocation rather than stalling on the
        // one the GPU may still be reading.
        guard let mapped = SDL_MapGPUTransferBuffer(device, transfer, true) else { return }
        pixels.withUnsafeBytes { source in
            if let base = source.baseAddress {
                mapped.copyMemory(from: base, byteCount: source.count)
            }
        }
        SDL_UnmapGPUTransferBuffer(device, transfer)

        guard let commandBuffer = SDL_AcquireGPUCommandBuffer(device) else { return }
        if let copyPass = SDL_BeginGPUCopyPass(commandBuffer) {
            var source = SDL_GPUTextureTransferInfo()
            source.transfer_buffer = transfer
            source.offset = 0
            source.pixels_per_row = UInt32(side)
            source.rows_per_layer = UInt32(side)
            var destination = SDL_GPUTextureRegion()
            destination.texture = texture
            destination.w = UInt32(side)
            destination.h = UInt32(side)
            destination.d = 1
            SDL_UploadToGPUTexture(copyPass, &source, &destination, true)
            SDL_EndGPUCopyPass(copyPass)
        }
        _ = SDL_SubmitGPUCommandBuffer(commandBuffer)
    }

    /// `igText` is variadic, and Swift cannot import a variadic C function, so
    /// every label is formatted in Swift and drawn with `igTextUnformatted`.
    /// The portable app must do the same throughout.
    static func text(_ value: String) {
        value.withCString { igTextUnformatted($0, nil) }
    }

    static func drawSpikeWindow(frame: Int, side: Int) {
        if igBegin("Spike", nil, 0) {
            text("frame \(frame)")
            text("uploading \(side)x\(side) R16_UINT every frame")
            igSeparator()
            text("§6.1 task 4: scroll the wheel, resize, move between monitors.")
            text("Wheel deltas and display-scale changes print to stdout.")
        }
        igEnd()
    }

    // MARK: - Helpers

    static var targetDescription: String {
#if os(Windows)
        return "x86_64-unknown-windows-msvc"
#elseif os(macOS)
        return "macOS"
#else
        return "linux"
#endif
    }

    static func lastSDLError() -> String {
        guard let message = SDL_GetError() else { return "unknown" }
        return String(cString: message)
    }

    static func shaderFormatNames(_ formats: SDL_GPUShaderFormat) -> String {
        var names: [String] = []
        if formats & SDL_GPU_SHADERFORMAT_DXBC != 0 { names.append("DXBC") }
        if formats & SDL_GPU_SHADERFORMAT_DXIL != 0 { names.append("DXIL") }
        if formats & SDL_GPU_SHADERFORMAT_SPIRV != 0 { names.append("SPIRV") }
        if formats & SDL_GPU_SHADERFORMAT_MSL != 0 { names.append("MSL") }
        if formats & SDL_GPU_SHADERFORMAT_METALLIB != 0 { names.append("METALLIB") }
        return names.isEmpty ? "none" : names.joined(separator: ", ")
    }
}
