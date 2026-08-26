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
        failures += run("moment centroid", testMomentCentroid)
        failures += run("empty sky", testEmptySky)
        failures += run("star fwhm", testStarFWHM)
        failures += run("circle fit", testCircleFit)
        failures += run("coma horizontal", testComaHorizontal)
        failures += run("coma vertical", testComaVertical)
        failures += run("concentric donut", testConcentric)
        failures += run("tracker recenter", testTrackerRecenter)
        failures += run("tracker hold when lost", testTrackerHoldWhenLost)
        failures += run("search recovery", testSearchRecovery)
        failures += run("auto exposure", testAutoExposure)
        failures += run("digital stabilize pan", testDigitalStabilizePan)
        failures += run("digital stabilize hold", testDigitalStabilizeHold)
        failures += run("digital stabilize disable", testDigitalStabilizeDisable)
        failures += run("digital stabilize process frame", testDigitalStabilizeProcessFrame)
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
            trackingROISize: 256,
            sensorWidth: 6252,
            sensorHeight: 4176
        )
    }
    try expect(last.state == TrackingState.lost, "stay lost until Search is pressed")
    try expect(last.requestedROI == nil, "do not switch to a search ROI")
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
        trackingROISize: 256,
        sensorWidth: 800,
        sensorHeight: 600
    )
    try expect(status.state == TrackingState.tracking, "state")
    try expect(status.requestedROI?.binning == 1, "bin")
    try expect(status.requestedROI?.width == 256 || status.requestedROI?.width == 252, "width")
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

private func starBlobFrame(at center: SIMD2<Double>) -> Frame {
    let width = 128
    let height = 128
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
        "P-command release north"
    )
}
