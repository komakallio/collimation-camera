import CollimationKernels
import Foundation

public struct StarDetection: Equatable, Sendable {
    public var centroid: SIMD2<Double>
    public var peak: UInt16
    public var flux: Double
    public var area: Int
    public var background: Double
    public var sigma: Double

    public init(
        centroid: SIMD2<Double>,
        peak: UInt16,
        flux: Double,
        area: Int,
        background: Double,
        sigma: Double
    ) {
        self.centroid = centroid
        self.peak = peak
        self.flux = flux
        self.area = area
        self.background = background
        self.sigma = sigma
    }

    public var snr: Double {
        guard sigma > 1e-3 else { return 0 }
        return max(0, (Double(peak) - background) / sigma)
    }

    public func offsetBy(_ delta: SIMD2<Double>) -> StarDetection {
        StarDetection(
            centroid: centroid + delta,
            peak: peak,
            flux: flux,
            area: area,
            background: background,
            sigma: sigma
        )
    }
}

public struct StarDetector: Sendable {
    public var kSigma: Double
    public var minArea: Int
    public var maxAreaFraction: Double

    /// Reject only a blob that is essentially the whole frame (washed-out sky).
    /// A well-exposed collimation donut can fill most of the 512 crop.
    public static let defaultMaxAreaFraction = 0.95

    /// Live-view moment window. Matches the 512 crop so a large donut is not
    /// clipped when the seed is off-centre. GPUCentroid uses the same value.
    public static let momentCentroidHalfWindow = CaptureLayout.displayCropSize

    public init(kSigma: Double = 5.0, minArea: Int = 20, maxAreaFraction: Double = defaultMaxAreaFraction) {
        self.kSigma = kSigma
        self.minArea = minArea
        self.maxAreaFraction = maxAreaFraction
    }

    public func detect(in frame: Frame, around seed: SIMD2<Double>? = nil) -> StarDetection? {
        let width = frame.width
        let height = frame.height
        guard width > 0, height > 0 else { return nil }

        if let seed {
            return detectRegion(
                in: frame,
                around: seed,
                halfWindow: Self.seedHalfWindow(width: width, height: height)
            )
        }
        // 2048×2048 tracking frames must be searched in full: a 4× PowerMate
        // donut is often larger than the old 768-pixel window around the rim.
        if frame.pixelCount <= CaptureLayout.trackingHardwareSize * CaptureLayout.trackingHardwareSize {
            return detectRegion(in: frame, x0: 0, y0: 0, x1: width, y1: height)
        }
        return detectLargeFrame(frame)
    }

    private static func seedHalfWindow(width: Int, height: Int) -> Int {
        max(momentCentroidHalfWindow, min(width, height) / 2)
    }

    private func detectLargeFrame(_ frame: Frame) -> StarDetection? {
        let peak = stridedPeak(in: frame)
            ?? SIMD2(Double(frame.width) / 2, Double(frame.height) / 2)
        let maxHW = max(min(frame.width, frame.height) / 2, 512)
        var halfWindow = 512
        while halfWindow < maxHW {
            if let found = detectRegion(
                in: frame,
                around: peak,
                halfWindow: halfWindow,
                allowClipped: false
            ) {
                return found
            }
            halfWindow = min(maxHW, halfWindow * 2)
        }
        return detectRegion(in: frame, around: peak, halfWindow: maxHW, allowClipped: true)
    }

    public func backgroundStats(_ frame: Frame) -> (median: Double, sigma: Double) {
        let step = max(1, frame.pixelCount / 20_000)
        var samples: [UInt16] = []
        samples.reserveCapacity((frame.pixelCount / step) + 1)
        var i = 0
        while i < frame.pixels.count {
            samples.append(frame.pixels[i])
            i += step
        }
        samples.sort()
        guard !samples.isEmpty else { return (0, 1) }
        let n = samples.count
        let p05 = Double(samples[max(0, n * 5 / 100)])
        let p16 = Double(samples[max(0, n * 16 / 100)])
        // Sky floor, not the sample median: a defocused donut can cover most of
        // the 512 crop, which would put p50 on the annulus and push k·σ above
        // the star. p16 stays on the sky while ~15% of the frame is still dark.
        // Sigma from the lower tail so the bright ring cannot inflate it.
        let sigma = max(12.0, (p16 - p05) * 1.55)
        return (p16, sigma)
    }

    private func detectRegion(
        in frame: Frame,
        around seed: SIMD2<Double>,
        halfWindow: Int,
        allowClipped: Bool = true
    ) -> StarDetection? {
        let hw = max(32, halfWindow)
        let cx = Int(seed.x.rounded())
        let cy = Int(seed.y.rounded())
        let x0 = max(0, cx - hw)
        let y0 = max(0, cy - hw)
        let x1 = min(frame.width, cx + hw + 1)
        let y1 = min(frame.height, cy + hw + 1)
        return detectRegion(in: frame, x0: x0, y0: y0, x1: x1, y1: y1, allowClipped: allowClipped)
    }

