import Foundation

/// Telescope plate scale used to convert FWHM from pixels to arcseconds.
public enum TelescopeOptics {
    public static let focalLengthMillimeters = 1600.0
    public static let pixelSizeMicrons = 3.76
    /// Arcseconds per unbinned pixel: 206.265 × pixel(µm) / f(mm).
    public static let arcsecondsPerUnbinnedPixel =
        206.264806247 * pixelSizeMicrons / focalLengthMillimeters

    public static func arcseconds(framePixels: Double, binning: Int) -> Double {
        framePixels * Double(max(1, binning)) * arcsecondsPerUnbinnedPixel
    }
}

public struct FWHMResult: Equatable, Sendable {
    /// FWHM in the current frame’s pixels (binned).
    public var framePixels: Double
    /// FWHM in unbinned sensor pixels.
    public var sensorPixels: Double
    public var arcseconds: Double
    public var binning: Int

    public init(framePixels: Double, binning: Int) {
        let bin = max(1, binning)
        self.framePixels = framePixels
        self.binning = bin
        self.sensorPixels = framePixels * Double(bin)
        self.arcseconds = TelescopeOptics.arcseconds(framePixels: framePixels, binning: bin)
    }
}

public struct FWHMEstimator: Sendable {
    public init() {}

    public func measure(frame: Frame, centroid: SIMD2<Double>) -> FWHMResult? {
        let width = frame.width
        let height = frame.height
        guard width > 8, height > 8 else { return nil }

        let maxRadius = min(96.0, Double(min(width, height)) / 2 - 1)
        guard maxRadius > 3 else { return nil }

        let background = StarDetector().backgroundStats(frame).median
        let x0 = max(0, Int(floor(centroid.x - maxRadius)))
        let x1 = min(width, Int(ceil(centroid.x + maxRadius)) + 1)
        let y0 = max(0, Int(floor(centroid.y - maxRadius)))
        let y1 = min(height, Int(ceil(centroid.y + maxRadius)) + 1)

        if let radial = radialFWHM(
            frame: frame,
            centroid: centroid,
            background: background,
            x0: x0,
            x1: x1,
            y0: y0,
            y1: y1,
            maxRadius: maxRadius
        ) {
            return FWHMResult(framePixels: radial, binning: frame.roi.binning)
        }
        if let moment = momentFWHM(
            frame: frame,
            centroid: centroid,
            background: background,
            x0: x0,
            x1: x1,
            y0: y0,
            y1: y1,
            maxRadius: maxRadius
        ) {
            return FWHMResult(framePixels: moment, binning: frame.roi.binning)
        }
        return nil
    }

    public func smooth(previous: FWHMResult?, current: FWHMResult, alpha: Double = 0.3) -> FWHMResult {
        guard let previous, previous.binning == current.binning else { return current }
        let a = min(max(alpha, 0.05), 1)
        return FWHMResult(
            framePixels: previous.framePixels * (1 - a) + current.framePixels * a,
            binning: current.binning
        )
    }

    /// Half-max diameter of the azimuthally averaged profile around `centroid`.
    private func radialFWHM(
        frame: Frame,
        centroid: SIMD2<Double>,
        background: Double,
        x0: Int,
        x1: Int,
        y0: Int,
        y1: Int,
        maxRadius: Double
    ) -> Double? {
        let binWidth = 0.5
        let binCount = Int(ceil(maxRadius / binWidth)) + 1
        var sums = [Double](repeating: 0, count: binCount)
        var counts = [Double](repeating: 0, count: binCount)
        let width = frame.width

        for y in y0..<y1 {
            let row = y * width
            let dy = Double(y) - centroid.y
            for x in x0..<x1 {
                let dx = Double(x) - centroid.x
                let r = sqrt(dx * dx + dy * dy)
                if r > maxRadius { continue }
                let bin = min(binCount - 1, Int(r / binWidth))
                sums[bin] += max(0, Double(frame.pixels[row + x]) - background)
                counts[bin] += 1
            }
        }

        var samples: [(radius: Double, intensity: Double)] = []
        samples.reserveCapacity(binCount)
        for i in 0..<binCount {
            guard counts[i] > 0 else { continue }
            samples.append((radius: (Double(i) + 0.5) * binWidth, intensity: sums[i] / counts[i]))
        }
        guard let peakIndex = samples.indices.max(by: { samples[$0].intensity < samples[$1].intensity }) else { return nil }
        let peak = samples[peakIndex].intensity
        guard peak > 20 else { return nil }
        let half = peak * 0.5

        var rHalf: Double?
        if peakIndex + 1 < samples.count {
            for i in peakIndex..<(samples.count - 1) {
                let y0 = samples[i].intensity
                let y1 = samples[i + 1].intensity
                if y0 >= half && y1 < half {
                    let t = (y0 - half) / max(y0 - y1, 1e-9)
                    rHalf = samples[i].radius + t * (samples[i + 1].radius - samples[i].radius)
                    break
                }
            }
        }
        guard let rHalf, rHalf > 0.4 else { return nil }
        return 2 * rHalf
    }

    /// Gaussian-equivalent FWHM from intensity-weighted second moments.
    private func momentFWHM(
        frame: Frame,
        centroid: SIMD2<Double>,
        background: Double,
        x0: Int,
        x1: Int,
        y0: Int,
        y1: Int,
        maxRadius: Double
    ) -> Double? {
        let maxR2 = maxRadius * maxRadius
        let width = frame.width
        var peak = 0.0
        for y in y0..<y1 {
            let row = y * width
            for x in x0..<x1 {
                let dx = Double(x) - centroid.x
                let dy = Double(y) - centroid.y
                if dx * dx + dy * dy > maxR2 { continue }
                peak = max(peak, Double(frame.pixels[row + x]) - background)
            }
        }
        guard peak > 20 else { return nil }
        let floor = peak * 0.05

        var sumW = 0.0
        var sumXX = 0.0
        var sumYY = 0.0
        for y in y0..<y1 {
            let row = y * width
            let dy = Double(y) - centroid.y
            for x in x0..<x1 {
                let dx = Double(x) - centroid.x
                if dx * dx + dy * dy > maxR2 { continue }
                let w = Double(frame.pixels[row + x]) - background
                if w < floor { continue }
                sumW += w
                sumXX += w * dx * dx
                sumYY += w * dy * dy
            }
        }
        guard sumW > 0 else { return nil }
        let sigma = sqrt(max(0, (sumXX + sumYY) / (2 * sumW)))
        let fwhm = 2.0 * sqrt(2.0 * log(2.0)) * sigma
        return fwhm > 0.5 ? fwhm : nil
    }
}
