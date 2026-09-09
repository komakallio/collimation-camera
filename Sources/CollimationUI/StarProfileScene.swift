import CollimationCore
import Foundation

/// The radial star profile plot, log scaled on the vertical axis.
///
/// Port of `StarProfileView`. The samples are an average of four cuts through
/// the star; the vertical axis runs from 0.15% of 16-bit full well to 100%,
/// because log(0) is undefined and the faint tail is what matters.
public enum StarProfileScene {
    public static let size = SIMD2(148.0, 102.0)
    public static let padding = 4.0
    public static let cornerRadius = 4.0
    public static let plotCornerRadius = 1.0

    /// 0.15% of full well is the bottom of the axis.
    public static let logFloor = 0.0015
    static let logMin = log10(logFloor)

    public static let background = HUDColor.black.opacity(0.5)
    public static let border = HUDColor.white.opacity(0.2)
    public static let plotFill = HUDColor.white.opacity(0.08)
    public static let plotBorder = HUDColor.white.opacity(0.75)
    public static let gridMinor = HUDColor.white.opacity(0.14)
    public static let gridMajor = HUDColor.white.opacity(0.32)
    public static let labelColor = HUDColor.white.opacity(0.7)
    public static let labelSize = 8.0
    public static let curve = OverlayChrome.starGood
    public static let curveFill = OverlayChrome.starGood.opacity(0.22)
    public static let curveWidth = 1.2

    public static func primitives(
        profile: StarIntensityProfile?,
        size boxSize: SIMD2<Double> = size
    ) -> [HUDPrimitive] {
        let origin = SIMD2(padding, padding)
        let plot = SIMD2(boxSize.x - padding * 2, boxSize.y - padding * 2)

        var result: [HUDPrimitive] = [
            .fillRect(origin: origin, size: plot, color: plotFill, cornerRadius: plotCornerRadius)
        ]

        var clipped = grid(origin: origin, size: plot)
        if let profile, profile.samples.count >= 2 {
            clipped += curvePrimitives(samples: profile.samples, origin: origin, size: plot)
        }
        result.append(.clipped(origin: origin, size: plot, cornerRadius: plotCornerRadius, primitives: clipped))

        result.append(
            .rect(origin: origin, size: plot, color: plotBorder, width: 1, cornerRadius: plotCornerRadius)
        )
        result += labels(origin: origin, size: plot)
        return result
    }

    /// Vertical position of a normalized intensity, log scaled.
    public static func yPosition(_ value: Double, origin: SIMD2<Double>, size: SIMD2<Double>) -> Double {
        let clamped = min(max(value, logFloor), 1)
        let t = (log10(clamped) - logMin) / -logMin
        return origin.y + size.y - t * size.y
    }

    static func grid(origin: SIMD2<Double>, size: SIMD2<Double>) -> [HUDPrimitive] {
        var result: [HUDPrimitive] = []
        let n = 4
        for i in 1..<n {
            let x = origin.x + size.x * Double(i) / Double(n)
            let isMajor = i * 2 == n
            result.append(.line(
                from: SIMD2(x, origin.y),
                to: SIMD2(x, origin.y + size.y),
                color: isMajor ? gridMajor : gridMinor,
                width: isMajor ? 0.6 : 0.5
            ))
        }
        for decade in [1e-2, 1e-1] {
            let y = yPosition(decade, origin: origin, size: size)
            let isMajor = decade == 1e-1
            result.append(.line(
                from: SIMD2(origin.x, y),
                to: SIMD2(origin.x + size.x, y),
                color: isMajor ? gridMajor : gridMinor,
                width: isMajor ? 0.6 : 0.5
            ))
        }
        return result
    }

    static func labels(origin: SIMD2<Double>, size: SIMD2<Double>) -> [HUDPrimitive] {
        let x = origin.x + 3
        return [
            .text(
                "100%",
                at: SIMD2(x, origin.y + 2),
                anchor: .topLeading,
                color: labelColor,
                size: labelSize,
                monospaced: true,
                weight: .medium
            ),
            .text(
                "1%",
                at: SIMD2(x, yPosition(0.01, origin: origin, size: size)),
                anchor: .leading,
                color: labelColor,
                size: labelSize,
                monospaced: true,
                weight: .medium
            ),
            .text(
                "0.15%",
                at: SIMD2(x, origin.y + size.y - 2),
                anchor: .bottomLeading,
                color: labelColor,
                size: labelSize,
                monospaced: true,
                weight: .medium
            ),
        ]
    }

    static func curvePrimitives(
        samples: [Double],
        origin: SIMD2<Double>,
        size: SIMD2<Double>
    ) -> [HUDPrimitive] {
        let last = samples.count - 1
        var points: [SIMD2<Double>] = []
        points.reserveCapacity(samples.count)
        for (index, value) in samples.enumerated() {
            let x = origin.x + size.x * Double(index) / Double(last)
            points.append(SIMD2(x, yPosition(value, origin: origin, size: size)))
        }
        // The filled area closes down to the baseline at both ends.
        var area = [SIMD2(points[0].x, origin.y + size.y)]
        area += points
        area.append(SIMD2(origin.x + size.x, origin.y + size.y))
        return [
            .fillPolygon(points: area, color: curveFill),
            .polyline(points: points, color: curve, width: curveWidth),
        ]
    }
}
