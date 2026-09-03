import CollimationCore
import Foundation

@main
struct CoreTests {
    static func main() {
        var failures = 0
        failures += run("histogram percentiles", testHistogramPercentiles)
        failures += run("auto stretch", testAutoStretch)
        failures += run("mtf identity", testMTFIdentityAtHalf)
        failures += run("arcsinh stretch", testArcsinhStretch)
        failures += run("star detection", testStarDetection)
        failures += run("large donut detection", testLargeDonutDetection)
        failures += run("moment centroid", testMomentCentroid)
        failures += run("empty sky", testEmptySky)
        failures += run("star fwhm", testStarFWHM)
        failures += run("telescope optics from camera name", testTelescopeOpticsFromCameraName)
        failures += run("airy diffraction", testAiryDiffraction)
        failures += run("airy simulator device", testAirySimulatorDevice)
        failures += run("circle fit", testCircleFit)
        failures += run("coma horizontal", testComaHorizontal)
        failures += run("coma vertical", testComaVertical)
        failures += run("concentric donut", testConcentric)
        failures += run("in-focus coma horizontal", testInFocusComaHorizontal)
        failures += run("in-focus coma symmetric", testInFocusComaSymmetric)
        failures += run("airy coma footprint", testAiryComaFootprint)
        failures += run("airy coma large footprint", testAiryComaLargeFootprint)
        failures += run("coma ring size on crop", testComaRingSizeOnCrop)
        failures += run("tracker recenter", testTrackerRecenter)
        failures += run("tracker hold when lost", testTrackerHoldWhenLost)
        failures += run("tracker auto search", testTrackerAutoSearch)
        failures += run("search recovery", testSearchRecovery)
        failures += run("software crop", testSoftwareCrop)
        failures += run("readout fps cap", testReadoutFPSCap)
        failures += run("sensor center overlay", testSensorCenterOverlay)
        failures += run("auto exposure", testAutoExposure)
        failures += run("star quality from peak", testStarQuality)
        failures += run("star intensity profile", testStarIntensityProfile)
        failures += run("digital stabilize pan", testDigitalStabilizePan)
        failures += run("digital stabilize hold", testDigitalStabilizeHold)
        failures += run("digital stabilize size change relocks", testDigitalStabilizeSizeChangeRelocks)
        failures += run("digital stabilize disable", testDigitalStabilizeDisable)
        failures += run("digital stabilize process frame", testDigitalStabilizeProcessFrame)
        failures += run("digital stabilize lost ignores noise", testDigitalStabilizeLostIgnoresNoise)
        failures += run("digital stabilize search then crop", testDigitalStabilizeSearchThenCrop)
        failures += run("guide solve orthogonal", testGuideSolveOrthogonal)
        failures += run("guide solve rotated", testGuideSolveRotated)
        failures += run("guide solve singular", testGuideSolveSingular)
        failures += run("guide pulse planner", testGuidePulsePlanner)
        failures += run("guide center threshold", testGuideCenterThreshold)
        failures += run("lx200 pulse command", testLX200PulseCommand)
        failures += run("skywatcher hex24", testSkyWatcherHex24)
        failures += run("skywatcher slow slew", testSkyWatcherSlowSlew)
        failures += run("guide nudge slice", testGuideNudgeSlice)
        failures += run("synscan fixed rate", testSynScanFixedRate)
        failures += run("guide calibration store", testGuideCalibrationStore)
        failures += run("guide slew axes", testGuideSlewAxes)
        failures += run("guide slew commit", testGuideSlewCommit)
        failures += run("synscan pad nudge", testSynScanPadNudge)
        failures += run("axis centering", testAxisCentering)
        failures += run("filter slot display name", testFilterSlotDisplayName)
        failures += run("filter wheel error text", testFilterWheelErrorText)
        failures += run("mono tiff 16-bit", testMonoTIFF)
        failures += run("mono tiff 32-bit float", testMonoTIFFFloat32)
        failures += run("frame stacker", testFrameStacker)

        if failures == 0 {
            print("All tests passed.")
            exit(0)
        } else {
            print("\(failures) test(s) failed.")
            exit(1)
        }
    }

    private static func run(_ name: String, _ body: () throws -> Void) -> Int {
        do {
            try body()
            print("ok  \(name)")
            return 0
        } catch {
            print("FAIL  \(name): \(error)")
            return 1
        }
    }
}

private struct Expectation: Error, CustomStringConvertible {
    var description: String
}

private func expect(_ condition: Bool, _ message: String) throws {
    if !condition { throw Expectation(description: message) }
}

private func testHistogramPercentiles() throws {
    var pixels = [UInt16](repeating: 1000, count: 1000)
    for i in 0..<10 { pixels[i] = 0 }
    for i in 990..<1000 { pixels[i] = 65535 }
    let frame = Frame(width: 100, height: 10, pixels: pixels, roi: ROI(x: 0, y: 0, width: 100, height: 10))
    let histogram = Histogram.compute(from: frame)
    try expect(histogram.sampleCount == 1000, "sample count")
    try expect(histogram.percentile(0.5) > 0.01 && histogram.percentile(0.5) < 0.1, "median")
    try expect(histogram.percentile(0.995) > 0.9, "high percentile")
}

private func testAutoStretch() throws {
    var pixels = [UInt16](repeating: 800, count: 256 * 256)
    for i in 0..<200 { pixels[i] = 40_000 }
    let frame = Frame(width: 256, height: 256, pixels: pixels, roi: ROI(x: 0, y: 0, width: 256, height: 256))
    let stretch = StretchParams.auto(from: Histogram.compute(from: frame))
    try expect(abs(stretch.white - 1) < 1e-12, "white stays at 100%")
    try expect(stretch.black >= StretchParams.blackRange.lowerBound && stretch.black <= StretchParams.blackRange.upperBound, "black \(stretch.black)")
    try expect(stretch.midtones >= 0.01 && stretch.midtones <= 0.6, "midtones \(stretch.midtones)")
}

private func testMTFIdentityAtHalf() throws {
    for x in [0.0, 0.25, 0.5, 0.75, 1.0] {
        try expect(abs(StretchParams.mtf(x, midtones: 0.5) - x) < 1e-9, "linear \(x)")
    }
    try expect(StretchParams.mtf(0, midtones: 0.2) == 0, "black")
    try expect(StretchParams.mtf(1, midtones: 0.2) == 1, "white")
    let lifted = StretchParams.mtf(0.25, midtones: 0.2)
    try expect(lifted > 0.25, "m<0.5 lifts midtones (\(lifted))")
}

private func testArcsinhStretch() throws {
    try expect(StretchParams.arcsinh(0, factor: 12) == 0, "black")
    try expect(StretchParams.arcsinh(1, factor: 12) == 1, "white")
    for x in [0.0, 0.25, 0.5, 0.75, 1.0] {
        let y = StretchParams.arcsinh(x, factor: StretchParams.arcsinhRange.lowerBound)
        try expect(abs(y - x) < 0.02, "small factor nearly linear \(x) -> \(y)")
    }
    let lifted = StretchParams.arcsinh(0.1, factor: 40)
    try expect(lifted > 0.1, "large factor lifts shadows (\(lifted))")
    try expect(lifted < StretchParams.arcsinh(0.3, factor: 40), "monotonic")

    let factor = StretchParams.arcsinhFactor(mapping: 0.05, to: 0.25)
    let mapped = StretchParams.arcsinh(0.05, factor: factor)
    try expect(abs(mapped - 0.25) < 0.01, "auto factor maps 0.05 -> 0.25 (\(mapped), α=\(factor))")

    var pixels = [UInt16](repeating: 800, count: 256 * 256)
    for i in 0..<200 { pixels[i] = 40_000 }
    let frame = Frame(width: 256, height: 256, pixels: pixels, roi: ROI(x: 0, y: 0, width: 256, height: 256))
    let stretch = StretchParams.auto(from: Histogram.compute(from: frame), curve: .arcsinh)
    try expect(stretch.curve == .arcsinh, "curve")
    try expect(abs(stretch.white - 1) < 1e-12, "white")
    try expect(stretch.arcsinh >= StretchParams.arcsinhRange.lowerBound, "factor \(stretch.arcsinh)")
    let sample = stretch.black + 0.05 * max(stretch.white - stretch.black, 1e-6)
    let displayed = stretch.apply(normalizedValue: sample)
    try expect(displayed > 0.05, "arcsinh lifts 5% linear (\(displayed), α=\(stretch.arcsinh))")
}

private func testStarDetection() throws {
    let scene = DonutScene(
        sensorWidth: 256,
        sensorHeight: 256,
        starPosition: SIMD2(180, 96),
        outerRadius: 28,
        innerRadius: 10,
        comaOffset: .zero,
        intensityAsymmetry: 0,
        noiseSigma: 12,
        seeingJitter: 0
    )
    let renderer = DonutRenderer(scene: scene)
    var rng = RNG(seed: 7)
    let frame = renderer.render(roi: ROI(x: 0, y: 0, width: 256, height: 256), jitter: .zero, rng: &rng)
    guard let detection = StarDetector().detect(in: frame) else {
        throw Expectation(description: "expected detection")
    }
    try expect(abs(detection.centroid.x - 180) < 6, "x \(detection.centroid.x)")
    try expect(abs(detection.centroid.y - 96) < 6, "y \(detection.centroid.y)")
    try expect(detection.snr > 10, "snr \(detection.snr)")
}

