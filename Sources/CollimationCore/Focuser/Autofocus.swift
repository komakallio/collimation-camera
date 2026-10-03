import Foundation

public enum AutofocusError: Error, LocalizedError, Sendable {
    case invalidRange
    case noStar
    case motionTimeout
    case positionMismatch
    case minimumNotBracketed
    case flatCurve
    case verificationFailed
    case exposureLimit
    case unstableExposure
    case invalidSlope
    case searchTravelLimit
    case searchNotImproving
    case unstableFit
    case recoveryFailed

    public var errorDescription: String? {
        switch self {
        case .invalidRange: return "Autofocus needs room for the entire scan and outward take-up. Move away from the travel limit or change the scan range."
        case .noStar: return "Autofocus could not measure five fresh star frames. Check tracking, exposure, saturation and whether the whole star fits in the ROI."
        case .motionTimeout: return "Autofocus timed out waiting for the focuser to stop."
        case .positionMismatch: return "The focuser stopped before reaching the autofocus target."
        case .minimumNotBracketed: return "Autofocus could not bracket a focus minimum. Check the star and autofocus step."
        case .flatCurve: return "The autofocus curve has no clear minimum. Increase the autofocus step and try again."
        case .verificationFailed: return "The legacy comparison routine rejected the final HFR."
        case .exposureLimit: return "The star is still saturated at minimum exposure. Reduce camera gain or star brightness and try autofocus again."
        case .unstableExposure: return "Autofocus could not stabilise the star exposure. Check changing illumination or camera gain and try again."
        case .invalidSlope: return "The best focus is at the scan edge, but the slope is too weak or inconsistent to follow. Check seeing and increase the autofocus step."
        case .searchTravelLimit: return "Autofocus reached the calibrated travel limit while following the focus slope. Move the optical focus within the focuser's range or reduce the autofocus step."
        case .searchNotImproving: return "The autofocus slope reversed or stopped improving after re-centering. Check seeing, star tracking and backlash, then try again."
        case .unstableFit: return "The focus curve has excessive residuals or an unstable focus estimate. Check seeing and scan spacing."
        case .recoveryFailed: return "The verification bracket contradicts the focus curve or remains inconclusive."
        }
    }
}

public struct AutofocusSample: Equatable, Sendable, Codable {
    public let position: Int
    /// Half-flux radius in unbinned sensor pixels, measured on raw ADU.
    public let hfr: Double
    public let exposureMicroseconds: Int?
    public var gain: Int?
    public var readings: [AutofocusReading]?
    public var startedAt: Date?
    public var finishedAt: Date?
    public var scatter: Double?
    public var rejectedFrames: Int?
    public var staleFrames: Int?
    public var durationSeconds: Double?
    public init(position: Int, hfr: Double, exposureMicroseconds: Int? = nil,
                gain: Int? = nil, readings: [AutofocusReading]? = nil,
                startedAt: Date? = nil, finishedAt: Date? = nil, rejectedFrames: Int? = nil) {
        self.position = position; self.hfr = hfr; self.exposureMicroseconds = exposureMicroseconds
        self.gain = gain; self.readings = readings; self.startedAt = startedAt; self.finishedAt = finishedAt
        self.rejectedFrames = rejectedFrames
        if let startedAt, let finishedAt { durationSeconds = finishedAt.timeIntervalSince(startedAt) }
        if let readings {
            let values = readings.compactMap(\.hfr)
            scatter = 1.4826 * AutofocusPlan.median(values.map { abs($0 - hfr) })
        }
    }

    /// Scatter describes a block, not a standard error of five independent frames.
    /// These policy floors are deliberately configurable, not camera constants.
    public func uncertainty(settings: AutofocusSettings) -> Double {
        max(settings.absoluteHFRFloor, max(settings.relativeHFRFloor * hfr, scatter ?? 0))
    }
}

