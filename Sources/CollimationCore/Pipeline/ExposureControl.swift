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

    /// Brightest-pixel estimate: star peak if present, otherwise the 99.9th percentile.
    public static func peakNormalized(histogram: Histogram, detectionPeak: UInt16?) -> Double {
        if let detectionPeak, detectionPeak > 0 {
            return Double(detectionPeak) / 65535.0
        }
        return histogram.percentile(0.999)
    }
}
