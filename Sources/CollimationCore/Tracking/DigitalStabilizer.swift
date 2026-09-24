import Foundation

/// Window-space lock for digital stabilization.
///
/// `lockNormalized` is the centroid’s position in the view (0…1). Each renderer
/// converts that into a pan using its own view size so Metal and the overlay stay aligned.
public struct StabilizationPose: Equatable, Sendable {
    public var lockNormalized: SIMD2<Double>?
    public var centroid: SIMD2<Double>?

    public init(lockNormalized: SIMD2<Double>? = nil, centroid: SIMD2<Double>? = nil) {
        self.lockNormalized = lockNormalized
        self.centroid = centroid
    }
}

/// Locks the tracked centroid to a fixed place in the window. Complements the
/// 2048×2048 hardware window: that ROI follows large motion, this cancels leftover
/// jitter on the 512×512 software crop.
///
/// The lock is in view space, but the centroid is in **this frame’s** pixel
/// coordinates. A size change (full-frame search ↔ 512 crop) drops the lock
/// so a pan computed for a binned full frame is never applied to the crop.
/// Lost/idle keeps the last lock and centroid so the view does not chase noise;
/// searching clears both.
public struct DigitalStabilizer: Equatable, Sendable {
    private var lockNormalized: SIMD2<Double>?
    private var lastCentroid: SIMD2<Double>?
    private var lastImageWidth = 0
    private var lastImageHeight = 0

    public init() {}

    public mutating func reset() {
        lockNormalized = nil
        lastCentroid = nil
        lastImageWidth = 0
        lastImageHeight = 0
    }

    public mutating func update(
        enabled: Bool,
        centroid: SIMD2<Double>?,
        tracking: TrackingState,
        imageWidth: Int,
        imageHeight: Int,
        viewWidth: Double,
        viewHeight: Double,
        zoom: Double
    ) -> StabilizationPose {
        guard enabled else {
            reset()
            return StabilizationPose()
        }
        if tracking == .searching || imageWidth < 1 || imageHeight < 1 || viewWidth <= 1 || viewHeight <= 1 {
            reset()
            return StabilizationPose()
        }
        if imageWidth != lastImageWidth || imageHeight != lastImageHeight {
            lockNormalized = nil
            lastCentroid = nil
        }
        lastImageWidth = imageWidth
        lastImageHeight = imageHeight

        // Only tracking frames may move the lock. Lost holds the last pose on
        // this image size; a new blob is almost always noise or a hot pixel.
        if tracking == .tracking, let centroid {
            lastCentroid = centroid
            if lockNormalized == nil {
                let layout = ImageLayout(
                    imageWidth: imageWidth,
                    imageHeight: imageHeight,
                    viewWidth: viewWidth,
                    viewHeight: viewHeight,
                    zoom: zoom
                )
                let locked = layout.viewPoint(image: centroid)
                lockNormalized = SIMD2(locked.x / viewWidth, locked.y / viewHeight)
            }
        }
        return StabilizationPose(lockNormalized: lockNormalized, centroid: lastCentroid)
    }
}

/// Per-frame digital stabilization. The live view measures a windowed intensity
/// centroid on the GPU from the texture about to be drawn; tests and fallback
/// use `process`, which does the same reduction on the CPU.
public final class StabilizationController: @unchecked Sendable {
    /// Drop a measurement that jumped this far from the last sensor seed. A
    /// large donut’s moment can wander more than a tight core; half the 512
    /// crop still rejects a hop to a different blob.
    public static let maxLockDriftPixels = 256.0

    private let lock = NSLock()
    private var enabled = false
    private var tracking: TrackingState = .idle
    private var viewWidth = 800.0
    private var viewHeight = 700.0
    private var zoom = 1.0
    private var stabilizer = DigitalStabilizer()
    private var lastSensorCentroid: SIMD2<Double>?
    private var lastPose = StabilizationPose()
    private let detector = StarDetector()

    public init() {}

