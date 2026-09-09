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
    /// Crop recorded for Save Stacked and Save Constellation.
    public static let stackingCropSize = 256
    /// `centeredROI` may shrink a 2048 request by a few pixels.
    public static let hardwareSizeSlack = 32
    /// Live-view readout cap. Hardware cameras are held here even when a small
    /// ROI could run faster. Player One `POA_FRAME_LIMIT` uses 0 for unlimited.
    public static let maxReadoutFPS = 30
    /// Requested `POA_FRAME_LIMIT` while capturing a stack (0 = unlimited).
    public static let unlimitedReadoutFPS = 0

    public static func clampedReadoutFPS(range: ClosedRange<Int>?) -> Int {
        let requested = maxReadoutFPS
        guard let range else { return requested }
        let lo = max(range.lowerBound, 1)
        let hi = max(range.upperBound, lo)
        return min(max(requested, lo), hi)
    }

    /// Fastest allowed readout for stack capture. Prefers unlimited (0) when
    /// the camera accepts it; otherwise the top of the device range.
    public static func stackingReadoutFPS(range: ClosedRange<Int>?) -> Int {
        guard let range else { return unlimitedReadoutFPS }
        if range.lowerBound <= unlimitedReadoutFPS { return unlimitedReadoutFPS }
        return range.upperBound
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

    /// 256×256 around the star for stacked TIFFs. Uses `seed` when given,
    /// otherwise the frame center (the live 512 crop is already on the star).
    public static func stackingFrame(from frame: Frame, seed: SIMD2<Double>? = nil) -> Frame {
        let size = stackingCropSize
        let shortest = min(frame.width, frame.height)
        guard shortest > size else { return frame }
        let center = seed ?? SIMD2(Double(frame.width) / 2, Double(frame.height) / 2)
        return frame.cropped(around: center, size: size)
    }

    public static func stackingSeed(cropSize: Int = stackingCropSize) -> SIMD2<Double> {
        SIMD2(Double(max(cropSize, 1) - 1) / 2, Double(max(cropSize, 1) - 1) / 2)
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

    /// The image quad in normalized device coordinates.
    ///
    /// `imageRect` has a top-left origin; NDC puts -1,-1 at the bottom left, so
    /// the vertical axis flips. Both renderers call this so the quad is built
    /// the same way on Metal and on SDL3 GPU.
    public func ndcRect(
        viewWidth: Double? = nil,
        viewHeight: Double? = nil
    ) -> (x0: Double, y0: Double, x1: Double, y1: Double) {
        Self.ndcRect(
            imageRect,
            inViewOfWidth: viewWidth ?? self.viewWidth,
            height: viewHeight ?? self.viewHeight
        )
    }

    /// Same conversion for a rect that has already been placed somewhere other
    /// than the whole view — the portable app lays the image out inside its
    /// live region and then draws into the full window.
    public static func ndcRect(
        _ rect: (x: Double, y: Double, width: Double, height: Double),
        inViewOfWidth width: Double,
        height: Double
    ) -> (x0: Double, y0: Double, x1: Double, y1: Double) {
        guard width > 0, height > 0 else { return (-1, -1, 1, 1) }
        return (
            x0: 2 * rect.x / width - 1,
            y0: 1 - 2 * (rect.y + rect.height) / height,
            x1: 2 * (rect.x + rect.width) / width - 1,
            y1: 1 - 2 * rect.y / height
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

/// Camera makers the app talks to. Both SDKs load at run time.
public enum CameraVendor: String, Equatable, Sendable, CaseIterable {
    case playerOne
    case zwo

    public var displayName: String {
        switch self {
        case .playerOne: return "Player One"
        case .zwo: return "ZWO"
        }
    }

    /// File name of the SDK library on this platform.
    public var libraryFileName: String {
        switch self {
        case .playerOne: return VendorLibrary.playerOneCamera
        case .zwo: return VendorLibrary.zwoCamera
        }
    }

    /// Folder under `Vendor/` the SDK library is expected in.
    public var vendorFolder: String {
        switch self {
        case .playerOne: return VendorLibrary.playerOneFolder
        case .zwo: return VendorLibrary.zwoFolder
        }
    }
}

public enum CameraError: Error, LocalizedError, Sendable {
    case sdkNotFound(vendor: CameraVendor)
    case sdkSymbolMissing(String)
    case notConnected
    case timeout
    case disconnected
    case invalidROI
    case sdk(vendor: CameraVendor, code: Int32, message: String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .sdkNotFound(let vendor):
            return "\(vendor.displayName) camera SDK library was not found. Place \(vendor.libraryFileName) in Vendor/\(vendor.vendorFolder) or next to the executable."
        case .sdkSymbolMissing(let name):
            return "The camera SDK is missing symbol \(name)."
        case .notConnected:
            return "No camera is connected."
        case .timeout:
            return "Timed out waiting for a camera frame."
        case .disconnected:
            return "The camera was disconnected."
        case .invalidROI:
            return "The requested ROI is not valid for this sensor."
        case .sdk(_, _, let message):
            return message
        case .unsupported(let detail):
            return detail
        }
    }
}

/// ROI granularity a camera accepts. Player One wants width and x on 4 and
/// height and y on 2; ZWO wants width on 8 and height on 2 and places no
/// constraint on the origin. Sizes are post-binning on both.
public struct ROIAlignment: Equatable, Sendable {
    public var widthMultiple: Int
    public var heightMultiple: Int
    public var originXMultiple: Int
    public var originYMultiple: Int
    /// Extra rule for the ASI120 family: `width * height` must be a multiple of
    /// this. 1 means no such rule.
    public var blockPixels: Int

    public init(
        widthMultiple: Int,
        heightMultiple: Int,
        originXMultiple: Int,
        originYMultiple: Int,
        blockPixels: Int = 1
    ) {
        self.widthMultiple = max(1, widthMultiple)
        self.heightMultiple = max(1, heightMultiple)
        self.originXMultiple = max(1, originXMultiple)
        self.originYMultiple = max(1, originYMultiple)
        self.blockPixels = max(1, blockPixels)
    }

    public static let playerOne = ROIAlignment(
        widthMultiple: 4,
        heightMultiple: 2,
        originXMultiple: 4,
        originYMultiple: 2
    )

    public static let zwo = ROIAlignment(
        widthMultiple: 8,
        heightMultiple: 2,
        originXMultiple: 1,
        originYMultiple: 1
    )

    /// `width * height % 1024 == 0` for the ASI120 family.
    public static let zwoASI120 = ROIAlignment(
        widthMultiple: 8,
        heightMultiple: 2,
        originXMultiple: 1,
        originYMultiple: 1,
        blockPixels: 1024
    )

    /// ZWO alignment for a camera model. Only the ASI120 family carries the
    /// extra 1024-pixel block rule.
    public static func forZWOCamera(named name: String) -> ROIAlignment {
        name.contains("120") ? .zwoASI120 : .zwo
    }

    /// Height granularity once the block rule is folded in, given the width
    /// that was already chosen.
    ///
    /// Forcing the height onto a fixed multiple would satisfy the block rule
    /// but throw away sensor rows: on a 1280×960 ASI120 a fixed 128 would cut
    /// the binned search window to 320×128, half the sensor. Deriving the step
    /// from the width keeps the full 320×240.
    public func heightMultiple(forWidth width: Int) -> Int {
        guard blockPixels > 1, width > 0 else { return heightMultiple }
        let needed = blockPixels / Self.greatestCommonDivisor(width, blockPixels)
        return Self.leastCommonMultiple(heightMultiple, needed)
    }

    static func greatestCommonDivisor(_ a: Int, _ b: Int) -> Int {
        var x = abs(a)
        var y = abs(b)
        while y != 0 {
            (x, y) = (y, x % y)
        }
        return x == 0 ? 1 : x
    }

    static func leastCommonMultiple(_ a: Int, _ b: Int) -> Int {
        let divisor = greatestCommonDivisor(a, b)
        return divisor == 0 ? max(a, b) : (a / divisor) * b
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
        binning: Int = 1,
        alignment: ROIAlignment = .playerOne
    ) -> ROI {
        let bin = max(1, binning)
        let widthStep = alignment.widthMultiple
        let requested = max(8, size)
        // Smallest legal ROI: 8 pixels, rounded up to the camera's granularity.
        var width = down(requested / bin, to: widthStep)
        width = max(width, up(8, to: widthStep))
        width = min(width, down(sensorWidth / bin, to: widthStep))

        // The height step can depend on the width (the ASI120 block rule).
        let heightStep = alignment.heightMultiple(forWidth: width)
        var height = down(requested / bin, to: heightStep)
        height = max(height, up(8, to: heightStep))
        height = min(height, down(sensorHeight / bin, to: heightStep))

        var x = Int(sensorPoint.x.rounded()) - (width * bin) / 2
        var y = Int(sensorPoint.y.rounded()) - (height * bin) / 2
        x = down(max(0, x), to: alignment.originXMultiple)
        y = down(max(0, y), to: alignment.originYMultiple)
        x = min(x, max(0, sensorWidth - width * bin))
        y = min(y, max(0, sensorHeight - height * bin))
        x = down(x, to: alignment.originXMultiple)
        y = down(y, to: alignment.originYMultiple)
        return ROI(x: x, y: y, width: width, height: height, binning: bin)
    }

    public static func fullFrameROI(
        sensorWidth: Int,
        sensorHeight: Int,
        binning: Int,
        alignment: ROIAlignment = .playerOne
    ) -> ROI {
        let bin = max(1, binning)
        let widthStep = alignment.widthMultiple
        let width = max(down(sensorWidth / bin, to: widthStep), up(8, to: widthStep))
        let heightStep = alignment.heightMultiple(forWidth: width)
        let height = max(down(sensorHeight / bin, to: heightStep), up(8, to: heightStep))
        return ROI(x: 0, y: 0, width: width, height: height, binning: bin)
    }
}