public struct AutofocusReading: Equatable, Sendable, Codable {
    public let timestamp: Date
    public let timestampUnixSeconds: Double
    public let hfr: Double?
    public let rejection: String?
    public init(timestamp: Date, hfr: Double?, rejection: String? = nil) {
        self.timestamp = timestamp; self.hfr = hfr; self.rejection = rejection
        self.timestampUnixSeconds = timestamp.timeIntervalSince1970
    }
}

public struct AutofocusSettings: Equatable, Sendable, Codable {
    public var step: Int
    public var takeUp: Int
    public var settleSeconds: Double
    public var discardFrames: Int
    public var verificationInterval: Double
    public var absoluteHFRFloor: Double
    public var relativeHFRFloor: Double
    public var gain: Int
    public var framesPerPosition: Int
    public var frameTimeout: Double
    public var motionTimeout: Double
    public var maximumRejectedFrames: Int
    public init(step: Int = 1000, takeUp: Int = 4000, settleSeconds: Double = 1,
                discardFrames: Int = 3, verificationInterval: Double = 1,
                absoluteHFRFloor: Double = 0.05, relativeHFRFloor: Double = 0.03, gain: Int = 0,
                frameTimeout: Double = 8, motionTimeout: Double = 60) {
        self.step = step; self.takeUp = takeUp; self.settleSeconds = settleSeconds
        self.discardFrames = discardFrames; self.verificationInterval = verificationInterval
        self.absoluteHFRFloor = absoluteHFRFloor; self.relativeHFRFloor = relativeHFRFloor; self.gain = gain
        self.framesPerPosition = 5; self.maximumRejectedFrames = 24
        self.frameTimeout = frameTimeout; self.motionTimeout = motionTimeout
    }
}

/// Only the opt-in hardware comparison selects legacy. Both apps use production.
public enum AutofocusComparisonPolicy: Sendable { case production, legacy }

/// A bounded diagnostic acquisition can fail without invalidating a fitted
/// focus position. Preserve partial readings rather than inventing a final HFR.
public struct AutofocusFinalMeasurementIssue: Equatable, Sendable, Codable {
    public let position: Int
    public let block: Int
    public let startedAt: Date
    public let finishedAt: Date
    public let readings: [AutofocusReading]
    public let reason: String
}

public struct AutofocusDiagnostics: Equatable, Sendable, Codable {
    public var settings: AutofocusSettings
    public var verificationPolicy: String?
    public var baseline: AutofocusSample?
    public var curves: [[AutofocusSample]] = []
    public var fit: AutofocusFit?
    public var verification: [AutofocusSample] = []
    public var finalMeasurementIssues: [AutofocusFinalMeasurementIssue]?
    public var recovery: [AutofocusSample] = []
    public var recoveryOutcome: String?
    public var recoveryFittedPosition: Int?
    public var recoveryPredictionHFR: Double?
    public var finalPosition: Int?
    public var finalHFR: Double?
    public var failure: String?
    public var rejectedReadings: [AutofocusReading] = []
    public init(settings: AutofocusSettings, verificationPolicy: String = "curve-fit-position-only") {
        self.settings = settings; self.verificationPolicy = verificationPolicy
    }
}

/// A supported minimum, including the final accepted curve and the star's
/// measured location. Scalars are intentional across Windows async boundaries.
public struct AutofocusResult: Equatable, Sendable, Codable {
    public let position: Int
    /// Diagnostic only. Nil when final-position HFR could not be measured.
    public let hfr: Double?
    public let sensorX: Double
    public let sensorY: Double
    public let timestamp: Date
    public let exposureMicroseconds: Int
    public let samples: [AutofocusSample]
    public let exposureRetries: Int
    public let recenters: Int
    public var diagnostics: AutofocusDiagnostics?

    public init(position: Int, hfr: Double?, sensorX: Double, sensorY: Double,
                timestamp: Date = Date(), exposureMicroseconds: Int,
                samples: [AutofocusSample], exposureRetries: Int = 0, recenters: Int = 0,
                diagnostics: AutofocusDiagnostics? = nil) {
        self.position = position; self.hfr = hfr
        self.sensorX = sensorX; self.sensorY = sensorY; self.timestamp = timestamp
        self.exposureMicroseconds = exposureMicroseconds; self.samples = samples
        self.exposureRetries = exposureRetries; self.recenters = recenters
        self.diagnostics = diagnostics
    }
}

