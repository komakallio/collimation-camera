import Foundation

public struct ComaResult: Equatable, Sendable {
    public var outer: FittedCircle
    public var inner: FittedCircle
    /// Inner-hole center minus outer-circle center, in frame pixels (x right, y down).
    public var vector: SIMD2<Double>
    public var magnitudePixels: Double
    /// |C| / (R − r), fraction of the annulus width.
    public var magnitudeNormalized: Double
    /// Direction of the concentricity vector, degrees: 0 = +x (right), 90 = +y (down).
    public var directionDegrees: Double
    /// Peak-to-peak annulus intensity variation relative to the mean (0...2 typical).
    public var sectorAsymmetry: Double
    /// First Fourier harmonic phase of the annulus, same convention as directionDegrees.
    public var harmonicDirectionDegrees: Double
    public var snr: Double
    public var quality: Double

    public init(
        outer: FittedCircle,
        inner: FittedCircle,
        vector: SIMD2<Double>,
        magnitudePixels: Double,
        magnitudeNormalized: Double,
        directionDegrees: Double,
        sectorAsymmetry: Double,
        harmonicDirectionDegrees: Double,
        snr: Double,
        quality: Double
    ) {
        self.outer = outer
        self.inner = inner
        self.vector = vector
        self.magnitudePixels = magnitudePixels
        self.magnitudeNormalized = magnitudeNormalized
        self.directionDegrees = directionDegrees
        self.sectorAsymmetry = sectorAsymmetry
        self.harmonicDirectionDegrees = harmonicDirectionDegrees
        self.snr = snr
        self.quality = quality
    }
}

public struct ComaAnalyzer: Sendable {
    public var kSigma: Double
    public var sectorCount: Int

    public init(kSigma: Double = 4.0, sectorCount: Int = 16) {
        self.kSigma = kSigma
        self.sectorCount = sectorCount
    }

    public func analyze(frame: Frame, detection: StarDetection?) -> ComaResult? {
        let stats = StarDetector(kSigma: kSigma).backgroundStats(frame)
        let threshold = UInt16(min(65535, max(0, stats.median + kSigma * stats.sigma)))
        guard let mask = largestBlobMask(frame: frame, threshold: threshold) else { return nil }

        let outerPoints = boundaryPoints(mask: mask, width: frame.width, height: frame.height)
        guard let outer = CircleFit.fit(points: subsample(outerPoints, maxCount: 600)) else { return nil }

        guard let hole = holeGeometry(frame: frame, mask: mask, outer: outer, background: stats.median) else {
            return nil
        }

        let vector = hole.center - outer.center
        let magnitude = simdLength(vector)
        let annulus = max(outer.radius - hole.radius, 1.0)
        let normalized = magnitude / annulus
        let direction = atan2(vector.y, vector.x) * 180 / .pi

        let sectors = sectorMeans(
            frame: frame,
            outer: outer,
            innerRadius: hole.radius,
            background: stats.median
        )
        let meanSector = sectors.reduce(0, +) / Double(max(sectors.count, 1))
        let peakToPeak = (sectors.max() ?? 0) - (sectors.min() ?? 0)
        let asymmetry = meanSector > 1e-3 ? peakToPeak / meanSector : 0
        let harmonic = firstHarmonic(sectors)

        let snr = detection?.snr ?? max(0, (Double(frame.pixels.max() ?? 0) - stats.median) / max(stats.sigma, 1))
        let quality = qualityScore(
            outer: outer,
            innerRadius: hole.radius,
            holePixels: hole.pixelCount,
            frame: frame,
            snr: snr
        )

        return ComaResult(
            outer: outer,
            inner: FittedCircle(center: hole.center, radius: hole.radius),
            vector: vector,
            magnitudePixels: magnitude,
            magnitudeNormalized: normalized,
            directionDegrees: wrapDegrees(direction),
            sectorAsymmetry: asymmetry,
            harmonicDirectionDegrees: wrapDegrees(harmonic),
            snr: snr,
            quality: quality
        )
    }

    public func smooth(previous: ComaResult?, current: ComaResult, alpha: Double = 0.25) -> ComaResult {
        guard let previous else { return current }
        let a = min(max(alpha, 0.05), 1)
        let vec = previous.vector * (1 - a) + current.vector * a
        let mag = simdLength(vec)
        let annulus = max(current.outer.radius - current.inner.radius, 1)
        return ComaResult(
            outer: FittedCircle(
                center: previous.outer.center * (1 - a) + current.outer.center * a,
                radius: previous.outer.radius * (1 - a) + current.outer.radius * a
            ),
            inner: FittedCircle(
                center: previous.inner.center * (1 - a) + current.inner.center * a,
                radius: previous.inner.radius * (1 - a) + current.inner.radius * a
            ),
            vector: vec,
            magnitudePixels: mag,
            magnitudeNormalized: mag / annulus,
            directionDegrees: wrapDegrees(atan2(vec.y, vec.x) * 180 / .pi),
            sectorAsymmetry: previous.sectorAsymmetry * (1 - a) + current.sectorAsymmetry * a,
            harmonicDirectionDegrees: current.harmonicDirectionDegrees,
            snr: previous.snr * (1 - a) + current.snr * a,
            quality: previous.quality * (1 - a) + current.quality * a
        )
    }

    private struct Hole {
        var center: SIMD2<Double>
        var radius: Double
        var pixelCount: Int
    }

