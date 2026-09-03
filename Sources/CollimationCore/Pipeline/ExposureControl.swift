import Foundation

public enum ExposureControl {
    /// UI and auto-exposure limits: 0.1 ms … 100 ms.
    public static let minMicroseconds = 100
    public static let maxMicroseconds = 100_000
    public static let range = minMicroseconds...maxMicroseconds
    /// Fraction of 16-bit full well to hold the brightest pixels at.
    public static let targetPeak = 0.80

    public static func clamp(_ microseconds: Int) -> Int {
        min(max(microseconds, minMicroseconds), maxMicroseconds)
    }

    /// Scale exposure so the current peak maps to `targetPeak` of saturation.
    public static func adjustedMicroseconds(
        current: Int,
        peakNormalized: Double
    ) -> Int {
        let peak = min(max(peakNormalized, 0), 1)
        let scale: Double
        if peak < 0.02 {
            scale = 4
        } else if peak > 0.98 {
            scale = 0.80 / peak * 0.7
        } else {
            scale = targetPeak / peak
        }
        let next = Double(max(current, 1)) * scale
        return clamp(Int(next.rounded()))
    }

    /// Brightest-pixel estimate from unstretched 16-bit ADU (not the displayed stretch).
    public static func peakNormalized(histogram: Histogram, detectionPeak: UInt16?) -> Double {
        let raw = max(histogram.maxADU, detectionPeak ?? 0)
        return Double(raw) / 65535.0
    }
}

/// Exposure quality of the tracked star, from its raw 16-bit peak.
public enum StarQuality: Equatable, Sendable {
    case faint
    case good
    case saturated

    public static let fullWell: UInt16 = 65535
    /// 12-bit cameras often occupy the top of a 16-bit container (`0xFFF0`).
    /// The live shader uses the same cutoff so clipped texels paint red.
    public static let clipADU: UInt16 = 0xFFF0
    public static let faintFraction = 0.10

    public static func from(peak: UInt16) -> StarQuality {
        if peak >= clipADU { return .saturated }
        if Double(peak) / Double(fullWell) < faintFraction { return .faint }
        return .good
    }
}
