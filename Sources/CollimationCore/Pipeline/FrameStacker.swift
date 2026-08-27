import Foundation

/// Running average of centroid-registered frames, kept in floating point.
public struct FrameStackAccumulator: Sendable {
    public let width: Int
    public let height: Int
    public let roi: ROI
    public let referenceCentroid: SIMD2<Double>
    public private(set) var count: Int

    private var sum: [Double]
    private var weight: [Double]

    public init(frame: Frame, centroid: SIMD2<Double>) {
        self.width = frame.width
        self.height = frame.height
        self.roi = frame.roi
        self.referenceCentroid = centroid
        self.count = 0
        self.sum = [Double](repeating: 0, count: frame.width * frame.height)
        self.weight = [Double](repeating: 0, count: frame.width * frame.height)
        _ = add(frame: frame, centroid: centroid)
    }

    /// Shift `frame` so `centroid` lands on the reference, then add it. Returns
    /// false when the size does not match the stack.
    @discardableResult
    public mutating func add(frame: Frame, centroid: SIMD2<Double>) -> Bool {
        guard frame.width == width, frame.height == height, frame.pixels.count == width * height else {
            return false
        }
        let dx = centroid.x - referenceCentroid.x
        let dy = centroid.y - referenceCentroid.y
        let pixels = frame.pixels
        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                guard let sample = FrameStacker.bilinearSample(
                    pixels: pixels,
                    width: width,
                    height: height,
                    x: Double(x) + dx,
                    y: Double(y) + dy
                ) else { continue }
                let i = row + x
                sum[i] += sample
                weight[i] += 1
            }
        }
        count += 1
        return true
    }

    public func finish(timestamp: Date = Date()) -> StackedImage {
        var pixels = [Float](repeating: 0, count: width * height)
        for i in 0..<pixels.count {
            let w = weight[i]
            guard w > 0 else { continue }
            pixels[i] = Float(sum[i] / w)
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
    public static let subframeCount = 100

    public static func average(_ subframes: [(frame: Frame, centroid: SIMD2<Double>)]) throws -> StackedImage {
        guard let first = subframes.first else {
            throw CameraError.unsupported("No subframes to stack.")
        }
        var stack = FrameStackAccumulator(frame: first.frame, centroid: first.centroid)
        for subframe in subframes.dropFirst() {
            guard stack.add(frame: subframe.frame, centroid: subframe.centroid) else {
                throw CameraError.unsupported("Stacked frames must share the same size.")
            }
        }
        return stack.finish(timestamp: first.frame.timestamp)
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