private func testLargeDonutDetection() throws {
    // 4× PowerMate on a 2.9 µm sensor makes a collimation donut hundreds of
    // pixels across. Detection used to search only a 768-pixel box around the
    // bright rim, which misses the rest of the annulus.
    let size = 1100
    let center = SIMD2(550.0, 540.0)
    let scene = DonutScene(
        sensorWidth: size,
        sensorHeight: size,
        starPosition: center,
        outerRadius: 260,
        innerRadius: 90,
        comaOffset: .zero,
        intensityAsymmetry: 0,
        noiseSigma: 12,
        seeingJitter: 0
    )
    var rng = RNG(seed: 11)
    let frame = DonutRenderer(scene: scene).render(
        roi: ROI(x: 0, y: 0, width: size, height: size),
        jitter: .zero,
        rng: &rng
    )
    guard let detection = StarDetector().detect(in: frame) else {
        throw Expectation(description: "expected large donut")
    }
    try expect(abs(detection.centroid.x - center.x) < 20, "x \(detection.centroid.x)")
    try expect(abs(detection.centroid.y - center.y) < 20, "y \(detection.centroid.y)")
    guard let seeded = StarDetector().detect(in: frame, around: center) else {
        throw Expectation(description: "expected seeded large donut")
    }
    try expect(abs(seeded.centroid.x - center.x) < 20, "seeded x \(seeded.centroid.x)")
}

private func testMomentCentroid() throws {
    let scene = DonutScene(
        sensorWidth: 256,
        sensorHeight: 256,
        starPosition: SIMD2(180, 96),
        outerRadius: 28,
        innerRadius: 10,
        comaOffset: .zero,
        intensityAsymmetry: 0,
        noiseSigma: 12,
        seeingJitter: 0
    )
    var renderer = DonutRenderer(scene: scene)
    var rng = RNG(seed: 7)
    let roi = ROI(x: 0, y: 0, width: 256, height: 256)
    let frame = renderer.render(roi: roi, jitter: .zero, rng: &rng)
    let detector = StarDetector()
    guard let seeded = detector.momentCentroid(in: frame, around: SIMD2(176, 92)) else {
        throw Expectation(description: "expected windowed centroid")
    }
    try expect(abs(seeded.x - 180) < 6, "seeded x \(seeded.x)")
    try expect(abs(seeded.y - 96) < 6, "seeded y \(seeded.y)")

    guard let full = detector.momentCentroid(in: frame, around: nil) else {
        throw Expectation(description: "expected full-frame centroid")
    }
    try expect(abs(full.x - 180) < 8, "full x \(full.x)")
    try expect(abs(full.y - 96) < 8, "full y \(full.y)")

    renderer.scene.starPosition = SIMD2(188, 90)
    let moved = renderer.render(roi: roi, jitter: .zero, rng: &rng)
    guard let next = detector.momentCentroid(in: moved, around: seeded) else {
        throw Expectation(description: "expected refined centroid")
    }
    try expect(abs(next.x - 188) < 6, "moved x \(next.x)")
    try expect(abs(next.y - 90) < 6, "moved y \(next.y)")
}

private func testEmptySky() throws {
    let pixels = [UInt16](repeating: 900, count: 128 * 128)
    let frame = Frame(width: 128, height: 128, pixels: pixels, roi: ROI(x: 0, y: 0, width: 128, height: 128))
    try expect(StarDetector().detect(in: frame) == nil, "false positive")
}

private func testStarFWHM() throws {
    let sigma = 4.0
    let expected = 2.0 * sqrt(2.0 * log(2.0)) * sigma
    let width = 128
    let height = 128
    let cx = 63.5
    let cy = 63.5
    var pixels = [UInt16](repeating: 800, count: width * height)
    for y in 0..<height {
        for x in 0..<width {
            let dx = Double(x) - cx
            let dy = Double(y) - cy
            let amp = 40_000.0 * exp(-(dx * dx + dy * dy) / (2 * sigma * sigma))
            pixels[y * width + x] = UInt16(min(65535, 800 + amp))
        }
    }
    let frame = Frame(
        width: width,
        height: height,
        pixels: pixels,
        roi: ROI(x: 0, y: 0, width: width, height: height, binning: 1)
    )
    guard let fwhm = FWHMEstimator().measure(frame: frame, centroid: SIMD2(cx, cy)) else {
        throw Expectation(description: "expected FWHM")
    }
    try expect(abs(fwhm.framePixels - expected) < 0.6, "FWHM px \(fwhm.framePixels) vs \(expected)")
    try expect(abs(fwhm.sensorPixels - fwhm.framePixels) < 1e-12, "bin1 sensor")
    let scale = 206.264806247 * 3.76 / 1600.0
    try expect(abs(TelescopeOptics.arcsecondsPerUnbinnedPixel - scale) < 1e-12, "plate scale")
    try expect(abs(fwhm.arcseconds - fwhm.sensorPixels * scale) < 1e-9, "arcsec \(fwhm.arcseconds)")

    let binned = Frame(
        width: width,
        height: height,
        pixels: pixels,
        roi: ROI(x: 0, y: 0, width: width, height: height, binning: 2)
    )
    guard let fwhm2 = FWHMEstimator().measure(frame: binned, centroid: SIMD2(cx, cy)) else {
        throw Expectation(description: "expected binned FWHM")
    }
    try expect(abs(fwhm2.sensorPixels - fwhm2.framePixels * 2) < 1e-12, "bin2 sensor")
    try expect(abs(fwhm2.arcseconds - fwhm2.sensorPixels * scale) < 1e-9, "bin2 arcsec")

    guard let xena = FWHMEstimator().measure(
        frame: frame,
        centroid: SIMD2(cx, cy),
        optics: .xena585M
    ) else {
        throw Expectation(description: "expected Xena FWHM")
    }
    let xenaScale = 206.264806247 * 2.9 / (1600.0 * 4.0)
    try expect(abs(TelescopeOptics.xena585M.arcsecondsPerUnbinnedPixel - xenaScale) < 1e-12, "xena scale")
    try expect(abs(xena.arcseconds - xena.sensorPixels * xenaScale) < 1e-9, "xena arcsec \(xena.arcseconds)")
    try expect(abs(xena.framePixels - fwhm.framePixels) < 1e-12, "pixels unchanged")
}

private func testTelescopeOpticsFromCameraName() throws {
    try expect(TelescopeOptics.forCameraName("Xena-M") == .xena585M, "Xena-M")
    try expect(TelescopeOptics.forCameraName("Player One Xena") == .xena585M, "Xena substring")
    try expect(TelescopeOptics.forCameraName("xena 585m") == .xena585M, "case")
    try expect(TelescopeOptics.forCameraName("Poseidon-M") == .poseidon, "Poseidon-M")
    try expect(TelescopeOptics.forCameraName("POSEIDON") == .poseidon, "POSEIDON")
    try expect(TelescopeOptics.forCameraName("Simulator (Airy)") == .poseidon, "simulator default")
    try expect(TelescopeOptics.xena585M.pixelSizeMicrons == 2.9, "2.9 µm")
    try expect(TelescopeOptics.xena585M.barlow == 4, "4× Barlow")
    try expect(TelescopeOptics.poseidon.pixelSizeMicrons == 3.76, "3.76 µm")
    try expect(TelescopeOptics.poseidon.barlow == 1, "no Barlow")
}

private func testAiryDiffraction() throws {
    let firstMin = 10.0
    let renderer = AiryRenderer(
        scene: AiryScene(
            sensorWidth: 256,
            sensorHeight: 256,
            starPosition: SIMD2(128, 128),
            firstMinimumPixels: firstMin,
            peakADU: 40_000,
            backgroundADU: 800,
            noiseSigma: 0,
            seeingJitter: 0
        )
    )
    try expect(abs(renderer.intensity(atRadiusPixels: 0) - 1) < 1e-9, "core")
    try expect(renderer.intensity(atRadiusPixels: firstMin) < 0.002, "first min \(renderer.intensity(atRadiusPixels: firstMin))")
    try expect(renderer.intensity(atRadiusPixels: firstMin * 0.4) > 0.4, "inside Airy disk")
    let firstRing = firstMin * (5.135622 / AiryScene.j1FirstZero)
    let ringI = renderer.intensity(atRadiusPixels: firstRing)
    try expect(ringI > 0.012 && ringI < 0.025, "first ring \(ringI)")
    try expect(ringI > renderer.intensity(atRadiusPixels: firstMin), "ring after dark")

    var rng = RNG(seed: 3)
    let frame = renderer.render(
        roi: ROI(x: 0, y: 0, width: 256, height: 256),
        jitter: .zero,
        rng: &rng
    )
    let core = Double(frame.pixel(x: 128, y: 128))
    try expect(core > 35_000, "core ADU \(core)")
    let dark = Double(frame.pixel(x: 128 + Int(firstMin.rounded()), y: 128))
    try expect(dark < core * 0.08, "dark ring ADU \(dark)")
    guard let detection = StarDetector().detect(in: frame) else {
        throw Expectation(description: "expected Airy star")
    }
    try expect(abs(detection.centroid.x - 128) < 2, "x \(detection.centroid.x)")
    try expect(abs(detection.centroid.y - 128) < 2, "y \(detection.centroid.y)")
}

