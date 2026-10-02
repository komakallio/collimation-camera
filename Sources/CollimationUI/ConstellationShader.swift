/// Float-ADU shader shared by native Metal and SDL's Metal/D3D renderers.
public enum ConstellationShader {
    public static let metal = """
    #include <metal_stdlib>
    using namespace metal;
    struct VertexOut { float4 position [[position]]; float2 uv; };
    struct QuadRect { float x0, y0, x1, y1, u0, v0, u1, v1; };
    struct StretchUniforms { float black, white, amount, nearest, mode, texW, texH, spare; };
    vertex VertexOut stretchVertex(uint vid [[vertex_id]], constant QuadRect &r [[buffer(0)]]) {
        VertexOut out;
        out.position = float4((vid == 0 || vid == 2) ? r.x0 : r.x1,
                              (vid == 0 || vid == 1) ? r.y1 : r.y0, 0, 1);
        out.uv = float2((vid == 0 || vid == 2) ? r.u0 : r.u1,
                        (vid == 0 || vid == 1) ? r.v0 : r.v1);
        return out;
    }
    fragment float4 stretchFragment(VertexOut in [[stage_in]],
        texture2d<float, access::read> tex [[texture(0)]], constant StretchUniforms &u [[buffer(0)]]) {
        if (any(in.uv < 0.0) || any(in.uv >= 1.0)) return float4(0, 0, 0, 1);
        float2 dimensions = float2(u.texW, u.texH);
        float raw;
        if (u.nearest > 0.5) {
            raw = tex.read(uint2(min(in.uv * dimensions, dimensions - 1.0))).r;
        } else {
            float2 p = clamp(in.uv * dimensions - 0.5, float2(0), dimensions - 1.0);
            uint2 lo = uint2(p), hi = uint2(min(floor(p) + 1.0, dimensions - 1.0));
            float2 f = fract(p);
            raw = mix(mix(tex.read(lo).r, tex.read(uint2(hi.x, lo.y)).r, f.x),
                      mix(tex.read(uint2(lo.x, hi.y)).r, tex.read(hi).r, f.x), f.y);
        }
        if (raw >= 65535.0) return float4(1.0, 0.18, 0.14, 1.0);
        raw /= 65535.0;
        float t = saturate((raw - u.black) / max(u.white - u.black, 1e-6));
        if (u.mode > 0.5) {
            float a = clamp(u.amount, 0.1, 1500.0);
            t = asinh(a * t) / max(asinh(a), 1e-6);
        } else {
            float m = clamp(u.amount, 1e-4, 1.0 - 1e-4);
            if (t > 0.0 && t < 1.0 && abs(m - 0.5) > 1e-6)
                t = saturate(((m - 1.0) * t) / ((2.0 * m - 1.0) * t - m));
        }
        return float4(t, t, t, 1);
    }
    """

    public static let hlslVertex = """
    cbuffer QuadRect : register(b0, space1) { float x0, y0, x1, y1, u0, v0, u1, v1; };
    struct VertexOut { float4 position : SV_Position; float2 uv : TEXCOORD0; };
    VertexOut main(uint vid : SV_VertexID) {
        VertexOut o;
        o.position = float4((vid == 0 || vid == 2) ? x0 : x1, (vid == 0 || vid == 1) ? y1 : y0, 0, 1);
        o.uv = float2((vid == 0 || vid == 2) ? u0 : u1, (vid == 0 || vid == 1) ? v0 : v1);
        return o;
    }
    """

    public static let hlslFragment = """
    Texture2D<float> tex : register(t0, space2);
    cbuffer StretchUniforms : register(b0, space3) { float black, white, amount, nearest, mode, texW, texH, spare; };
    float4 main(float4 position : SV_Position, float2 uv : TEXCOORD0) : SV_Target {
        if (any(uv < 0.0) || any(uv >= 1.0)) return float4(0, 0, 0, 1);
        float2 dimensions = float2(texW, texH);
        float raw;
        if (nearest > 0.5) {
            raw = tex.Load(int3(min(uv * dimensions, dimensions - 1.0), 0));
        } else {
            float2 p = clamp(uv * dimensions - 0.5, 0.0, dimensions - 1.0);
            int2 lo = int2(p), hi = int2(min(floor(p) + 1.0, dimensions - 1.0));
            float2 f = frac(p);
            raw = lerp(lerp(tex.Load(int3(lo, 0)), tex.Load(int3(hi.x, lo.y, 0)), f.x),
                       lerp(tex.Load(int3(lo.x, hi.y, 0)), tex.Load(int3(hi, 0)), f.x), f.y);
        }
        if (raw >= 65535.0) return float4(1.0, 0.18, 0.14, 1.0);
        raw /= 65535.0;
        float t = saturate((raw - black) / max(white - black, 1e-6));
        if (mode > 0.5) {
            float a = clamp(amount, 0.1, 1500.0);
            float at = a * t;
            t = log(at + sqrt(at * at + 1.0)) / max(log(a + sqrt(a * a + 1.0)), 1e-6);
        } else {
            float m = clamp(amount, 1e-4, 1.0 - 1e-4);
            if (t > 0.0 && t < 1.0 && abs(m - 0.5) > 1e-6)
                t = saturate(((m - 1.0) * t) / ((2.0 * m - 1.0) * t - m));
        }
        return float4(t, t, t, 1);
    }
    """
}
