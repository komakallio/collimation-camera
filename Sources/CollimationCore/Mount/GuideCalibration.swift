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

    /// Sidereal (rate 1) speed of this axis in sensor pixels per millisecond.
    public func pixelsPerMillisecond(on axis: MountAxis) -> Double {
        switch axis {
        case .ra: return hypot(eastX, eastY)
        case .dec: return hypot(northX, northY)
        }
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

    /// Signed remaining pixels along RA (east positive) and Dec (north positive).
    public func signedAxisPixels(toMoveStarBy delta: SIMD2<Double>) -> (ra: Double, dec: Double)? {
        guard let times = pulses(toMoveStarBy: delta) else { return nil }
        return (hypot(eastX, eastY) * times.eastMs, hypot(northX, northY) * times.northMs)
    }

    /// Star motion from a single-axis move that closes the remaining error on `axis`.
    public func remainingOnAxis(_ axis: MountAxis, movingStarBy delta: SIMD2<Double>) -> SIMD2<Double>? {
        guard let times = pulses(toMoveStarBy: delta) else { return nil }
        switch axis {
        case .ra:
            return eastRate * times.eastMs
        case .dec:
            return northRate * times.northMs
        }
    }
}

public enum MountAxis: String, Equatable, Sendable {
    case ra
    case dec

    public var other: MountAxis { self == .ra ? .dec : .ra }

    public var displayName: String {
        switch self {
        case .ra: return "RA"
        case .dec: return "Dec"
        }
    }
}

/// Sequential one-axis centering: finish RA or Dec, then the other.
/// Each slew uses the sidereal multiple that covers the remaining distance
/// in about one second.
public enum AxisCentering {
    public struct Plan: Equatable, Sendable {
        public var axis: MountAxis
        public var direction: GuideDirection
        public var siderealMultiple: Double
        public var durationMs: Int
        public var overshot: Bool

        public var nudge: SlewNudge {
            switch axis {
            case .ra:
                return SlewNudge(ra: direction, dec: nil, siderealMultiple: siderealMultiple)
            case .dec:
                return SlewNudge(ra: nil, dec: direction, siderealMultiple: siderealMultiple)
            }
        }
    }

    /// Per-axis stop so both axes inside this radius keep hypot ≤ `doneRadiusSensorPixels`.
    public static var axisDoneRadiusSensorPixels: Double {
        MountGuide.doneRadiusSensorPixels / sqrt(2)
    }

    public static func isAxisCentered(_ pixels: Double) -> Bool {
        abs(pixels) <= axisDoneRadiusSensorPixels
    }

    public static func primaryAxis(raPixels: Double, decPixels: Double) -> MountAxis? {
        if isAxisCentered(raPixels) && isAxisCentered(decPixels) { return nil }
        return abs(raPixels) >= abs(decPixels) ? .ra : .dec
    }

    public static func primaryAxis(
        calibration: GuideCalibration,
        movingStarBy delta: SIMD2<Double>
    ) -> MountAxis? {
        guard let pixels = calibration.signedAxisPixels(toMoveStarBy: delta) else { return nil }
        return primaryAxis(raPixels: pixels.ra, decPixels: pixels.dec)
    }

    public static func overshot(remaining: Double, previousSign: Double?) -> Bool {
        guard let previous = previousSign, previous != 0, remaining != 0 else { return false }
        return (previous > 0) != (remaining > 0)
    }

    public static func direction(axis: MountAxis, remainingPixels: Double) -> GuideDirection? {
        guard remainingPixels != 0 else { return nil }
        switch axis {
        case .ra: return remainingPixels > 0 ? .east : .west
        case .dec: return remainingPixels > 0 ? .north : .south
        }
    }

