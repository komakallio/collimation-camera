import Foundation

public enum AutofocusError: Error, LocalizedError, Sendable {
    case invalidRange
    case noStar
    case motionTimeout
    case positionMismatch
    case minimumNotBracketed
    case flatCurve
    case verificationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidRange: return "Autofocus needs room for five steps inward and four outward. Reduce the autofocus step or move away from the travel limit."
        case .noStar: return "Autofocus could not measure five fresh star frames. Check tracking, exposure, saturation and whether the whole star fits in the ROI."
        case .motionTimeout: return "Autofocus timed out waiting for the focuser to stop."
        case .positionMismatch: return "The focuser stopped before reaching the autofocus target."
        case .minimumNotBracketed: return "The best focus is at the scan edge. Move toward that edge or increase the autofocus step and try again."
        case .flatCurve: return "The autofocus curve has no clear minimum. Increase the autofocus step and try again."
        case .verificationFailed: return "Focus verification was worse than the scan minimum. Check seeing, exposure and backlash, then try again."
        }
    }
}

public struct AutofocusSample: Equatable, Sendable {
    public let position: Int
    /// Half-flux radius in unbinned sensor pixels, measured on raw ADU.
    public let hfr: Double
    public init(position: Int, hfr: Double) { self.position = position; self.hfr = hfr }
}

public enum AutofocusState: Equatable, Sendable {
    case idle
    case checkingStar(frames: Int)
    case moving(position: Int)
    case measuring(position: Int, frames: Int)
    case verifying(position: Int)
    case complete(position: Int, hfr: Double)
    case cancelled
    case failed
}

public struct AutofocusTiming: Sendable {
    public var motionTimeout: TimeInterval
    public var frameTimeout: TimeInterval
    public var settleSeconds: TimeInterval
    public init(motionTimeout: TimeInterval = 60, frameTimeout: TimeInterval = 8, settleSeconds: TimeInterval = 0.3) {
        self.motionTimeout = motionTimeout
        self.frameTimeout = frameTimeout
        self.settleSeconds = settleSeconds
    }
}

/// A bounded, increasing-position scan. Preloads and the final approach use
/// the same direction so mechanical play does not shift the fitted minimum.
public struct AutofocusPlan: Sendable {
    public static let sampleCount = 9
    public static let framesPerPosition = 5
    public let positions: [Int]
    public let step: Int
    public let preloadPosition: Int

    public init(position: Int, maximum: Int, step: Int) throws {
        // Division checks precede multiplication, including for Int.max input.
        guard position >= 0, maximum > 0, position <= maximum, step > 0,
              step <= position / 5, step <= (maximum - position) / 4 else {
            throw AutofocusError.invalidRange
        }
        self.step = step
        preloadPosition = position - 5 * step
        positions = (-4...4).map { position + $0 * step }
    }

    /// Interpolate HFR squared around the lowest point. Normalised coordinates
    /// avoid ill-conditioned fits to large absolute ESATTO motor positions.
    public func solution(samples: [AutofocusSample]) throws -> Int {
        guard samples.count == positions.count,
              zip(samples, positions).allSatisfy({ $0.position == $1 && $0.hfr.isFinite && $0.hfr > 0 })
        else { throw AutofocusError.noStar }
        let best = samples.indices.min { samples[$0].hfr < samples[$1].hfr }!
        let low = samples[best].hfr
        guard samples.map(\.hfr).max()! > low * 1.05 else { throw AutofocusError.flatCurve }
        guard best > 0, best < samples.count - 1 else { throw AutofocusError.minimumNotBracketed }
        guard samples.first!.hfr > low * 1.05, samples.last!.hfr > low * 1.05 else {
            throw AutofocusError.flatCurve
        }
        let left = pow(samples[best - 1].hfr, 2)
        let middle = low * low
        let right = pow(samples[best + 1].hfr, 2)
        let curvature = left - 2 * middle + right
        guard curvature.isFinite, curvature > middle * 0.005 else { throw AutofocusError.flatCurve }
        let offset = 0.5 * (left - right) / curvature
        guard offset.isFinite, abs(offset) <= 1 else { throw AutofocusError.flatCurve }
        return samples[best].position + Int((offset * Double(step)).rounded())
    }

