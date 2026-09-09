import CSDL3
import CollimationCore
import Foundation

/// The live view on SDL3 GPU, mirroring `MetalRenderer` one to one.
///
/// The frame is an R16_UINT storage-read texture so the shader sees raw ADU and
/// can paint clipped pixels red; §6.2's fallback chain applies if a GPU cannot
/// do that, and §14a records that Intel Iris Xe can.
final class GPULiveRenderer {
    private let device: OpaquePointer
    private var pipeline: OpaquePointer?
    private var texture: OpaquePointer?
    private var transfer: OpaquePointer?
    private var textureWidth = 0
    private var textureHeight = 0
    private var transferCapacity = 0
    private var lastSequence: UInt64 = .max
    private var lastStabilizedSequence: UInt64 = .max

    /// Background behind the image, the same colour the Metal view clears to.
    static let clearColor = SDL_FColor(r: 0.04, g: 0.045, b: 0.055, a: 1)

    init?(device: OpaquePointer, colorFormat: SDL_GPUTextureFormat) {
        self.device = device
        guard let pipeline = Self.makePipeline(device: device, colorFormat: colorFormat) else {
            return nil
        }
        self.pipeline = pipeline
    }

    deinit {
        if let texture { SDL_ReleaseGPUTexture(device, texture) }
        if let transfer { SDL_ReleaseGPUTransferBuffer(device, transfer) }
        if let pipeline { SDL_ReleaseGPUGraphicsPipeline(device, pipeline) }
    }

    /// Why the pipeline could not be built, for the startup message box. On
    /// Windows that is the `D3DCompile` diagnostic, which names the line and
    /// the mistake — far more use than "the pipeline could not be created".
    static var shaderError: String? {
#if os(Windows)
        return HLSLCompiler.lastError
#elseif os(macOS)
        return nil
#else
        return "No shader backend for this platform; build SPIR-V offline with shadercross."
#endif
    }

    /// Whether the primary texture format works on this device. Logged at
    /// startup so a fallback decision is visible in the log.
    static func supportsR16UInt(device: OpaquePointer) -> Bool {
        SDL_GPUTextureSupportsFormat(
            device,
            CSDL3_TEXTUREFORMAT_R16_UINT,
            SDL_GPU_TEXTURETYPE_2D,
            SDL_GPU_TEXTUREUSAGE_GRAPHICS_STORAGE_READ
        )
    }

    // MARK: - Frame

    /// Uploads a new frame if there is one, updates the stabilizer pose, and
    /// records the whole frame: copy pass, then render pass, then ImGui.
    ///
    /// Copy passes cannot be nested inside a render pass, so the upload is
    /// recorded first. The command buffer is always submitted, even when
    /// nothing was drawn, so a recorded upload is not lost.
    func draw(
        frames: FrameSlot,
        renderState: RenderStateSlot,
        stabilization: StabilizationController,
        window: OpaquePointer,
        /// Both in view points, with the window's top-left as the origin.
        liveRect: (origin: SIMD2<Double>, size: SIMD2<Double>),
        windowSize: SIMD2<Double>,
        drawImGui: (OpaquePointer, OpaquePointer) -> Void,
        prepareImGui: (OpaquePointer) -> Void
    ) {
        var pendingUpload: Frame?
        if let latest = frames.peek() {
            if latest.sequence != lastSequence {
                pendingUpload = latest.frame
                lastSequence = latest.sequence
            }
            if stabilization.isEnabled {
                if latest.sequence != lastStabilizedSequence {
                    let pose = stabilization.process(
                        latest.frame,
                        viewWidth: liveRect.size.x,
                        viewHeight: liveRect.size.y
                    )
                    lastStabilizedSequence = latest.sequence
                    renderState.update { state in
                        state.stabilizeLock = pose.lockNormalized
                        state.stabilizeCentroid = pose.centroid
                        state.imageWidth = latest.frame.width
                        state.imageHeight = latest.frame.height
                        state.roi = latest.frame.roi
                    }
                }
            } else {
                lastStabilizedSequence = .max
            }
        }

        guard let commandBuffer = SDL_AcquireGPUCommandBuffer(device) else { return }

        if let frame = pendingUpload {
            upload(frame, commandBuffer: commandBuffer)
        }

        prepareImGui(commandBuffer)

        var swapchain: OpaquePointer?
        var width: UInt32 = 0
        var height: UInt32 = 0
        let acquired = SDL_WaitAndAcquireGPUSwapchainTexture(commandBuffer, window, &swapchain, &width, &height)
        guard acquired, let swapchain else {
            // Minimized or occluded: submit anyway so the upload is kept.
            _ = SDL_SubmitGPUCommandBuffer(commandBuffer)
            return
        }

        renderScene(
            commandBuffer: commandBuffer,
            colorTarget: swapchain,
            renderState: renderState.peek(),
            liveRect: liveRect,
            windowSize: windowSize,
            targetPixels: SIMD2(Double(width), Double(height)),
            drawImGui: drawImGui
        )
        _ = SDL_SubmitGPUCommandBuffer(commandBuffer)
    }

