import Foundation

public struct ROI: Equatable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
    public var binning: Int

    public init(x: Int, y: Int, width: Int, height: Int, binning: Int = 1) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.binning = max(1, binning)
    }

    public var size: SIMD2<Int> { SIMD2(width, height) }

    /// Unbinned width of this ROI on the sensor.
    public var sensorWidth: Int { width * binning }
    /// Unbinned height of this ROI on the sensor.
    public var sensorHeight: Int { height * binning }

    public func contains(sensorPoint p: SIMD2<Double>) -> Bool {
        p.x >= Double(x) && p.y >= Double(y)
            && p.x < Double(x + width * binning)
            && p.y < Double(y + height * binning)
    }

    /// Map a pixel in this frame to unbinned sensor coordinates.
    public func sensorPoint(fromFramePixel p: SIMD2<Double>) -> SIMD2<Double> {
        SIMD2(
            Double(x) + (p.x + 0.5) * Double(binning),
            Double(y) + (p.y + 0.5) * Double(binning)
        )
    }

    /// Map unbinned sensor coordinates to a pixel in this frame.
    public func framePixel(fromSensorPoint p: SIMD2<Double>) -> SIMD2<Double> {
        SIMD2(
            (p.x - Double(x)) / Double(binning) - 0.5,
            (p.y - Double(y)) / Double(binning) - 0.5
        )
    }
}

/// Camera readout vs the software window used for analysis and display.
public enum CaptureLayout {
    /// Hardware ROI while a star is tracked. Large enough that digital
    /// stabilization can pan without restarting the camera stream.
    public static let trackingHardwareSize = 2048
    /// Software crop for detection, histogram, coma, FWHM, and live view while tracking.
    public static let displayCropSize = 512
    /// `centeredROI` may shrink a 2048 request by a few pixels.
    public static let hardwareSizeSlack = 32
    /// Hardware cameras are capped here even when a small ROI could run faster.
    /// Player One `POA_FRAME_LIMIT` uses 0 for unlimited.
    public static let maxReadoutFPS = 30

    public static func clampedReadoutFPS(range: ClosedRange<Int>?) -> Int {
        let requested = maxReadoutFPS
        guard let range else { return requested }
        let lo = max(range.lowerBound, 1)
        let hi = max(range.upperBound, lo)
        return min(max(requested, lo), hi)
    }

    public static func isTrackingCapture(_ frame: Frame) -> Bool {
        let shortest = min(frame.width, frame.height)
        let longest = max(frame.width, frame.height)
        guard shortest >= displayCropSize else { return false }
        guard longest <= trackingHardwareSize + hardwareSizeSlack else { return false }
        return longest - shortest <= hardwareSizeSlack * 8
    }

    /// 512×512 around the last centroid when the frame is larger than the crop.
    /// Binned full-frame search (no seed) stays full so the whole sensor can be
    /// scanned. Unbinned mount-centering still gets a local crop so detection
    /// stays fast while the live view shows the full sensor.
    public static func analysisFrame(from frame: Frame, seed: SIMD2<Double>?) -> Frame {
        let shortest = min(frame.width, frame.height)
        guard shortest > displayCropSize else { return frame }
        if !isTrackingCapture(frame), seed == nil {
            return frame
        }
        let center = seed ?? SIMD2(Double(frame.width) / 2, Double(frame.height) / 2)
        return frame.cropped(around: center, size: displayCropSize)
    }

    /// 512×512 around the star on a tracking capture; otherwise the full frame
    /// (search and mount centering).
    public static func displayFrame(
        from frame: Frame,
        tracking: TrackingState,
        centroid: SIMD2<Double>?
    ) -> Frame {
        guard tracking == .tracking, isTrackingCapture(frame) else {
            return frame
        }
        return analysisFrame(from: frame, seed: centroid)
    }
}

public struct ImageLayout: Equatable, Sendable {
    public var imageWidth: Int
    public var imageHeight: Int
    public var viewWidth: Double
    public var viewHeight: Double
    /// View pixels per image pixel. 1.0 is 1:1.
    public var zoom: Double
    /// Extra translation in image pixels, applied after centering.
    public var pan: SIMD2<Double>

    public init(
        imageWidth: Int,
        imageHeight: Int,
        viewWidth: Double,
        viewHeight: Double,
        zoom: Double,
        pan: SIMD2<Double> = .zero
    ) {
        self.imageWidth = max(1, imageWidth)
        self.imageHeight = max(1, imageHeight)
        self.viewWidth = viewWidth
        self.viewHeight = viewHeight
        self.zoom = max(0.01, zoom)
        self.pan = pan
    }

