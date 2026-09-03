import Foundation

/// Intensity along a cut through the star, averaged over several diameters.
///
/// `samples` run from −radius to +radius (center in the middle). Each value is
/// ADU / 65535. The live plot uses a logarithmic vertical axis from 0.15% to full well.
public struct StarIntensityProfile: Equatable, Sendable {
    public var samples: [Double]
    public var radiusPixels: Double
    public var sectionCount: Int

    public init(samples: [Double], radiusPixels: Double, sectionCount: Int) {
        self.samples = samples
        self.radiusPixels = radiusPixels
        self.sectionCount = sectionCount
    }

    public var isEmpty: Bool { samples.isEmpty }
}

public struct StarProfileSampler: Sendable {
    public var sectionCount: Int
    public var sampleCount: Int

    public init(sectionCount: Int = 4, sampleCount: Int = 97) {
        self.sectionCount = max(2, sectionCount)
        self.sampleCount = max(9, sampleCount | 1)
    }

    public func measure(
        frame: Frame,
        centroid: SIMD2<Double>,
        radiusPixels: Double
    ) -> StarIntensityProfile? {
        let radius = min(
            max(radiusPixels, 4),
            Double(min(frame.width, frame.height)) / 2 - 1
        )
        guard radius > 2, frame.width > 4, frame.height > 4 else { return nil }

        let n = sampleCount
        var sums = [Double](repeating: 0, count: n)
        let sections = Double(sectionCount)
        for s in 0..<sectionCount {
            let theta = Double(s) / sections * .pi
            let dx = cos(theta)
            let dy = sin(theta)
            for i in 0..<n {
                let t = (Double(i) / Double(n - 1)) * 2 - 1
                let x = centroid.x + t * radius * dx
                let y = centroid.y + t * radius * dy
                sums[i] += bilinear(frame, x: x, y: y)
            }
        }
        let scale = 65535.0 * sections
        let samples = sums.map { min(max($0 / scale, 0), 1) }
        return StarIntensityProfile(samples: samples, radiusPixels: radius, sectionCount: sectionCount)
    }

    private func bilinear(_ frame: Frame, x: Double, y: Double) -> Double {
        let maxX = Double(frame.width - 1)
        let maxY = Double(frame.height - 1)
        let cx = min(max(x, 0), maxX)
        let cy = min(max(y, 0), maxY)
        let x0 = Int(floor(cx))
        let y0 = Int(floor(cy))
        let x1 = min(x0 + 1, frame.width - 1)
        let y1 = min(y0 + 1, frame.height - 1)
        let fx = cx - Double(x0)
        let fy = cy - Double(y0)
        let v00 = Double(frame.pixels[y0 * frame.width + x0])
        let v10 = Double(frame.pixels[y0 * frame.width + x1])
        let v01 = Double(frame.pixels[y1 * frame.width + x0])
        let v11 = Double(frame.pixels[y1 * frame.width + x1])
        return mix(mix(v00, v10, fx), mix(v01, v11, fx), fy)
    }

    private func mix(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + (b - a) * t
    }
}
