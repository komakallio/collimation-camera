import CollimationCore
import CollimationUI
import Foundation

// The stretch maths exists four times: `StretchParams.apply` on the CPU, two
// MSL fragment shaders — `MetalRenderer.shaderSource` for the macOS release
// and `ShaderSource.metal` for the portable app — and the HLSL one
// (§12.1 item 6). No shader can be run from here, so this re-implements the
// maths in Swift, line for line, and checks it against the CPU version over a
// synthetic frame.
//
// What this cannot see is which shader strings the app actually contains: it
// re-implements them rather than reading them, so two shaders that disagree
// with each other both still pass. `stretch shader copies` is the test that
// reads the files.
//
// Everything runs in Float, not Double: that is what the GPU does, and it sets
// the tolerance.

/// Nearest-neighbour column of both shaders.
private func shaderNearest(
    frame: [UInt16],
    width: Int,
    height: Int,
    u: Float,
    v: Float
) -> UInt16 {
    let w = Float(width)
    let h = Float(height)
    let x = UInt32(min(max(u * w, 0), w - 1))
    let y = UInt32(min(max(v * h, 0), h - 1))
    return frame[Int(y) * width + Int(x)]
}

/// Bilinear column of both shaders, including the half-texel offset and the
/// clamp that keeps `p00 + 1` inside the texture.
private func shaderBilinear(
    frame: [UInt16],
    width: Int,
    height: Int,
    u: Float,
    v: Float
) -> Float {
    let w = Float(width)
    let h = Float(height)
    var coordX = u * w - 0.5
    var coordY = v * h - 0.5
    coordX = min(max(coordX, 0), w - 1.001)
    coordY = min(max(coordY, 0), h - 1.001)
    let x0 = Int(UInt32(coordX))
    let y0 = Int(UInt32(coordY))
    let x1 = Int(UInt32(min(coordX + 1, w - 1)))
    let y1 = Int(UInt32(min(coordY + 1, h - 1)))
    let fx = coordX - coordX.rounded(.down)
    let fy = coordY - coordY.rounded(.down)
    let a00 = Float(frame[y0 * width + x0])
    let a10 = Float(frame[y0 * width + x1])
    let a01 = Float(frame[y1 * width + x0])
    let a11 = Float(frame[y1 * width + x1])
    let top = a00 + (a10 - a00) * fx
    let bottom = a01 + (a11 - a01) * fx
    return top + (bottom - top) * fy
}

/// MSL: `asinh`. HLSL has no such intrinsic and uses the log form.
private func hlslAsinh(_ x: Float) -> Float {
    log(x + (x * x + 1).squareRoot())
}

/// The tail of both fragment shaders, from `raw` to the grey level.
private func shaderCurve(_ raw: Float, _ params: StretchParams, hlsl: Bool) -> Float {
    let black = Float(params.black)
    let white = Float(max(params.white, params.black + 0.0005))
    var t = min(max((raw - black) / max(white - black, 1e-6), 0), 1)
    switch params.curve {
    case .arcsinh:
        // The renderer clamps the factor before pushing it, so the shader
        // never sees one outside the range.
        let clamped = Float(
            min(max(params.arcsinh, StretchParams.arcsinhRange.lowerBound), StretchParams.arcsinhRange.upperBound)
        )
        let a = max(clamped, 1e-4)
        t = hlsl
            ? hlslAsinh(a * t) / max(hlslAsinh(a), 1e-6)
            : asinh(a * t) / max(asinh(a), 1e-6)
    case .mtf:
        let m = Float(min(max(params.midtones, 1e-4), 1 - 1e-4))
        if t > 0, t < 1, abs(m - 0.5) > 1e-6 {
            t = min(max(((m - 1) * t) / ((2 * m - 1) * t - m), 0), 1)
        }
    }
    return t
}

/// A 64×64 frame: a diagonal ramp over the whole 16-bit range, a flat
/// background block, and one saturated pixel for the clip rule.
private func syntheticFrame(width: Int, height: Int) -> [UInt16] {
    var pixels = [UInt16](repeating: 0, count: width * height)
    for y in 0..<height {
        for x in 0..<width {
            let ramp = Double(x + y) / Double(width + height - 2)
            pixels[y * width + x] = UInt16(ramp * 65535)
        }
    }
    for y in 8..<16 {
        for x in 8..<16 {
            pixels[y * width + x] = 900
        }
    }
    pixels[40 * width + 40] = 0xFFFF
    return pixels
}

