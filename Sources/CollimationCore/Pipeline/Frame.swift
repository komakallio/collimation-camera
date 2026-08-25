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
