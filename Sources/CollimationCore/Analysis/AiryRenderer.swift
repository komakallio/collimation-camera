import Darwin
import Foundation

/// In-focus star with a circular-aperture Airy pattern: \(I \propto [2 J_1(x)/x]^2\).
///
/// Native Poseidon-M sampling puts the first minimum at ~1.4 px (f/8, 550 nm),
/// which hides the rings. The default radius is an 8×-sampled Airy so the first
/// few rings are visible in the 512 crop.
public struct AiryScene: Equatable, Sendable {
    public var sensorWidth: Int
    public var sensorHeight: Int
    public var starPosition: SIMD2<Double>
    /// Sensor pixels from the core to the first dark ring (J1's first zero).
    public var firstMinimumPixels: Double
    public var peakADU: Double
    public var backgroundADU: Double
    public var noiseSigma: Double
    public var seeingJitter: Double

    /// First zero of J₁.
    public static let j1FirstZero = 3.8317059702075125

    public init(
        sensorWidth: Int = 6252,
        sensorHeight: Int = 4176,
        starPosition: SIMD2<Double>? = nil,
        firstMinimumPixels: Double = AiryScene.defaultFirstMinimumPixels,
        peakADU: Double = 42_000,
        backgroundADU: Double = 900,
        noiseSigma: Double = 20,
        seeingJitter: Double = 0.12
    ) {
        self.sensorWidth = sensorWidth
        self.sensorHeight = sensorHeight
        self.starPosition = starPosition ?? SIMD2(Double(sensorWidth) / 2, Double(sensorHeight) / 2)
        self.firstMinimumPixels = max(1.5, firstMinimumPixels)
        self.peakADU = peakADU
        self.backgroundADU = backgroundADU
        self.noiseSigma = noiseSigma
        self.seeingJitter = seeingJitter
    }

    /// 1.22 λ f / (D · pixel), with an 8× Barlow so rings are resolved.
    public static let defaultFirstMinimumPixels: Double = {
        let wavelengthM = 550e-9
        let apertureM = 0.200
        let focalM = TelescopeOptics.focalLengthMillimeters / 1000
        let pixelM = TelescopeOptics.pixelSizeMicrons * 1e-6
        let native = 1.22 * wavelengthM * focalM / (apertureM * pixelM)
        return native * 8
    }()
}

public struct AiryRenderer: Sendable {
    public var scene: AiryScene

    public init(scene: AiryScene = AiryScene()) {
        self.scene = scene
    }

    public func intensity(atRadiusPixels r: Double) -> Double {
        let scale = scene.firstMinimumPixels
        let x = AiryScene.j1FirstZero * r / scale
        if abs(x) < 1e-6 { return 1 }
        let a = 2 * j1(x) / x
        return a * a
    }

    public func render(roi: ROI, jitter: SIMD2<Double> = .zero, rng: inout RNG) -> Frame {
        let width = roi.width
        let height = roi.height
        var pixels = [UInt16](repeating: 0, count: width * height)
        let origin = scene.starPosition + jitter
        let bin = Double(roi.binning)
        let background = UInt16(min(65535, max(0, scene.backgroundADU.rounded())))
        let margin = scene.firstMinimumPixels * 5.5

        var x0 = Int(floor((origin.x - margin - Double(roi.x)) / bin))
        var y0 = Int(floor((origin.y - margin - Double(roi.y)) / bin))
        var x1 = Int(ceil((origin.x + margin - Double(roi.x)) / bin))
        var y1 = Int(ceil((origin.y + margin - Double(roi.y)) / bin))
        x0 = min(max(x0, 0), width)
        y0 = min(max(y0, 0), height)
        x1 = min(max(x1, 0), width)
        y1 = min(max(y1, 0), height)

        if scene.noiseSigma > 0 {
            let amp = UInt16(min(200, max(1, scene.noiseSigma.rounded())))
            for i in 0..<pixels.count {
                let n = UInt16(rng.next() & 0x3F)
                pixels[i] = background &+ (n % amp)
            }
        } else {
            for i in 0..<pixels.count { pixels[i] = background }
        }

        if x1 > x0, y1 > y0 {
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let sx = Double(roi.x) + (Double(x) + 0.5) * bin
                    let sy = Double(roi.y) + (Double(y) + 0.5) * bin
                    let dx = sx - origin.x
                    let dy = sy - origin.y
                    let r = sqrt(dx * dx + dy * dy)
                    let signal = intensity(atRadiusPixels: r)
                    if signal < 2e-5 { continue }
                    var value = scene.backgroundADU + signal * scene.peakADU
                    if scene.noiseSigma > 0 {
                        value += rng.cheapNoise() * scene.noiseSigma
                    }
                    pixels[y * width + x] = UInt16(min(65535, max(0, value.rounded())))
                }
            }
        }

        return Frame(width: width, height: height, pixels: pixels, roi: roi)
    }
}
