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

/// Locks the tracked centroid to a fixed place in the window. Complements camera
/// ROI recentering: the ROI follows large motion, this cancels leftover jitter.
///
/// The lock is in view space, but the centroid is in **this frame’s** pixel
/// coordinates. A size change (search ↔ tracking ROI, user ROI) drops the lock
/// so a pan computed for a 4×-binned full frame is never applied to a 512 crop.
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

/// Per-frame digital stabilization. A windowed intensity centroid is measured on
/// the frame about to be drawn so the live pan matches that image even when the
/// star jitters a lot from frame to frame.
///
/// A GPU reduction was considered and rejected for these ROIs: 256–2048 frames
/// are already in RAM, a ~400² window is microseconds on CPU, and a compute
/// shader would add encode + readback latency without helping the overlay lock.
public final class StabilizationController: @unchecked Sendable {
    /// Drop a measurement that jumped this far from the last sensor seed. The
    /// tracking ROI recenters at ~15% of the frame; beyond that the blob is not
    /// the same star (or the crop changed and the seed is stale).
    public static let maxLockDriftPixels = 96.0

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

    public func process(
        _ frame: Frame,
        viewWidth viewWidthOverride: Double? = nil,
        viewHeight viewHeightOverride: Double? = nil
    ) -> StabilizationPose {
        lock.lock()
        let enabled = self.enabled
        let tracking = self.tracking
        let viewWidth = viewWidthOverride ?? self.viewWidth
        let viewHeight = viewHeightOverride ?? self.viewHeight
        let zoom = self.zoom
        let mappedSeed = lastSensorCentroid.map { frame.roi.framePixel(fromSensorPoint: $0) }
        let seed = Self.inFrame(mappedSeed, width: frame.width, height: frame.height)
        if !enabled || tracking == .searching {
            stabilizer.reset()
            lastSensorCentroid = nil
            lastPose = StabilizationPose()
            let pose = lastPose
            lock.unlock()
            return pose
        }
        lock.unlock()

        let measured = tracking == .tracking
            ? detector.momentCentroid(in: frame, around: seed)
            : nil
        let centroid = Self.acceptedCentroid(measured, seed: seed)

        lock.lock()
        if let centroid {
            lastSensorCentroid = frame.roi.sensorPoint(fromFramePixel: centroid)
        }
        lastPose = stabilizer.update(
            enabled: self.enabled,
            centroid: centroid,
            tracking: self.tracking,
            imageWidth: frame.width,
            imageHeight: frame.height,
            viewWidth: viewWidth,
            viewHeight: viewHeight,
            zoom: zoom
        )
        let pose = lastPose
        lock.unlock()
        return pose
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