private func testAirySimulatorDevice() throws {
    let ids = Set(DeviceCatalog.list().map(\.id))
    try expect(ids.contains(CameraDescriptor.simulator.id), "donut simulator")
    try expect(ids.contains(CameraDescriptor.airySimulator.id), "Airy simulator")
    let device = try DeviceCatalog.makeDevice(id: CameraDescriptor.airySimulator.id)
    try expect(device.descriptor.name.contains("Airy"), "name \(device.descriptor.name)")
    try expect(device.descriptor.isSimulator, "simulator flag")
}

private func testCircleFit() throws {
    var points: [SIMD2<Double>] = []
    let center = SIMD2(40.0, 55.0)
    let radius = 22.0
    for i in 0..<72 {
        let t = Double(i) / 72.0 * 2 * .pi
        points.append(SIMD2(center.x + cos(t) * radius, center.y + sin(t) * radius))
    }
    guard let fit = CircleFit.fit(points: points) else {
        throw Expectation(description: "fit failed")
    }
    try expect(abs(fit.center.x - center.x) < 0.2, "cx")
    try expect(abs(fit.center.y - center.y) < 0.2, "cy")
    try expect(abs(fit.radius - radius) < 0.2, "r")
}

private func analyze(offset: SIMD2<Double>, asymmetry: Double = 0.3) -> ComaResult? {
    let scene = DonutScene(
        sensorWidth: 320,
        sensorHeight: 320,
        starPosition: SIMD2(160, 160),
        outerRadius: 58,
        innerRadius: 22,
        comaOffset: offset,
        intensityAsymmetry: asymmetry,
        peakADU: 48_000,
        backgroundADU: 700,
        noiseSigma: 10,
        seeingJitter: 0
    )
    let renderer = DonutRenderer(scene: scene)
    var rng = RNG(seed: 11)
    let frame = renderer.render(roi: ROI(x: 0, y: 0, width: 320, height: 320), jitter: .zero, rng: &rng)
    return ComaAnalyzer().analyze(frame: frame, detection: StarDetector().detect(in: frame))
}

private func minAngleDelta(_ a: Double, _ b: Double) -> Double {
    var d = abs(a - b).truncatingRemainder(dividingBy: 360)
    if d > 180 { d = 360 - d }
    return d
}

private func testComaHorizontal() throws {
    guard let result = analyze(offset: SIMD2(4.5, 0)) else {
        throw Expectation(description: "analysis failed")
    }
    try expect(abs(result.magnitudePixels - 4.5) < 2.0, "mag px \(result.magnitudePixels)")
    try expect(minAngleDelta(result.directionDegrees, 0) < 20, "dir \(result.directionDegrees)")
    try expect(result.magnitudeNormalized > 0.04, "norm \(result.magnitudeNormalized)")
    try expect(result.isDonut, "donut method")
}

private func testComaVertical() throws {
    guard let result = analyze(offset: SIMD2(0, 5.0)) else {
        throw Expectation(description: "analysis failed")
    }
    try expect(minAngleDelta(result.directionDegrees, 90) < 25, "dir \(result.directionDegrees)")
    try expect(result.magnitudePixels > 2, "mag \(result.magnitudePixels)")
}

private func testConcentric() throws {
    guard let result = analyze(offset: .zero, asymmetry: 0) else {
        throw Expectation(description: "analysis failed")
    }
    try expect(result.magnitudeNormalized < 0.08, "norm \(result.magnitudeNormalized)")
}

private func testInFocusComaHorizontal() throws {
    let frame = inFocusStarFrame(brightnessOffset: SIMD2(1, 0))
    guard let result = ComaAnalyzer().analyze(frame: frame, detection: StarDetector().detect(in: frame)) else {
        throw Expectation(description: "expected in-focus coma")
    }
    try expect(result.isDonut == false, "should use in-focus method")
    try expect(result.quality >= 0.4, "quality \(result.quality)")
    try expect(result.magnitudePixels > 0.15, "mag \(result.magnitudePixels)")
    try expect(minAngleDelta(result.directionDegrees, 0) < 25, "dir \(result.directionDegrees)")
}

private func testInFocusComaSymmetric() throws {
    let frame = inFocusStarFrame(brightnessOffset: .zero)
    guard let result = ComaAnalyzer().analyze(frame: frame, detection: StarDetector().detect(in: frame)) else {
        throw Expectation(description: "expected symmetric in-focus coma")
    }
    try expect(result.isDonut == false, "in-focus")
    try expect(result.magnitudeNormalized < 0.08, "norm \(result.magnitudeNormalized)")
}

private func testAiryComaFootprint() throws {
    let firstMin = 10.0
    let center = SIMD2(128.0, 128.0)
    var rng = RNG(seed: 5)
    let symmetric = AiryRenderer(
        scene: AiryScene(
            sensorWidth: 256,
            sensorHeight: 256,
            starPosition: center,
            firstMinimumPixels: firstMin,
            peakADU: 40_000,
            backgroundADU: 800,
            noiseSigma: 0,
            seeingJitter: 0
        )
    ).render(roi: ROI(x: 0, y: 0, width: 256, height: 256), jitter: .zero, rng: &rng)
    guard let concentric = ComaAnalyzer().analyze(
        frame: symmetric,
        detection: StarDetector().detect(in: symmetric)
    ) else {
        throw Expectation(description: "expected Airy coma")
    }
    try expect(concentric.isDonut == false, "in-focus")
    try expect(abs(concentric.outer.radius - firstMin) < 2.0, "footprint \(concentric.outer.radius) vs \(firstMin)")
    try expect(concentric.magnitudeNormalized < 0.08, "symmetric \(concentric.magnitudeNormalized)")

    rng = RNG(seed: 5)
    let flared = AiryRenderer(
        scene: AiryScene(
            sensorWidth: 256,
            sensorHeight: 256,
            starPosition: center,
            firstMinimumPixels: firstMin,
            peakADU: 40_000,
            backgroundADU: 800,
            noiseSigma: 0,
            seeingJitter: 0,
            intensityAsymmetry: 0.55
        )
    ).render(roi: ROI(x: 0, y: 0, width: 256, height: 256), jitter: .zero, rng: &rng)
    guard let coma = ComaAnalyzer().analyze(
        frame: flared,
        detection: StarDetector().detect(in: flared)
    ) else {
        throw Expectation(description: "expected flared Airy coma")
    }
    try expect(coma.isDonut == false, "in-focus flare")
    try expect(abs(coma.outer.radius - firstMin) < 2.5, "flare footprint \(coma.outer.radius)")
    try expect(coma.magnitudePixels > 0.08, "mag \(coma.magnitudePixels)")
    try expect(minAngleDelta(coma.directionDegrees, 0) < 30, "dir \(coma.directionDegrees)")
}

private func testAiryComaLargeFootprint() throws {
    let firstMin = 32.0
    let center = SIMD2(128.0, 128.0)
    var rng = RNG(seed: 9)
    let frame = AiryRenderer(
        scene: AiryScene(
            sensorWidth: 256,
            sensorHeight: 256,
            starPosition: center,
            firstMinimumPixels: firstMin,
            peakADU: 40_000,
            backgroundADU: 800,
            noiseSigma: 0,
            seeingJitter: 0
        )
    ).render(roi: ROI(x: 0, y: 0, width: 256, height: 256), jitter: .zero, rng: &rng)
    guard let result = ComaAnalyzer().analyze(
        frame: frame,
        detection: StarDetector().detect(in: frame)
    ) else {
        throw Expectation(description: "expected large Airy coma")
    }
    try expect(result.isDonut == false, "in-focus")
    try expect(abs(result.outer.radius - firstMin) < 3.0, "footprint \(result.outer.radius) vs \(firstMin)")
    try expect(result.magnitudeNormalized < 0.08, "symmetric \(result.magnitudeNormalized)")
}

/// Circular star whose brightness can be shifted so the photocenter leaves the geometric center.
private func inFocusStarFrame(brightnessOffset: SIMD2<Double>) -> Frame {
    let size = 256
    let cx = 128.0
    let cy = 128.0
    let radius = 16.0
    var pixels = [UInt16](repeating: 800, count: size * size)
    let peak = 40_000.0
    for y in 0..<size {
        for x in 0..<size {
            let dx = Double(x) - cx
            let dy = Double(y) - cy
            let r = sqrt(dx * dx + dy * dy)
            if r > radius { continue }
            let falloff = max(0, 1 - r / radius)
            var signal = peak * falloff * falloff
            if brightnessOffset != .zero {
                let along = dx * brightnessOffset.x + dy * brightnessOffset.y
                signal *= 1 + 0.55 * max(-1, min(1, along / radius))
            }
            pixels[y * size + x] = UInt16(min(65535, 800 + signal.rounded()))
        }
    }
    return Frame(
        width: size,
        height: size,
        pixels: pixels,
        roi: ROI(x: 0, y: 0, width: size, height: size)
    )
}

