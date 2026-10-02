import CollimationCore
import CollimationUI
import MetalKit
import SwiftUI

struct ConstellationView: View {
    let engine: CollimationEngine
    var body: some View {
        let state = ConstellationRenderState(result: engine.constellationResult,
            zoom: engine.constellationZoom, stretch: engine.constellationStretch)
        ZStack {
            ConstellationMetalView(slot: engine.constellationRenderSlot, state: state) { factor in
                engine.constellationZoom = engine.clampedConstellationZoom(engine.constellationZoom * factor)
            }
            Canvas { context, size in
                HUDCanvas.draw(ConstellationScene.primitives(state: state, size: SIMD2(size.width, size.height)), in: &context)
            }
            .allowsHitTesting(false)
        }
    }
}

private struct ConstellationMetalView: NSViewRepresentable {
    let slot: ConstellationRenderSlot
    let state: ConstellationRenderState
    let onZoom: (Double) -> Void

    func makeCoordinator() -> ConstellationMetalRenderer? { ConstellationMetalRenderer(slot: slot) }
    func makeNSView(context: Context) -> LiveMTKView {
        let view = LiveMTKView()
        view.device = context.coordinator?.device
        view.delegate = context.coordinator
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0.04, green: 0.045, blue: 0.055, alpha: 1)
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.onScroll = { delta in Task { @MainActor in onZoom(delta > 0 ? 1.08 : 0.92) } }
        view.onMagnify = { factor in Task { @MainActor in onZoom(Double(factor)) } }
        return view
    }
    func updateNSView(_ view: LiveMTKView, context: Context) {
        view.needsDisplay = true
    }
}

private final class ConstellationMetalRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let slot: ConstellationRenderSlot
    private var textures: [MTLTexture] = []
    private var uploadedID: UUID?

    init?(slot: ConstellationRenderSlot) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: ConstellationShader.metal, options: nil) else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "stretchVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "stretchFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        self.slot = slot
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { view.needsDisplay = true }
    func draw(in view: MTKView) {
        let state = slot.peek()
        guard let result = state.result else { return }
        if uploadedID != result.id {
            var uploaded: [MTLTexture] = []
            for tile in result.tiles {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float,
                    width: tile.image.width, height: tile.image.height, mipmapped: false)
                descriptor.storageMode = .shared
                descriptor.usage = .shaderRead
                guard let texture = device.makeTexture(descriptor: descriptor) else { return }
                tile.image.pixels.withUnsafeBytes { bytes in
                    if let base = bytes.baseAddress {
                        texture.replace(region: MTLRegionMake2D(0, 0, tile.image.width, tile.image.height), mipmapLevel: 0,
                            withBytes: base, bytesPerRow: tile.image.width * 4)
                    }
                }
                uploaded.append(texture)
            }
            textures = uploaded
            uploadedID = result.id
        }
        guard let drawable = view.currentDrawable, let descriptor = view.currentRenderPassDescriptor,
              let command = queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        let size = SIMD2(Double(view.bounds.width), Double(view.bounds.height))
        encoder.setRenderPipelineState(pipeline)
        for (i, cell) in ConstellationScene.cells(result: result, size: size, zoom: state.zoom).enumerated() {
            let ndc = ImageLayout.ndcRect((x: cell.origin.x, y: cell.origin.y, width: cell.size.x, height: cell.size.y),
                inViewOfWidth: size.x, height: size.y)
            let uv = cell.uvOrigin, end = uv + cell.uvSize
            let rect: [Float] = [Float(ndc.x0), Float(ndc.y0), Float(ndc.x1), Float(ndc.y1), Float(uv.x), Float(uv.y), Float(end.x), Float(end.y)]
            let s = state.stretch
            let uniforms: [Float] = [Float(s.black), Float(s.white), Float(s.curve == .mtf ? s.midtones : s.arcsinh),
                cell.scale >= 1 ? 1 : 0, s.curve == .mtf ? 0 : 1, 256, 256, 0]
            rect.withUnsafeBytes { if let base = $0.baseAddress { encoder.setVertexBytes(base, length: 32, index: 0) } }
            uniforms.withUnsafeBytes { if let base = $0.baseAddress { encoder.setFragmentBytes(base, length: 32, index: 0) } }
            encoder.setFragmentTexture(textures[i], index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
        command.present(drawable)
        command.commit()
    }
}
