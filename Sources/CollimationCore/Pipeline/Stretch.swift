import Foundation

public enum StretchCurve: String, Equatable, Sendable, CaseIterable, Identifiable, Hashable {
    case mtf
    case arcsinh

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .mtf: return "MTF"
        case .arcsinh: return "Arcsinh"
        }
    }
}

public struct StretchParams: Equatable, Sendable {
    /// Black point as a fraction of the 16-bit range (0...1).
    public var black: Double
    /// White point as a fraction of the 16-bit range (0...1).
    public var white: Double
    /// Midtones balance in (0, 1). 0.5 is linear; values below 0.5 lift shadows (STF-style).
    public var midtones: Double
    /// Arcsinh factor α. `asinh(αx) / asinh(α)`; larger α lifts shadows more.
    public var arcsinh: Double
    public var curve: StretchCurve

    public init(
        black: Double = 0.01,
        white: Double = 1,
        midtones: Double = 0.25,
        arcsinh: Double = 10,
        curve: StretchCurve = .mtf
    ) {
        self.black = black
        self.white = white
        self.midtones = midtones
        self.arcsinh = arcsinh
        self.curve = curve
    }

    public static let `default` = StretchParams()
    /// Upper bound for the black point (5% of the 16-bit range).
    public static let blackRange: ClosedRange<Double> = 0...0.05
    public static let arcsinhRange: ClosedRange<Double> = 0.1...500

    /// PixInsight midtones transfer function.
    /// MTF(x, m) = ((m − 1) x) / ((2m − 1) x − m)
    public static func mtf(_ x: Double, midtones m: Double) -> Double {
        let x = min(max(x, 0), 1)
        let m = min(max(m, 1e-4), 1 - 1e-4)
        if x == 0 || x == 1 || abs(m - 0.5) < 1e-6 { return x }
        let y = ((m - 1) * x) / ((2 * m - 1) * x - m)
        return min(max(y, 0), 1)
    }

    /// Normalized arcsinh stretch: asinh(αx) / asinh(α).
    public static func arcsinh(_ x: Double, factor a: Double) -> Double {
        let x = min(max(x, 0), 1)
        let a = min(max(a, arcsinhRange.lowerBound), arcsinhRange.upperBound)
        if x == 0 { return 0 }
        if x == 1 { return 1 }
        let denom = Darwin.asinh(a)
        if denom < 1e-12 { return x }
        return min(max(Darwin.asinh(a * x) / denom, 0), 1)
    }

    /// Factor that maps `linear` to `target` under the arcsinh curve.
    public static func arcsinhFactor(mapping linear: Double, to target: Double) -> Double {
        let linear = min(max(linear, 1e-6), 1 - 1e-6)
        let target = min(max(target, 1e-6), 1 - 1e-6)
        if linear >= target - 1e-4 {
            return arcsinhRange.lowerBound
        }
        var lo = arcsinhRange.lowerBound
        var hi = arcsinhRange.upperBound
        if arcsinh(linear, factor: hi) < target {
            return hi
        }
        for _ in 0..<48 {
            let mid = (lo + hi) / 2
            if arcsinh(linear, factor: mid) < target {
                lo = mid
            } else {
                hi = mid
            }
        }
        return (lo + hi) / 2
    }

    public func apply(normalizedValue x: Double) -> Double {
        let span = max(white - black, 1e-6)
        let t = min(max((x - black) / span, 0), 1)
        switch curve {
        case .mtf:
            return Self.mtf(t, midtones: midtones)
        case .arcsinh:
            return Self.arcsinh(t, factor: arcsinh)
        }
    }

    /// Auto stretch: clip the black point, leave white at 100%, then choose
    /// the active curve so the median maps to 0.25.
    public static func auto(from histogram: Histogram, curve: StretchCurve = .mtf) -> StretchParams {
        let black = min(max(histogram.percentile(0.001), blackRange.lowerBound), blackRange.upperBound)
        let white = 1.0
        let median = histogram.percentile(0.5)
        let linear = (median - black) / max(white - black, 1e-6)
        let clampedLinear = min(max(linear, 1e-4), 1 - 1e-4)
        let targetBackground = 0.25
        let midtones = min(max(mtf(clampedLinear, midtones: targetBackground), 0.01), 0.6)
        let arcsinh = arcsinhFactor(mapping: clampedLinear, to: targetBackground)
        return StretchParams(
            black: black,
            white: white,
            midtones: midtones,
            arcsinh: arcsinh,
            curve: curve
        )
    }
}