private func testComaRingSizeOnCrop() throws {
    let size = 2048
    let center = SIMD2(1024.0, 1024.0)
    let outerR = 48.0
    let innerR = 18.0
    let scene = DonutScene(
        sensorWidth: size,
        sensorHeight: size,
        starPosition: center,
        outerRadius: outerR,
        innerRadius: innerR,
        comaOffset: SIMD2(3.5, -2.0),
        intensityAsymmetry: 0.28,
        peakADU: 42_000,
        backgroundADU: 900,
        noiseSigma: 12,
        seeingJitter: 0
    )
    var rng = RNG(seed: 42)
    let frame = DonutRenderer(scene: scene).render(
        roi: ROI(x: 0, y: 0, width: size, height: size),
        jitter: .zero,
        rng: &rng
    )
    let crop = CaptureLayout.analysisFrame(from: frame, seed: center)
    guard let detection = StarDetector().detect(in: crop) else {
        throw Expectation(description: "expected detection on 512 crop")
    }
    guard let coma = ComaAnalyzer().analyze(frame: crop, detection: detection) else {
        throw Expectation(description: "expected coma on 512 crop")
    }
    try expect(abs(coma.outer.radius - outerR) < 10, "outer \(coma.outer.radius) vs \(outerR)")
    try expect(abs(coma.inner.radius - innerR) < 10, "inner \(coma.inner.radius) vs \(innerR)")
}

private func testTrackerRecenter() throws {
    var tracker = Tracker(config: TrackingConfig(recenterThreshold: 0.15, minRecenterInterval: 0))
    let frame = Frame(
        width: 128,
        height: 128,
        pixels: [UInt16](repeating: 800, count: 128 * 128),
        roi: ROI(x: 100, y: 100, width: 128, height: 128)
    )
    let detection = StarDetection(
        centroid: SIMD2(20, 20),
        peak: 50_000,
        flux: 50_000,
        area: 40,
        background: 800,
        sigma: 20
    )
    let status = tracker.process(
        frame: frame,
        detection: detection,
        autoCenter: true,
        autoSearch: false,
        trackingROISize: 128,
        sensorWidth: 6252,
        sensorHeight: 4176
    )
    try expect(status.state == TrackingState.tracking, "state")
    try expect(status.requestedROI != nil, "requested ROI")
}

private func testTrackerHoldWhenLost() throws {
    var tracker = Tracker(config: TrackingConfig(lostFrameLimit: 3))
    let frame = Frame(
        width: 64,
        height: 64,
        pixels: [UInt16](repeating: 800, count: 64 * 64),
        roi: ROI(x: 0, y: 0, width: 64, height: 64)
    )
    var last = TrackingStatus()
    for _ in 0..<8 {
        last = tracker.process(
            frame: frame,
            detection: nil,
            autoCenter: true,
            autoSearch: false,
            trackingROISize: 256,
            sensorWidth: 6252,
            sensorHeight: 4176
        )
    }
    try expect(last.state == TrackingState.lost, "stay lost when auto-search is off")
    try expect(last.requestedROI == nil, "do not switch to a search ROI")
}

private func testTrackerAutoSearch() throws {
    var tracker = Tracker(config: TrackingConfig(lostFrameLimit: 3))
    let frame = Frame(
        width: 64,
        height: 64,
        pixels: [UInt16](repeating: 800, count: 64 * 64),
        roi: ROI(x: 0, y: 0, width: 64, height: 64)
    )
    var last = TrackingStatus()
    var searchROI: ROI?
    for _ in 0..<4 {
        last = tracker.process(
            frame: frame,
            detection: nil,
            autoCenter: true,
            autoSearch: true,
            trackingROISize: 256,
            sensorWidth: 6252,
            sensorHeight: 4176
        )
        if let roi = last.requestedROI { searchROI = roi }
    }
    try expect(last.state == TrackingState.searching, "state \(last.state)")
    try expect(searchROI?.binning == 4, "bin \(String(describing: searchROI?.binning))")
    try expect(searchROI?.x == 0, "origin")
}

private func testSearchRecovery() throws {
    var tracker = Tracker()
    tracker.markSearching()
    let roi = Alignment.fullFrameROI(sensorWidth: 800, sensorHeight: 600, binning: 4)
    let frame = Frame(
        width: roi.width,
        height: roi.height,
        pixels: [UInt16](repeating: 900, count: roi.width * roi.height),
        roi: roi
    )
    let detection = StarDetection(
        centroid: SIMD2(10, 10),
        peak: 40_000,
        flux: 40_000,
        area: 50,
        background: 900,
        sigma: 15
    )
    let status = tracker.process(
        frame: frame,
        detection: detection,
        autoCenter: true,
        autoSearch: true,
        trackingROISize: CaptureLayout.trackingHardwareSize,
        sensorWidth: 800,
        sensorHeight: 600
    )
    try expect(status.state == TrackingState.tracking, "state")
    try expect(status.requestedROI?.binning == 1, "bin")
    try expect(
        status.requestedROI?.width == 800 || status.requestedROI?.width == 796,
        "tracking window \(String(describing: status.requestedROI?.width))"
    )
}

private func testSoftwareCrop() throws {
    var pixels = [UInt16](repeating: 0, count: 64 * 64)
    pixels[10 * 64 + 20] = 1000
    let frame = Frame(
        width: 64,
        height: 64,
        pixels: pixels,
        roi: ROI(x: 100, y: 200, width: 64, height: 64)
    )
    let crop = frame.cropped(around: SIMD2(20, 10), size: 16)
    try expect(crop.width == 16 && crop.height == 16, "size")
    try expect(crop.roi.x == 100 + 20 - 8, "roi x \(crop.roi.x)")
    try expect(crop.roi.y == 200 + 10 - 8, "roi y \(crop.roi.y)")
    try expect(crop.pixel(x: 8, y: 8) == 1000, "hot pixel at crop center")
    let origin = crop.origin(inParent: frame)
    try expect(origin == SIMD2(12, 2), "origin \(origin)")

    let edge = frame.cropped(around: SIMD2(1, 1), size: 16)
    try expect(edge.roi.x == 100 && edge.roi.y == 200, "clamped to origin")

    var window = [UInt16](repeating: 0, count: 1024 * 1024)
    window[400 * 1024 + 300] = 999
    let tracking = Frame(
        width: 1024,
        height: 1024,
        pixels: window,
        roi: ROI(x: 40, y: 80, width: 1024, height: 1024)
    )
    try expect(CaptureLayout.isTrackingCapture(tracking), "square tracking window")
    let display = CaptureLayout.displayFrame(from: tracking, tracking: .tracking, centroid: SIMD2(300, 400))
    try expect(display.width == CaptureLayout.displayCropSize, "view crop \(display.width)")
    try expect(display.pixel(x: 256, y: 256) == 999, "star centered in the view crop")

    let analysis = CaptureLayout.analysisFrame(from: tracking, seed: SIMD2(300, 400))
    try expect(analysis.width == CaptureLayout.displayCropSize, "analysis crop \(analysis.width)")
    try expect(analysis.pixel(x: 256, y: 256) == 999, "star centered in the analysis crop")
    let unseeded = CaptureLayout.analysisFrame(from: tracking, seed: nil)
    try expect(unseeded.width == CaptureLayout.displayCropSize, "unseeded crop")
    try expect(unseeded.roi.x != analysis.roi.x || unseeded.roi.y != analysis.roi.y, "unseeded uses window center")

    let searchROI = Alignment.fullFrameROI(sensorWidth: 6252, sensorHeight: 4176, binning: 4)
    let search = Frame(
        width: searchROI.width,
        height: searchROI.height,
        pixels: [0],
        roi: searchROI
    )
    try expect(!CaptureLayout.isTrackingCapture(search), "full-frame search is not a tracking window")
    let shown = CaptureLayout.displayFrame(from: search, tracking: .searching, centroid: SIMD2(10, 10))
    try expect(shown.width == search.width, "search shows the full frame")
}

private func testReadoutFPSCap() throws {
    try expect(CaptureLayout.maxReadoutFPS == 30, "30 fps")
    try expect(CaptureLayout.clampedReadoutFPS(range: nil) == 30, "no range")
    try expect(CaptureLayout.clampedReadoutFPS(range: 0...2000) == 30, "unlimited min is 0")
    try expect(CaptureLayout.clampedReadoutFPS(range: 0...20) == 20, "camera max below 30")
    try expect(CaptureLayout.clampedReadoutFPS(range: 50...200) == 50, "camera min above 30")
}

