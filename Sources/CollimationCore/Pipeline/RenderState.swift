import Combine
import Foundation

public struct RenderState: Sendable {
    public var stretch: StretchParams
    public var zoom: Double
    public var stabilizeLock: SIMD2<Double>?
    public var stabilizeCentroid: SIMD2<Double>?
    /// Size and ROI of the frame the stabilize pose was measured on.
    public var imageWidth: Int
    public var imageHeight: Int
    public var roi: ROI?

    public init(
        stretch: StretchParams = .default,
        zoom: Double = 1,
        stabilizeLock: SIMD2<Double>? = nil,
        stabilizeCentroid: SIMD2<Double>? = nil,
        imageWidth: Int = 0,
        imageHeight: Int = 0,
        roi: ROI? = nil
    ) {
        self.stretch = stretch
        self.zoom = zoom
        self.stabilizeLock = stabilizeLock
        self.stabilizeCentroid = stabilizeCentroid
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.roi = roi
    }
}

public final class RenderStateSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var state = RenderState()

    public init() {}

    public func store(_ state: RenderState) {
        lock.lock()
        self.state = state
        lock.unlock()
    }

    public func update(_ body: (inout RenderState) -> Void) {
        lock.lock()
        body(&state)
        lock.unlock()
    }

    public func peek() -> RenderState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }
}
