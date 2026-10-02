import CollimationCore
import Foundation

private func focusedGaussian(width: Double, shift: Double, seed: UInt64, skyRipple: Bool = false) -> Frame {
    let size = 128
    let center = SIMD2(64 + shift, 64 + shift * 0.7)
    var rng = RNG(seed: seed)
    var pixels = [UInt16](repeating: 0, count: size * size)
    for y in 0..<size {
        for x in 0..<size {
            let dx = Double(x) - center.x
            let dy = Double(y) - center.y
            let r = sqrt(dx * dx + dy * dy)
            // Smooth sky fluctuations create local minima well outside the core.
            let ripple = skyRipple ? 10 + 8 * cos(r * 0.8) : 0
            let value = 200 + ripple + 30_000 * exp(-r * r / (2 * width * width))
                + rng.gaussian() * 12
            pixels[y * size + x] = UInt16(min(65535, max(0, value.rounded())))
        }
    }
    return Frame(width: size, height: size, pixels: pixels,
                 roi: ROI(x: 0, y: 0, width: size, height: size))
}

func testCompactFocusedComa() throws {
    for width in [0.7, 0.85, 1.0] {
        for index in 0..<12 {
            let shift = Double(index) / 12
            let frame = focusedGaussian(width: width, shift: shift, seed: UInt64(index + 1))
            guard let result = ComaAnalyzer().analyze(frame: frame, detection: nil) else {
                throw UIModelExpectation(description: "compact star rejected: width \(width), shift \(shift)")
            }
            try expectUI(!result.isDonut && result.quality >= 0.4,
                         "focused width \(width), shift \(shift): donut \(result.isDonut), quality \(result.quality)")
            try expectUI(result.outer.radius >= 2 && result.outer.radius <= 4, "compact footprint \(result.outer.radius)")
            try expectUI(result.magnitudeNormalized < 0.15, "symmetric compact core \(result.magnitudeNormalized)")
        }
    }
}

func testFocusedComaIgnoresSkyMinima() throws {
    for index in 0..<12 {
        let frame = focusedGaussian(width: 1.1, shift: Double(index) / 12,
                                    seed: UInt64(index + 21), skyRipple: true)
        guard let detection = StarDetector().detect(in: frame),
              let result = ComaAnalyzer().analyze(frame: frame, detection: detection) else {
            throw UIModelExpectation(description: "expected a tracked focused star")
        }
        try expectUI(result.outer.radius < 5, "sky minimum mistaken for the core: \(result.outer.radius)")
        try expectUI(result.quality >= 0.4, "focused overlay remains usable")
    }
}

func testCompactAiryComa() throws {
    for firstMinimum in [2.7, 3.5, 5.0] {
        for index in 0..<8 {
            var rng = RNG(seed: UInt64(index + 41))
            let frame = AiryRenderer(scene: AiryScene(
                sensorWidth: 128, sensorHeight: 128,
                starPosition: SIMD2(64 + Double(index) / 8, 64.3),
                firstMinimumPixels: firstMinimum, peakADU: 30_000,
                backgroundADU: 200, noiseSigma: 12, seeingJitter: 0
            )).render(roi: ROI(x: 0, y: 0, width: 128, height: 128), jitter: .zero, rng: &rng)
            guard let result = ComaAnalyzer().analyze(frame: frame, detection: nil) else {
                throw UIModelExpectation(description: "compact Airy star rejected: minimum \(firstMinimum), frame \(index)")
            }
            try expectUI(!result.isDonut && result.quality >= 0.4, "compact Airy measurement")
            try expectUI(result.outer.radius <= firstMinimum + 1.5, "footprint follows the core \(result.outer.radius)")
        }
    }
}

func testFocusedComaRejectsArtifacts() throws {
    let size = 128
    let roi = ROI(x: 0, y: 0, width: size, height: size)
    var rng = RNG(seed: 71)
    let sky = (0..<(size * size)).map { _ in UInt16(max(0, (200 + rng.gaussian() * 12).rounded())) }
    for footprint in [0, 1, 2] {
        var pixels = sky
        for y in 64..<(64 + footprint) {
            for x in 64..<(64 + footprint) { pixels[y * size + x] = 40_000 }
        }
        let frame = Frame(width: size, height: size, pixels: pixels, roi: roi)
        try expectUI(ComaAnalyzer().analyze(frame: frame, detection: nil) == nil,
                   "noise or \(footprint)x\(footprint) hot pixels must not produce coma")
    }
    var faint = [UInt16](repeating: 200, count: size * size)
    for y in 63...65 {
        for x in 63...65 { faint[y * size + x] = 270 }
    }
    try expectUI(ComaAnalyzer().analyze(frame: Frame(width: size, height: size, pixels: faint, roi: roi),
                                     detection: nil) == nil, "weak compact patch is not a reliable measurement")
}

func testDonutComaWithCentralSpot() throws {
    var rng = RNG(seed: 81)
    let frame = DonutRenderer(scene: DonutScene(
        sensorWidth: 128, sensorHeight: 128, starPosition: SIMD2(64, 64),
        outerRadius: 30, innerRadius: 12, comaOffset: .zero,
        intensityAsymmetry: 0, noiseSigma: 12, seeingJitter: 0
    )).render(roi: ROI(x: 0, y: 0, width: 128, height: 128), jitter: .zero, rng: &rng)
    var pixels = frame.pixels
    for y in 62...66 {
        for x in 62...66 { pixels[y * frame.width + x] = 40_000 }
    }
    let withSpot = Frame(width: frame.width, height: frame.height, pixels: pixels, roi: frame.roi)
    guard let result = ComaAnalyzer().analyze(frame: withSpot, detection: StarDetector().detect(in: withSpot)) else {
        throw UIModelExpectation(description: "secondary shadow with a small bright spot rejected")
    }
    try expectUI(result.isDonut && result.quality >= 0.4, "retain donut analysis with a central spot")
    try expectUI(result.magnitudeNormalized < 0.08, "concentric donut remains concentric")
}