private func testSensorCenterOverlay() throws {
    let sensorWidth = 6252
    let sensorHeight = 4176
    let center = MountGuide.frameCenter(width: sensorWidth, height: sensorHeight)

    let far = OverlayModel(
        imageWidth: 512,
        imageHeight: 512,
        sensorWidth: sensorWidth,
        sensorHeight: sensorHeight,
        roi: ROI(x: 40, y: 80, width: 512, height: 512)
    )
    guard let farPoint = far.sensorCenterInImage else {
        throw Expectation(description: "expected sensor center mapping")
    }
    try expect(farPoint.x < 0 || farPoint.x >= 512 || farPoint.y < 0 || farPoint.y >= 512, "corner crop is not sensor center")
    try expect(abs(farPoint.x - 256) > 100, "must not sit at crop center \(farPoint.x)")

    let roi = Alignment.centeredROI(
        around: center,
        size: 512,
        sensorWidth: sensorWidth,
        sensorHeight: sensorHeight
    )
    let onCenter = OverlayModel(
        imageWidth: roi.width,
        imageHeight: roi.height,
        sensorWidth: sensorWidth,
        sensorHeight: sensorHeight,
        roi: roi
    )
    guard let point = onCenter.sensorCenterInImage else {
        throw Expectation(description: "expected on-center mapping")
    }
    try expect(abs(point.x - Double(roi.width) / 2) < 4, "x \(point.x)")
    try expect(abs(point.y - Double(roi.height) / 2) < 4, "y \(point.y)")

    let full = Alignment.fullFrameROI(sensorWidth: sensorWidth, sensorHeight: sensorHeight, binning: 1)
    let fullOverlay = OverlayModel(
        imageWidth: full.width,
        imageHeight: full.height,
        sensorWidth: sensorWidth,
        sensorHeight: sensorHeight,
        roi: full
    )
    guard let fullPoint = fullOverlay.sensorCenterInImage else {
        throw Expectation(description: "expected full-frame mapping")
    }
    try expect(abs(fullPoint.x - Double(full.width) / 2) < 2, "full x \(fullPoint.x)")
    try expect(abs(fullPoint.y - Double(full.height) / 2) < 2, "full y \(fullPoint.y)")
}

private func testAutoExposure() throws {
    try expect(ExposureControl.clamp(10) == 100, "min 0.1 ms")
    try expect(ExposureControl.clamp(5_000_000) == 100_000, "max 100 ms")
    let doubled = ExposureControl.adjustedMicroseconds(current: 10_000, peakNormalized: 0.40)
    try expect(doubled == 20_000, "scale 0.80/0.40 -> 2x (\(doubled))")
    let atTarget = ExposureControl.adjustedMicroseconds(current: 8_000, peakNormalized: 0.80)
    try expect(atTarget == 8_000, "already at target (\(atTarget))")

    var pixels = [UInt16](repeating: 1_000, count: 64 * 64)
    pixels[0] = 16_384
    let histogram = Histogram.compute(from: Frame(
        width: 64,
        height: 64,
        pixels: pixels,
        roi: ROI(x: 0, y: 0, width: 64, height: 64)
    ))
    let raw = ExposureControl.peakNormalized(histogram: histogram, detectionPeak: nil)
    try expect(abs(raw - 16_384.0 / 65535.0) < 1e-12, "raw ADU peak \(raw)")
    let stretchedLook = StretchParams(black: 0, white: 1, midtones: 0.15).apply(normalizedValue: raw)
    try expect(stretchedLook > raw, "stretch would lift the display")
    try expect(abs(raw - ExposureControl.peakNormalized(histogram: histogram, detectionPeak: 16_384)) < 1e-12, "detection peak is raw")
}

private func testStarQuality() throws {
    try expect(StarQuality.from(peak: 0) == .faint, "zero")
    try expect(StarQuality.from(peak: 6553) == .faint, "just under 10%")
    try expect(StarQuality.from(peak: 6554) == .good, "10%")
    try expect(StarQuality.from(peak: 52_428) == .good, "80%")
    try expect(StarQuality.from(peak: 65_519) == .good, "just under 12-bit full well")
    try expect(StarQuality.from(peak: 65_520) == .saturated, "12-bit left-aligned clip")
    try expect(StarQuality.from(peak: 65_535) == .saturated, "full well")
}

private func testStarIntensityProfile() throws {
    let width = 128
    let height = 128
    let cx = 63.5
    let cy = 63.5
    let peak = 40_000.0
    var pixels = [UInt16](repeating: 800, count: width * height)
    for y in 0..<height {
        for x in 0..<width {
            let dx = Double(x) - cx
            let dy = Double(y) - cy
            let amp = peak * exp(-(dx * dx + dy * dy) / (2 * 4.0 * 4.0))
            pixels[y * width + x] = UInt16(min(65535, 800 + amp))
        }
    }
    let frame = Frame(
        width: width,
        height: height,
        pixels: pixels,
        roi: ROI(x: 0, y: 0, width: width, height: height)
    )
    guard let profile = StarProfileSampler().measure(
        frame: frame,
        centroid: SIMD2(cx, cy),
        radiusPixels: 24
    ) else {
        throw Expectation(description: "expected profile")
    }
    try expect(profile.samples.count >= 9, "samples \(profile.samples.count)")
    let mid = profile.samples[profile.samples.count / 2]
    let edge = profile.samples[0]
    try expect(mid > 0.5, "center \(mid) should be near peak/65535")
    try expect(abs(mid - (800 + peak) / 65535.0) < 0.08, "center vs full well \(mid)")
    try expect(edge < 0.08, "edge \(edge) stays near background on 0…1 scale")
    try expect(mid < 0.95, "must not autoscale a 40k peak to full well")
    let mirror = profile.samples[profile.samples.count - 1]
    try expect(abs(edge - mirror) < 0.02, "symmetric \(edge) vs \(mirror)")

    pixels[Int(cy) * width + Int(cx)] = 65_535
    let clipped = Frame(
        width: width,
        height: height,
        pixels: pixels,
        roi: ROI(x: 0, y: 0, width: width, height: height)
    )
    guard let saturated = StarProfileSampler().measure(
        frame: clipped,
        centroid: SIMD2(cx, cy),
        radiusPixels: 8
    ) else {
        throw Expectation(description: "expected clipped profile")
    }
    try expect(saturated.samples[saturated.samples.count / 2] > 0.7, "clipped center")
}

private func testDigitalStabilizePan() throws {
    var stabilizer = DigitalStabilizer()
    let first = stabilizer.update(
        enabled: true,
        centroid: SIMD2(50, 50),
        tracking: .tracking,
        imageWidth: 100,
        imageHeight: 100,
        viewWidth: 200,
        viewHeight: 200,
        zoom: 1
    )
    try expect(first.lockNormalized != nil, "lock on first tracking frame")
    let layout0 = ImageLayout(
        imageWidth: 100,
        imageHeight: 100,
        viewWidth: 200,
        viewHeight: 200,
        zoom: 1,
        lockNormalized: first.lockNormalized,
        stabilizeCentroid: first.centroid
    )
    let p0 = layout0.viewPoint(image: SIMD2(50, 50))
    try expect(abs(p0.x - 100) < 1e-9 && abs(p0.y - 100) < 1e-9, "no jump when enabled")

    let moved = stabilizer.update(
        enabled: true,
        centroid: SIMD2(55, 47),
        tracking: .tracking,
        imageWidth: 100,
        imageHeight: 100,
        viewWidth: 200,
        viewHeight: 200,
        zoom: 1
    )
    let layout1 = ImageLayout(
        imageWidth: 100,
        imageHeight: 100,
        viewWidth: 200,
        viewHeight: 200,
        zoom: 1,
        lockNormalized: moved.lockNormalized,
        stabilizeCentroid: moved.centroid
    )
    let p1 = layout1.viewPoint(image: SIMD2(55, 47))
    try expect(abs(p1.x - p0.x) < 1e-9 && abs(p1.y - p0.y) < 1e-9, "centroid stays in the window (\(p1.x), \(p1.y))")
    try expect(abs(layout1.pan.x + 5) < 1e-9 && abs(layout1.pan.y - 3) < 1e-9, "pan \(layout1.pan)")
}

private func testDigitalStabilizeHold() throws {
    var stabilizer = DigitalStabilizer()
    _ = stabilizer.update(
        enabled: true,
        centroid: SIMD2(40, 60),
        tracking: .tracking,
        imageWidth: 100,
        imageHeight: 100,
        viewWidth: 200,
        viewHeight: 200,
        zoom: 2
    )
    let lost = stabilizer.update(
        enabled: true,
        centroid: nil,
        tracking: .lost,
        imageWidth: 100,
        imageHeight: 100,
        viewWidth: 200,
        viewHeight: 200,
        zoom: 2
    )
    try expect(lost.centroid == SIMD2(40, 60), "hold last centroid")
    try expect(lost.lockNormalized != nil, "keep lock while lost")

    let lostWithBlob = stabilizer.update(
        enabled: true,
        centroid: SIMD2(10, 10),
        tracking: .lost,
        imageWidth: 100,
        imageHeight: 100,
        viewWidth: 200,
        viewHeight: 200,
        zoom: 2
    )
    try expect(lostWithBlob.centroid == SIMD2(40, 60), "lost ignores a new blob")
    try expect(lostWithBlob.lockNormalized != nil, "keep lock while lost")

    let search = stabilizer.update(
        enabled: true,
        centroid: SIMD2(10, 10),
        tracking: .searching,
        imageWidth: 200,
        imageHeight: 150,
        viewWidth: 200,
        viewHeight: 200,
        zoom: 1
    )
    try expect(search.lockNormalized == nil && search.centroid == nil, "clear lock while searching")
}

