import Foundation

public enum GuideDirection: String, Equatable, Sendable, CaseIterable {
    case north
    case south
    case east
    case west

    public var opposite: GuideDirection {
        switch self {
        case .north: return .south
        case .south: return .north
        case .east: return .west
        case .west: return .east
        }
    }
}

public struct GuidePulse: Equatable, Sendable {
    public var direction: GuideDirection
    public var milliseconds: Int

    public init(direction: GuideDirection, milliseconds: Int) {
        self.direction = direction
        self.milliseconds = milliseconds
    }
}

/// Maps pulse-guide axes onto unbinned sensor pixels.
///
/// `eastRate` / `northRate` are the star's motion in sensor pixels for each
/// millisecond of an East or North pulse. West and South are the negatives.
public struct GuideCalibration: Equatable, Sendable, Codable {
    public var eastX: Double
    public var eastY: Double
    public var northX: Double
    public var northY: Double
    public var sampleDurationMs: Int
    public var calibratedAt: Date

    public init(
        eastRate: SIMD2<Double>,
        northRate: SIMD2<Double>,
        sampleDurationMs: Int,
        calibratedAt: Date = Date()
    ) {
        self.eastX = eastRate.x
        self.eastY = eastRate.y
        self.northX = northRate.x
        self.northY = northRate.y
        self.sampleDurationMs = sampleDurationMs
        self.calibratedAt = calibratedAt
    }

    public var eastRate: SIMD2<Double> { SIMD2(eastX, eastY) }
    public var northRate: SIMD2<Double> { SIMD2(northX, northY) }

    public var determinant: Double {
        eastX * northY - northX * eastY
    }

    public var isValid: Bool {
        abs(determinant) > 1e-8
            && hypot(eastX, eastY) > 1e-5
            && hypot(northX, northY) > 1e-5
    }

    /// Pulse durations that move the star by `delta` sensor pixels.
    /// Negative East time means West; negative North time means South.
    public func pulses(toMoveStarBy delta: SIMD2<Double>) -> (eastMs: Double, northMs: Double)? {
        let det = determinant
        guard abs(det) > 1e-8 else { return nil }
        let eastMs = (delta.x * northY - northX * delta.y) / det
        let northMs = (eastX * delta.y - delta.x * eastY) / det
        guard eastMs.isFinite, northMs.isFinite else { return nil }
        return (eastMs, northMs)
    }

    /// Axes to slew so the star moves by `delta`. An axis is omitted when the
    /// remaining motion along it is below `minAxisPixels`, so a fast slew can
    /// stop one motor while the other continues.
    public func slewAxes(
        toMoveStarBy delta: SIMD2<Double>,
        minAxisPixels: Double
    ) -> (ra: GuideDirection?, dec: GuideDirection?) {
        guard let times = pulses(toMoveStarBy: delta) else { return (nil, nil) }
        let eastPixels = hypot(eastX, eastY) * abs(times.eastMs)
        let northPixels = hypot(northX, northY) * abs(times.northMs)
        let ra: GuideDirection? = eastPixels >= minAxisPixels
            ? (times.eastMs >= 0 ? .east : .west)
            : nil
        let dec: GuideDirection? = northPixels >= minAxisPixels
            ? (times.northMs >= 0 ? .north : .south)
            : nil
        return (ra, dec)
    }
}

public enum GuidePulsePlanner {
    public static let maxCommandMs = 9999
    public static let minPulseMs = 40
    public static let maxAxisMsPerStep = 9000

    public static func pulses(eastMs: Double, northMs: Double) -> [GuidePulse] {
        let east = clamped(eastMs)
        let north = clamped(northMs)
        var result: [GuidePulse] = []
        result.append(contentsOf: split(positive: .east, negative: .west, milliseconds: east))
        result.append(contentsOf: split(positive: .north, negative: .south, milliseconds: north))
        return result
    }

    public static func clamped(_ milliseconds: Double) -> Double {
        min(max(milliseconds, -Double(maxAxisMsPerStep)), Double(maxAxisMsPerStep))
    }

    static func split(positive: GuideDirection, negative: GuideDirection, milliseconds: Double) -> [GuidePulse] {
        let rounded = Int(milliseconds.rounded())
        guard abs(rounded) >= minPulseMs else { return [] }
        let direction = rounded >= 0 ? positive : negative
        var remaining = abs(rounded)
        var pulses: [GuidePulse] = []
        while remaining > 0 {
            let chunk = min(remaining, maxCommandMs)
            pulses.append(GuidePulse(direction: direction, milliseconds: chunk))
            remaining -= chunk
        }
        return pulses
    }
}

public enum MountGuide {
    public static let calibrationPulseMs = 3000
    public static let maxCenterIterations = 20
    public static let doneRadiusSensorPixels = 2.0
    public static let slewRadiusSensorPixels = 50.0
    public static let slewAxisStopPixels = 40.0
    public static let minCalibrationMovePixels = 3.0
    public static let settleMilliseconds = 1_200

    public static func frameCenter(width: Int, height: Int) -> SIMD2<Double> {
        SIMD2(Double(max(width, 1) - 1) / 2, Double(max(height, 1) - 1) / 2)
    }

    public static func rate(before: SIMD2<Double>, after: SIMD2<Double>, durationMs: Double) -> SIMD2<Double> {
        guard durationMs > 0 else { return .zero }
        return (after - before) / durationMs
    }

