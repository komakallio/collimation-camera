import Foundation

public struct DonutScene: Equatable, Sendable {
    public var sensorWidth: Int
    public var sensorHeight: Int
    public var starPosition: SIMD2<Double>
    public var outerRadius: Double
    public var innerRadius: Double
    /// Inner-hole offset relative to the outer center, in unbinned pixels.
    public var comaOffset: SIMD2<Double>
    /// Extra cosine intensity modulation along the coma direction (0...1).
    public var intensityAsymmetry: Double
    public var peakADU: Double
    public var backgroundADU: Double
    public var noiseSigma: Double
    public var seeingJitter: Double

    public init(
        sensorWidth: Int = 6252,
        sensorHeight: Int = 4176,
        starPosition: SIMD2<Double>? = nil,
        outerRadius: Double = 48,
        innerRadius: Double = 18,
        comaOffset: SIMD2<Double> = SIMD2(3.5, -2.0),
        intensityAsymmetry: Double = 0.28,
        peakADU: Double = 42_000,
        backgroundADU: Double = 900,
        noiseSigma: Double = 35,
        seeingJitter: Double = 0.6
    ) {
        self.sensorWidth = sensorWidth
        self.sensorHeight = sensorHeight
        self.starPosition = starPosition ?? SIMD2(Double(sensorWidth) / 2, Double(sensorHeight) / 2)
        self.outerRadius = outerRadius
        self.innerRadius = innerRadius
        self.comaOffset = comaOffset
        self.intensityAsymmetry = intensityAsymmetry
        self.peakADU = peakADU
        self.backgroundADU = backgroundADU
        self.noiseSigma = noiseSigma
        self.seeingJitter = seeingJitter
    }

    public var comaAngleRadians: Double {
        atan2(comaOffset.y, comaOffset.x)
    }
}

public struct DonutRenderer: Sendable {
    public var scene: DonutScene

    public init(scene: DonutScene = DonutScene()) {
        self.scene = scene
    }

    public func render(roi: ROI, jitter: SIMD2<Double> = .zero, rng: inout RNG) -> Frame {
        let width = roi.width
        let height = roi.height
        var pixels = [UInt16](repeating: 0, count: width * height)
        let origin = scene.starPosition + jitter
        let innerCenter = origin + scene.comaOffset
        let outerR = scene.outerRadius
        let innerR = scene.innerRadius
        let edge = max(1.2, outerR * 0.06)
        let innerEdge = max(1.0, innerR * 0.08)
        let comaAngle = scene.comaAngleRadians
        let bin = Double(roi.binning)

        for y in 0..<height {
            for x in 0..<width {
                let sx = Double(roi.x) + (Double(x) + 0.5) * bin
                let sy = Double(roi.y) + (Double(y) + 0.5) * bin
                let dxO = sx - origin.x
                let dyO = sy - origin.y
                let dO = sqrt(dxO * dxO + dyO * dyO)
                let dxI = sx - innerCenter.x
                let dyI = sy - innerCenter.y
                let dI = sqrt(dxI * dxI + dyI * dyI)

                let outer = smoothstep(outerR + edge, outerR - edge, dO)
                let hole = smoothstep(innerR - innerEdge, innerR + innerEdge, dI)
                var signal = outer * hole
                if signal > 0 {
                    let theta = atan2(dyO, dxO)
                    signal *= 1 + scene.intensityAsymmetry * cos(theta - comaAngle)
                    // Soft radial peak in the middle of the annulus.
                    let mid = (outerR + innerR) * 0.5
                    let radial = exp(-0.5 * pow((dO - mid) / max(outerR * 0.28, 1), 2))
                    signal *= 0.55 + 0.45 * radial
                }

                var value = scene.backgroundADU + signal * scene.peakADU
                if scene.noiseSigma > 0 {
                    value += rng.gaussian() * scene.noiseSigma
                }
                pixels[y * width + x] = UInt16(min(65535, max(0, value.rounded())))
            }
        }

        return Frame(width: width, height: height, pixels: pixels, roi: roi)
    }

    private func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

/// Small deterministic RNG so tests and the simulator are reproducible when seeded.
public struct RNG: Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        self.state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    public mutating func uniform() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }

    public mutating func gaussian() -> Double {
        let u1 = max(uniform(), 1e-12)
        let u2 = uniform()
        return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }
}