    public init(
        imageWidth: Int,
        imageHeight: Int,
        viewWidth: Double,
        viewHeight: Double,
        zoom: Double,
        lockNormalized: SIMD2<Double>?,
        stabilizeCentroid: SIMD2<Double>?
    ) {
        let pan: SIMD2<Double>
        if let lockNormalized, let stabilizeCentroid {
            pan = ImageLayout.pan(
                locking: stabilizeCentroid,
                toNormalized: lockNormalized,
                imageWidth: imageWidth,
                imageHeight: imageHeight,
                viewWidth: viewWidth,
                viewHeight: viewHeight,
                zoom: zoom
            )
        } else {
            pan = .zero
        }
        self.init(
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            viewWidth: viewWidth,
            viewHeight: viewHeight,
            zoom: zoom,
            pan: pan
        )
    }

    public var imageRect: (x: Double, y: Double, width: Double, height: Double) {
        let w = Double(imageWidth) * zoom
        let h = Double(imageHeight) * zoom
        return (
            (viewWidth - w) / 2 + pan.x * zoom,
            (viewHeight - h) / 2 + pan.y * zoom,
            w,
            h
        )
    }

    public func viewPoint(image: SIMD2<Double>) -> SIMD2<Double> {
        let r = imageRect
        return SIMD2(r.x + image.x * zoom, r.y + image.y * zoom)
    }

    public func imagePoint(view: SIMD2<Double>) -> SIMD2<Double> {
        let r = imageRect
        return SIMD2((view.x - r.x) / zoom, (view.y - r.y) / zoom)
    }

    /// Image-pixel pan that places `centroid` at `lockNormalized` (0…1 in the view).
    public static func pan(
        locking centroid: SIMD2<Double>,
        toNormalized lock: SIMD2<Double>,
        imageWidth: Int,
        imageHeight: Int,
        viewWidth: Double,
        viewHeight: Double,
        zoom: Double
    ) -> SIMD2<Double> {
        let layout = ImageLayout(
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            viewWidth: viewWidth,
            viewHeight: viewHeight,
            zoom: zoom
        )
        let lockView = SIMD2(lock.x * viewWidth, lock.y * viewHeight)
        return (lockView - layout.viewPoint(image: centroid)) / layout.zoom
    }

    public static func fitZoom(
        imageWidth: Int,
        imageHeight: Int,
        viewWidth: Double,
        viewHeight: Double
    ) -> Double {
        guard imageWidth > 0, imageHeight > 0, viewWidth > 0, viewHeight > 0 else { return 1 }
        return min(viewWidth / Double(imageWidth), viewHeight / Double(imageHeight))
    }
}

public enum CameraError: Error, LocalizedError, Sendable {
    case sdkNotFound
    case sdkSymbolMissing(String)
    case notConnected
    case timeout
    case disconnected
    case invalidROI
    case poa(code: Int32, message: String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .sdkNotFound:
            return "Player One Camera SDK library was not found. Place libPlayerOneCamera.dylib in Vendor/PlayerOne or the app Frameworks folder."
        case .sdkSymbolMissing(let name):
            return "Player One SDK is missing symbol \(name)."
        case .notConnected:
            return "No camera is connected."
        case .timeout:
            return "Timed out waiting for a camera frame."
        case .disconnected:
            return "The camera was disconnected."
        case .invalidROI:
            return "The requested ROI is not valid for this sensor."
        case .poa(_, let message):
            return message
        case .unsupported(let detail):
            return detail
        }
    }
}

public enum Alignment {
    public static func down(_ value: Int, to multiple: Int) -> Int {
        guard multiple > 0 else { return value }
        return (value / multiple) * multiple
    }

    public static func up(_ value: Int, to multiple: Int) -> Int {
        guard multiple > 0 else { return value }
        return ((value + multiple - 1) / multiple) * multiple
    }

    /// Build a camera-legal ROI centered on a sensor point.
    public static func centeredROI(
        around sensorPoint: SIMD2<Double>,
        size: Int,
        sensorWidth: Int,
        sensorHeight: Int,
        binning: Int = 1
    ) -> ROI {
        let bin = max(1, binning)
        let requested = max(8, size)
        var width = down(requested / bin, to: 4)
        var height = down(requested / bin, to: 2)
        width = max(width, 8)
        height = max(height, 8)
        width = min(width, down(sensorWidth / bin, to: 4))
        height = min(height, down(sensorHeight / bin, to: 2))

        var x = Int(sensorPoint.x.rounded()) - (width * bin) / 2
        var y = Int(sensorPoint.y.rounded()) - (height * bin) / 2
        x = down(max(0, x), to: 4)
        y = down(max(0, y), to: 2)
        x = min(x, max(0, sensorWidth - width * bin))
        y = min(y, max(0, sensorHeight - height * bin))
        x = down(x, to: 4)
        y = down(y, to: 2)
        return ROI(x: x, y: y, width: width, height: height, binning: bin)
    }

    public static func fullFrameROI(sensorWidth: Int, sensorHeight: Int, binning: Int) -> ROI {
        let bin = max(1, binning)
        let width = down(sensorWidth / bin, to: 4)
        let height = down(sensorHeight / bin, to: 2)
        return ROI(x: 0, y: 0, width: max(width, 8), height: max(height, 8), binning: bin)
    }
}
