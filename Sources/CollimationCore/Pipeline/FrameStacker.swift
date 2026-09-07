import CollimationKernels
import Foundation

/// Collects unique camera frames on the grab thread until `target` is reached.
public final class StackCaptureBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [Frame] = []
    private var target = 0
    private var capturing = false

    public init() {}

    public var isCapturing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return capturing
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return frames.count
    }

    public var targetCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return target
    }

    public func begin(target: Int) {
        lock.lock()
        frames.removeAll(keepingCapacity: true)
        self.target = max(0, target)
        if self.target > 0 {
            frames.reserveCapacity(self.target)
        }
        capturing = self.target > 0
        lock.unlock()
    }

    public func cancel() {
        lock.lock()
        frames.removeAll(keepingCapacity: true)
        target = 0
        capturing = false
        lock.unlock()
    }

    /// Append `frame` when a capture is open. Returns the new count.
    @discardableResult
    public func offer(_ frame: Frame) -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard capturing, frames.count < target else { return frames.count }
        frames.append(frame)
        if frames.count >= target {
            capturing = false
        }
        return frames.count
    }

    public func takeIfComplete() -> [Frame]? {
        lock.lock()
        defer { lock.unlock() }
        guard target > 0, frames.count >= target else { return nil }
        let captured = frames
        frames = []
        target = 0
        capturing = false
        return captured
    }
}

/// Running average of centroid-registered frames, kept in floating point.
public struct FrameStackAccumulator: Sendable {
    public let width: Int
    public let height: Int
    public let roi: ROI
    public let referenceCentroid: SIMD2<Double>
    public private(set) var count: Int

    fileprivate var sum: [Float]
    fileprivate var weight: [Float]

    public init(frame: Frame, centroid: SIMD2<Double>) {
        self.width = frame.width
        self.height = frame.height
        self.roi = frame.roi
        self.referenceCentroid = centroid
        self.count = 0
        self.sum = [Float](repeating: 0, count: frame.width * frame.height)
        self.weight = [Float](repeating: 0, count: frame.width * frame.height)
        _ = add(frame: frame, centroid: centroid)
    }

    fileprivate init(width: Int, height: Int, roi: ROI, referenceCentroid: SIMD2<Double>) {
        self.width = width
        self.height = height
        self.roi = roi
        self.referenceCentroid = referenceCentroid
        self.count = 0
        self.sum = [Float](repeating: 0, count: width * height)
        self.weight = [Float](repeating: 0, count: width * height)
    }

    /// Shift `frame` so `centroid` lands on the reference, then add it. Returns
    /// false when the size does not match the stack.
    @discardableResult
    public mutating func add(frame: Frame, centroid: SIMD2<Double>) -> Bool {
        guard frame.width == width, frame.height == height, frame.pixels.count == width * height else {
            return false
        }
        FrameStacker.accumulate(
            pixels: frame.pixels,
            width: width,
            height: height,
            dx: centroid.x - referenceCentroid.x,
            dy: centroid.y - referenceCentroid.y,
            sum: &sum,
            weight: &weight
        )
        count += 1
        return true
    }

    fileprivate mutating func merge(_ other: FrameStackAccumulator) {
        let n = min(sum.count, other.sum.count)
        sum.withUnsafeMutableBufferPointer { dest in
            other.sum.withUnsafeBufferPointer { src in
                for i in 0..<n { dest[i] += src[i] }
            }
        }
        weight.withUnsafeMutableBufferPointer { dest in
            other.weight.withUnsafeBufferPointer { src in
                for i in 0..<n { dest[i] += src[i] }
            }
        }
        count += other.count
    }

    public func finish(timestamp: Date = Date()) -> StackedImage {
        var pixels = [Float](repeating: 0, count: width * height)
        let n = pixels.count
        pixels.withUnsafeMutableBufferPointer { dest in
            sum.withUnsafeBufferPointer { sum in
                weight.withUnsafeBufferPointer { weight in
                    for i in 0..<n {
                        let w = weight[i]
                        if w > 0 { dest[i] = sum[i] / w }
                    }
                }
            }
        }
        return StackedImage(
            width: width,
            height: height,
            pixels: pixels,
            roi: roi,
            timestamp: timestamp
        )
    }
}

public struct StackedImage: Sendable {
    public var width: Int
    public var height: Int
    public var pixels: [Float]
    public var roi: ROI
    public var timestamp: Date

    public init(width: Int, height: Int, pixels: [Float], roi: ROI, timestamp: Date = Date()) {
        self.width = width
        self.height = height
        self.pixels = pixels
        self.roi = roi
        self.timestamp = timestamp
    }
}

public enum FrameStacker {
    public static let subframeCounts = [10, 50, 100, 500, 1000, 5000, 10000]
    public static let defaultSubframeCount = 100
    public static let subframeCount = defaultSubframeCount

    public static func clampedCount(_ count: Int) -> Int {
        subframeCounts.contains(count) ? count : defaultSubframeCount
    }

    /// Covers the 256 stacking crop, including collimation donut rings.
    static let stackingCentroidHalfWindow = 256