    /// One render pass into `colorTarget`: clear, the stretched image, then
    /// the ImGui draw data on top. The swapchain and the offscreen snapshot
    /// both go through this, so a snapshot is the same picture the window
    /// shows rather than a second implementation of it.
    func renderScene(
        commandBuffer: OpaquePointer,
        colorTarget: OpaquePointer,
        renderState: RenderState,
        liveRect: (origin: SIMD2<Double>, size: SIMD2<Double>),
        windowSize: SIMD2<Double>,
        /// The colour target's real size, for the scissor. Points are what the
        /// layout is in; the scissor is in pixels.
        targetPixels: SIMD2<Double>,
        drawImGui: (OpaquePointer, OpaquePointer) -> Void
    ) {
        var target = SDL_GPUColorTargetInfo()
        target.texture = colorTarget
        target.clear_color = Self.clearColor
        target.load_op = SDL_GPU_LOADOP_CLEAR
        target.store_op = SDL_GPU_STOREOP_STORE

        guard let pass = SDL_BeginGPURenderPass(commandBuffer, &target, 1, nil) else { return }

        // Clip the image to the live region. The quad is placed in view points
        // inside that region but converted to NDC against the whole window, and
        // `image.x` goes negative as soon as the image is wider than the
        // region — zoom in far enough and the quad reaches left of the sidebar.
        // The sidebar is drawn over it afterwards and mostly hides it, which is
        // why this was never obvious; "mostly" is not a guarantee.
        let scaleX = windowSize.x > 0 ? targetPixels.x / windowSize.x : 1
        let scaleY = windowSize.y > 0 ? targetPixels.y / windowSize.y : 1
        var live = SDL_Rect(
            x: Int32(max(0, (liveRect.origin.x * scaleX).rounded(.down))),
            y: Int32(max(0, (liveRect.origin.y * scaleY).rounded(.down))),
            w: Int32(max(0, (liveRect.size.x * scaleX).rounded())),
            h: Int32(max(0, (liveRect.size.y * scaleY).rounded()))
        )
        SDL_SetGPUScissor(pass, &live)
        drawImage(
            pass: pass,
            commandBuffer: commandBuffer,
            renderState: renderState,
            liveRect: liveRect,
            windowSize: windowSize
        )
        // ImGui sets a scissor per draw command, but it is only ever narrowed
        // from whatever is current, so hand it back the whole target.
        var whole = SDL_Rect(x: 0, y: 0, w: Int32(targetPixels.x), h: Int32(targetPixels.y))
        SDL_SetGPUScissor(pass, &whole)
        drawImGui(commandBuffer, pass)
        SDL_EndGPURenderPass(pass)
    }

