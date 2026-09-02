import Foundation

public struct Frame: Sendable {
    public let width: Int
    public let height: Int
    public let pixels: [UInt16]
    public let roi: ROI
    public let timestamp: Date

    public init(width: Int, height: Int, pixels: [UInt16], roi: ROI, timestamp: Date = Date()) {
        self.width = width
        self.height = height
        self.pixels = pixels
        self.roi = roi
        self.timestamp = timestamp
    }

    public var pixelCount: Int { width * height }

    public func pixel(x: Int, y: Int) -> UInt16 {
        pixels[y * width + x]
    }

    public func pixelClamped(x: Int, y: Int) -> UInt16 {
        let cx = min(max(x, 0), width - 1)
        let cy = min(max(y, 0), height - 1)
        return pixels[cy * width + cx]
    }

    /// Integer crop around `center`, clamped to the frame. `roi` is updated so
    /// sensor coordinates stay valid.
    public func cropped(around center: SIMD2<Double>, size: Int) -> Frame {
        let side = min(max(1, size), width, height)
        var x0 = Int(center.x.rounded()) - side / 2
        var y0 = Int(center.y.rounded()) - side / 2
        x0 = min(max(0, x0), width - side)
        y0 = min(max(0, y0), height - side)
        if x0 == 0, y0 == 0, side == width, side == height {
            return self
        }
        var cropped = [UInt16](repeating: 0, count: side * side)
        for y in 0..<side {
            let src = (y0 + y) * width + x0
            let dst = y * side
            cropped.replaceSubrange(dst..<(dst + side), with: pixels[src..<(src + side)])
        }
        return Frame(
            width: side,
            height: side,
            pixels: cropped,
            roi: ROI(
                x: roi.x + x0 * roi.binning,
                y: roi.y + y0 * roi.binning,
                width: side,
                height: side,
                binning: roi.binning
            ),
            timestamp: timestamp
        )
    }

    /// Pixel offset of this crop inside `parent` (same binning).
    public func origin(inParent parent: Frame) -> SIMD2<Double> {
        let bin = Double(max(parent.roi.binning, 1))
        return SIMD2(
            Double(roi.x - parent.roi.x) / bin,
            Double(roi.y - parent.roi.y) / bin
        )
    }
}

/// Latest-frame-wins slot shared between the capture thread and the Metal view.
public final class FrameSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var frame: Frame?
    private var sequence: UInt64 = 0

    public init() {}

    public func store(_ frame: Frame) {
        lock.lock()
        self.frame = frame
        sequence &+= 1
        lock.unlock()
    }

    public func peek() -> (frame: Frame, sequence: UInt64)? {
        lock.lock()
        defer { lock.unlock() }
        guard let frame else { return nil }
        return (frame, sequence)
    }

    public func clear() {
        lock.lock()
        frame = nil
        lock.unlock()
    }
}

/// Crops tracking frames to `CaptureLayout.displayCropSize` using the last
/// sensor centroid so the live view stays a 512 window between analysis ticks.
public final class SoftwareCropController: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false
    private var sensorCentroid: SIMD2<Double>?

    public init() {}

    public func update(enabled: Bool, sensorCentroid: SIMD2<Double>?) {
        lock.lock()
        self.enabled = enabled
        self.sensorCentroid = sensorCentroid
        lock.unlock()
    }

    public func reset() {
        update(enabled: false, sensorCentroid: nil)
    }

    public func apply(_ frame: Frame) -> Frame {
        lock.lock()
        let enabled = self.enabled
        let sensor = self.sensorCentroid
        lock.unlock()
        guard enabled, let sensor else { return frame }
        return CaptureLayout.displayFrame(
            from: frame,
            tracking: .tracking,
            centroid: frame.roi.framePixel(fromSensorPoint: sensor)
        )
    }
}