    public static func isCentered(errorPixels: SIMD2<Double>) -> Bool {
        hypot(errorPixels.x, errorPixels.y) < doneRadiusSensorPixels
    }

    public static func isWithinSlewTolerance(_ errorPixels: SIMD2<Double>) -> Bool {
        hypot(errorPixels.x, errorPixels.y) <= slewRadiusSensorPixels
    }

    /// New slew direction after a measurement. Sign flips stop the axis instead
    /// of reversing, so a fast slew cannot oscillate around the target.
    public static func committedSlew(current: GuideDirection?, desired: GuideDirection?) -> GuideDirection? {
        if current == desired { return current }
        if let current, desired == current.opposite { return nil }
        return desired
    }

    public static func errorLength(_ error: SIMD2<Double>) -> Double {
        hypot(error.x, error.y)
    }
}

public enum GuideCalibrationStore {
    public static let fileName = "guide-calibration.json"

    public static func defaultURL() throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let folder = root.appendingPathComponent("Collimation Camera", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(fileName)
    }

    public static func load(from url: URL) -> GuideCalibration? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(GuideCalibration.self, from: data)
    }

    public static func save(_ calibration: GuideCalibration, to url: URL) throws {
        let data = try JSONEncoder().encode(calibration)
        try data.write(to: url, options: .atomic)
    }

    public static func load() -> GuideCalibration? {
        guard let url = try? defaultURL() else { return nil }
        return load(from: url)
    }

    public static func save(_ calibration: GuideCalibration) throws {
        try save(calibration, to: defaultURL())
    }
}

public enum LX200PulseGuide {
    public static func command(_ direction: GuideDirection, milliseconds: Int) -> String {
        let ms = min(max(milliseconds, 0), 9999)
        let letter: String
        switch direction {
        case .north: letter = "n"
        case .south: letter = "s"
        case .east: letter = "e"
        case .west: letter = "w"
        }
        return String(format: ":Mg%@%04d#", letter, ms)
    }
}

public enum SkyWatcherEncoding {
    /// 24-bit little-endian value as six hex characters, as used by the motor controller.
    public static func hex24(_ value: Int) -> String {
        let n = UInt32(clamping: max(0, value))
        return String(format: "%02X%02X%02X", n & 0xFF, (n >> 8) & 0xFF, (n >> 16) & 0xFF)
    }

    public static func parseHex24(_ text: String) -> Int? {
        let hex = text.filter(\.isHexDigit)
        guard hex.count >= 6 else { return nil }
        let start = hex.startIndex
        let b0 = hex[start..<hex.index(start, offsetBy: 2)]
        let b1 = hex[hex.index(start, offsetBy: 2)..<hex.index(start, offsetBy: 4)]
        let b2 = hex[hex.index(start, offsetBy: 4)..<hex.index(start, offsetBy: 6)]
        guard let low = Int(b0, radix: 16),
              let mid = Int(b1, radix: 16),
              let high = Int(b2, radix: 16)
        else { return nil }
        return low + mid * 256 + high * 65536
    }
}

public struct PadNudge: Equatable, Sendable {
    public var ra: GuideDirection?
    public var dec: GuideDirection?
    public var rate: UInt8

    public init(ra: GuideDirection?, dec: GuideDirection?, rate: UInt8) {
        self.ra = ra
        self.dec = dec
        self.rate = (ra == nil && dec == nil) ? 0 : min(max(rate, 1), 9)
    }

    public var isIdle: Bool { ra == nil && dec == nil }
}

public enum SynScanGuide {
    /// Handset / SynScan-app D-pad rates. The pad sends the SynScan `P`
    /// fixed-rate command with this 1–9 value (0 stops). Multiples are sidereal.
    public static func siderealMultiple(_ rate: UInt8) -> Double {
        switch rate {
        case 0: return 0
        case 1: return 1
        case 2: return 8
        case 3: return 16
        case 4: return 32
        case 5: return 64
        case 6: return 128
        case 7: return 400
        case 8: return 600
        default: return 800
        }
    }

    public static func rate(forDistancePixels distance: Double) -> UInt8 {
        switch distance {
        case 2500...: return 6
        case 1000...: return 5
        case 400...: return 4
        case 150...: return 3
        default: return 2
        }
    }

    public static func nudge(
        movingStarBy delta: SIMD2<Double>,
        calibration: GuideCalibration,
        minAxisPixels: Double,
        distancePixels: Double
    ) -> PadNudge? {
        let axes = calibration.slewAxes(toMoveStarBy: delta, minAxisPixels: minAxisPixels)
        if axes.ra == nil && axes.dec == nil { return nil }
        return PadNudge(ra: axes.ra, dec: axes.dec, rate: rate(forDistancePixels: distancePixels))
    }

    /// Official SynScan D-pad command: hold a direction at rate 1–9, or 0 to release.
    public static func fixedRateCommand(direction: GuideDirection, rate: UInt8) -> Data {
        let ra: Bool
        let positive: Bool
        switch direction {
        case .east:
            ra = true
            positive = true
        case .west:
            ra = true
            positive = false
        case .north:
            ra = false
            positive = true
        case .south:
            ra = false
            positive = false
        }
        return Data([
            UInt8(ascii: "P"),
            2,
            ra ? 16 : 17,
            positive ? 36 : 37,
            rate,
            0, 0, 0
        ])
    }
}
