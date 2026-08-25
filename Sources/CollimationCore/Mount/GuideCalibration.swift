import Foundation

public enum GuideDirection: String, Equatable, Sendable, CaseIterable {
    case north
    case south
    case east
    case west
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

public enum SynScanGuide {
    /// Official SynScan fixed-rate slew used to simulate autoguiding (rate 1 does not cancel equatorial tracking).
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