public enum AutofocusState: Equatable, Sendable {
    case idle
    case adjustingExposure(microseconds: Int)
    case recentering(position: Int)
    case checkingStar(frames: Int)
    case moving(position: Int)
    case measuring(position: Int, frames: Int)
    case verifying(position: Int)
    case verificationBlock(position: Int, block: Int)
    case recordingFinalHFR(position: Int, block: Int)
    case recovering(position: Int)
    case complete(position: Int, hfr: Double?)
    case cancelled
    case failed
}

/// Leave headroom for a sharper star and seeing fluctuations. Clipped peaks
/// cannot reveal the actual brightness, so back off before proportional tuning.
public enum AutofocusExposureControl {
    public static let maximumRestarts = 4
    public static let maximumAdjustments = 12

    public static func nextMicroseconds(current: Int, peak: UInt16) throws -> Int {
        let current = max(ExposureControl.minMicroseconds, min(ExposureControl.maxMicroseconds, current))
        if peak >= StarQuality.clipADU {
            guard current > ExposureControl.minMicroseconds else { throw AutofocusError.exposureLimit }
            return max(ExposureControl.minMicroseconds, Int(Double(current) * 0.2))
        }
        let fraction = Double(peak) / 65535
        if fraction >= 0.45 && fraction <= 0.60 { return current }
        let proposed = Double(current) * 0.50 / max(fraction, 1.0 / 65535)
        return Int(max(Double(ExposureControl.minMicroseconds),
                       min(Double(ExposureControl.maxMicroseconds), proposed)).rounded())
    }
}

/// Independent of HFR: clipped stars have useful exposure feedback even when
/// their flux radius is invalid. Scalars avoid SIMD transfers through async calls.
struct FocusExposureReading: Sendable {
    let peak: UInt16
    let snr: Double
    let sensorX: Double
    let sensorY: Double
    let detected: Bool
}

struct AutofocusExposureChanged: Error {}

