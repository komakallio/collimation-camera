import Foundation

public struct StretchParams: Equatable, Sendable {
    /// Black point as a fraction of the 16-bit range (0...1).
    public var black: Double
    /// White point as a fraction of the 16-bit range (0...1).
    public var white: Double
    /// Midtones balance in (0, 1). 0.5 is linear; values below 0.5 lift shadows (STF-style).
    public var midtones: Double

    public init(black: Double = 0.01, white: Double = 0.35, midtones: Double = 0.25) {
        self.black = black
        self.white = white
        self.midtones = midtones
    }

    public static let `default` = StretchParams()

    /// PixInsight midtones transfer function.
    /// MTF(x, m) = ((m − 1) x) / ((2m − 1) x − m)
    public static func mtf(_ x: Double, midtones m: Double) -> Double {
        let x = min(max(x, 0), 1)
        let m = min(max(m, 1e-4), 1 - 1e-4)
        if x == 0 || x == 1 || abs(m - 0.5) < 1e-6 { return x }
        let y = ((m - 1) * x) / ((2 * m - 1) * x - m)
        return min(max(y, 0), 1)
    }

    public func apply(normalizedValue x: Double) -> Double {
        let span = max(white - black, 1e-6)
        let t = min(max((x - black) / span, 0), 1)
        return Self.mtf(t, midtones: midtones)
    }

    /// Auto stretch: clip by percentiles, then choose midtones so the median maps to 0.25.
    public static func auto(from histogram: Histogram) -> StretchParams {
        let black = histogram.percentile(0.001)
        var white = histogram.percentile(0.999)
        if white - black < 0.004 {
            white = min(1, black + 0.02)
        }
        let median = histogram.percentile(0.5)
        let linear = (median - black) / max(white - black, 1e-6)
        let clampedLinear = min(max(linear, 1e-4), 1 - 1e-4)
        let targetBackground = 0.25
        let midtones = min(max(mtf(clampedLinear, midtones: targetBackground), 0.01), 0.6)
        return StretchParams(black: black, white: white, midtones: midtones)
    }
}
