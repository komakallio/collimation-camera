import Foundation

public struct Histogram: Sendable, Equatable {
    public static let binCount = 256

    public var bins: [UInt32]
    public var sampleCount: Int
    /// Brightest raw 16-bit sample seen while building the histogram (unstretched).
    public var maxADU: UInt16

    public init(
        bins: [UInt32] = Array(repeating: 0, count: binCount),
        sampleCount: Int = 0,
        maxADU: UInt16 = 0
    ) {
        self.bins = bins
        self.sampleCount = sampleCount
        self.maxADU = maxADU
    }

    public static func compute(from frame: Frame, stride: Int = 1) -> Histogram {
        var bins = [UInt32](repeating: 0, count: binCount)
        let step = max(1, stride)
        var count = 0
        var maxADU: UInt16 = 0
        var i = 0
        let pixels = frame.pixels
        while i < pixels.count {
            let value = pixels[i]
            if value > maxADU { maxADU = value }
            bins[Int(value >> 8)] &+= 1
            count += 1
            i += step
        }
        return Histogram(bins: bins, sampleCount: count, maxADU: maxADU)
    }

    /// Percentile in 0...1 mapped to 0...1 of the 16-bit range.
    public func percentile(_ p: Double) -> Double {
        guard sampleCount > 0 else { return 0 }
        let target = min(max(p, 0), 1) * Double(sampleCount)
        var cumulative = 0.0
        for (index, bin) in bins.enumerated() {
            cumulative += Double(bin)
            if cumulative >= target {
                return Double(index) / 255.0
            }
        }
        return 1
    }

    public var median: Double { percentile(0.5) }
}
