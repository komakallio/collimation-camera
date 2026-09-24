import CollimationCore
import Foundation

/// The sidebar histogram with the black and white stretch markers.
///
/// Port of `HistogramView`. Bars are normalized to the tallest bin, so the
/// shape is readable regardless of exposure.
public enum HistogramScene {
    public static let barColor = HUDColor.white.opacity(0.55)
    public static let blackMarker = HUDColor.systemBlue.opacity(0.9)
    public static let whiteMarker = HUDColor.systemOrange.opacity(0.9)
    public static let background = HUDColor.black.opacity(0.35)
    public static let cornerRadius = 4.0
    public static let markerWidth = 1.0
    /// Bars never render thinner than this, so a wide histogram stays visible.
    public static let minimumBarWidth = 0.5

    public static func primitives(
        histogram: Histogram,
        stretch: StretchParams,
        size: SIMD2<Double>
    ) -> [HUDPrimitive] {
        var result: [HUDPrimitive] = []
        let maxBin = Double(max(histogram.bins.max() ?? 1, 1))
        let barWidth = size.x / Double(Histogram.binCount)
        for (index, value) in histogram.bins.enumerated() {
            let height = Double(value) / maxBin * size.y
            result.append(.fillRect(
                origin: SIMD2(Double(index) * barWidth, size.y - height),
                size: SIMD2(max(barWidth, minimumBarWidth), height),
                color: barColor,
                cornerRadius: 0
            ))
        }
        let blackX = stretch.black * size.x
        let whiteX = stretch.white * size.x
        result.append(.line(
            from: SIMD2(blackX, 0),
            to: SIMD2(blackX, size.y),
            color: blackMarker,
            width: markerWidth
        ))
        result.append(.line(
            from: SIMD2(whiteX, 0),
            to: SIMD2(whiteX, size.y),
            color: whiteMarker,
            width: markerWidth
        ))
        return result
    }
}

/// The dial showing which way the coma points.
///
/// Port of `CompassDial`. Angles are image angles: 0° is right and 90° is down,
/// matching the overlay arrow.
public enum CompassDialScene {
    public static let size = SIMD2(88.0, 88.0)
    /// Gap between the box edge and the dial.
    public static let inset = 4.0
    /// How far inside the rim the R/D/L/U labels sit.
    public static let labelInset = 10.0
    public static let labelSize = 8.0

    public static let rim = HUDColor.white.opacity(0.35)
    public static let labelColor = HUDColor.white.opacity(0.6)
    public static let arrow = HUDColor(1, 0.4, 0.3)
    public static let arrowWidth = 2.0

    public static let labels: [(String, Double)] = [("R", 0), ("D", 90), ("L", 180), ("U", 270)]

    public static func primitives(
        degrees: Double?,
        magnitude: Double,
        size boxSize: SIMD2<Double> = size
    ) -> [HUDPrimitive] {
        let radius = min(boxSize.x, boxSize.y) / 2 - inset
        let center = SIMD2(boxSize.x / 2, boxSize.y / 2)
        var result: [HUDPrimitive] = [
            .circle(center: center, radius: radius, color: rim, width: 1)
        ]
        for (label, angle) in labels {
            let radians = angle * .pi / 180
            result.append(.text(
                label,
                at: SIMD2(
                    center.x + cos(radians) * (radius - labelInset),
                    center.y + sin(radians) * (radius - labelInset)
                ),
                anchor: .center,
                color: labelColor,
                size: labelSize,
                monospaced: true,
                weight: .semibold
            ))
        }
        if let degrees {
            let radians = degrees * .pi / 180
            // A short arrow still reads as a direction, so the length starts at
            // a quarter of the radius and saturates at the rim.
            let length = radius * min(1, 0.25 + magnitude * 3)
            result.append(.line(
                from: center,
                to: SIMD2(center.x + cos(radians) * length, center.y + sin(radians) * length),
                color: arrow,
                width: arrowWidth
            ))
        }
        return result
    }
}