public struct AutofocusTiming: Sendable {
    public var motionTimeout: TimeInterval
    public var frameTimeout: TimeInterval
    public var settleSeconds: TimeInterval
    public var verificationInterval: TimeInterval
    public init(motionTimeout: TimeInterval = 60, frameTimeout: TimeInterval = 8, settleSeconds: TimeInterval = 1,
                verificationInterval: TimeInterval = 1) {
        self.motionTimeout = motionTimeout
        self.frameTimeout = frameTimeout
        self.settleSeconds = settleSeconds
        self.verificationInterval = verificationInterval
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
    public let takeUp: Int

    public init(position: Int, maximum: Int, step: Int, takeUp: Int = 4000) throws {
        // Division checks precede multiplication, including for Int.max input.
        guard position >= 0, maximum > 0, position <= maximum, step > 0,
              takeUp > 0, takeUp <= position,
              step <= (position - takeUp) / 4, step <= (maximum - position) / 4 else {
            throw AutofocusError.invalidRange
        }
        self.step = step
        self.takeUp = takeUp
        preloadPosition = position - 4 * step - takeUp
        positions = (-4...4).map { position + $0 * step }
    }

    /// Fit the full weighted curve. Normalised coordinates avoid conditioning
    /// problems at large absolute ESATTO motor positions.
    public func solution(samples: [AutofocusSample]) throws -> Int {
        try fit(samples: samples).position
    }

    public func fit(samples: [AutofocusSample], settings: AutofocusSettings? = nil) throws -> AutofocusFit {
        _ = try minimumIndex(samples: samples)
        return try AutofocusFitter.fit(samples, settings: settings ?? AutofocusSettings(step: step, takeUp: takeUp))
    }

    /// Retained solely for the opt-in old/new hardware comparison.
    public func legacySolution(samples: [AutofocusSample]) throws -> Int {
        let best = try minimumIndex(samples: samples)
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

    private func minimumIndex(samples: [AutofocusSample]) throws -> Int {
        guard samples.count == positions.count,
              zip(samples, positions).allSatisfy({ $0.position == $1 && $0.hfr.isFinite && $0.hfr > 0 }),
              samples.allSatisfy({ $0.exposureMicroseconds == samples.first?.exposureMicroseconds })
        else { throw AutofocusError.noStar }
        return samples.indices.min { samples[$0].hfr < samples[$1].hfr }!
    }

    /// Follow a supported edge trend, with half the old window overlapping.
    /// Median thirds and pairwise slopes reject an isolated low edge reading.
    public func recentered(samples: [AutofocusSample], maximum: Int) throws -> AutofocusPlan {
        let best = try minimumIndex(samples: samples)
        guard best == 0 || best == samples.count - 1 else { throw AutofocusError.minimumNotBracketed }
        let towardEdge = best == 0 ? samples.reversed().map(\.hfr) : samples.map(\.hfr)
        let far = Self.median(Array(towardEdge[0..<3]))
        let middle = Self.median(Array(towardEdge[3..<6]))
        let near = Self.median(Array(towardEdge[6..<9]))
        var slopes: [Double] = []
        for i in 0..<towardEdge.count {
            for j in (i + 1)..<towardEdge.count {
                slopes.append((towardEdge[j] - towardEdge[i]) / Double(j - i))
            }
        }
        guard far > middle * 1.02, middle > near * 1.02, far > near * 1.05,
              Self.median(slopes) < -Self.median(towardEdge) * 0.005,
              slopes.filter({ $0 < 0 }).count * 4 >= slopes.count * 3 else {
            throw AutofocusError.invalidSlope
        }
        // The current plan has already proved these multiplications safe.
        guard maximum >= positions.last! else { throw AutofocusError.searchTravelLimit }
        let center = max(4 * step + takeUp, min(maximum - 4 * step, positions[best]))
        guard center != positions[4] else { throw AutofocusError.searchTravelLimit }
        return try AutofocusPlan(position: center, maximum: maximum, step: step, takeUp: takeUp)
    }

    public static func approach(target: Int, maximum: Int, takeUp: Int) throws -> [Int] {
        guard takeUp > 0, target >= takeUp, target <= maximum else { throw AutofocusError.invalidRange }
        return [target - takeUp, target]
    }

    public static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return .nan }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    /// Historical behaviour, used only by the opt-in old-routine comparison.
    public static func verifyLegacyHFR(hfr: Double, samples: [AutofocusSample]) throws {
        guard samples.allSatisfy({ $0.hfr.isFinite && $0.hfr > 0 }),
              let best = samples.map(\.hfr).min(), hfr.isFinite, hfr > 0,
              hfr <= best * 1.15 else { throw AutofocusError.verificationFailed }
    }
}

/// Calibrated travel bounds terminate a continuing slope. Reject reversals and
/// lack of progress so changing seeing cannot make the motor shuttle forever.
public struct AutofocusSearch: Sendable {
    private var direction: Int?
    private var previousBest: Double?
    public init() {}

    public mutating func exposureChanged() { previousBest = nil }

    public mutating func recenter(plan: AutofocusPlan, samples: [AutofocusSample], maximum: Int) throws -> AutofocusPlan {
        let next = try plan.recentered(samples: samples, maximum: maximum)
        let nextDirection = next.positions[4] > plan.positions[4] ? 1 : -1
        let best = samples.map(\.hfr).min()!
        guard direction == nil || direction == nextDirection,
              previousBest == nil || best < previousBest! * 0.98 else { throw AutofocusError.searchNotImproving }
        direction = nextDirection
        previousBest = best
        return next
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
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
    func check() throws { try lock.withLock { if cancelled { throw CancellationError() } } }
}
