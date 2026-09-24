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

        // The sensor center, only while it is inside the displayed frame.
        if let sensorCenter = overlay.sensorCenterInImage,
           sensorCenter.x >= -2, sensorCenter.y >= -2,
           sensorCenter.x <= Double(overlay.imageWidth) + 2,
           sensorCenter.y <= Double(overlay.imageHeight) + 2 {
            result += HUDShape.crosshair(
                at: layout.viewPoint(image: sensorCenter),
                color: OverlayChrome.frameCenter,
                size: OverlayChrome.sensorCrosshairSize,
                lineWidth: OverlayChrome.crosshairWidth,
                dotRadius: OverlayChrome.crosshairDotRadius
            )
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
            case crosshair(HUDColor)
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
        Row(label: "Sensor center", mark: .crosshair(OverlayChrome.frameCenter)),
        Row(label: "Star", mark: .starPeaks),
        Row(label: "Outer ring", mark: .ring(OverlayChrome.outerRing)),
        Row(label: "Inner ring", mark: .ring(OverlayChrome.innerRing)),
        Row(label: "Coma", mark: .line(OverlayChrome.coma)),
    ]

    /// The sample drawn beside a legend label, inside a `markSize` box.
    public static func markPrimitives(_ mark: Row.Mark, size: SIMD2<Double> = markSize) -> [HUDPrimitive] {
        let center = SIMD2(size.x / 2, size.y / 2)
        switch mark {
        case .crosshair(let color):
            return HUDShape.crosshair(at: center, color: color, size: 8, lineWidth: 1, dotRadius: max(8 * 0.22, 1.2))
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
