import CollimationCore
import Foundation

/// One drawing instruction, in view points with the origin at the top left of
/// the widget box.
///
/// A scene is a pure function from state to `[HUDPrimitive]`, and each app has
/// one rasterizer: `GraphicsContext` on macOS, an ImGui draw list in the
/// portable app. Adding a HUD widget means adding a scene and a test, never
/// drawing code in a view.
public enum HUDPrimitive: Equatable, Sendable {
    case line(from: SIMD2<Double>, to: SIMD2<Double>, color: HUDColor, width: Double)
    case polyline(points: [SIMD2<Double>], color: HUDColor, width: Double)
    case circle(center: SIMD2<Double>, radius: Double, color: HUDColor, width: Double)
    case disc(center: SIMD2<Double>, radius: Double, color: HUDColor)
    case rect(
        origin: SIMD2<Double>,
        size: SIMD2<Double>,
        color: HUDColor,
        width: Double,
        cornerRadius: Double
    )
    case fillRect(
        origin: SIMD2<Double>,
        size: SIMD2<Double>,
        color: HUDColor,
        cornerRadius: Double
    )
    case fillPolygon(points: [SIMD2<Double>], color: HUDColor)
    case text(
        String,
        at: SIMD2<Double>,
        anchor: HUDAnchor,
        color: HUDColor,
        size: Double,
        monospaced: Bool,
        weight: HUDWeight
    )
    indirect case clipped(
        origin: SIMD2<Double>,
        size: SIMD2<Double>,
        primitives: [HUDPrimitive]
    )
}

/// Shapes several scenes share.
public enum HUDShape {
    /// The crosshair used for the sensor center and the star marker: a cross of
    /// half-width `size` with a filled dot at the middle.
    public static func crosshair(
        at point: SIMD2<Double>,
        color: HUDColor,
        size: Double,
        lineWidth: Double = 1,
        dotRadius: Double? = nil
    ) -> [HUDPrimitive] {
        [
            .line(
                from: SIMD2(point.x - size, point.y),
                to: SIMD2(point.x + size, point.y),
                color: color,
                width: lineWidth
            ),
            .line(
                from: SIMD2(point.x, point.y - size),
                to: SIMD2(point.x, point.y + size),
                color: color,
                width: lineWidth
            ),
            .disc(center: point, radius: dotRadius ?? 3, color: color),
        ]
    }
}

/// Every colour the scenes draw, as explicit sRGB.
///
/// The pre-port views used SwiftUI `Color` values, some of them named system
/// colours. ImGui has no such names, so they are resolved here and both
/// rasterizers draw the same constants.
public enum OverlayChrome {
    public static let frameCenter = HUDColor.white.opacity(0.55)
    public static let outerRing = HUDColor(0.4, 0.75, 1)
    public static let innerRing = HUDColor(1, 0.75, 0.25)
    public static let coma = HUDColor(1, 0.35, 0.3)
    public static let starGood = HUDColor(0.3, 0.9, 0.4)
    public static let starFaint = HUDColor(1, 0.85, 0.15)
    public static let starSaturated = HUDColor(1, 0.22, 0.18)

    /// Stroke widths and sizes the overlay uses, in view points.
    public static let crosshairWidth = 1.0
    public static let sensorCrosshairSize = 18.0
    public static let starCrosshairSize = 14.0
    public static let crosshairDotRadius = 3.0
    public static let ringWidth = 1.2
    public static let comaWidth = 2.0
    /// The coma vector is drawn this many times longer than it measures.
    public static let comaVectorScale = 8.0

    public static func starMarker(peak: UInt16?) -> HUDColor {
        switch peak.map(StarQuality.from) {
        case .saturated: return starSaturated
        case .faint: return starFaint
        case .good, .none: return starGood
        }
    }
}