    private func largestBlobMask(frame: Frame, threshold: UInt16) -> [UInt8]? {
        let count = frame.pixelCount
        var visited = [UInt8](repeating: 0, count: count)
        var bestMask: [UInt8]?
        var bestArea = 0
        let width = frame.width
        let height = frame.height
        let pixels = frame.pixels

        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                let idx = row + x
                if visited[idx] != 0 || pixels[idx] < threshold { continue }
                var mask = [UInt8](repeating: 0, count: count)
                var stack = [idx]
                visited[idx] = 1
                var area = 0
                while let cur = stack.popLast() {
                    if pixels[cur] < threshold { continue }
                    mask[cur] = 1
                    area += 1
                    let cx = cur % width
                    let cy = cur / width
                    let neighbors = [cx > 0 ? cur - 1 : -1,
                                     cx + 1 < width ? cur + 1 : -1,
                                     cy > 0 ? cur - width : -1,
                                     cy + 1 < height ? cur + width : -1]
                    for n in neighbors where n >= 0 {
                        if visited[n] == 0, pixels[n] >= threshold {
                            visited[n] = 1
                            stack.append(n)
                        } else if visited[n] == 0 {
                            visited[n] = 1
                        }
                    }
                }
                if area > bestArea, area >= 30 {
                    bestArea = area
                    bestMask = mask
                }
            }
        }
        return bestMask
    }

    private func boundaryPoints(mask: [UInt8], width: Int, height: Int) -> [SIMD2<Double>] {
        var points: [SIMD2<Double>] = []
        points.reserveCapacity(512)
        for y in 1..<(height - 1) {
            let row = y * width
            for x in 1..<(width - 1) {
                if mask[row + x] == 0 { continue }
                let edge = mask[row + x - 1] == 0
                    || mask[row + x + 1] == 0
                    || mask[row + x - width] == 0
                    || mask[row + x + width] == 0
                if edge {
                    points.append(SIMD2(Double(x), Double(y)))
                }
            }
        }
        return points
    }

    private func holeGeometry(
        frame: Frame,
        mask: [UInt8],
        outer: FittedCircle,
        background: Double
    ) -> Hole? {
        let width = frame.width
        let height = frame.height
        var sumX = 0.0
        var sumY = 0.0
        var n = 0
        let rCut = outer.radius * 0.85
        let rCut2 = rCut * rCut
        let darkCut = background + max(40, 0.35 * (Double(frame.pixels.max() ?? 0) - background))

        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                let dx = Double(x) - outer.center.x
                let dy = Double(y) - outer.center.y
                if dx * dx + dy * dy > rCut2 { continue }
                let insideDark = mask[row + x] == 0 || Double(frame.pixels[row + x]) < darkCut
                if insideDark {
                    sumX += Double(x)
                    sumY += Double(y)
                    n += 1
                }
            }
        }
        guard n > 8 else { return nil }
        let center = SIMD2(sumX / Double(n), sumY / Double(n))
        let radius = sqrt(Double(n) / .pi)
        return Hole(center: center, radius: max(radius, 1), pixelCount: n)
    }

    private func sectorMeans(
        frame: Frame,
        outer: FittedCircle,
        innerRadius: Double,
        background: Double
    ) -> [Double] {
        var sums = [Double](repeating: 0, count: sectorCount)
        var counts = [Double](repeating: 0, count: sectorCount)
        let inner = innerRadius * 1.15
        let outerR = outer.radius * 0.95
        let inner2 = inner * inner
        let outer2 = outerR * outerR
        let width = frame.width
        let height = frame.height

        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                let dx = Double(x) - outer.center.x
                let dy = Double(y) - outer.center.y
                let r2 = dx * dx + dy * dy
                if r2 < inner2 || r2 > outer2 { continue }
                var angle = atan2(dy, dx)
                if angle < 0 { angle += 2 * .pi }
                let sector = min(sectorCount - 1, Int(angle / (2 * .pi) * Double(sectorCount)))
                sums[sector] += max(0, Double(frame.pixels[row + x]) - background)
                counts[sector] += 1
            }
        }
        return zip(sums, counts).map { $1 > 0 ? $0 / $1 : 0 }
    }

    private func firstHarmonic(_ sectors: [Double]) -> Double {
        var a = 0.0
        var b = 0.0
        let n = Double(sectors.count)
        for (i, value) in sectors.enumerated() {
            let theta = (Double(i) + 0.5) / n * 2 * .pi
            a += value * cos(theta)
            b += value * sin(theta)
        }
        return atan2(b, a) * 180 / .pi
    }

    private func qualityScore(
        outer: FittedCircle,
        innerRadius: Double,
        holePixels: Int,
        frame: Frame,
        snr: Double
    ) -> Double {
        let minDim = Double(min(frame.width, frame.height))
        let sizeOK = outer.radius > minDim * 0.08 && outer.radius < minDim * 0.48
        let holeOK = innerRadius > 2 && holePixels > 12
        let snrOK = snr > 8
        var q = 0.0
        if sizeOK { q += 0.4 }
        if holeOK { q += 0.4 }
        if snrOK { q += 0.2 }
        return q
    }

    private func subsample(_ points: [SIMD2<Double>], maxCount: Int) -> [SIMD2<Double>] {
        guard points.count > maxCount, maxCount > 0 else { return points }
        let step = Double(points.count) / Double(maxCount)
        var result: [SIMD2<Double>] = []
        result.reserveCapacity(maxCount)
        var i = 0.0
        while result.count < maxCount && Int(i) < points.count {
            result.append(points[Int(i)])
            i += step
        }
        return result
    }

    private func wrapDegrees(_ value: Double) -> Double {
        var v = value.truncatingRemainder(dividingBy: 360)
        if v < 0 { v += 360 }
        return v
    }

    private func simdLength(_ v: SIMD2<Double>) -> Double {
        sqrt(v.x * v.x + v.y * v.y)
    }
}
