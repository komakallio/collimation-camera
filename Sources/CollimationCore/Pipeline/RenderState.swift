import Combine
import Foundation

public struct RenderState: Sendable {
    public var stretch: StretchParams
    public var zoom: Double
    public var stabilizeLock: SIMD2<Double>?
    public var stabilizeCentroid: SIMD2<Double>?

    public init(
        stretch: StretchParams = .default,
        zoom: Double = 1,
        stabilizeLock: SIMD2<Double>? = nil,
        stabilizeCentroid: SIMD2<Double>? = nil
    ) {
        self.stretch = stretch
        self.zoom = zoom
        self.stabilizeLock = stabilizeLock
        self.stabilizeCentroid = stabilizeCentroid
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

    public func peek() -> RenderState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }
}