    public static func plan(
        axis: MountAxis,
        remainingPixels: Double,
        pixelsPerMsAt1x: Double,
        lastSign: Double? = nil
    ) -> Plan? {
        guard !isAxisCentered(remainingPixels),
              let direction = Self.direction(axis: axis, remainingPixels: remainingPixels)
        else { return nil }
        let speed = MountGuide.slewSpeed(
            remainingPixels: remainingPixels,
            pixelsPerMsAt1x: pixelsPerMsAt1x
        )
        return Plan(
            axis: axis,
            direction: direction,
            siderealMultiple: speed.siderealMultiple,
            durationMs: speed.durationMs,
            overshot: Self.overshot(remaining: remainingPixels, previousSign: lastSign)
        )
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
    public static let doneRadiusSensorPixels = 32.0
    public static let slewRadiusSensorPixels = 50.0
    public static let slewAxisStopPixels = 40.0
    public static let minCalibrationMovePixels = 3.0
    public static let settleMilliseconds = 1_200
    public static let minNudgeSliceMs = 200
    public static let maxNudgeSliceMs = 1_500
    public static let targetSlewMilliseconds = 1_000.0

    public static func frameCenter(width: Int, height: Int) -> SIMD2<Double> {
        SIMD2(Double(max(width, 1) - 1) / 2, Double(max(height, 1) - 1) / 2)
    }

    public static func rate(before: SIMD2<Double>, after: SIMD2<Double>, durationMs: Double) -> SIMD2<Double> {
        guard durationMs > 0 else { return .zero }
        return (after - before) / durationMs
    }

    public static func isCentered(errorPixels: SIMD2<Double>) -> Bool {
        hypot(errorPixels.x, errorPixels.y) <= doneRadiusSensorPixels
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

    public struct SlewSpeed: Equatable, Sendable {
        public var siderealMultiple: Double
        public var durationMs: Int
    }

    /// Sidereal multiple and run time so `remainingPixels` is covered in about 1 s.
    public static func slewSpeed(
        remainingPixels: Double,
        pixelsPerMsAt1x: Double,
        targetMs: Double = targetSlewMilliseconds,
        maxMultiple: Double = SkyWatcherEncoding.maxSlowSlewMultiple
    ) -> SlewSpeed {
        let px = abs(remainingPixels)
        let duration = max(targetMs, 1)
        guard pixelsPerMsAt1x > 1e-9 else {
            return SlewSpeed(siderealMultiple: minSiderealMultiple, durationMs: Int(duration.rounded()))
        }
        let needed = px / (pixelsPerMsAt1x * duration)
        let multiple = min(max(needed, minSiderealMultiple), max(maxMultiple, minSiderealMultiple))
        let ms = px / (pixelsPerMsAt1x * multiple)
        let slice = Int(min(max(ms, Double(minNudgeSliceMs)), Double(maxNudgeSliceMs)).rounded())
        return SlewSpeed(siderealMultiple: multiple, durationMs: slice)
    }

    public static let minSiderealMultiple = 0.25
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

    /// Typical EQ6 T1 interval for 1× sidereal in slow slew mode.
    public static let defaultSiderealPeriod = 620
    public static let minSlowSlewPeriod = 16

    public static func plausibleSiderealPeriod(_ value: Int?) -> Int? {
        guard let value, (50...50_000).contains(value) else { return nil }
        return value
    }

    public static func trackingPeriod(sidereal: Int) -> Int {
        max(plausibleSiderealPeriod(sidereal) ?? defaultSiderealPeriod, 50)
    }

    /// Fastest slow-slew multiple (`:G*10` / `:G*11` with period ≥ `minSlowSlewPeriod`).
    /// High-speed gearbox mode is not used: it is loud on EQ6.
    public static var maxSlowSlewMultiple: Double {
        maxSlowSlewMultiple(sidereal: defaultSiderealPeriod)
    }

    public static func maxSlowSlewMultiple(sidereal: Int) -> Double {
        Double(trackingPeriod(sidereal: sidereal)) / Double(minSlowSlewPeriod)
    }

    /// Step-timer period for a sidereal multiple in slow slew mode.
    public static func slowSlewPeriod(sidereal: Int, siderealMultiple: Double) -> Int {
        let multiple = max(siderealMultiple, MountGuide.minSiderealMultiple)
        let base = Double(trackingPeriod(sidereal: sidereal))
        return max(minSlowSlewPeriod, Int((base / multiple).rounded()))
    }
}

public struct SlewNudge: Equatable, Sendable {
    public var ra: GuideDirection?
    public var dec: GuideDirection?
    /// Motor speed in units of sidereal (1×).
    public var siderealMultiple: Double

    public init(ra: GuideDirection?, dec: GuideDirection?, siderealMultiple: Double) {
        self.ra = ra
        self.dec = dec
        self.siderealMultiple = (ra == nil && dec == nil) ? 0 : max(siderealMultiple, 0)
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

    /// Closest slow-slew P-command rate (1–4) to a continuous sidereal multiple.
    /// Used only when the mount speaks SynScan/LX200, which cannot set an exact speed.
    public static func nearestFixedRate(forSiderealMultiple multiple: Double) -> UInt8 {
        let target = max(multiple, 0)
        var best: UInt8 = 1
        var bestError = Double.greatestFiniteMagnitude
        for rate: UInt8 in 1...4 {
            let error = abs(siderealMultiple(rate) - target)
            if error < bestError {
                bestError = error
                best = rate
            }
        }
        return best
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
