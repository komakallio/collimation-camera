import CollimationCore
import Foundation

/// The small full-sensor map showing where the camera ROI sits.
///
/// Port of `ROIMapView`. The box keeps the sensor aspect ratio, so its size
/// depends on the camera and the caller must ask for it before laying out.
public enum ROIMapScene {
    public static let maxSize = SIMD2(140.0, 94.0)
    /// Padding between the box edge and the sensor rectangle.
    public static let padding = 4.0
    public static let cornerRadius = 4.0
    public static let plotCornerRadius = 1.0

    public static let background = HUDColor.black.opacity(0.5)
    public static let border = HUDColor.white.opacity(0.2)
    public static let sensorFill = HUDColor.white.opacity(0.08)
    public static let sensorBorder = HUDColor.white.opacity(0.75)
    public static let gridMinor = HUDColor.white.opacity(0.14)
    public static let gridMajor = HUDColor.white.opacity(0.32)
    public static let roiFill = HUDColor.systemRed.opacity(0.28)
    public static let roiBorder = HUDColor.systemRed
    public static let centroid = HUDColor.systemYellow
    public static let plusArm = 4.0
    public static let plusWidth = 1.25
    /// Sensor quarters: the middle line of four divisions is drawn brighter.
    public static let gridDivisions = 4

    public static func size(sensorWidth: Int, sensorHeight: Int) -> SIMD2<Double> {
        let sw = Double(max(sensorWidth, 1))
        let sh = Double(max(sensorHeight, 1))
        let scale = min(maxSize.x / sw, maxSize.y / sh)
        return SIMD2(sw * scale + padding * 2, sh * scale + padding * 2)
    }

    public static func primitives(
        sensorWidth: Int,
        sensorHeight: Int,
        roi: ROI,
        centroidInFrame: SIMD2<Double>? = nil,
        size boxSize: SIMD2<Double>? = nil
    ) -> [HUDPrimitive] {
        let box = boxSize ?? size(sensorWidth: sensorWidth, sensorHeight: sensorHeight)
        let sw = Double(max(sensorWidth, 1))
        let sh = Double(max(sensorHeight, 1))
        let scale = min((box.x - padding * 2) / sw, (box.y - padding * 2) / sh)
        let frame = SIMD2(sw * scale, sh * scale)
        let origin = SIMD2((box.x - frame.x) / 2, (box.y - frame.y) / 2)

        var result: [HUDPrimitive] = [
            .fillRect(origin: origin, size: frame, color: sensorFill, cornerRadius: plotCornerRadius)
        ]
        result.append(
            .clipped(origin: origin, size: frame, primitives: grid(origin: origin, size: frame))
        )
        result.append(
            .rect(origin: origin, size: frame, color: sensorBorder, width: 1, cornerRadius: plotCornerRadius)
        )

        let sensorCenter = MountGuide.frameCenter(width: sensorWidth, height: sensorHeight)
        result += plus(
            at: SIMD2(origin.x + sensorCenter.x * scale, origin.y + sensorCenter.y * scale),
            color: OverlayChrome.frameCenter
        )

        // A tiny ROI still needs to be visible, hence the 1.5 pt floor.
        let roiOrigin = SIMD2(origin.x + Double(roi.x) * scale, origin.y + Double(roi.y) * scale)
        let roiSize = SIMD2(
            max(Double(roi.sensorWidth) * scale, 1.5),
            max(Double(roi.sensorHeight) * scale, 1.5)
        )
        result.append(.fillRect(origin: roiOrigin, size: roiSize, color: roiFill, cornerRadius: 0))
        result.append(.rect(origin: roiOrigin, size: roiSize, color: roiBorder, width: 1.2, cornerRadius: 0))

        if let centroidInFrame {
            let sensor = roi.sensorPoint(fromFramePixel: centroidInFrame)
            result += plus(
                at: SIMD2(origin.x + sensor.x * scale, origin.y + sensor.y * scale),
                color: centroid
            )
        }
        return result
    }

    static func grid(origin: SIMD2<Double>, size: SIMD2<Double>) -> [HUDPrimitive] {
        let n = max(2, gridDivisions)
        var result: [HUDPrimitive] = []
        for i in 1..<n {
            let x = origin.x + size.x * Double(i) / Double(n)
            let y = origin.y + size.y * Double(i) / Double(n)
            let isMajor = i * 2 == n
            let color = isMajor ? gridMajor : gridMinor
            let width = isMajor ? 0.6 : 0.5
            result.append(.line(from: SIMD2(x, origin.y), to: SIMD2(x, origin.y + size.y), color: color, width: width))
            result.append(.line(from: SIMD2(origin.x, y), to: SIMD2(origin.x + size.x, y), color: color, width: width))
        }
        return result
    }

    static func plus(at point: SIMD2<Double>, color: HUDColor) -> [HUDPrimitive] {
        [
            .line(
                from: SIMD2(point.x - plusArm, point.y),
                to: SIMD2(point.x + plusArm, point.y),
                color: color,
                width: plusWidth
            ),
            .line(
                from: SIMD2(point.x, point.y - plusArm),
                to: SIMD2(point.x, point.y + plusArm),
                color: color,
                width: plusWidth
            ),
        ]
    }
}