    private func detectRegion(
        in frame: Frame,
        x0: Int,
        y0: Int,
        x1: Int,
        y1: Int,
        allowClipped: Bool = true
    ) -> StarDetection? {
        guard x1 > x0, y1 > y0 else { return nil }
        let stats = backgroundStats(frame)
        let threshold = UInt16(min(65535, max(0, stats.median + kSigma * stats.sigma)))
        let maxArea = Int(Double(frame.pixelCount) * maxAreaFraction)
        let width = frame.width
        let height = frame.height
        let fullFrame = x0 == 0 && y0 == 0 && x1 == width && y1 == height
        let rw = x1 - x0
        var visited = [UInt8](repeating: 0, count: rw * (y1 - y0))
        var best: StarDetection?
        var bestFlux = -1.0
        let pixels = frame.pixels

        for y in y0..<y1 {
            let row = y * width
            let visRow = (y - y0) * rw
            for x in x0..<x1 {
                let vis = visRow + (x - x0)
                if visited[vis] != 0 { continue }
                let idx = row + x
                if pixels[idx] < threshold { continue }
                guard let blob = floodFill(
                    pixels: pixels,
                    visited: &visited,
                    width: width,
                    height: height,
                    x0: x0,
                    y0: y0,
                    x1: x1,
                    y1: y1,
                    start: idx,
                    threshold: threshold
                ), blob.area >= minArea, blob.area <= maxArea, blob.flux > bestFlux
                else { continue }
                if blob.clippedByWindow, !fullFrame, !allowClipped { continue }
                bestFlux = blob.flux
                best = StarDetection(
                    centroid: blob.centroid,
                    peak: blob.peak,
                    flux: blob.flux,
                    area: blob.area,
                    background: stats.median,
                    sigma: stats.sigma
                )
            }
        }
        return best
    }

    private func stridedPeak(in frame: Frame, stride: Int = 8) -> SIMD2<Double>? {
        let step = max(1, stride)
        var peak: UInt16 = 0
        var px = 0
        var py = 0
        var y = 0
        while y < frame.height {
            let row = y * frame.width
            var x = 0
            while x < frame.width {
                let value = frame.pixels[row + x]
                if value > peak {
                    peak = value
                    px = x
                    py = y
                }
                x += step
            }
            y += step
        }
        guard peak > 0 else { return nil }
        return SIMD2(Double(px), Double(py))
    }

    private struct Blob {
        var centroid: SIMD2<Double>
        var peak: UInt16
        var flux: Double
        var area: Int
        var clippedByWindow: Bool
    }

    private func floodFill(
        pixels: [UInt16],
        visited: inout [UInt8],
        width: Int,
        height: Int,
        x0: Int,
        y0: Int,
        x1: Int,
        y1: Int,
        start: Int,
        threshold: UInt16
    ) -> Blob? {
        let rw = x1 - x0
        var stack = [start]
        let sx = start % width
        let sy = start / width
        visited[(sy - y0) * rw + (sx - x0)] = 1
        var area = 0
        var flux = 0.0
        var sumX = 0.0
        var sumY = 0.0
        var peak: UInt16 = 0
        var clippedByWindow = false

        while let idx = stack.popLast() {
            let value = pixels[idx]
            if value < threshold { continue }
            let x = idx % width
            let y = idx / width
            area += 1
            let w = Double(value)
            flux += w
            sumX += Double(x) * w
            sumY += Double(y) * w
            if value > peak { peak = value }

            func consider(_ nx: Int, _ ny: Int) {
                guard nx >= x0, nx < x1, ny >= y0, ny < y1 else {
                    if nx >= 0, nx < width, ny >= 0, ny < height {
                        clippedByWindow = true
                    }
                    return
                }
                let vis = (ny - y0) * rw + (nx - x0)
                if visited[vis] != 0 { return }
                let n = ny * width + nx
                if pixels[n] < threshold { return }
                visited[vis] = 1
                stack.append(n)
            }
            consider(x - 1, y)
            consider(x + 1, y)
            consider(x, y - 1)
            consider(x, y + 1)
        }

        guard area > 0, flux > 0 else { return nil }
        return Blob(
            centroid: SIMD2(sumX / flux, sumY / flux),
            peak: peak,
            flux: flux,
            area: area,
            clippedByWindow: clippedByWindow
        )
    }

    /// Intensity-weighted centroid in a window. The live view uses a GPU copy of
    /// this reduction; this CPU path is for detection, stacking, and tests.
    public func momentCentroid(
        in frame: Frame,
        around seed: SIMD2<Double>?,
        halfWindow: Int = momentCentroidHalfWindow
    ) -> SIMD2<Double>? {
        let width = frame.width
        let height = frame.height
        guard width > 0, height > 0 else { return nil }

        let cx = seed.map { Int($0.x.rounded()) } ?? width / 2
        let cy = seed.map { Int($0.y.rounded()) } ?? height / 2
        let hw = max(32, min(halfWindow, max(width, height)))
        return frame.pixels.withUnsafeBufferPointer { buffer in
            guard let pixels = buffer.baseAddress else { return nil }
            var x = 0.0
            var y = 0.0
            guard collimation_moment_centroid(
                pixels,
                Int32(width),
                Int32(height),
                Int32(cx),
                Int32(cy),
                Int32(hw),
                &x,
                &y
            ) != 0 else {
                return nil
            }
            return SIMD2(x, y)
        }
    }
}
