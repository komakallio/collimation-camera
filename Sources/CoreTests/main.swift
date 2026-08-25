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
        failures += run("empty sky", testEmptySky)
        failures += run("circle fit", testCircleFit)
        failures += run("coma horizontal", testComaHorizontal)
        failures += run("coma vertical", testComaVertical)
        failures += run("concentric donut", testConcentric)
        failures += run("tracker recenter", testTrackerRecenter)
        failures += run("tracker search", testTrackerSearch)
        failures += run("search recovery", testSearchRecovery)
        failures += run("auto exposure", testAutoExposure)
        failures += run("digital stabilize pan", testDigitalStabilizePan)
        failures += run("digital stabilize hold", testDigitalStabilizeHold)
        failures += run("digital stabilize disable", testDigitalStabilizeDisable)

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

private func testEmptySky() throws {
    let pixels = [UInt16](repeating: 900, count: 128 * 128)
    let frame = Frame(width: 128, height: 128, pixels: pixels, roi: ROI(x: 0, y: 0, width: 128, height: 128))
    try expect(StarDetector().detect(in: frame) == nil, "false positive")
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

private func testTrackerSearch() throws {
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