    public static func average(_ subframes: [(frame: Frame, centroid: SIMD2<Double>)]) throws -> StackedImage {
        guard let first = subframes.first else {
            throw CameraError.unsupported("No subframes to stack.")
        }
        let workerCount = min(ProcessInfo.processInfo.activeProcessorCount, subframes.count)
        guard workerCount > 1, subframes.count >= 8 else {
            var stack = FrameStackAccumulator(frame: first.frame, centroid: first.centroid)
            for subframe in subframes.dropFirst() {
                guard stack.add(frame: subframe.frame, centroid: subframe.centroid) else {
                    throw CameraError.unsupported("Stacked frames must share the same size.")
                }
            }
            return stack.finish(timestamp: first.frame.timestamp)
        }

        let partials = (0..<workerCount).map { _ in
            FrameStackPartial(
                width: first.frame.width,
                height: first.frame.height,
                roi: first.frame.roi,
                reference: first.centroid
            )
        }
        DispatchQueue.concurrentPerform(iterations: workerCount) { worker in
            let partial = partials[worker]
            var index = worker
            while index < subframes.count {
                let subframe = subframes[index]
                if !partial.stack.add(frame: subframe.frame, centroid: subframe.centroid) {
                    partial.failed = true
                    return
                }
                index += workerCount
            }
        }
        if partials.contains(where: \.failed) {
            throw CameraError.unsupported("Stacked frames must share the same size.")
        }
        var combined = partials[0].stack
        for partial in partials.dropFirst() {
            combined.merge(partial.stack)
        }
        return combined.finish(timestamp: first.frame.timestamp)
    }

    /// Register each frame on its star centroid, then average. Frames without a
    /// lock or with a mismatched size are skipped.
    public static func average(_ frames: [Frame], seed: SIMD2<Double>?) throws -> StackedImage {
        let count = frames.count
        guard count > 0 else {
            throw CameraError.unsupported("No tracked star. Keep the artificial star in the frame to stack.")
        }
        let width = frames[0].width
        let height = frames[0].height
        let workerCount = min(ProcessInfo.processInfo.activeProcessorCount, count)
        var found = [SIMD2<Double>?](repeating: nil, count: count)
        found.withUnsafeMutableBufferPointer { buffer in
            let slots = UncheckedBuffer(buffer.baseAddress!)
            DispatchQueue.concurrentPerform(iterations: workerCount) { worker in
                var index = worker
                while index < count {
                    let frame = frames[index]
                    if frame.width == width, frame.height == height {
                        slots.base[index] = StarDetector().momentCentroid(
                            in: frame,
                            around: seed,
                            halfWindow: stackingCentroidHalfWindow
                        )
                    }
                    index += workerCount
                }
            }
        }
        var pairs: [(frame: Frame, centroid: SIMD2<Double>)] = []
        pairs.reserveCapacity(count)
        for index in 0..<count {
            if let centroid = found[index] {
                pairs.append((frames[index], centroid))
            }
        }
        guard !pairs.isEmpty else {
            throw CameraError.unsupported("No tracked star. Keep the artificial star in the frame to stack.")
        }
        return try average(pairs)
    }

    static func accumulate(
        pixels: [UInt16],
        width: Int,
        height: Int,
        dx: Double,
        dy: Double,
        sum: inout [Float],
        weight: inout [Float]
    ) {
        guard width > 0, height > 0,
              pixels.count == width * height,
              sum.count == width * height,
              weight.count == width * height else {
            return
        }
        pixels.withUnsafeBufferPointer { src in
            sum.withUnsafeMutableBufferPointer { sum in
                weight.withUnsafeMutableBufferPointer { weight in
                    guard let p = src.baseAddress, let s = sum.baseAddress, let w = weight.baseAddress else {
                        return
                    }
                    if abs(dx - dx.rounded()) < 1e-6, abs(dy - dy.rounded()) < 1e-6 {
                        collimation_accumulate_integer(
                            p,
                            Int32(width),
                            Int32(height),
                            Int32(dx.rounded()),
                            Int32(dy.rounded()),
                            s,
                            w
                        )
                    } else {
                        collimation_accumulate_bilinear(
                            p,
                            Int32(width),
                            Int32(height),
                            Float(dx),
                            Float(dy),
                            s,
                            w
                        )
                    }
                }
            }
        }
    }

    /// Sample `pixels` at a subpixel location. Returns nil when the point is
    /// entirely outside the frame.
    public static func bilinearSample(
        pixels: [UInt16],
        width: Int,
        height: Int,
        x: Double,
        y: Double
    ) -> Double? {
        guard width > 0, height > 0, pixels.count == width * height else { return nil }
        let x0 = Int(floor(x))
        let y0 = Int(floor(y))
        let fx = x - Double(x0)
        let fy = y - Double(y0)
        let x1 = x0 + 1
        let y1 = y0 + 1

        func pixel(_ ix: Int, _ iy: Int) -> Double? {
            guard ix >= 0, iy >= 0, ix < width, iy < height else { return nil }
            return Double(pixels[iy * width + ix])
        }

        let w00 = (1 - fx) * (1 - fy)
        let w10 = fx * (1 - fy)
        let w01 = (1 - fx) * fy
        let w11 = fx * fy

        var sum = 0.0
        var weight = 0.0
        if w00 > 1e-12, let p = pixel(x0, y0) { sum += p * w00; weight += w00 }
        if w10 > 1e-12, let p = pixel(x1, y0) { sum += p * w10; weight += w10 }
        if w01 > 1e-12, let p = pixel(x0, y1) { sum += p * w01; weight += w01 }
        if w11 > 1e-12, let p = pixel(x1, y1) { sum += p * w11; weight += w11 }
        guard weight > 1e-12 else { return nil }
        return sum / weight
    }
}

private final class FrameStackPartial: @unchecked Sendable {
    var stack: FrameStackAccumulator
    var failed = false

    init(width: Int, height: Int, roi: ROI, reference: SIMD2<Double>) {
        stack = FrameStackAccumulator(
            width: width,
            height: height,
            roi: roi,
            referenceCentroid: reference
        )
    }
}

private struct UncheckedBuffer<T>: @unchecked Sendable {
    let base: UnsafeMutablePointer<T>
    init(_ base: UnsafeMutablePointer<T>) {
        self.base = base
    }
}