    private func drawImage(
        pass: OpaquePointer,
        commandBuffer: OpaquePointer,
        renderState: RenderState,
        liveRect: (origin: SIMD2<Double>, size: SIMD2<Double>),
        windowSize: SIMD2<Double>
    ) {
        guard let pipeline, let texture, textureWidth > 0, textureHeight > 0 else { return }

        // The image is laid out inside the live region in view points, then
        // mapped to the whole swapchain in NDC, so the sidebar does not cover
        // it and the HUD lines up.
        let layout = ImageLayout(
            imageWidth: textureWidth,
            imageHeight: textureHeight,
            viewWidth: liveRect.size.x,
            viewHeight: liveRect.size.y,
            zoom: renderState.zoom,
            lockNormalized: renderState.stabilizeLock,
            stabilizeCentroid: renderState.stabilizeCentroid
        )
        let image = layout.imageRect
        // The layout is in view points inside the live region; the quad covers
        // the whole window. Offset by where the live region starts, then
        // convert with the shared helper so both renderers agree.
        let placed = ImageLayout.ndcRect(
            (
                x: liveRect.origin.x + image.x,
                y: liveRect.origin.y + image.y,
                width: image.width,
                height: image.height
            ),
            inViewOfWidth: windowSize.x,
            height: windowSize.y
        )

        var rect = QuadRect(
            x0: Float(placed.x0),
            y0: Float(placed.y0),
            x1: Float(placed.x1),
            y1: Float(placed.y1)
        )
        var uniforms = StretchUniforms(
            black: Float(renderState.stretch.black),
            white: Float(max(renderState.stretch.white, renderState.stretch.black + 0.0005)),
            amount: renderState.stretch.curve == .arcsinh
                ? Float(min(max(renderState.stretch.arcsinh, StretchParams.arcsinhRange.lowerBound), StretchParams.arcsinhRange.upperBound))
                : Float(min(max(renderState.stretch.midtones, 1e-4), 1 - 1e-4)),
            nearest: renderState.zoom >= 1 ? 1 : 0,
            mode: renderState.stretch.curve == .arcsinh ? 1 : 0,
            clipADU: UInt32(StarQuality.clipADU),
            texW: Float(textureWidth),
            texH: Float(textureHeight)
        )

        SDL_PushGPUVertexUniformData(commandBuffer, 0, &rect, UInt32(MemoryLayout<QuadRect>.size))
        SDL_PushGPUFragmentUniformData(commandBuffer, 0, &uniforms, UInt32(MemoryLayout<StretchUniforms>.size))
        SDL_BindGPUGraphicsPipeline(pass, pipeline)
        var boundTexture: OpaquePointer? = texture
        SDL_BindGPUFragmentStorageTextures(pass, 0, &boundTexture, 1)
        SDL_DrawGPUPrimitives(pass, 4, 1, 0, 0)
    }

    // MARK: - Upload

    private func upload(_ frame: Frame, commandBuffer: OpaquePointer) {
        ensureTexture(width: frame.width, height: frame.height)
        guard let texture, let transfer else { return }

        let byteCount = frame.width * frame.height * MemoryLayout<UInt16>.size
        guard let mapped = SDL_MapGPUTransferBuffer(device, transfer, true) else { return }
        frame.pixels.withUnsafeBytes { source in
            if let base = source.baseAddress {
                mapped.copyMemory(from: base, byteCount: min(byteCount, source.count))
            }
        }
        SDL_UnmapGPUTransferBuffer(device, transfer)

        guard let copyPass = SDL_BeginGPUCopyPass(commandBuffer) else { return }
        var source = SDL_GPUTextureTransferInfo()
        source.transfer_buffer = transfer
        source.offset = 0
        // Rows are tightly packed: a 2048-pixel row is 4096 bytes, which
        // already satisfies D3D12's 256-byte row alignment.
        source.pixels_per_row = UInt32(frame.width)
        source.rows_per_layer = UInt32(frame.height)
        var region = SDL_GPUTextureRegion()
        region.texture = texture
        region.w = UInt32(frame.width)
        region.h = UInt32(frame.height)
        region.d = 1
        SDL_UploadToGPUTexture(copyPass, &source, &region, true)
        SDL_EndGPUCopyPass(copyPass)
    }

