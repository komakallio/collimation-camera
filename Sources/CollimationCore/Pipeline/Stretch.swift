import Foundation

public struct StretchParams: Equatable, Sendable {
    /// Black point as a fraction of the 16-bit range (0...1).
    public var black: Double
    /// White point as a fraction of the 16-bit range (0...1).
    public var white: Double
    public var gamma: Double

    public init(black: Double = 0.01, white: Double = 0.35, gamma: Double = 0.45) {
        self.black = black
        self.white = white
        self.gamma = gamma
    }

    public static let `default` = StretchParams()

    /// Screen-transfer-function style auto stretch from a histogram.
    public static func auto(from histogram: Histogram) -> StretchParams {
        let black = histogram.percentile(0.001)
        var white = histogram.percentile(0.999)
        if white - black < 0.004 {
            white = min(1, black + 0.02)
        }
        let median = histogram.percentile(0.5)
        let linear = (median - black) / max(white - black, 1e-6)
        let clampedLinear = min(max(linear, 0.02), 0.98)
        let targetMid: Double = 0.25
        var gamma = log(targetMid) / log(clampedLinear)
        gamma = min(max(gamma, 0.15), 4.0)
        return StretchParams(black: black, white: white, gamma: gamma)
    }
}