private func testDigitalStabilizeSizeChangeRelocks() throws {
    var stabilizer = DigitalStabilizer()
    let small = stabilizer.update(
        enabled: true,
        centroid: SIMD2(40, 40),
        tracking: .tracking,
        imageWidth: 100,
        imageHeight: 100,
        viewWidth: 200,
        viewHeight: 200,
        zoom: 1
    )
    try expect(small.lockNormalized != nil, "lock on small frame")
    let large = stabilizer.update(
        enabled: true,
        centroid: SIMD2(80, 80),
        tracking: .tracking,
        imageWidth: 200,
        imageHeight: 200,
        viewWidth: 200,
        viewHeight: 200,
        zoom: 1
    )
    try expect(large.lockNormalized != small.lockNormalized, "new lock after size change")
    let layout = ImageLayout(
        imageWidth: 200,
        imageHeight: 200,
        viewWidth: 200,
        viewHeight: 200,
        zoom: 1,
        lockNormalized: large.lockNormalized,
        stabilizeCentroid: large.centroid
    )
    try expect(abs(layout.pan.x) < 1e-9 && abs(layout.pan.y) < 1e-9, "first frame of new size is unpanned")
}

private func testDigitalStabilizeDisable() throws {
    var stabilizer = DigitalStabilizer()
    _ = stabilizer.update(
        enabled: true,
        centroid: SIMD2(20, 20),
        tracking: .tracking,
        imageWidth: 64,
        imageHeight: 64,
        viewWidth: 128,
        viewHeight: 128,
        zoom: 1
    )
    let off = stabilizer.update(
        enabled: false,
        centroid: SIMD2(20, 20),
        tracking: .tracking,
        imageWidth: 64,
        imageHeight: 64,
        viewWidth: 128,
        viewHeight: 128,
        zoom: 1
    )
    try expect(off.lockNormalized == nil && off.centroid == nil, "disable clears pose")
}

private func testDigitalStabilizeProcessFrame() throws {
    let controller = StabilizationController()
    controller.configure(
        enabled: true,
        tracking: .tracking,
        viewWidth: 256,
        viewHeight: 256,
        zoom: 1
    )
    let first = controller.process(starBlobFrame(at: SIMD2(80, 80)))
    try expect(first.lockNormalized != nil && first.centroid != nil, "pose from first frame")
    let layout0 = ImageLayout(
        imageWidth: 128,
        imageHeight: 128,
        viewWidth: 256,
        viewHeight: 256,
        zoom: 1,
        lockNormalized: first.lockNormalized,
        stabilizeCentroid: first.centroid
    )
    let p0 = layout0.viewPoint(image: first.centroid!)

    let moved = controller.process(starBlobFrame(at: SIMD2(92, 74)))
    try expect(moved.centroid != first.centroid, "centroid follows the new frame")
    let layout1 = ImageLayout(
        imageWidth: 128,
        imageHeight: 128,
        viewWidth: 256,
        viewHeight: 256,
        zoom: 1,
        lockNormalized: moved.lockNormalized,
        stabilizeCentroid: moved.centroid
    )
    let p1 = layout1.viewPoint(image: moved.centroid!)
    try expect(abs(p1.x - p0.x) < 0.5 && abs(p1.y - p0.y) < 0.5, "pan matches the frame about to be drawn (\(p1.x), \(p1.y))")
}

private func testDigitalStabilizeLostIgnoresNoise() throws {
    let controller = StabilizationController()
    controller.configure(
        enabled: true,
        tracking: .tracking,
        viewWidth: 256,
        viewHeight: 256,
        zoom: 1
    )
    let first = controller.process(starBlobFrame(at: SIMD2(80, 80)))
    try expect(first.centroid != nil, "locked on star")
    controller.configure(
        enabled: true,
        tracking: .lost,
        viewWidth: 256,
        viewHeight: 256,
        zoom: 1
    )
    let lost = controller.process(starBlobFrame(at: SIMD2(20, 20)))
    try expect(lost.lockNormalized == first.lockNormalized, "keep lock while lost")
    try expect(lost.centroid == first.centroid, "do not chase a new blob")
}

private func testDigitalStabilizeSearchThenCrop() throws {
    let controller = StabilizationController()
    controller.configure(
        enabled: true,
        tracking: .searching,
        viewWidth: 256,
        viewHeight: 256,
        zoom: 1
    )
    let search = controller.process(starBlobFrame(at: SIMD2(20, 20), width: 256, height: 256))
    try expect(search.lockNormalized == nil, "no lock while searching")

    controller.configure(
        enabled: true,
        tracking: .tracking,
        viewWidth: 256,
        viewHeight: 256,
        zoom: 1
    )
    controller.seed(frameCentroid: SIMD2(20, 20), roi: ROI(x: 0, y: 0, width: 256, height: 256))
    try expect(controller.pose().lockNormalized == nil, "seed does not lock on the overlay frame")

    let crop = controller.process(starBlobFrame(at: SIMD2(64, 64), width: 128, height: 128))
    try expect(crop.lockNormalized != nil && crop.centroid != nil, "lock on the cropped frame")
    let layout = ImageLayout(
        imageWidth: 128,
        imageHeight: 128,
        viewWidth: 256,
        viewHeight: 256,
        zoom: 1,
        lockNormalized: crop.lockNormalized,
        stabilizeCentroid: crop.centroid
    )
    try expect(abs(layout.pan.x) < 1 && abs(layout.pan.y) < 1, "crop frame is not panned with the search lock")
}

private func starBlobFrame(at center: SIMD2<Double>, width: Int = 128, height: Int = 128) -> Frame {
    var pixels = [UInt16](repeating: 800, count: width * height)
    let cx = Int(center.x.rounded())
    let cy = Int(center.y.rounded())
    for dy in -4...4 {
        for dx in -4...4 {
            let x = cx + dx
            let y = cy + dy
            guard x >= 0, x < width, y >= 0, y < height else { continue }
            let r2 = dx * dx + dy * dy
            pixels[y * width + x] = r2 <= 9 ? 50_000 : 8_000
        }
    }
    return Frame(
        width: width,
        height: height,
        pixels: pixels,
        roi: ROI(x: 0, y: 0, width: width, height: height)
    )
}

private func testGuideSolveOrthogonal() throws {
    let calibration = GuideCalibration(
        eastRate: SIMD2(0.01, 0),
        northRate: SIMD2(0, 0.02),
        sampleDurationMs: 800
    )
    try expect(calibration.isValid, "valid")
    let times = calibration.pulses(toMoveStarBy: SIMD2(-10, 5))
    try expect(times != nil, "solved")
    try expect(abs((times?.eastMs ?? 0) - (-1000)) < 1e-6, "east \(times?.eastMs ?? 0)")
    try expect(abs((times?.northMs ?? 0) - 250) < 1e-6, "north \(times?.northMs ?? 0)")
}

private func testGuideSolveRotated() throws {
    // Camera rotated 90°: east moves +Y, north moves -X.
    let calibration = GuideCalibration(
        eastRate: SIMD2(0, 0.01),
        northRate: SIMD2(-0.01, 0),
        sampleDurationMs: 800
    )
    let times = calibration.pulses(toMoveStarBy: SIMD2(5, 10))
    try expect(times != nil, "solved")
    try expect(abs((times?.eastMs ?? 0) - 1000) < 1e-6, "east \(times?.eastMs ?? 0)")
    try expect(abs((times?.northMs ?? 0) - (-500)) < 1e-6, "north \(times?.northMs ?? 0)")
}

private func testGuideSolveSingular() throws {
    let calibration = GuideCalibration(
        eastRate: SIMD2(0.01, 0),
        northRate: SIMD2(0.02, 0),
        sampleDurationMs: 800
    )
    try expect(!calibration.isValid, "parallel axes")
    try expect(calibration.pulses(toMoveStarBy: SIMD2(1, 1)) == nil, "no solution")
}

private func testGuidePulsePlanner() throws {
    try expect(GuidePulsePlanner.pulses(eastMs: 20, northMs: -20).isEmpty, "below min")
    let west = GuidePulsePlanner.pulses(eastMs: -400, northMs: 0)
    try expect(west == [GuidePulse(direction: .west, milliseconds: 400)], "west \(west)")
    let north = GuidePulsePlanner.pulses(eastMs: 0, northMs: 150)
    try expect(north == [GuidePulse(direction: .north, milliseconds: 150)], "north \(north)")
    let split = GuidePulsePlanner.pulses(eastMs: 12_000, northMs: 0)
    try expect(split == [GuidePulse(direction: .east, milliseconds: 9000)], "clamp per step \(split)")
    let both = GuidePulsePlanner.pulses(eastMs: 100, northMs: -120)
    try expect(both == [
        GuidePulse(direction: .east, milliseconds: 100),
        GuidePulse(direction: .south, milliseconds: 120)
    ], "both axes \(both)")
}

