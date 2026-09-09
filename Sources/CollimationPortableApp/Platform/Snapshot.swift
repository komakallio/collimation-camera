import CImGui
import CSDL3
import CollimationCore
import Foundation

/// `CollimationCamera --snapshot <file.png>`: renders one frame to an
/// offscreen texture and writes it out, then exits.
///
/// Two things need this. The HUD comparison of §9.8 wants the same picture
/// from both apps for the same state, and a screen grab of a live window is a
/// poor way to get it: the window manager, the compositor, and whatever is on
/// top all interfere. And a machine reached over remote desktop, or one whose
/// display has gone to sleep, cannot be photographed at all — but it can still
/// render.
///
/// The picture comes out of `GPULiveRenderer.renderScene`, the same call the
/// window uses, so it is what the window would have shown.
@MainActor
enum Snapshot {
    static func requestedPath(_ arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: "--snapshot"),
              arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    /// Seconds to run the normal loop before the shot, so the simulator has
    /// produced a star and tracking has settled. `--snapshot-after <seconds>`.
    static func settleSeconds(_ arguments: [String]) -> Double {
        guard let index = arguments.firstIndex(of: "--snapshot-after"),
              arguments.indices.contains(index + 1),
              let value = Double(arguments[index + 1]) else { return 3 }
        return min(max(value, 0), 120)
    }

    /// D3D12 wants 256-byte aligned rows in a copy, and the surface takes an
    /// explicit pitch, so the padding costs nothing but a few bytes.
    private static func alignedPixels(_ width: Int) -> Int {
        let pixelsPerAlignment = 64      // 64 pixels × 4 bytes = 256
        return ((width + pixelsPerAlignment - 1) / pixelsPerAlignment) * pixelsPerAlignment
    }

    private static func surfaceFormat(for format: SDL_GPUTextureFormat) -> SDL_PixelFormat? {
        if format == SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM { return SDL_PIXELFORMAT_BGRA32 }
        if format == SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM { return SDL_PIXELFORMAT_RGBA32 }
        return nil
    }

    /// Renders and writes the file. Returns false and logs the reason on any
    /// failure; the caller decides the exit status.
    static func write(
        to path: String,
        device: OpaquePointer,
        window: OpaquePointer,
        format: SDL_GPUTextureFormat,
        renderer: GPULiveRenderer,
        engine: CollimationEngine,
        liveRect: (origin: SIMD2<Double>, size: SIMD2<Double>),
        windowSize: SIMD2<Double>,
        drawImGui: (OpaquePointer, OpaquePointer) -> Void,
        prepareImGui: (OpaquePointer) -> Void
    ) -> Bool {
        guard let pixelFormat = surfaceFormat(for: format) else {
            Log.info("snapshot: swapchain format \(format.rawValue) is not one this can save")
            return false
        }

        var pixelWidth: Int32 = 0
        var pixelHeight: Int32 = 0
        SDL_GetWindowSizeInPixels(window, &pixelWidth, &pixelHeight)
        let width = Int(pixelWidth)
        let height = Int(pixelHeight)
        guard width > 0, height > 0 else {
            Log.info("snapshot: the window has no size")
            return false
        }

        var textureInfo = SDL_GPUTextureCreateInfo()
        textureInfo.type = SDL_GPU_TEXTURETYPE_2D
        textureInfo.format = format
        textureInfo.usage = SDL_GPU_TEXTUREUSAGE_COLOR_TARGET
        textureInfo.width = UInt32(width)
        textureInfo.height = UInt32(height)
        textureInfo.layer_count_or_depth = 1
        textureInfo.num_levels = 1
        textureInfo.sample_count = SDL_GPU_SAMPLECOUNT_1
        guard let colorTarget = SDL_CreateGPUTexture(device, &textureInfo) else {
            Log.info("snapshot: SDL_CreateGPUTexture failed: \(Diagnostics.sdlError())")
            return false
        }
        defer { SDL_ReleaseGPUTexture(device, colorTarget) }

        let rowPixels = alignedPixels(width)
        let byteCount = rowPixels * height * 4
        var transferInfo = SDL_GPUTransferBufferCreateInfo()
        transferInfo.usage = SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD
        transferInfo.size = UInt32(byteCount)
        guard let transfer = SDL_CreateGPUTransferBuffer(device, &transferInfo) else {
            Log.info("snapshot: SDL_CreateGPUTransferBuffer failed: \(Diagnostics.sdlError())")
            return false
        }
        defer { SDL_ReleaseGPUTransferBuffer(device, transfer) }

        guard let commandBuffer = SDL_AcquireGPUCommandBuffer(device) else {
            Log.info("snapshot: SDL_AcquireGPUCommandBuffer failed: \(Diagnostics.sdlError())")
            return false
        }
        prepareImGui(commandBuffer)
        renderer.renderScene(
            commandBuffer: commandBuffer,
            colorTarget: colorTarget,
            renderState: engine.renderStateSlot.peek(),
            liveRect: liveRect,
            windowSize: windowSize,
            drawImGui: drawImGui
        )

        guard let copyPass = SDL_BeginGPUCopyPass(commandBuffer) else {
            Log.info("snapshot: SDL_BeginGPUCopyPass failed: \(Diagnostics.sdlError())")
            _ = SDL_SubmitGPUCommandBuffer(commandBuffer)
            return false
        }
        var region = SDL_GPUTextureRegion()
        region.texture = colorTarget
        region.w = UInt32(width)
        region.h = UInt32(height)
        region.d = 1
        var destination = SDL_GPUTextureTransferInfo()
        destination.transfer_buffer = transfer
        destination.offset = 0
        destination.pixels_per_row = UInt32(rowPixels)
        destination.rows_per_layer = UInt32(height)
        SDL_DownloadFromGPUTexture(copyPass, &region, &destination)
        SDL_EndGPUCopyPass(copyPass)

        guard let fence = SDL_SubmitGPUCommandBufferAndAcquireFence(commandBuffer) else {
            Log.info("snapshot: submit failed: \(Diagnostics.sdlError())")
            return false
        }
        var fences: OpaquePointer? = fence
        _ = SDL_WaitForGPUFences(device, true, &fences, 1)
        SDL_ReleaseGPUFence(device, fence)

        guard let mapped = SDL_MapGPUTransferBuffer(device, transfer, false) else {
            Log.info("snapshot: SDL_MapGPUTransferBuffer failed: \(Diagnostics.sdlError())")
            return false
        }
        defer { SDL_UnmapGPUTransferBuffer(device, transfer) }

        guard let surface = SDL_CreateSurfaceFrom(
            Int32(width),
            Int32(height),
            pixelFormat,
            mapped,
            Int32(rowPixels * 4)
        ) else {
            Log.info("snapshot: SDL_CreateSurfaceFrom failed: \(Diagnostics.sdlError())")
            return false
        }
        defer { SDL_DestroySurface(surface) }

        let saved = path.withCString { SDL_SavePNG(surface, $0) }
        if saved {
            Log.info("snapshot: wrote \(path) (\(width)x\(height))")
        } else {
            Log.info("snapshot: SDL_SavePNG failed: \(Diagnostics.sdlError())")
        }
        return saved
    }
}
