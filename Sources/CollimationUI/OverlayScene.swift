import CollimationCore
import Foundation

/// The collimation overlay drawn over the live view.
///
/// Port of `OverlayView.body`. Coordinates are view points with the origin at
/// the top left of the live view.
public enum OverlayScene {
    public static func primitives(
        overlay: OverlayModel,
        zoom: Double,
        lockNormalized: SIMD2<Double>? = nil,
        liveCentroid: SIMD2<Double>? = nil,
        displayedWidth: Int? = nil,
        displayedHeight: Int? = nil,
        viewSize: SIMD2<Double>
    ) -> [HUDPrimitive] {
        // The live pose belongs to whatever frame the renderer is showing. If
        // that is not this overlay's frame, the pose would move the rings onto
        // the wrong pixels, so it is dropped.
        let poseMatchesDisplayed = displayedWidth == nil
            || displayedHeight == nil
            || (displayedWidth == overlay.imageWidth && displayedHeight == overlay.imageHeight)
        let live = poseMatchesDisplayed ? liveCentroid : nil

        let layout = ImageLayout(
            imageWidth: max(overlay.imageWidth, 1),
            imageHeight: max(overlay.imageHeight, 1),
            viewWidth: viewSize.x,
            viewHeight: viewSize.y,
            zoom: zoom,
            lockNormalized: poseMatchesDisplayed ? lockNormalized : nil,
            stabilizeCentroid: live ?? overlay.centroid
        )
        let ringShift = overlay.shift(toLiveCentroid: live)

        var result: [HUDPrimitive] = []

        // A cross through the sensor center, only while that point is on screen.
        // Each arm runs to the view edge and fades out along the way.
        if let sensorCenter = overlay.sensorCenterInImage,
           sensorCenter.x >= -2, sensorCenter.y >= -2,
           sensorCenter.x <= Double(overlay.imageWidth) + 2,
           sensorCenter.y <= Double(overlay.imageHeight) + 2 {
            result += fadingCross(at: layout.viewPoint(image: sensorCenter), viewSize: viewSize)
        }

        // The star, coloured by how well exposed it is.
        if let centroid = live ?? overlay.centroid {
            result += HUDShape.crosshair(
                at: layout.viewPoint(image: centroid),
                color: OverlayChrome.starMarker(peak: overlay.starPeak),
                size: OverlayChrome.starCrosshairSize,
                lineWidth: OverlayChrome.crosshairWidth,
                dotRadius: OverlayChrome.crosshairDotRadius
            )
        }

        if let outer = overlay.outer {
            result.append(circle(outer.translated(by: ringShift), layout: layout, color: OverlayChrome.outerRing))
        }
        if let inner = overlay.inner {
            result.append(circle(inner.translated(by: ringShift), layout: layout, color: OverlayChrome.innerRing))
        }
        if let outer = overlay.outer, let vector = overlay.comaVector {
            let origin = outer.center + ringShift
            let start = layout.viewPoint(image: origin)
            let end = layout.viewPoint(image: origin + vector * OverlayChrome.comaVectorScale)
            result.append(.line(from: start, to: end, color: OverlayChrome.coma, width: OverlayChrome.comaWidth))
        }
        return result
    }

    /// Four arms from the sensor center to the view edges. A stroke cannot
    /// carry a gradient, so each arm is short pieces whose alpha falls off
    /// with the square of the distance.
    private static func fadingCross(at center: SIMD2<Double>, viewSize: SIMD2<Double>) -> [HUDPrimitive] {
        guard center.x >= 0, center.y >= 0, center.x <= viewSize.x, center.y <= viewSize.y else { return [] }
        let ends = [
            SIMD2(0, center.y),
            SIMD2(viewSize.x, center.y),
            SIMD2(center.x, 0),
            SIMD2(center.x, viewSize.y),
        ]
        return ends.flatMap { fadingArm(from: center, to: $0) }
    }

    private static let fadeSteps = 12

    private static func fadingArm(from: SIMD2<Double>, to: SIMD2<Double>) -> [HUDPrimitive] {
        let length = hypot(to.x - from.x, to.y - from.y)
        guard length > 1 else { return [] }
        let steps = fadeSteps
        return (0..<steps).map { index in
            let t0 = Double(index) / Double(steps)
            let t1 = Double(index + 1) / Double(steps)
            let start = SIMD2(from.x + (to.x - from.x) * t0, from.y + (to.y - from.y) * t0)
            let end = SIMD2(from.x + (to.x - from.x) * t1, from.y + (to.y - from.y) * t1)
            let remain = 1 - (t0 + t1) / 2
            let alpha = Double(OverlayChrome.frameCenter.a) * remain * remain
            return .line(
                from: start,
                to: end,
                color: OverlayChrome.frameCenter.opacity(alpha),
                width: OverlayChrome.crosshairWidth
            )
        }
    }

    private static func circle(
        _ fitted: FittedCircle,
        layout: ImageLayout,
        color: HUDColor
    ) -> HUDPrimitive {
        .circle(
            center: layout.viewPoint(image: fitted.center),
            radius: fitted.radius * layout.zoom,
            color: color,
            width: OverlayChrome.ringWidth
        )
    }
}

/// The legend under the overlay: one row per marker with a small sample.
public enum LegendScene {
    public struct Row: Equatable, Sendable {
        public enum Mark: Equatable, Sendable {
            case cross(HUDColor)
            case starPeaks
            case ring(HUDColor)
            case line(HUDColor)
        }

        public var label: String
        public var mark: Mark

        public init(label: String, mark: Mark) {
            self.label = label
            self.mark = mark
        }
    }

    public static let markSize = SIMD2(28.0, 12.0)
    public static let rowSpacing = 5.0
    public static let markSpacing = 6.0

    public static let rows: [Row] = [
        Row(label: "Sensor center", mark: .cross(OverlayChrome.frameCenter)),
        Row(label: "Star", mark: .starPeaks),
        Row(label: "Outer ring", mark: .ring(OverlayChrome.outerRing)),
        Row(label: "Inner ring", mark: .ring(OverlayChrome.innerRing)),
        Row(label: "Coma", mark: .line(OverlayChrome.coma)),
    ]

    /// The sample drawn beside a legend label, inside a `markSize` box.
    public static func markPrimitives(_ mark: Row.Mark, size: SIMD2<Double> = markSize) -> [HUDPrimitive] {
        let center = SIMD2(size.x / 2, size.y / 2)
        switch mark {
        case .cross(let color):
            return [
                .line(from: SIMD2(2, center.y), to: SIMD2(size.x - 2, center.y), color: color, width: 1),
                .line(from: SIMD2(center.x, 1), to: SIMD2(center.x, size.y - 1), color: color, width: 1),
            ]
        case .starPeaks:
            let colors = [OverlayChrome.starGood, OverlayChrome.starFaint, OverlayChrome.starSaturated]
            let step = size.x / 4
            return colors.enumerated().flatMap { index, color in
                HUDShape.crosshair(
                    at: SIMD2(step * Double(index + 1), center.y),
                    color: color,
                    size: 4,
                    lineWidth: 1,
                    dotRadius: max(4 * 0.22, 1.2)
                )
            }
        case .ring(let color):
            return [.circle(center: center, radius: 5, color: color, width: 1.2)]
        case .line(let color):
            return [.line(from: SIMD2(1, center.y), to: SIMD2(size.x - 1, center.y), color: color, width: 2)]
        }
    }
}