private func testGuideCenterThreshold() throws {
    let center = MountGuide.frameCenter(width: 512, height: 256)
    try expect(abs(center.x - 255.5) < 1e-9, "x \(center.x)")
    try expect(abs(center.y - 127.5) < 1e-9, "y \(center.y)")
    try expect(MountGuide.isCentered(errorPixels: SIMD2(20, 20)), "inside")
    try expect(MountGuide.isCentered(errorPixels: SIMD2(32, 0)), "on the 32 px limit")
    try expect(!MountGuide.isCentered(errorPixels: SIMD2(32, 8)), "outside")
    let sensor = MountGuide.frameCenter(width: 6252, height: 4176)
    try expect(abs(sensor.x - 3125.5) < 1e-9, "sensor x \(sensor.x)")
    try expect(abs(sensor.y - 2087.5) < 1e-9, "sensor y \(sensor.y)")
    let rate = MountGuide.rate(before: SIMD2(10, 10), after: SIMD2(18, 6), durationMs: 800)
    try expect(abs(rate.x - 0.01) < 1e-12, "rate x")
    try expect(abs(rate.y - (-0.005)) < 1e-12, "rate y")
}

private func testLX200PulseCommand() throws {
    try expect(LX200PulseGuide.command(.north, milliseconds: 500) == ":Mgn0500#", "north")
    try expect(LX200PulseGuide.command(.east, milliseconds: 150) == ":Mge0150#", "east")
    try expect(LX200PulseGuide.command(.west, milliseconds: 12_000) == ":Mgw9999#", "clamp")
}

private func testSkyWatcherHex24() throws {
    try expect(SkyWatcherEncoding.hex24(0x123456) == "563412", "encode")
    try expect(SkyWatcherEncoding.parseHex24("563412") == 0x123456, "decode")
    try expect(SkyWatcherEncoding.parseHex24("=563412\r") == 0x123456, "decode wrapped")
}

private func testSkyWatcherSlowSlew() throws {
    try expect(SkyWatcherEncoding.slowSlewPeriod(sidereal: 1024, rate: 1) == 1024, "1x")
    try expect(SkyWatcherEncoding.slowSlewPeriod(sidereal: 1024, rate: 4) == 32, "32x stays in slow mode")
    try expect(SkyWatcherEncoding.plausibleSiderealPeriod(4) == nil, "reject tiny period")
    try expect(SkyWatcherEncoding.trackingPeriod(sidereal: 0) == SkyWatcherEncoding.defaultSiderealPeriod, "default")
    try expect(SkyWatcherEncoding.parseHex24("F60100") == 502, "logged I-command period")
}

private func testGuideNudgeSlice() throws {
    let calibration = GuideCalibration(
        eastRate: SIMD2(0.01, 0),
        northRate: SIMD2(0, 0.01),
        sampleDurationMs: 800
    )
    let far = MountGuide.nudgeSliceMilliseconds(
        remaining: SIMD2(20_000, 0),
        calibration: calibration,
        rate: 4
    )
    try expect(far == MountGuide.maxNudgeSliceMs, "cap long slews \(far)")
    let near = MountGuide.nudgeSliceMilliseconds(
        remaining: SIMD2(20, 0),
        calibration: calibration,
        rate: 2
    )
    try expect(near >= MountGuide.minNudgeSliceMs, "minimum \(near)")
    try expect(near <= MountGuide.maxNudgeSliceMs, "not over cap \(near)")
}

private func testSynScanFixedRate() throws {
    try expect(
        SynScanGuide.fixedRateCommand(direction: .east, rate: 1) == Data([0x50, 2, 16, 36, 1, 0, 0, 0]),
        "east start"
    )
    try expect(
        SynScanGuide.fixedRateCommand(direction: .south, rate: 0) == Data([0x50, 2, 17, 37, 0, 0, 0, 0]),
        "south stop"
    )
}

private func testGuideCalibrationStore() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent(GuideCalibrationStore.fileName)
    let original = GuideCalibration(
        eastRate: SIMD2(0.012, -0.001),
        northRate: SIMD2(0.002, 0.011),
        sampleDurationMs: 800,
        calibratedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    try GuideCalibrationStore.save(original, to: url)
    let loaded = GuideCalibrationStore.load(from: url)
    try expect(loaded == original, "round-trip \(String(describing: loaded))")
}

private func testGuideSlewAxes() throws {
    let calibration = GuideCalibration(
        eastRate: SIMD2(0.01, 0),
        northRate: SIMD2(0, 0.01),
        sampleDurationMs: 800
    )
    let far = calibration.slewAxes(toMoveStarBy: SIMD2(200, -80), minAxisPixels: 40)
    try expect(far.ra == .east, "ra \(String(describing: far.ra))")
    try expect(far.dec == .south, "dec \(String(describing: far.dec))")
    let near = calibration.slewAxes(toMoveStarBy: SIMD2(20, 10), minAxisPixels: 40)
    try expect(near.ra == nil && near.dec == nil, "below stop threshold")
    try expect(MountGuide.isWithinSlewTolerance(SIMD2(30, 40)), "50 px")
    try expect(!MountGuide.isWithinSlewTolerance(SIMD2(40, 40)), "over 50")
}

private func testGuideSlewCommit() throws {
    try expect(MountGuide.committedSlew(current: nil, desired: .east) == .east, "start")
    try expect(MountGuide.committedSlew(current: .east, desired: .east) == .east, "hold")
    try expect(MountGuide.committedSlew(current: .east, desired: nil) == nil, "stop")
    try expect(MountGuide.committedSlew(current: .east, desired: .west) == nil, "no reverse")
    try expect(MountGuide.committedSlew(current: .north, desired: .south) == nil, "no reverse dec")
}

private func testSynScanPadNudge() throws {
    try expect(SynScanGuide.siderealMultiple(1) == 1, "rate 1")
    try expect(SynScanGuide.siderealMultiple(2) == 8, "rate 2")
    try expect(SynScanGuide.siderealMultiple(9) == 800, "rate 9")
    try expect(SynScanGuide.rate(forDistancePixels: 3000) == 4, "far")
    try expect(SynScanGuide.rate(forDistancePixels: 80) == 2, "near")
    try expect(SynScanGuide.rate(forDistancePixels: 20) == 1, "fine")
    try expect(PadNudge(ra: .east, dec: nil, rate: 9).rate == 4, "never above pad rate 4")
    let calibration = GuideCalibration(
        eastRate: SIMD2(0.01, 0),
        northRate: SIMD2(0, 0.01),
        sampleDurationMs: 800
    )
    let diagonal = SynScanGuide.nudge(
        movingStarBy: SIMD2(200, 200),
        calibration: calibration,
        minAxisPixels: 40,
        distancePixels: 280
    )
    try expect(diagonal?.ra == .east && diagonal?.dec == .north, "diagonal \(String(describing: diagonal))")
    try expect(diagonal?.rate == 3, "rate for 280 px \(String(describing: diagonal?.rate))")
    try expect(
        SynScanGuide.fixedRateCommand(direction: .west, rate: 6) == Data([0x50, 2, 16, 37, 6, 0, 0, 0]),
        "P-command west rate 6"
    )
    try expect(
        SynScanGuide.fixedRateCommand(direction: .north, rate: 0) == Data([0x50, 2, 17, 36, 0, 0, 0, 0]),
        "P-command north stop"
    )
}

