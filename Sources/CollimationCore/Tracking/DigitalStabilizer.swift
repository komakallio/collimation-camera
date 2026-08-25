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
public struct DigitalStabilizer: Equatable, Sendable {
    private var lockNormalized: SIMD2<Double>?
    private var lastCentroid: SIMD2<Double>?

    public init() {}

    public mutating func reset() {
        lockNormalized = nil
        lastCentroid = nil
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
        if let centroid {
            lastCentroid = centroid
            let layout = ImageLayout(
                imageWidth: imageWidth,
                imageHeight: imageHeight,
                viewWidth: viewWidth,
                viewHeight: viewHeight,
                zoom: zoom
            )
            if lockNormalized == nil {
                let locked = layout.viewPoint(image: centroid)
                lockNormalized = SIMD2(locked.x / viewWidth, locked.y / viewHeight)
            }
        }
        return StabilizationPose(lockNormalized: lockNormalized, centroid: lastCentroid)
    }
}

/// Per-frame digital stabilization. Runs a windowed intensity centroid on the
/// grab thread so the live view can pan with every camera frame, while coma
/// analysis stays coalesced.
///
/// A GPU reduction was considered and rejected for these ROIs: 256–2048 frames
/// are already in RAM, a ~400² window is microseconds on CPU, and a compute
/// shader would add encode + readback latency without helping the overlay lock.
final class StabilizationController: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false
    private var tracking: TrackingState = .idle
    private var viewWidth = 800.0
    private var viewHeight = 700.0
    private var zoom = 1.0
    private var stabilizer = DigitalStabilizer()
    private var lastSensorCentroid: SIMD2<Double>?
    private var lastImageWidth = 0
    private var lastImageHeight = 0
    private var lastPose = StabilizationPose()
    private let detector = StarDetector()

    var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled
    }

    func configure(
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

    /// Use a detected centroid only to start tracking, never to overwrite a
    /// fresher per-frame measurement.
    func seed(frameCentroid: SIMD2<Double>, roi: ROI, imageWidth: Int, imageHeight: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard enabled, tracking != .searching else { return }
        guard lastSensorCentroid == nil else { return }
        lastSensorCentroid = roi.sensorPoint(fromFramePixel: frameCentroid)
        lastImageWidth = imageWidth
        lastImageHeight = imageHeight
        lastPose = stabilizer.update(
            enabled: enabled,
            centroid: frameCentroid,
            tracking: tracking,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            viewWidth: viewWidth,
            viewHeight: viewHeight,
            zoom: zoom
        )
    }

    func pose() -> StabilizationPose {
        lock.lock()
        defer { lock.unlock() }
        return lastPose
    }

    func process(_ frame: Frame) -> StabilizationPose {
        lock.lock()
        let enabled = self.enabled
        let tracking = self.tracking
        let viewWidth = self.viewWidth
        let viewHeight = self.viewHeight
        let zoom = self.zoom
        let seed = lastSensorCentroid.map { frame.roi.framePixel(fromSensorPoint: $0) }
        if !enabled || tracking == .searching {
            stabilizer.reset()
            lastSensorCentroid = nil
            lastPose = StabilizationPose()
            let pose = lastPose
            lock.unlock()
            return pose
        }
        lock.unlock()

        let centroid = detector.momentCentroid(in: frame, around: seed)

        lock.lock()
        lastImageWidth = frame.width
        lastImageHeight = frame.height
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

    func reset() {
        lock.lock()
        stabilizer.reset()
        lastSensorCentroid = nil
        lastPose = StabilizationPose()
        lock.unlock()
    }
}
