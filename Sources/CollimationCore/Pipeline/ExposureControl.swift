import Foundation

public enum ExposureControl {
    /// UI and auto-exposure limits: 0.1 ms … 100 ms.
    public static let minMicroseconds = 100
    public static let maxMicroseconds = 100_000
    public static let range = minMicroseconds...maxMicroseconds
    /// Fraction of 16-bit full well to hold the brightest pixels at.
    public static let targetPeak = 0.85
    /// Accept a peak within this band of `targetPeak` (absolute fraction of full well).
    public static let targetTolerance = 0.03
    /// When any pixel is clipped, multiply the current exposure by this factor.
    public static let saturationBackoff = 0.20
    public static let maxAutoIterations = 12

    public static func clamp(_ microseconds: Int) -> Int {
        min(max(microseconds, minMicroseconds), maxMicroseconds)
    }

    public static func isSaturated(peakADU: UInt16) -> Bool {
        peakADU >= StarQuality.clipADU
    }

    public static func isAtTarget(peakNormalized: Double, saturated: Bool = false) -> Bool {
        guard !saturated else { return false }
        let peak = min(max(peakNormalized, 0), 1)
        return abs(peak - targetPeak) <= targetTolerance
    }

    /// Next exposure: 20% of current if clipped, otherwise the scale that maps
    /// `peakNormalized` onto `targetPeak`.
    public static func adjustedMicroseconds(
        current: Int,
        peakNormalized: Double,
        saturated: Bool = false
    ) -> Int {
        let scale: Double
        if saturated {
            scale = saturationBackoff
        } else {
            let peak = min(max(peakNormalized, 1.0 / 65535.0), 1)
            scale = targetPeak / peak
        }
        let next = Double(max(current, 1)) * scale
        return clamp(Int(next.rounded()))
    }

    /// Brightest-pixel estimate from unstretched 16-bit ADU (not the displayed stretch).
    public static func peakNormalized(peakADU: UInt16) -> Double {
        Double(peakADU) / 65535.0
    }

    public static func peakNormalized(histogram: Histogram, detectionPeak: UInt16?) -> Double {
        peakNormalized(peakADU: max(histogram.maxADU, detectionPeak ?? 0))
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
