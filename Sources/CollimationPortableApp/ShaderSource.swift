import Foundation

/// The stretch shader, in the two languages SDL's GPU backends accept.
///
/// Both are ports of `MetalRenderer.shaderSource`, and the reference for the
/// maths is `StretchParams.apply` in CollimationCore. §12.1 item 6: a change to
/// one of these three must change all three in the same commit, along with the
/// `stretch shader math` equivalence test.
///
/// Register assignment is fixed by SDL, not chosen here (§9.4):
///   vertex uniforms          b0, space1   /  [[buffer(0)]]
///   fragment storage texture t0, space2   /  [[texture(0)]]
///   fragment uniforms        b0, space3   /  [[buffer(0)]]
///
/// The texture is a read-only storage texture, which is an SRV in D3D12, so
/// HLSL uses `Texture2D<uint>` with `Load`, never `RWTexture2D`.
enum ShaderSource {
    /// Vertex stage: the quad comes from `SV_VertexID`, so there is no vertex
    /// buffer. The NDC rect is `ImageLayout.ndcRect`.
    static let metal = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    struct QuadRect {
        float x0, y0, x1, y1;
    };

    struct StretchUniforms {
        float black;
        float white;
        float amount;
        float nearest;
        float mode;
        uint clipADU;
        float texW;
        float texH;
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
                                   constant QuadRect &rect [[buffer(0)]]) {
        // Triangle strip: 0 top-left, 1 top-right, 2 bottom-left, 3 bottom-right.
        float x = (vid == 0 || vid == 2) ? rect.x0 : rect.x1;
        float y = (vid == 0 || vid == 1) ? rect.y1 : rect.y0;
        float u = (vid == 0 || vid == 2) ? 0.0 : 1.0;
        float v = (vid == 0 || vid == 1) ? 0.0 : 1.0;
        VertexOut out;
        out.position = float4(x, y, 0, 1);
        out.uv = float2(u, v);
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

    /// HLSL has no `asinh`, `fract` or `mix`, so this uses the log form of
    /// asinh (exact for the non-negative inputs here) plus `frac` and `lerp`.
    /// Targets are vs_5_1 and ps_5_1: SM 5.0 has no register spaces and the
    /// root signature would not match.
    static let hlslVertex = """
    struct VertexOut {
        float4 position : SV_Position;
        float2 uv : TEXCOORD0;
    };

    cbuffer QuadRect : register(b0, space1) {
        float x0;
        float y0;
        float x1;
        float y1;
    };

    VertexOut main(uint vid : SV_VertexID) {
        float x = (vid == 0 || vid == 2) ? x0 : x1;
        float y = (vid == 0 || vid == 1) ? y1 : y0;
        float u = (vid == 0 || vid == 2) ? 0.0 : 1.0;
        float v = (vid == 0 || vid == 1) ? 0.0 : 1.0;
        VertexOut output;
        output.position = float4(x, y, 0, 1);
        output.uv = float2(u, v);
        return output;
    }
    """

    static let hlslFragment = """
    struct VertexOut {
        float4 position : SV_Position;
        float2 uv : TEXCOORD0;
    };

    Texture2D<uint> tex : register(t0, space2);

    cbuffer StretchUniforms : register(b0, space3) {
        float black;
        float white;
        float amount;
        float nearest;
        float mode;
        uint clipADU;
        float texW;
        float texH;
    };

    static const float4 kClipColor = float4(1.0, 0.18, 0.14, 1.0);

    uint readADU(uint2 p) {
        uint2 maxP = uint2((uint)texW - 1, (uint)texH - 1);
        return tex.Load(int3(min(p, maxP), 0));
    }

    bool isClipped(uint adu) {
        return adu >= clipADU;
    }

    // HLSL has no asinh intrinsic. log(x + sqrt(x*x + 1)) is exact for the
    // non-negative arguments this shader uses.
    float asinhf(float x) {
        return log(x + sqrt(x * x + 1.0));
    }

    float4 main(VertexOut input) : SV_Target {
        float w = texW;
        float h = texH;
        float2 uv = input.uv;
        float raw;
        if (nearest > 0.5) {
            uint x = (uint)clamp(uv.x * w, 0.0, w - 1.0);
            uint y = (uint)clamp(uv.y * h, 0.0, h - 1.0);
            uint adu = readADU(uint2(x, y));
            if (isClipped(adu)) {
                return kClipColor;
            }
            raw = (float)adu / 65535.0;
        } else {
            float2 coord = uv * float2(w, h) - 0.5;
            coord = clamp(coord, float2(0, 0), float2(w - 1.001, h - 1.001));
            uint2 p00 = (uint2)coord;
            uint2 p11 = (uint2)min(coord + 1.0, float2(w - 1, h - 1));
            float2 f = frac(coord);
            uint a00 = readADU(p00);
            uint a10 = readADU(uint2(p11.x, p00.y));
            uint a01 = readADU(uint2(p00.x, p11.y));
            uint a11 = readADU(p11);
            if (isClipped(a00) || isClipped(a10) || isClipped(a01) || isClipped(a11)) {
                return kClipColor;
            }
            raw = lerp(lerp((float)a00, (float)a10, f.x), lerp((float)a01, (float)a11, f.x), f.y) / 65535.0;
        }
        float t = saturate((raw - black) / max(white - black, 1e-6));
        if (mode > 0.5) {
            float a = max(amount, 1e-4);
            t = asinhf(a * t) / max(asinhf(a), 1e-6);
        } else {
            float m = amount;
            if (t > 0.0 && t < 1.0 && abs(m - 0.5) > 1e-6) {
                t = saturate(((m - 1.0) * t) / ((2.0 * m - 1.0) * t - m));
            }
        }
        return float4(t, t, t, 1);
    }
    """
}

/// Fragment uniforms. Eight 4-byte scalars, so HLSL cbuffer packing and MSL
/// layout agree without padding.
struct StretchUniforms {
    var black: Float = 0
    var white: Float = 1
    var amount: Float = 0.5
    var nearest: Float = 1
    var mode: Float = 0
    var clipADU: UInt32 = 0
    var texW: Float = 1
    var texH: Float = 1
}

/// Vertex uniforms: the image quad in NDC.
struct QuadRect {
    var x0: Float = -1
    var y0: Float = -1
    var x1: Float = 1
    var y1: Float = 1
}