    public static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return .nan }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    public static func verify(hfr: Double, samples: [AutofocusSample]) throws {
        guard samples.allSatisfy({ $0.hfr.isFinite && $0.hfr > 0 }),
              let best = samples.map(\.hfr).min(), hfr.isFinite, hfr > 0,
              hfr <= best * 1.15 else { throw AutofocusError.verificationFailed }
    }
}

public struct FocusMetric: Sendable {
    public let hfr: Double
    public let sensorX: Double
    public let sensorY: Double
}

/// Background-subtracted half-flux radius of the detected connected star.
/// Thresholding removes sky noise; rejecting aperture contact prevents a
/// cropped donut from appearing artificially sharp. No display stretch enters.
public struct FocusMetricEstimator: Sendable {
    public init() {}

    public func measure(frame: Frame, detection: StarDetection) -> FocusMetric? {
        let center = detection.centroid
        guard center.x.isFinite, center.y.isFinite, detection.snr >= 10,
              detection.peak < StarQuality.clipADU,
              frame.width > 16, frame.height > 16,
              frame.pixels.count == frame.width * frame.height else { return nil }
        let radius = min(center.x, center.y, Double(frame.width - 1) - center.x,
                         Double(frame.height - 1) - center.y) - 3
        guard radius >= 6 else { return nil }
        let radiusSquared = radius * radius
        let threshold = detection.background + 3 * detection.sigma
        let x0 = max(0, Int(center.x - radius)), x1 = min(frame.width - 1, Int(center.x + radius))
        let y0 = max(0, Int(center.y - radius)), y1 = min(frame.height - 1, Int(center.y + radius))
        var seed: Int?
        var seedDistance = radiusSquared
        for y in y0...y1 {
            for x in x0...x1 {
                let dx = Double(x) - center.x, dy = Double(y) - center.y
                let distance = dx * dx + dy * dy
                // Detection chose the brightest integrated blob. A nearby
                // compact star/hot pixel may have a higher individual peak.
                if distance < seedDistance, frame.pixels[y * frame.width + x] == detection.peak {
                    seedDistance = distance; seed = y * frame.width + x
                }
            }
        }
        guard let seed else { return nil }
        var visited = [Bool](repeating: false, count: frame.pixelCount)
        var queue = [seed]
        visited[seed] = true
        let binWidth = 0.25
        var fluxBins = [Double](repeating: 0, count: Int(ceil(radius / binWidth)) + 1)
        var flux = 0.0
        var index = 0
        while index < queue.count {
            let pixel = queue[index]; index += 1
            let x = pixel % frame.width, y = pixel / frame.width
            let dx = Double(x) - center.x, dy = Double(y) - center.y
            let distance = sqrt(dx * dx + dy * dy)
            guard distance < radius - 1, x > 0, y > 0, x < frame.width - 1, y < frame.height - 1,
                  frame.pixels[pixel] < StarQuality.clipADU else { return nil }
            let weight = max(0, Double(frame.pixels[pixel]) - detection.background)
            flux += weight
            fluxBins[Int(distance / binWidth)] += weight
            for neighbour in [pixel - 1, pixel + 1, pixel - frame.width, pixel + frame.width] {
                if !visited[neighbour], Double(frame.pixels[neighbour]) > threshold {
                    visited[neighbour] = true
                    queue.append(neighbour)
                }
            }
        }
        guard queue.count >= 20, flux > 0 else { return nil }
        var cumulative = 0.0
        for (bin, weight) in fluxBins.enumerated() {
            if weight > 0, cumulative + weight >= flux / 2 {
                let hfr = (Double(bin) + (flux / 2 - cumulative) / weight) * binWidth
                let sensor = frame.roi.sensorPoint(fromFramePixel: center)
                return FocusMetric(hfr: hfr * Double(frame.roi.binning), sensorX: sensor.x, sensorY: sensor.y)
            }
            cumulative += weight
        }
        return nil
    }
}

/// Main-actor cancellation also prevents commands still waiting on the serial
/// queue from reaching the motor. Task cancellation alone cannot do that.
final class AutofocusCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.withLock { cancelled = true } }
    func check() throws { try lock.withLock { if cancelled { throw CancellationError() } } }
}
