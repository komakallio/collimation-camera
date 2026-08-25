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
}

public struct StarDetector: Sendable {
    public var kSigma: Double
    public var minArea: Int
    public var maxAreaFraction: Double

    public init(kSigma: Double = 5.0, minArea: Int = 20, maxAreaFraction: Double = 0.6) {
        self.kSigma = kSigma
        self.minArea = minArea
        self.maxAreaFraction = maxAreaFraction
    }

    public func detect(in frame: Frame) -> StarDetection? {
        let stats = backgroundStats(frame)
        let threshold = UInt16(min(65535, max(0, stats.median + kSigma * stats.sigma)))
        let maxArea = Int(Double(frame.pixelCount) * maxAreaFraction)

        var visited = [UInt8](repeating: 0, count: frame.pixelCount)
        var best: StarDetection?
        var bestFlux = -1.0

        let width = frame.width
        let height = frame.height
        let pixels = frame.pixels

        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                let idx = row + x
                if visited[idx] != 0 || pixels[idx] < threshold { continue }
                if let blob = floodFill(
                    pixels: pixels,
                    visited: &visited,
                    width: width,
                    height: height,
                    start: idx,
                    threshold: threshold
                ), blob.area >= minArea, blob.area <= maxArea, blob.flux > bestFlux {
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
        }
        return best
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
        let median = Double(samples[samples.count / 2])
        let p16 = Double(samples[max(0, samples.count * 16 / 100)])
        let p84 = Double(samples[min(samples.count - 1, samples.count * 84 / 100)])
        let sigma = max(12.0, (p84 - p16) / 2.0)
        return (median, sigma)
    }

    private struct Blob {
        var centroid: SIMD2<Double>
        var peak: UInt16
        var flux: Double
        var area: Int
    }

    private func floodFill(
        pixels: [UInt16],
        visited: inout [UInt8],
        width: Int,
        height: Int,
        start: Int,
        threshold: UInt16
    ) -> Blob? {
        var stack = [start]
        visited[start] = 1
        var area = 0
        var flux = 0.0
        var sumX = 0.0
        var sumY = 0.0
        var peak: UInt16 = 0

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

            if x > 0 {
                let n = idx - 1
                if visited[n] == 0, pixels[n] >= threshold {
                    visited[n] = 1
                    stack.append(n)
                }
            }
            if x + 1 < width {
                let n = idx + 1
                if visited[n] == 0, pixels[n] >= threshold {
                    visited[n] = 1
                    stack.append(n)
                }
            }
            if y > 0 {
                let n = idx - width
                if visited[n] == 0, pixels[n] >= threshold {
                    visited[n] = 1
                    stack.append(n)
                }
            }
            if y + 1 < height {
                let n = idx + width
                if visited[n] == 0, pixels[n] >= threshold {
                    visited[n] = 1
                    stack.append(n)
                }
            }
        }

        guard area > 0, flux > 0 else { return nil }
        return Blob(centroid: SIMD2(sumX / flux, sumY / flux), peak: peak, flux: flux, area: area)
    }
}
