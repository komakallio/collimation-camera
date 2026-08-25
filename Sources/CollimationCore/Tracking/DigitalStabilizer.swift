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
        if let centroid, tracking == .tracking {
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