func testStretchShaderMath() throws {
    let width = 64
    let height = 64
    let frame = syntheticFrame(width: width, height: height)

    let cases: [StretchParams] = [
        StretchParams(black: 0, white: 1, midtones: 0.5, curve: .mtf),
        StretchParams(black: 0.01, white: 1, midtones: 0.25, curve: .mtf),
        StretchParams(black: 0.002, white: 0.6, midtones: 0.05, curve: .mtf),
        StretchParams(black: 0, white: 1, arcsinh: 0.1, curve: .arcsinh),
        StretchParams(black: 0.01, white: 1, arcsinh: 10, curve: .arcsinh),
        StretchParams(black: 0.004, white: 0.8, arcsinh: 1_500, curve: .arcsinh),
    ]

    // Float has ~7 decimal digits, and the curves amplify the difference near
    // the black point, so this is the practical bound rather than eps.
    let tolerance: Float = 3e-4

    for params in cases {
        var worst: Float = 0
        for y in 0..<height {
            for x in 0..<width {
                // Sample the texel centre, which is what the nearest column
                // does for a 1:1 zoom.
                let u = (Float(x) + 0.5) / Float(width)
                let v = (Float(y) + 0.5) / Float(height)

                let adu = shaderNearest(frame: frame, width: width, height: height, u: u, v: v)
                try expectUI(
                    adu == frame[y * width + x],
                    "nearest sampling hit \(adu) instead of \(frame[y * width + x]) at \(x),\(y)"
                )

                // The clip rule short-circuits before the curve in both
                // shaders, so those pixels are excluded from the comparison.
                if adu >= StarQuality.clipADU { continue }

                let raw = Float(adu) / 65535
                let cpu = Float(params.apply(normalizedValue: Double(raw)))
                let msl = shaderCurve(raw, params, hlsl: false)
                let hlsl = shaderCurve(raw, params, hlsl: true)
                worst = max(worst, abs(cpu - msl))
                worst = max(worst, abs(cpu - hlsl))
                worst = max(worst, abs(msl - hlsl))
            }
        }
        try expectUI(
            worst < tolerance,
            "curve \(params.curve) black \(params.black): worst difference \(worst)"
        )
    }

    // The bilinear column against a Swift reference, at points that are not
    // texel centres so the weights are actually exercised.
    for params in cases.prefix(2) {
        for (u, v) in [(0.0 as Float, 0.0 as Float), (0.5, 0.5), (0.123, 0.777), (1.0, 1.0)] {
            let value = shaderBilinear(frame: frame, width: width, height: height, u: u, v: v)
            try expectUI(value >= 0 && value <= 65535, "bilinear \(value) out of range at \(u),\(v)")

            let raw = value / 65535
            let msl = shaderCurve(raw, params, hlsl: false)
            let hlsl = shaderCurve(raw, params, hlsl: true)
            try expectUI(abs(msl - hlsl) < tolerance, "bilinear columns differ by \(abs(msl - hlsl))")
        }
    }

    // Corners stay inside the texture. The half-texel offset puts u = 0 exactly
    // on the first texel; u = 1 lands 0.999 of the way to the last one, which
    // is what the clamp to `w - 1.001` is for — one texel short of the edge
    // rather than one past it.
    try expectUI(
        shaderBilinear(frame: frame, width: width, height: height, u: 0, v: 0) == Float(frame[0]),
        "top-left corner"
    )
    let last = Float(frame[(height - 1) * width + width - 1])
    let inward = Float(frame[(height - 2) * width + width - 2])
    let corner = shaderBilinear(frame: frame, width: width, height: height, u: 1, v: 1)
    try expectUI(
        corner <= last && corner > inward,
        "bottom-right corner \(corner) outside \(inward)...\(last)"
    )
    try expectUI(last - corner < 0.01 * (last - inward), "bottom-right corner not close enough to \(last)")

    // HLSL's log form of asinh over the domain the shader uses: t in 0...1
    // scaled by the factor, so the argument reaches the top of arcsinhRange.
    var worstAsinh: Float = 0
    for step in 0...2_000 {
        let x = Float(step) / 2_000 * Float(StretchParams.arcsinhRange.upperBound)
        worstAsinh = max(worstAsinh, abs(hlslAsinh(x) - asinh(x)))
    }
    try expectUI(worstAsinh < 1e-5, "asinh log form differs by \(worstAsinh)")

    // The clip threshold both shaders compare against.
    try expectUI(StarQuality.clipADU == 0xFFF0, "clip threshold \(StarQuality.clipADU)")
}