    private func ensureTexture(width: Int, height: Int) {
        if width == textureWidth, height == textureHeight, texture != nil, transfer != nil {
            return
        }
        if let texture { SDL_ReleaseGPUTexture(device, texture) }
        texture = nil

        var info = SDL_GPUTextureCreateInfo()
        info.type = SDL_GPU_TEXTURETYPE_2D
        info.format = CSDL3_TEXTUREFORMAT_R16_UINT
        info.usage = SDL_GPU_TEXTUREUSAGE_GRAPHICS_STORAGE_READ
        info.width = UInt32(width)
        info.height = UInt32(height)
        info.layer_count_or_depth = 1
        info.num_levels = 1
        info.sample_count = SDL_GPU_SAMPLECOUNT_1
        guard let created = SDL_CreateGPUTexture(device, &info) else {
            Log.info("SDL_CreateGPUTexture \(width)x\(height) failed: \(Diagnostics.sdlError())")
            return
        }
        texture = created
        textureWidth = width
        textureHeight = height

        let byteCount = width * height * MemoryLayout<UInt16>.size
        if byteCount > transferCapacity {
            if let transfer { SDL_ReleaseGPUTransferBuffer(device, transfer) }
            var transferInfo = SDL_GPUTransferBufferCreateInfo()
            transferInfo.usage = SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD
            transferInfo.size = UInt32(byteCount)
            transfer = SDL_CreateGPUTransferBuffer(device, &transferInfo)
            transferCapacity = byteCount
        }
    }

    // MARK: - Pipeline

    private static func makePipeline(
        device: OpaquePointer,
        colorFormat: SDL_GPUTextureFormat
    ) -> OpaquePointer? {
        guard let vertex = makeShader(device: device, stage: SDL_GPU_SHADERSTAGE_VERTEX),
              let fragment = makeShader(device: device, stage: SDL_GPU_SHADERSTAGE_FRAGMENT) else {
            return nil
        }
        defer {
            SDL_ReleaseGPUShader(device, vertex)
            SDL_ReleaseGPUShader(device, fragment)
        }

        var target = SDL_GPUColorTargetDescription()
        target.format = colorFormat

        var info = SDL_GPUGraphicsPipelineCreateInfo()
        info.vertex_shader = vertex
        info.fragment_shader = fragment
        info.primitive_type = SDL_GPU_PRIMITIVETYPE_TRIANGLESTRIP
        // No vertex buffers: the quad comes from SV_VertexID and the NDC rect
        // uniform.
        info.vertex_input_state.num_vertex_buffers = 0
        info.vertex_input_state.num_vertex_attributes = 0
        info.target_info.num_color_targets = 1

        return withUnsafePointer(to: &target) { pointer in
            info.target_info.color_target_descriptions = pointer
            return SDL_CreateGPUGraphicsPipeline(device, &info)
        }
    }

    private static func makeShader(
        device: OpaquePointer,
        stage: SDL_GPUShaderStage
    ) -> OpaquePointer? {
        let isVertex = stage == SDL_GPU_SHADERSTAGE_VERTEX

#if os(macOS)
        return ShaderSource.metal.withCString { source in
            var info = SDL_GPUShaderCreateInfo()
            info.code = UnsafeRawPointer(source).assumingMemoryBound(to: UInt8.self)
            info.code_size = strlen(source)
            info.format = SDL_GPU_SHADERFORMAT_MSL
            info.stage = stage
            info.num_uniform_buffers = 1
            info.num_storage_textures = isVertex ? 0 : 1
            info.num_samplers = 0
            return (isVertex ? "stretchVertex" : "stretchFragment").withCString { entry in
                info.entrypoint = entry
                return SDL_CreateGPUShader(device, &info)
            }
        }
#elseif os(Windows)
        guard let blob = HLSLCompiler.compile(
            source: isVertex ? ShaderSource.hlslVertex : ShaderSource.hlslFragment,
            entryPoint: "main",
            target: isVertex ? "vs_5_1" : "ps_5_1"
        ) else {
            return nil
        }
        return blob.withUnsafeBytes { bytes -> OpaquePointer? in
            guard let base = bytes.baseAddress else { return nil }
            var info = SDL_GPUShaderCreateInfo()
            info.code = base.assumingMemoryBound(to: UInt8.self)
            info.code_size = bytes.count
            info.format = SDL_GPU_SHADERFORMAT_DXBC
            info.stage = stage
            info.num_uniform_buffers = 1
            info.num_storage_textures = isVertex ? 0 : 1
            info.num_samplers = 0
            return "main".withCString { entry in
                info.entrypoint = entry
                return SDL_CreateGPUShader(device, &info)
            }
        }
#else
        // Linux is not a release target: SPIR-V would have to be produced
        // offline with SDL_shadercross.
        Log.info("No shader backend for this platform; build SPIR-V offline with shadercross.")
        return nil
#endif
    }
}