private func testAxisCentering() throws {
    let calibration = GuideCalibration(
        eastRate: SIMD2(0.01, 0),
        northRate: SIMD2(0, 0.01),
        sampleDurationMs: 800
    )
    let pixels = calibration.signedAxisPixels(toMoveStarBy: SIMD2(200, -80))
    try expect(pixels?.ra == 200, "ra pixels \(String(describing: pixels?.ra))")
    try expect(pixels?.dec == -80, "dec pixels \(String(describing: pixels?.dec))")
    try expect(
        calibration.remainingOnAxis(.ra, movingStarBy: SIMD2(200, -80)) == SIMD2(200, 0),
        "ra-only remaining"
    )
    try expect(
        calibration.remainingOnAxis(.dec, movingStarBy: SIMD2(200, -80)) == SIMD2(0, -80),
        "dec-only remaining"
    )

    try expect(AxisCentering.primaryAxis(raPixels: 800, decPixels: 100) == .ra, "larger ra")
    try expect(AxisCentering.primaryAxis(raPixels: 100, decPixels: 800) == .dec, "larger dec")
    try expect(AxisCentering.primaryAxis(raPixels: 100, decPixels: 100) == .ra, "tie prefers ra")
    try expect(AxisCentering.primaryAxis(raPixels: 10, decPixels: 10) == nil, "both axes done")
    try expect(
        AxisCentering.primaryAxis(calibration: calibration, movingStarBy: SIMD2(40, 200)) == .dec,
        "primary from calibration"
    )

    let limit = AxisCentering.axisDoneRadiusSensorPixels
    try expect(AxisCentering.isAxisCentered(limit), "on the per-axis limit")
    try expect(!AxisCentering.isAxisCentered(limit + 1), "outside the per-axis limit")
    try expect(
        MountGuide.isCentered(errorPixels: SIMD2(limit, limit)),
        "both axes done implies hypot centered"
    )

    try expect(!AxisCentering.overshot(remaining: 50, previousSign: nil), "first move")
    try expect(!AxisCentering.overshot(remaining: 50, previousSign: 80), "same sign")
    try expect(AxisCentering.overshot(remaining: -40, previousSign: 80), "sign flip")

    try expect(AxisCentering.nextRate(remainingPixels: 800, lastRate: nil, overshot: false) == 4, "start far")
    try expect(AxisCentering.nextRate(remainingPixels: 200, lastRate: 4, overshot: false) == 3, "slow as we close")
    try expect(AxisCentering.nextRate(remainingPixels: -80, lastRate: 3, overshot: true) == 2, "overshoot drops rate")
    try expect(AxisCentering.nextRate(remainingPixels: 200, lastRate: 2, overshot: false) == 2, "do not speed back up")
    try expect(AxisCentering.nextRate(remainingPixels: 10, lastRate: 1, overshot: true) == 1, "rate 1 stays 1")

    try expect(AxisCentering.direction(axis: .ra, remainingPixels: 50) == .east, "east")
    try expect(AxisCentering.direction(axis: .ra, remainingPixels: -50) == .west, "west")
    try expect(AxisCentering.direction(axis: .dec, remainingPixels: 50) == .north, "north")
    try expect(AxisCentering.direction(axis: .dec, remainingPixels: -50) == .south, "south")

    let first = AxisCentering.plan(axis: .ra, remainingPixels: 800, lastRate: nil, lastSign: nil)
    try expect(first?.direction == .east && first?.rate == 4 && first?.overshot == false, "first ra plan")
    try expect(first?.padNudge.ra == .east && first?.padNudge.dec == nil, "single-axis ra nudge")
    let reverse = AxisCentering.plan(axis: .ra, remainingPixels: -90, lastRate: 4, lastSign: 800)
    try expect(reverse?.direction == .west && reverse?.rate == 3 && reverse?.overshot == true, "overshoot reverse")
    try expect(reverse?.padNudge.dec == nil, "still only ra")
    let decPlan = AxisCentering.plan(axis: .dec, remainingPixels: 200, lastRate: nil, lastSign: nil)
    try expect(decPlan?.direction == .north && decPlan?.padNudge.ra == nil, "single-axis dec")
    try expect(AxisCentering.plan(axis: .ra, remainingPixels: 10, lastRate: 1, lastSign: 10) == nil, "axis done")
}

private func testFilterSlotDisplayName() throws {
    try expect(FilterSlot.displayName(position: 0, alias: "") == "1", "empty alias")
    try expect(FilterSlot.displayName(position: 2, alias: "  Ha  ") == "3 · Ha", "trimmed alias")
    try expect(FilterSlot(position: 4, alias: "IR-cut").displayName == "5 · IR-cut", "instance")
}

private func testFilterWheelErrorText() throws {
    try expect(
        FilterWheelError.sdkNotFound.localizedDescription.contains("libPlayerOnePW.dylib"),
        "sdk path"
    )
    try expect(
        FilterWheelError.noWheelSelected.localizedDescription.contains("Phoenix"),
        "select wheel"
    )
    try expect(
        FilterWheelError.invalidPosition.localizedDescription.contains("position"),
        "bad slot"
    )
}

private func testMonoTIFF() throws {
    let pixels: [UInt16] = [0, 1, 32768, 65535]
    let data = try MonoTIFF.encode(pixels: pixels, width: 2, height: 2)
    try expect(Array(data.prefix(4)) == [UInt8(ascii: "I"), UInt8(ascii: "I"), 42, 0], "TIFF II* header")
    let ifdOffset = UInt32(data[4]) | UInt32(data[5]) << 8 | UInt32(data[6]) << 16 | UInt32(data[7]) << 24
    try expect(ifdOffset == 8 + 8, "IFD after 2×2×2 pixel bytes")
    let values = (0..<4).map { i in
        UInt16(data[8 + i * 2]) | UInt16(data[9 + i * 2]) << 8
    }
    try expect(values == pixels, "16-bit samples \(values)")
    let name = MonoTIFF.suggestedFileName(width: 512, height: 256, date: Date(timeIntervalSince1970: 1_700_000_000))
    try expect(name.hasPrefix("collimation-512x256-"), "size in name \(name)")
    try expect(name.hasSuffix(".tif"), "tif suffix \(name)")
    let stackedName = MonoTIFF.suggestedFileName(
        width: 512,
        height: 256,
        date: Date(timeIntervalSince1970: 1_700_000_000),
        label: "stack100"
    )
    try expect(stackedName.contains("-stack100-"), "stack label \(stackedName)")
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("collimation-tiff-test.tif")
    try MonoTIFF.write(
        frame: Frame(width: 2, height: 2, pixels: pixels, roi: ROI(x: 0, y: 0, width: 2, height: 2)),
        to: url
    )
    let roundTrip = try Data(contentsOf: url)
    try expect(roundTrip == data, "file matches encode")
    try? FileManager.default.removeItem(at: url)
}

private func testFrameStacker() throws {
    try expect(FrameStacker.subframeCount == 100, "100 subframes")
    let mid = FrameStacker.bilinearSample(pixels: [10, 20, 30, 40], width: 2, height: 2, x: 0.5, y: 0)
    try expect(mid != nil && abs(mid! - 15) < 1e-9, "horizontal bilinear \(String(describing: mid))")
    let exact = FrameStacker.bilinearSample(pixels: [10, 20, 30, 40], width: 2, height: 2, x: 1, y: 0)
    try expect(exact == 20, "integer sample \(String(describing: exact))")
    try expect(
        FrameStacker.bilinearSample(pixels: [10, 20], width: 2, height: 1, x: -1, y: 0) == nil,
        "outside"
    )

    let roi = ROI(x: 0, y: 0, width: 8, height: 8)
    func hot(x: Int, y: Int, value: UInt16) -> Frame {
        var pixels = [UInt16](repeating: 0, count: 64)
        pixels[y * 8 + x] = value
        return Frame(width: 8, height: 8, pixels: pixels, roi: roi)
    }
    let stacked = try FrameStacker.average([
        (hot(x: 3, y: 4, value: 1000), SIMD2(3, 4)),
        (hot(x: 5, y: 4, value: 1000), SIMD2(5, 4))
    ])
    try expect(stacked.pixels[4 * 8 + 3] == 1000, "aligned peak \(stacked.pixels[4 * 8 + 3])")
    try expect(stacked.pixels[4 * 8 + 5] == 0, "shifted-away peak stays empty \(stacked.pixels[4 * 8 + 5])")

    let dark = Frame(
        width: 2,
        height: 2,
        pixels: [100, 100, 100, 100],
        roi: ROI(x: 0, y: 0, width: 2, height: 2)
    )
    let bright = Frame(
        width: 2,
        height: 2,
        pixels: [201, 201, 201, 201],
        roi: ROI(x: 0, y: 0, width: 2, height: 2)
    )
    let mean = try FrameStacker.average([
        (dark, SIMD2(1, 1)),
        (bright, SIMD2(1, 1))
    ])
    try expect(mean.pixels.allSatisfy { abs($0 - 150.5) < 1e-5 }, "float mean \(mean.pixels)")
}

private func testMonoTIFFFloat32() throws {
    let pixels: [Float] = [0, 0.5, 100.25, 65535]
    let data = try MonoTIFF.encode(floats: pixels, width: 2, height: 2)
    try expect(Array(data.prefix(4)) == [UInt8(ascii: "I"), UInt8(ascii: "I"), 42, 0], "TIFF II* header")
    let ifdOffset = UInt32(data[4]) | UInt32(data[5]) << 8 | UInt32(data[6]) << 16 | UInt32(data[7]) << 24
    try expect(ifdOffset == 8 + 16, "IFD after 2×2×4 pixel bytes")
    let values = (0..<4).map { i -> Float in
        let o = 8 + i * 4
        let bits = UInt32(data[o])
            | UInt32(data[o + 1]) << 8
            | UInt32(data[o + 2]) << 16
            | UInt32(data[o + 3]) << 24
        return Float(bitPattern: bits)
    }
    try expect(values == pixels, "32-bit float samples \(values)")
    let bitsPerSample = tiffShortValue(data, ifdOffset: Int(ifdOffset), entry: 2)
    try expect(bitsPerSample == 32, "BitsPerSample \(bitsPerSample)")
    let sampleFormat = tiffShortValue(data, ifdOffset: Int(ifdOffset), entry: 9)
    try expect(sampleFormat == 3, "SampleFormat IEEE float \(sampleFormat)")
}

private func tiffShortValue(_ data: Data, ifdOffset: Int, entry: Int) -> UInt16 {
    let o = ifdOffset + 2 + entry * 12 + 8
    return UInt16(data[o]) | UInt16(data[o + 1]) << 8
}
