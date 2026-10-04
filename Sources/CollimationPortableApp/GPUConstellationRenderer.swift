import CSDL3
import CollimationCore
import CollimationUI
import Foundation

final class GPUConstellationRenderer {
    private let device: OpaquePointer
    private let pipeline: OpaquePointer
    private var textures: [OpaquePointer] = []
    private var transfer: OpaquePointer?
    private var uploadedID: UUID?

    init?(device: OpaquePointer, colorFormat: SDL_GPUTextureFormat) {
        self.device = device
        guard SDL_GPUTextureSupportsFormat(device, CSDL3_TEXTUREFORMAT_R32_FLOAT,
            SDL_GPU_TEXTURETYPE_2D, SDL_GPU_TEXTUREUSAGE_GRAPHICS_STORAGE_READ),
            let pipeline = GPULiveRenderer.makePipeline(device: device, colorFormat: colorFormat, constellation: true) else { return nil }
        self.pipeline = pipeline
    }

    deinit {
        for texture in textures { SDL_ReleaseGPUTexture(device, texture) }
        if let transfer { SDL_ReleaseGPUTransferBuffer(device, transfer) }
        SDL_ReleaseGPUGraphicsPipeline(device, pipeline)
    }

    func prepare(_ state: ConstellationRenderState, commandBuffer: OpaquePointer) {
        guard let result = state.result, uploadedID != result.id else { return }
        let side = CaptureLayout.stackingCropSize
        let tileBytes = side * side * 4
        if textures.count != result.tiles.count {
            for texture in textures { SDL_ReleaseGPUTexture(device, texture) }
            textures = []
            if let transfer { SDL_ReleaseGPUTransferBuffer(device, transfer) }
            transfer = nil
            uploadedID = nil
            for _ in result.tiles {
                var info = SDL_GPUTextureCreateInfo()
                info.type = SDL_GPU_TEXTURETYPE_2D
                info.format = CSDL3_TEXTUREFORMAT_R32_FLOAT
                info.usage = SDL_GPU_TEXTUREUSAGE_GRAPHICS_STORAGE_READ
                info.width = UInt32(side)
                info.height = UInt32(side)
                info.layer_count_or_depth = 1
                info.num_levels = 1
                info.sample_count = SDL_GPU_SAMPLECOUNT_1
                guard let texture = SDL_CreateGPUTexture(device, &info) else {
                    for created in textures { SDL_ReleaseGPUTexture(device, created) }
                    textures = []
                    Log.info("constellation texture creation failed: \(Diagnostics.sdlError())")
                    return
                }
                textures.append(texture)
            }
        }
        if transfer == nil {
            var info = SDL_GPUTransferBufferCreateInfo()
            info.usage = SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD
            info.size = UInt32(tileBytes * result.tiles.count)
            transfer = SDL_CreateGPUTransferBuffer(device, &info)
        }
        guard let transfer, let mapped = SDL_MapGPUTransferBuffer(device, transfer, true) else { return }
        for (i, tile) in result.tiles.enumerated() {
            tile.image.pixels.withUnsafeBytes { bytes in
                if let base = bytes.baseAddress { mapped.advanced(by: i * tileBytes).copyMemory(from: base, byteCount: tileBytes) }
            }
        }
        SDL_UnmapGPUTransferBuffer(device, transfer)
        guard let copy = SDL_BeginGPUCopyPass(commandBuffer) else { return }
        for i in result.tiles.indices {
            var source = SDL_GPUTextureTransferInfo()
            source.transfer_buffer = transfer
            source.offset = UInt32(i * tileBytes)
            source.pixels_per_row = UInt32(side)
            source.rows_per_layer = UInt32(side)
            var region = SDL_GPUTextureRegion()
            region.texture = textures[i]
            region.w = UInt32(side)
            region.h = UInt32(side)
            region.d = 1
            SDL_UploadToGPUTexture(copy, &source, &region, true)
        }
        SDL_EndGPUCopyPass(copy)
        uploadedID = result.id
    }

    func draw(state: ConstellationRenderState, pass: OpaquePointer, commandBuffer: OpaquePointer,
              origin: SIMD2<Double>, size: SIMD2<Double>, windowSize: SIMD2<Double>) {
        guard let result = state.result, uploadedID == result.id, textures.count == result.tiles.count else { return }
        SDL_BindGPUGraphicsPipeline(pass, pipeline)
        for (i, cell) in ConstellationScene.cells(result: result, size: size, zoom: state.zoom).enumerated() {
            let ndc = ImageLayout.ndcRect((x: origin.x + cell.origin.x, y: origin.y + cell.origin.y,
                width: cell.size.x, height: cell.size.y), inViewOfWidth: windowSize.x, height: windowSize.y)
            let uv = cell.uvOrigin, end = uv + cell.uvSize
            let rect: [Float] = [Float(ndc.x0), Float(ndc.y0), Float(ndc.x1), Float(ndc.y1), Float(uv.x), Float(uv.y), Float(end.x), Float(end.y)]
            let s = state.stretch
            let uniforms: [Float] = [Float(s.black), Float(s.white), Float(s.curve == .mtf ? s.midtones : s.arcsinh),
                cell.scale >= 1 ? 1 : 0, s.curve == .mtf ? 0 : 1, 256, 256, 0]
            rect.withUnsafeBytes { SDL_PushGPUVertexUniformData(commandBuffer, 0, $0.baseAddress, 32) }
            uniforms.withUnsafeBytes { SDL_PushGPUFragmentUniformData(commandBuffer, 0, $0.baseAddress, 32) }
            var texture: OpaquePointer? = textures[i]
            SDL_BindGPUFragmentStorageTextures(pass, 0, &texture, 1)
            SDL_DrawGPUPrimitives(pass, 4, 1, 0, 0)
        }
    }
}
