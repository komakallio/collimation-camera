import Foundation

public struct ComaResult: Equatable, Sendable {
    public var outer: FittedCircle
    public var inner: FittedCircle
    /// Bright-core (or hole) center minus the geometric envelope center, in
    /// frame pixels (x right, y down).
    public var vector: SIMD2<Double>
    public var magnitudePixels: Double
    /// |C| / scale: annulus width for a donut, first-minimum radius in-focus.
    public var magnitudeNormalized: Double
    /// Direction of the concentricity vector, degrees: 0 = +x (right), 90 = +y (down).
    public var directionDegrees: Double
    /// Peak-to-peak annulus intensity variation relative to the mean (0...2 typical).
    public var sectorAsymmetry: Double
    /// First Fourier harmonic phase of the annulus, same convention as directionDegrees.
    public var harmonicDirectionDegrees: Double
    public var snr: Double
    public var quality: Double
    /// `false` when the secondary shadow is gone and coma is measured in-focus.
    public var isDonut: Bool

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
        quality: Double,
        isDonut: Bool = true
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
        self.isDonut = isDonut
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
        let snr = detection?.snr ?? max(0, (Double(frame.pixels.max() ?? 0) - stats.median) / max(stats.sigma, 1))

        if let hole = holeGeometry(frame: frame, mask: mask, outer: outer, background: stats.median),
           isPerceptibleHole(hole, outer: outer) {
            return donutResult(
                frame: frame,
                outer: outer,
                hole: hole,
                background: stats.median,
                snr: snr
            )
        }
        return inFocusResult(
            frame: frame,
            mask: mask,
            outer: outer,
            background: stats.median,
            snr: snr
        )
    }

    private func donutResult(
        frame: Frame,
        outer: FittedCircle,
        hole: Hole,
        background: Double,
        snr: Double
    ) -> ComaResult {
        let vector = hole.center - outer.center
        let magnitude = simdLength(vector)
        let annulus = max(outer.radius - hole.radius, 1.0)
        let sectors = sectorMeans(
            frame: frame,
            outer: outer,
            innerRadius: hole.radius,
            background: background
        )
        let meanSector = sectors.reduce(0, +) / Double(max(sectors.count, 1))
        let peakToPeak = (sectors.max() ?? 0) - (sectors.min() ?? 0)
        let asymmetry = meanSector > 1e-3 ? peakToPeak / meanSector : 0
        return ComaResult(
            outer: outer,
            inner: FittedCircle(center: hole.center, radius: hole.radius),
            vector: vector,
            magnitudePixels: magnitude,
            magnitudeNormalized: magnitude / annulus,
            directionDegrees: wrapDegrees(atan2(vector.y, vector.x) * 180 / .pi),
            sectorAsymmetry: asymmetry,
            harmonicDirectionDegrees: wrapDegrees(firstHarmonic(sectors)),
            snr: snr,
            quality: qualityScore(
                outer: outer,
                innerRadius: hole.radius,
                holePixels: hole.pixelCount,
                frame: frame,
                snr: snr
            ),
            isDonut: true
        )
    }

    /// Geometric center of the star vs brightness-weighted photocenter, using
    /// only the disk out to the first visible Airy minimum.
    private func inFocusResult(
        frame: Frame,
        mask: [UInt8],
        outer: FittedCircle,
        background: Double,
        snr: Double
    ) -> ComaResult? {
        let shape = geometricCentroid(mask: mask, width: frame.width, height: frame.height)
            ?? outer.center
        let maxRadius = min(
            Double(min(frame.width, frame.height)) / 2 - 1,
            max(outer.radius * 3.5, 24)
        )
        let footprint = firstVisibleMinimum(
            frame: frame,
            center: shape,
            background: background,
            maxRadius: maxRadius
        ) ?? coreRadiusFallback(
            frame: frame,
            center: shape,
            background: background,
            maxRadius: maxRadius
        ) ?? outer.radius
        let radius = max(footprint, 2)

        let width = frame.width
        let pixels = frame.pixels
        let r2max = radius * radius
        var fluxX = 0.0
        var fluxY = 0.0
        var flux = 0.0
        var n = 0
        let x0 = max(0, Int(floor(shape.x - radius)))
        let x1 = min(width, Int(ceil(shape.x + radius)) + 1)
        let y0 = max(0, Int(floor(shape.y - radius)))
        let y1 = min(frame.height, Int(ceil(shape.y + radius)) + 1)
        for y in y0..<y1 {
            let row = y * width
            let dy = Double(y) - shape.y
            for x in x0..<x1 {
                let dx = Double(x) - shape.x
                if dx * dx + dy * dy > r2max { continue }
                n += 1
                let weight = max(0, Double(pixels[row + x]) - background)
                if weight <= 0 { continue }
                fluxX += Double(x) * weight
                fluxY += Double(y) * weight
                flux += weight
            }
        }
        guard n >= 30, flux > 1e-3 else { return nil }
        let brightness = SIMD2(fluxX / flux, fluxY / flux)
        let vector = brightness - shape
        let magnitude = simdLength(vector)
        let sectors = diskSectorMeans(
            frame: frame,
            center: shape,
            radius: radius,
            background: background
        )
        let meanSector = sectors.reduce(0, +) / Double(max(sectors.count, 1))
        let peakToPeak = (sectors.max() ?? 0) - (sectors.min() ?? 0)
        let asymmetry = meanSector > 1e-3 ? peakToPeak / meanSector : 0
        return ComaResult(
            outer: FittedCircle(center: shape, radius: radius),
            inner: FittedCircle(center: brightness, radius: max(1.5, radius * 0.35)),
            vector: vector,
            magnitudePixels: magnitude,
            magnitudeNormalized: magnitude / radius,
            directionDegrees: wrapDegrees(atan2(vector.y, vector.x) * 180 / .pi),
            sectorAsymmetry: asymmetry,
            harmonicDirectionDegrees: wrapDegrees(firstHarmonic(sectors)),
            snr: snr,
            quality: inFocusQuality(pixelCount: n, radius: radius, frame: frame, snr: snr),
            isDonut: false
        )
    }

    private func geometricCentroid(mask: [UInt8], width: Int, height: Int) -> SIMD2<Double>? {
        var xSum = 0.0
        var ySum = 0.0
        var n = 0.0
        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                if mask[row + x] == 0 { continue }
                xSum += Double(x)
                ySum += Double(y)
                n += 1
            }
        }
        guard n >= 1 else { return nil }
        return SIMD2(xSum / n, ySum / n)
    }

    /// Azimuthally averaged first dark ring after the core, confirmed by a rise
    /// into the first diffraction ring.
    private func firstVisibleMinimum(
        frame: Frame,
        center: SIMD2<Double>,
        background: Double,
        maxRadius: Double
    ) -> Double? {
        let profile = radialProfile(
            frame: frame,
            center: center,
            background: background,
            maxRadius: maxRadius
        )
        guard profile.count >= 8 else { return nil }
        var smooth = profile
        if profile.count >= 3 {
            for i in 1..<(profile.count - 1) {
                smooth[i].intensity =
                    (profile[i - 1].intensity + profile[i].intensity + profile[i + 1].intensity) / 3
            }
        }
        guard let peakIndex = smooth.indices.max(by: { smooth[$0].intensity < smooth[$1].intensity }) else {
            return nil
        }
        let peak = smooth[peakIndex].intensity
        guard peak > 20 else { return nil }

        var dropped = false
        var i = peakIndex + 1
        while i < smooth.count - 2 {
            let cur = smooth[i].intensity
            if cur < peak * 0.45 { dropped = true }
            if dropped {
                let prev = smooth[i - 1].intensity
                let next = smooth[i + 1].intensity
                if cur <= prev, cur <= next, cur < peak * 0.2 {
                    let r = smooth[i].radius
                    var ringPeak = cur
                    var j = i + 1
                    while j < smooth.count, smooth[j].radius <= r * 1.85 {
                        ringPeak = max(ringPeak, smooth[j].intensity)
                        j += 1
                    }
                    let rise = max(12.0, 0.002 * peak)
                    if ringPeak > cur + rise, ringPeak > cur * 1.15 {
                        return r
                    }
                }
            }
            i += 1
        }
        return nil
    }

    /// If the first Airy ring is not visible, stop at the core's outer falloff.
    private func coreRadiusFallback(
        frame: Frame,
        center: SIMD2<Double>,
        background: Double,
        maxRadius: Double
    ) -> Double? {
        let profile = radialProfile(
            frame: frame,
            center: center,
            background: background,
            maxRadius: maxRadius
        )
        guard let peakIndex = profile.indices.max(by: { profile[$0].intensity < profile[$1].intensity }) else {
            return nil
        }
        let peak = profile[peakIndex].intensity
        guard peak > 20 else { return nil }
        let floor = peak * 0.08
        var i = peakIndex
        while i < profile.count {
            if profile[i].intensity < floor {
                return max(profile[i].radius, 2)
            }
            i += 1
        }
        return profile.last.map { max($0.radius, 2) }
    }

    private func radialProfile(
        frame: Frame,
        center: SIMD2<Double>,
        background: Double,
        maxRadius: Double
    ) -> [(radius: Double, intensity: Double)] {
        let binWidth = 0.5
        let binCount = max(2, Int(ceil(maxRadius / binWidth)) + 1)
        var sums = [Double](repeating: 0, count: binCount)
        var counts = [Double](repeating: 0, count: binCount)
        let width = frame.width
        let x0 = max(0, Int(floor(center.x - maxRadius)))
        let x1 = min(frame.width, Int(ceil(center.x + maxRadius)) + 1)
        let y0 = max(0, Int(floor(center.y - maxRadius)))
        let y1 = min(frame.height, Int(ceil(center.y + maxRadius)) + 1)
        for y in y0..<y1 {
            let row = y * width
            let dy = Double(y) - center.y
            for x in x0..<x1 {
                let dx = Double(x) - center.x
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
        return samples
    }

    private func diskSectorMeans(
        frame: Frame,
        center: SIMD2<Double>,
        radius: Double,
        background: Double
    ) -> [Double] {
        var sums = [Double](repeating: 0, count: sectorCount)
        var counts = [Double](repeating: 0, count: sectorCount)
        let r2max = radius * radius
        let width = frame.width
        let x0 = max(0, Int(floor(center.x - radius)))
        let x1 = min(frame.width, Int(ceil(center.x + radius)) + 1)
        let y0 = max(0, Int(floor(center.y - radius)))
        let y1 = min(frame.height, Int(ceil(center.y + radius)) + 1)
        for y in y0..<y1 {
            let row = y * width
            let dy = Double(y) - center.y
            for x in x0..<x1 {
                let dx = Double(x) - center.x
                let r2 = dx * dx + dy * dy
                if r2 > r2max || r2 < 1e-6 { continue }
                var angle = atan2(dy, dx)
                if angle < 0 { angle += 2 * .pi }
                let sector = min(sectorCount - 1, Int(angle / (2 * .pi) * Double(sectorCount)))
                sums[sector] += max(0, Double(frame.pixels[row + x]) - background)
                counts[sector] += 1
            }
        }
        return zip(sums, counts).map { $1 > 0 ? $0 / $1 : 0 }
    }

    private func isPerceptibleHole(_ hole: Hole, outer: FittedCircle) -> Bool {
        hole.pixelCount > 12 && hole.radius > 2 && hole.radius < outer.radius * 0.7
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

    private func inFocusQuality(pixelCount: Int, radius: Double, frame: Frame, snr: Double) -> Double {
        let minDim = Double(min(frame.width, frame.height))
        var q = 0.0
        if pixelCount >= 30 { q += 0.4 }
        if radius > 2 && radius < minDim * 0.4 { q += 0.2 }
        if snr > 8 { q += 0.2 }
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
