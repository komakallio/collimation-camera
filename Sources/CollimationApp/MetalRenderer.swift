import Foundation
import Metal
import MetalKit
import CollimationCore

final class MetalRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var textures: [MTLTexture?] = [nil, nil]
    private var textureWidth = 0
    private var textureHeight = 0
    private var writeIndex = 0
    private var lastSequence: UInt64 = .max
    private var lastStabilizedSequence: UInt64 = .max
    private let gpuCentroid: GPUCentroid?

    let frames: FrameSlot
    let renderState: RenderStateSlot
    let stabilization: StabilizationController

    init?(
        device: MTLDevice,
        frames: FrameSlot,
        renderState: RenderStateSlot,
        stabilization: StabilizationController
    ) {
        self.device = device
        self.frames = frames
        self.renderState = renderState
        self.stabilization = stabilization
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
        self.gpuCentroid = GPUCentroid(device: device)

        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        // Layout in view points so the quad matches the SwiftUI overlay. Using
        // `drawableSize` (pixels) on Retina made the image half as large as the rings.
        let viewWidth = max(Double(view.bounds.width), 1)
        let viewHeight = max(Double(view.bounds.height), 1)

        if let latest = frames.peek() {
            if latest.sequence != lastSequence {
                upload(latest.frame)
                lastSequence = latest.sequence
            }
            if stabilization.isEnabled {
                if latest.sequence != lastStabilizedSequence {
                    let pose = stabilizePose(
                        frame: latest.frame,
                        viewWidth: viewWidth,
                        viewHeight: viewHeight
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

        guard let descriptor = view.currentRenderPassDescriptor else { return }
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.04, green: 0.045, blue: 0.055, alpha: 1)
        descriptor.colorAttachments[0].loadAction = .clear

        guard let drawable = view.currentDrawable,
              let command = queue.makeCommandBuffer(),
              let encoder = command.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }

        guard let texture = textures[writeIndex] else {
            encoder.endEncoding()
            command.present(drawable)
            command.commit()
            return
        }

        let state = renderState.peek()
        let livePose = stabilization.pose()
        let lockNormalized = stabilization.isEnabled ? livePose.lockNormalized : nil
        let stabilizeCentroid = stabilization.isEnabled ? livePose.centroid : nil
        let layout = ImageLayout(
            imageWidth: texture.width,
            imageHeight: texture.height,
            viewWidth: viewWidth,
            viewHeight: viewHeight,
            zoom: state.zoom,
            lockNormalized: lockNormalized,
            stabilizeCentroid: stabilizeCentroid
        )
        // Shared with the portable app's renderer so both build the same quad.
        let ndc = layout.ndcRect()

        var uniforms = StretchUniforms(
            black: Float(state.stretch.black),
            white: Float(max(state.stretch.white, state.stretch.black + 0.0005)),
            amount: state.stretch.curve == .arcsinh
                ? Float(min(max(state.stretch.arcsinh, StretchParams.arcsinhRange.lowerBound), StretchParams.arcsinhRange.upperBound))
                : Float(min(max(state.stretch.midtones, 1e-4), 1 - 1e-4)),
            nearest: state.zoom >= 1 ? 1 : 0,
            mode: state.stretch.curve == .arcsinh ? 1 : 0,
            clipADU: UInt32(StarQuality.clipADU)
        )

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<StretchUniforms>.stride, index: 0)

        let x0 = Float(ndc.x0)
        let x1 = Float(ndc.x1)
        let y0 = Float(ndc.y0)
        let y1 = Float(ndc.y1)
        var vertices: [Float] = [
            x0, y1, 0, 0,
            x1, y1, 1, 0,
            x0, y0, 0, 1,
            x1, y0, 1, 1
        ]
        encoder.setVertexBytes(&vertices, length: vertices.count * MemoryLayout<Float>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        command.present(drawable)
        command.commit()
    }

    private func stabilizePose(frame: Frame, viewWidth: Double, viewHeight: Double) -> StabilizationPose {
        let measured: SIMD2<Double>?
        if stabilization.measuresCentroid {
            if let gpuCentroid, let texture = textures[writeIndex],
               texture.width == frame.width, texture.height == frame.height {
                measured = gpuCentroid.measure(
                    queue: queue,
                    texture: texture,
                    seed: stabilization.measurementSeed(in: frame)
                )
            } else {
                return stabilization.process(frame, viewWidth: viewWidth, viewHeight: viewHeight)
            }
        } else {
            measured = nil
        }
        return stabilization.applyMeasured(
            measured,
            frame: frame,
            viewWidth: viewWidth,
            viewHeight: viewHeight
        )
    }

    private func upload(_ frame: Frame) {
        if textures[0] == nil || textureWidth != frame.width || textureHeight != frame.height {
            for i in 0..<2 {
                let desc = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .r16Uint,
                    width: frame.width,
                    height: frame.height,
                    mipmapped: false
                )
                desc.usage = [.shaderRead]
                desc.storageMode = .shared
                textures[i] = device.makeTexture(descriptor: desc)
            }
            textureWidth = frame.width
            textureHeight = frame.height
            writeIndex = 0
        } else {
            writeIndex ^= 1
        }
        guard let texture = textures[writeIndex] else { return }
        frame.pixels.withUnsafeBytes { raw in
            texture.replace(
                region: MTLRegionMake2D(0, 0, frame.width, frame.height),
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: frame.width * 2
            )
        }
    }

    private struct StretchUniforms {
        var black: Float
        var white: Float
        var amount: Float
        var nearest: Float
        var mode: Float
        var clipADU: UInt32
        var pad0: Float = 0
        var pad1: Float = 0
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
        float amount;
        float nearest;
        float mode;
        uint clipADU;
        float pad0;
        float pad1;
    };

    constant float4 kClipColor = float4(1.0, 0.18, 0.14, 1.0);

    ushort readADU(texture2d<ushort, access::read> tex, uint2 p) {
        uint2 maxP = uint2(tex.get_width() - 1, tex.get_height() - 1);
        return tex.read(min(p, maxP)).r;
    }

    bool isClipped(ushort adu, uint clipADU) {
        return uint(adu) >= clipADU;
    }

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
            ushort adu = readADU(tex, uint2(x, y));
            if (isClipped(adu, u.clipADU)) {
                return kClipColor;
            }
            raw = float(adu) / 65535.0;
        } else {
            float2 coord = uv * float2(w, h) - 0.5;
            coord = clamp(coord, float2(0), float2(w - 1.001, h - 1.001));
            uint2 p00 = uint2(coord);
            uint2 p11 = uint2(min(coord + 1.0, float2(w - 1, h - 1)));
            float2 f = fract(coord);
            ushort a00 = readADU(tex, p00);
            ushort a10 = readADU(tex, uint2(p11.x, p00.y));
            ushort a01 = readADU(tex, uint2(p00.x, p11.y));
            ushort a11 = readADU(tex, p11);
            if (isClipped(a00, u.clipADU) || isClipped(a10, u.clipADU)
                || isClipped(a01, u.clipADU) || isClipped(a11, u.clipADU)) {
                return kClipColor;
            }
            raw = mix(mix(float(a00), float(a10), f.x), mix(float(a01), float(a11), f.x), f.y) / 65535.0;
        }
        float t = saturate((raw - u.black) / max(u.white - u.black, 1e-6));
        if (u.mode > 0.5) {
            float a = max(u.amount, 1e-4);
            t = asinh(a * t) / max(asinh(a), 1e-6);
        } else {
            float m = u.amount;
            if (t > 0.0 && t < 1.0 && abs(m - 0.5) > 1e-6) {
                t = saturate(((m - 1.0) * t) / ((2.0 * m - 1.0) * t - m));
            }
        }
        return float4(t, t, t, 1);
    }
    """
}
