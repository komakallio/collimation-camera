import Foundation
import Metal
import MetalKit
import CollimationCore

final class MetalRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var texture: MTLTexture?
    private var textureWidth = 0
    private var textureHeight = 0
    private var lastSequence: UInt64 = .max

    let frames: FrameSlot
    let renderState: RenderStateSlot
    var viewSize = CGSize(width: 1, height: 1)

    init?(device: MTLDevice, frames: FrameSlot, renderState: RenderStateSlot) {
        self.device = device
        self.frames = frames
        self.renderState = renderState
        guard let queue = device.makeCommandQueue() else { return nil }
        self.queue = queue

        let options = MTLCompileOptions()
        guard let library = try? device.makeLibrary(source: Self.shaderSource, options: options) else {
            return nil
        }
        guard let vertex = library.makeFunction(name: "stretchVertex"),
              let fragment = library.makeFunction(name: "stretchFragment") else {
            return nil
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertex
        desc.fragmentFunction = fragment
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: desc) else { return nil }
        self.pipeline = pipeline

        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        viewSize = size
    }

    func draw(in view: MTKView) {
        guard let descriptor = view.currentRenderPassDescriptor else { return }
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.04, green: 0.045, blue: 0.055, alpha: 1)
        descriptor.colorAttachments[0].loadAction = .clear

        guard let drawable = view.currentDrawable,
              let command = queue.makeCommandBuffer(),
              let encoder = command.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }

        if let latest = frames.peek() {
            if latest.sequence != lastSequence {
                upload(latest.frame)
                lastSequence = latest.sequence
            }
        }

        guard let texture else {
            encoder.endEncoding()
            command.present(drawable)
            command.commit()
            return
        }

        let state = renderState.peek()
        let layout = ImageLayout(
            imageWidth: texture.width,
            imageHeight: texture.height,
            viewWidth: viewSize.width,
            viewHeight: viewSize.height,
            zoom: state.zoom
        )
        let rect = layout.imageRect
        let ndc = toNDC(
            x: rect.x,
            y: rect.y,
            width: rect.width,
            height: rect.height,
            viewWidth: viewSize.width,
            viewHeight: viewSize.height
        )

        var uniforms = StretchUniforms(
            black: Float(state.stretch.black),
            white: Float(max(state.stretch.white, state.stretch.black + 0.0005)),
            gamma: Float(state.stretch.gamma),
            nearest: state.zoom >= 1 ? 1 : 0
        )

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<StretchUniforms>.stride, index: 0)

        var vertices: [Float] = [
            ndc.x0, ndc.y1, 0, 0,
            ndc.x1, ndc.y1, 1, 0,
            ndc.x0, ndc.y0, 0, 1,
            ndc.x1, ndc.y0, 1, 1
        ]
        encoder.setVertexBytes(&vertices, length: vertices.count * MemoryLayout<Float>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        command.present(drawable)
        command.commit()
    }

    private func upload(_ frame: Frame) {
        if texture == nil || textureWidth != frame.width || textureHeight != frame.height {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r16Uint,
                width: frame.width,
                height: frame.height,
                mipmapped: false
            )
            desc.usage = [.shaderRead]
            desc.storageMode = .shared
            texture = device.makeTexture(descriptor: desc)
            textureWidth = frame.width
            textureHeight = frame.height
        }
        guard let texture else { return }
        frame.pixels.withUnsafeBytes { raw in
            texture.replace(
                region: MTLRegionMake2D(0, 0, frame.width, frame.height),
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: frame.width * 2
            )
        }
    }

    private func toNDC(x: Double, y: Double, width: Double, height: Double, viewWidth: Double, viewHeight: Double)
        -> (x0: Float, y0: Float, x1: Float, y1: Float)
    {
        // SwiftUI overlay uses top-left origin. Convert so y=0 is the top of the view.
        let x0 = Float(2 * x / viewWidth - 1)
        let x1 = Float(2 * (x + width) / viewWidth - 1)
        let top = y
        let bottom = y + height
        let y1 = Float(1 - 2 * top / viewHeight)
        let y0 = Float(1 - 2 * bottom / viewHeight)
        return (x0, y0, x1, y1)
    }

    private struct StretchUniforms {
        var black: Float
        var white: Float
        var gamma: Float
        var nearest: Float
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    struct StretchUniforms {
        float black;
        float white;
        float gamma;
        float nearest;
    };

    vertex VertexOut stretchVertex(uint vid [[vertex_id]],
                                   constant float4 *verts [[buffer(0)]]) {
        float4 v = verts[vid];
        VertexOut out;
        out.position = float4(v.x, v.y, 0, 1);
        out.uv = float2(v.z, v.w);
        return out;
    }

    fragment float4 stretchFragment(VertexOut in [[stage_in]],
                                    texture2d<ushort, access::read> tex [[texture(0)]],
                                    constant StretchUniforms &u [[buffer(0)]]) {
        float w = float(tex.get_width());
        float h = float(tex.get_height());
        float2 uv = in.uv;
        float raw;
        if (u.nearest > 0.5) {
            uint x = uint(clamp(uv.x * w, 0.0, w - 1.0));
            uint y = uint(clamp(uv.y * h, 0.0, h - 1.0));
            raw = float(tex.read(uint2(x, y)).r) / 65535.0;
        } else {
            float2 coord = uv * float2(w, h) - 0.5;
            coord = clamp(coord, float2(0), float2(w - 1.001, h - 1.001));
            uint2 p00 = uint2(coord);
            uint2 p11 = uint2(min(coord + 1.0, float2(w - 1, h - 1)));
            float2 f = fract(coord);
            float v00 = float(tex.read(p00).r);
            float v10 = float(tex.read(uint2(p11.x, p00.y)).r);
            float v01 = float(tex.read(uint2(p00.x, p11.y)).r);
            float v11 = float(tex.read(p11).r);
            raw = mix(mix(v00, v10, f.x), mix(v01, v11, f.x), f.y) / 65535.0;
        }
        float t = saturate((raw - u.black) / max(u.white - u.black, 1e-6));
        t = pow(t, u.gamma);
        return float4(t, t, t, 1);
    }
    """
}
