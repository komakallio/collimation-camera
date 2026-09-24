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
        viewSize: SIMD2<Double>,
        showCollimation: Bool = true,
        showSensorMarks: Bool = true
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

        if showSensorMarks, overlay.trackingState == .tracking {
            result += trackingGrid(overlay: overlay, layout: layout)
        }

        // A cross through the sensor center, 200 sensor pixels each way, only
        // while that point is on screen. The arms fade out to the grid colour.
        if showSensorMarks, let sensorCenter = overlay.sensorCenterInImage,
           sensorCenter.x >= -2, sensorCenter.y >= -2,
           sensorCenter.x <= Double(overlay.imageWidth) + 2,
           sensorCenter.y <= Double(overlay.imageHeight) + 2 {
            let binning = Double(max(overlay.roi.binning, 1))
            let arm = OverlayChrome.sensorCrossArmPixels / binning * layout.zoom
            // While the grid is up, pieces that have already reached its colour
            // would paint over the center lines and come out brighter.
            let gridUnderneath = overlay.trackingState == .tracking
            result += fadingCross(
                at: layout.viewPoint(image: sensorCenter),
                arm: arm,
                omitGridColor: gridUnderneath
            )
        }

        // The star, coloured by how well exposed it is.
        if showSensorMarks, let centroid = live ?? overlay.centroid {
            result += HUDShape.crosshair(
                at: layout.viewPoint(image: centroid),
                color: OverlayChrome.starMarker(peak: overlay.starPeak),
                size: OverlayChrome.starCrosshairSize,
                lineWidth: OverlayChrome.crosshairWidth,
                dotRadius: OverlayChrome.crosshairDotRadius
            )
        }

        if showCollimation, let outer = overlay.outer {
            result.append(circle(outer.translated(by: ringShift), layout: layout, color: OverlayChrome.outerRing))
        }
        if showCollimation, let inner = overlay.inner {
            result.append(circle(inner.translated(by: ringShift), layout: layout, color: OverlayChrome.innerRing))
        }
        if showCollimation, let outer = overlay.outer, let vector = overlay.comaVector {
            let origin = outer.center + ringShift
            let start = layout.viewPoint(image: origin)
            let end = layout.viewPoint(image: origin + vector * OverlayChrome.comaVectorScale)
            result.append(.line(from: start, to: end, color: OverlayChrome.coma, width: OverlayChrome.comaWidth))
        }
        return result
    }

    /// Four arms of `arm` view points. A stroke cannot carry a gradient, so
    /// each arm is short pieces whose alpha falls off with the square of the
    /// distance.
    private static func fadingCross(at center: SIMD2<Double>, arm: Double, omitGridColor: Bool) -> [HUDPrimitive] {
        guard arm > 1 else { return [] }
        let ends = [
            SIMD2(center.x - arm, center.y),
            SIMD2(center.x + arm, center.y),
            SIMD2(center.x, center.y - arm),
            SIMD2(center.x, center.y + arm),
        ]
        return ends.flatMap { fadingArm(from: center, to: $0, omitGridColor: omitGridColor) }
    }

    private static let fadeSteps = 12

    private static func fadingArm(from: SIMD2<Double>, to: SIMD2<Double>, omitGridColor: Bool) -> [HUDPrimitive] {
        let length = hypot(to.x - from.x, to.y - from.y)
        guard length > 1 else { return [] }
        let steps = fadeSteps
        return (0..<steps).compactMap { index in
            let t0 = Double(index) / Double(steps)
            let t1 = Double(index + 1) / Double(steps)
            let start = SIMD2(from.x + (to.x - from.x) * t0, from.y + (to.y - from.y) * t0)
            let end = SIMD2(from.x + (to.x - from.x) * t1, from.y + (to.y - from.y) * t1)
            // Square falloff, twice as steep as a full-arm fade, so the arm
            // matches the grid colour halfway out and stays there.
            let remain = 1 - t1
            let traveled = min(1, (1 - remain) * 2)
            let color = OverlayChrome.frameCenter.mixed(
                with: OverlayChrome.sensorGrid,
                amount: traveled * traveled
            )
            if omitGridColor, color == OverlayChrome.sensorGrid { return nil }
            return .line(
                from: start,
                to: end,
                color: color,
                width: OverlayChrome.crosshairWidth
            )
        }
    }

    /// Lines every 200 unbinned sensor pixels, anchored on the sensor center,
    /// clipped to the displayed image.
    private static func trackingGrid(overlay: OverlayModel, layout: ImageLayout) -> [HUDPrimitive] {
        guard overlay.sensorWidth > 0, overlay.sensorHeight > 0, overlay.imageWidth > 0 else { return [] }
        let spacing = OverlayChrome.sensorCrossArmPixels
        guard spacing > 0 else { return [] }
        let center = MountGuide.frameCenter(width: overlay.sensorWidth, height: overlay.sensorHeight)
        let rect = layout.imageRect
        let color = OverlayChrome.sensorGrid
        let width = OverlayChrome.sensorGridWidth
        var lines: [HUDPrimitive] = []

        func viewX(_ sensorX: Double) -> Double {
            layout.viewPoint(image: overlay.roi.framePixel(fromSensorPoint: SIMD2(sensorX, center.y))).x
        }
        func viewY(_ sensorY: Double) -> Double {
            layout.viewPoint(image: overlay.roi.framePixel(fromSensorPoint: SIMD2(center.x, sensorY))).y
        }

        let left = Double(overlay.roi.x)
        let right = Double(overlay.roi.x + overlay.roi.sensorWidth)
        let top = Double(overlay.roi.y)
        let bottom = Double(overlay.roi.y + overlay.roi.sensorHeight)
        let firstColumn = Int(ceil((left - center.x) / spacing))
        let lastColumn = Int(floor((right - center.x) / spacing))
        let firstRow = Int(ceil((top - center.y) / spacing))
        let lastRow = Int(floor((bottom - center.y) / spacing))

        if firstColumn <= lastColumn {
            for n in firstColumn...lastColumn {
                let x = viewX(center.x + Double(n) * spacing)
                guard x >= rect.x - 0.5, x <= rect.x + rect.width + 0.5 else { continue }
                lines.append(.line(
                    from: SIMD2(x, rect.y),
                    to: SIMD2(x, rect.y + rect.height),
                    color: color,
                    width: width
                ))
            }
        }
        if firstRow <= lastRow {
            for n in firstRow...lastRow {
                let y = viewY(center.y + Double(n) * spacing)
                guard y >= rect.y - 0.5, y <= rect.y + rect.height + 0.5 else { continue }
                lines.append(.line(
                    from: SIMD2(rect.x, y),
                    to: SIMD2(rect.x + rect.width, y),
                    color: color,
                    width: width
                ))
            }
        }
        return lines
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

        public enum Group: Equatable, Sendable {
            case sensor
            case collimation
        }

        public var label: String
        public var mark: Mark
        public var group: Group

        public init(label: String, mark: Mark, group: Group) {
            self.label = label
            self.mark = mark
            self.group = group
        }
    }

    public static func rows(collimation: Bool, sensorMarks: Bool) -> [Row] {
        rows.filter { row in
            switch row.group {
            case .sensor: return sensorMarks
            case .collimation: return collimation
            }
        }
    }

    public static let markSize = SIMD2(28.0, 12.0)
    public static let rowSpacing = 5.0
    public static let markSpacing = 6.0

    public static let rows: [Row] = [
        Row(label: "Sensor center", mark: .cross(OverlayChrome.frameCenter), group: .sensor),
        Row(label: "Star", mark: .starPeaks, group: .sensor),
        Row(label: "Outer ring", mark: .ring(OverlayChrome.outerRing), group: .collimation),
        Row(label: "Inner ring", mark: .ring(OverlayChrome.innerRing), group: .collimation),
        Row(label: "Coma", mark: .line(OverlayChrome.coma), group: .collimation),
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