    public var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled
    }

    /// True when a new centroid should be measured on the displayed frame.
    public var measuresCentroid: Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled && tracking == .tracking
    }

    public func configure(
        enabled: Bool,
        tracking: TrackingState,
        viewWidth: Double,
        viewHeight: Double,
        zoom: Double
    ) {
        lock.lock()
        self.enabled = enabled
        self.tracking = tracking
        self.viewWidth = viewWidth
        self.viewHeight = viewHeight
        self.zoom = zoom
        if !enabled || tracking == .searching {
            stabilizer.reset()
            lastSensorCentroid = nil
            lastPose = StabilizationPose()
        }
        lock.unlock()
    }

    /// Hint for the first `process` after a search or connect. Does not set the
    /// view lock — that must be measured on the frame Metal is about to draw,
    /// whose size may differ from the overlay’s analyzed frame.
    public func seed(frameCentroid: SIMD2<Double>, roi: ROI) {
        lock.lock()
        defer { lock.unlock() }
        guard enabled, tracking != .searching else { return }
        guard lastSensorCentroid == nil else { return }
        lastSensorCentroid = roi.sensorPoint(fromFramePixel: frameCentroid)
    }

    public func pose() -> StabilizationPose {
        lock.lock()
        defer { lock.unlock() }
        return lastPose
    }

    /// Last accepted centroid mapped into `frame`, for a windowed GPU/CPU measure.
    public func measurementSeed(in frame: Frame) -> SIMD2<Double>? {
        lock.lock()
        defer { lock.unlock() }
        let mapped = lastSensorCentroid.map { frame.roi.framePixel(fromSensorPoint: $0) }
        return Self.inFrame(mapped, width: frame.width, height: frame.height)
    }

    /// CPU centroid of `frame`, then lock/pan. Used by tests; the live view
    /// measures on the GPU and calls `applyMeasured`.
    public func process(
        _ frame: Frame,
        viewWidth viewWidthOverride: Double? = nil,
        viewHeight viewHeightOverride: Double? = nil
    ) -> StabilizationPose {
        let measured = measuresCentroid && CaptureLayout.shouldStabilize(frame)
            ? detector.momentCentroid(in: frame, around: measurementSeed(in: frame))
            : nil
        return applyMeasured(
            measured,
            frame: frame,
            viewWidth: viewWidthOverride,
            viewHeight: viewHeightOverride
        )
    }

    /// Apply a centroid already measured on the frame about to be drawn.
    public func applyMeasured(
        _ measured: SIMD2<Double>?,
        frame: Frame,
        viewWidth viewWidthOverride: Double? = nil,
        viewHeight viewHeightOverride: Double? = nil
    ) -> StabilizationPose {
        lock.lock()
        defer { lock.unlock() }
        let viewWidth = viewWidthOverride ?? self.viewWidth
        let viewHeight = viewHeightOverride ?? self.viewHeight
        let zoom = self.zoom
        if !enabled || tracking == .searching || !CaptureLayout.shouldStabilize(frame) {
            stabilizer.reset()
            lastSensorCentroid = nil
            lastPose = StabilizationPose()
            return lastPose
        }
        let mappedSeed = lastSensorCentroid.map { frame.roi.framePixel(fromSensorPoint: $0) }
        let seed = Self.inFrame(mappedSeed, width: frame.width, height: frame.height)
        let centroid = tracking == .tracking ? Self.acceptedCentroid(measured, seed: seed) : nil
        if let centroid {
            lastSensorCentroid = frame.roi.sensorPoint(fromFramePixel: centroid)
        }
        lastPose = stabilizer.update(
            enabled: enabled,
            centroid: centroid,
            tracking: tracking,
            imageWidth: frame.width,
            imageHeight: frame.height,
            viewWidth: viewWidth,
            viewHeight: viewHeight,
            zoom: zoom
        )
        return lastPose
    }

    public func reset() {
        lock.lock()
        stabilizer.reset()
        lastSensorCentroid = nil
        lastPose = StabilizationPose()
        lock.unlock()
    }

    private static func inFrame(_ seed: SIMD2<Double>?, width: Int, height: Int) -> SIMD2<Double>? {
        guard let seed else { return nil }
        guard seed.x >= 0, seed.y >= 0, seed.x < Double(width), seed.y < Double(height) else {
            return nil
        }
        return seed
    }

    private static func acceptedCentroid(_ measured: SIMD2<Double>?, seed: SIMD2<Double>?) -> SIMD2<Double>? {
        guard let measured else { return nil }
        guard let seed else { return measured }
        let dx = measured.x - seed.x
        let dy = measured.y - seed.y
        guard (dx * dx + dy * dy).squareRoot() <= maxLockDriftPixels else { return nil }
        return measured
    }
}
