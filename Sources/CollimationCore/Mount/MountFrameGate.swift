import Foundation

/// Changing the readout must not turn a stale crop or a different detection
/// into a mount command. No motor is moving while this gate is used.
public struct MountFrameGate {
    private let expectedROI: ROI
    private let reference: SIMD2<Double>?
    private var matchingFrames = 0

    public init(expectedROI: ROI, reference: SIMD2<Double>?) {
        self.expectedROI = expectedROI
        self.reference = reference
    }

    public mutating func observe(roi: ROI, tracking: TrackingStatus) throws -> SIMD2<Double>? {
        guard roi == expectedROI,
              tracking.state == .tracking,
              tracking.detection != nil,
              let centroid = tracking.centroidOnSensor,
              centroid.x.isFinite, centroid.y.isFinite,
              roi.contains(sensorPoint: centroid) else {
            matchingFrames = 0
            return nil
        }
        if let reference,
           MountGuide.errorLength(centroid - reference) > Double(CaptureLayout.displayCropSize) / 4 {
            throw MountError.starChangedDuringFrameSwitch
        }
        matchingFrames += 1
        return matchingFrames >= 2 ? centroid : nil
    }
}

/// Keep vectors out of async arguments/results: Windows calibration logs had
/// corrupt Y coordinates, and the async-transfer test reproduced corruption
/// with SIMD arguments. Carry an immutable reference and reconstruct vectors
/// synchronously at the call site.
public final class MountCentroidSample: Sendable, CustomStringConvertible {
    public let x: Double
    public let y: Double

    public init(_ point: SIMD2<Double>) {
        x = point.x
        y = point.y
    }

    public var point: SIMD2<Double> { SIMD2(x, y) }
    public var description: String { "(x: \(x), y: \(y))" }
}
