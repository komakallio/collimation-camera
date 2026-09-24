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
    /// Lost on-axis pixels when RA reverses, from the east-return residual.
    public var raBacklashPixels: Double
    /// Lost on-axis pixels when Dec reverses, from the north-return residual.
    public var decBacklashPixels: Double

    public init(
        eastRate: SIMD2<Double>,
        northRate: SIMD2<Double>,
        sampleDurationMs: Int,
        calibratedAt: Date = Date(),
        raBacklashPixels: Double = 0,
        decBacklashPixels: Double = 0
    ) {
        self.eastX = eastRate.x
        self.eastY = eastRate.y
        self.northX = northRate.x
        self.northY = northRate.y
        self.sampleDurationMs = sampleDurationMs
        self.calibratedAt = calibratedAt
        self.raBacklashPixels = max(0, raBacklashPixels)
        self.decBacklashPixels = max(0, decBacklashPixels)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        eastX = try c.decode(Double.self, forKey: .eastX)
        eastY = try c.decode(Double.self, forKey: .eastY)
        northX = try c.decode(Double.self, forKey: .northX)
        northY = try c.decode(Double.self, forKey: .northY)
        sampleDurationMs = try c.decode(Int.self, forKey: .sampleDurationMs)
        calibratedAt = try c.decode(Date.self, forKey: .calibratedAt)
        raBacklashPixels = max(0, try c.decodeIfPresent(Double.self, forKey: .raBacklashPixels) ?? 0)
        decBacklashPixels = max(0, try c.decodeIfPresent(Double.self, forKey: .decBacklashPixels) ?? 0)
    }

    private enum CodingKeys: String, CodingKey {
        case eastX, eastY, northX, northY, sampleDurationMs, calibratedAt
        case raBacklashPixels, decBacklashPixels
    }

    public var eastRate: SIMD2<Double> { SIMD2(eastX, eastY) }
    public var northRate: SIMD2<Double> { SIMD2(northX, northY) }

    public var determinant: Double {
        eastX * northY - northX * eastY
    }

    public var isValid: Bool {
        eastX.isFinite && eastY.isFinite && northX.isFinite && northY.isFinite
            && raBacklashPixels.isFinite && decBacklashPixels.isFinite
            && abs(determinant) > 1e-8
            && hypot(eastX, eastY) > 1e-5
            && hypot(northX, northY) > 1e-5
            && axisSeparationSine >= 0.25
    }

    /// A nonzero determinant alone accepts almost parallel measurements and
    /// amplifies a small image error into large, opposing motor commands.
    public var axisSeparationSine: Double {
        let scale = hypot(eastX, eastY) * hypot(northX, northY)
        guard scale.isFinite, scale > 0 else { return 0 }
        return abs(determinant) / scale
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
        guard isValid else { return nil }
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

    public func backlashPixels(on axis: MountAxis) -> Double {
        switch axis {
        case .ra: return raBacklashPixels
        case .dec: return decBacklashPixels
        }
    }

    /// Extra on-axis pixels to command when this move reverses (or the last
    /// direction is unknown). Same-direction follow-ups take up none.
    public func takeupPixels(
        on axis: MountAxis,
        direction: GuideDirection,
        lastDirection: GuideDirection?
    ) -> Double {
        let backlash = backlashPixels(on: axis)
        guard backlash > 0 else { return 0 }
        guard let lastDirection else { return backlash }
        return lastDirection == direction.opposite ? backlash : 0
    }

    public func travelPixels(
        on axis: MountAxis,
        remaining: Double,
        lastDirection: GuideDirection?
    ) -> Double {
        let distance = abs(remaining)
        guard let direction = AxisCentering.direction(axis: axis, remainingPixels: remaining) else {
            return distance
        }
        return distance + takeupPixels(on: axis, direction: direction, lastDirection: lastDirection)
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

/// Last commanded direction on each axis, used to apply backlash only on reverse.
public struct AxisDirectionMemory: Equatable, Sendable {
    public var ra: GuideDirection?
    public var dec: GuideDirection?

    public init(ra: GuideDirection? = nil, dec: GuideDirection? = nil) {
        self.ra = ra
        self.dec = dec
    }

    public func last(on axis: MountAxis) -> GuideDirection? {
        switch axis {
        case .ra: return ra
        case .dec: return dec
        }
    }

    public mutating func record(_ direction: GuideDirection) {
        switch direction {
        case .east, .west: ra = direction
        case .north, .south: dec = direction
        }
    }
}

/// Simultaneous RA/Dec centering. Normal corrections cover 90% of the remaining
/// error; a correction after crossing the target covers 45% without take-up.
public enum AxisCentering {
    /// Fraction of remaining on-axis error to command in one slew. Leaves a
    /// margin so a slightly fast mount does not overshoot the target.
    public static let iterationFraction = 0.9
    /// After this many simultaneous RA/Dec moves, leave the star where it is.
    public static let maxSlews = 5

    public struct Plan: Equatable, Sendable {
        public var axis: MountAxis
        public var direction: GuideDirection
        public var siderealMultiple: Double
        public var durationMs: Int
        public var overshot: Bool

        public var nudge: SlewNudge {
            switch axis {
            case .ra:
                return SlewNudge(ra: direction, dec: nil, raSiderealMultiple: siderealMultiple, decSiderealMultiple: 0)
            case .dec:
                return SlewNudge(ra: nil, dec: direction, raSiderealMultiple: 0, decSiderealMultiple: siderealMultiple)
            }
        }
    }

    public struct DualPlan: Equatable, Sendable {
        public var ra: Plan?
        public var dec: Plan?

        public init(ra: Plan? = nil, dec: Plan? = nil) {
            self.ra = ra
            self.dec = dec
        }

        public var durationMs: Int {
            max(ra?.durationMs ?? 0, dec?.durationMs ?? 0)
        }

        public var nudge: SlewNudge {
            SlewNudge(
                ra: ra?.direction,
                dec: dec?.direction,
                raSiderealMultiple: ra?.siderealMultiple ?? 0,
                decSiderealMultiple: dec?.siderealMultiple ?? 0
            )
        }

        /// Both motors start together. If one axis finishes first, stop it and
        /// keep the other running for the remaining time.
        public var stopSchedule: (firstMs: Int, remaining: SlewNudge?, restMs: Int) {
            let raMs = ra?.durationMs ?? 0
            let decMs = dec?.durationMs ?? 0
            guard raMs > 0, decMs > 0, raMs != decMs else {
                return (max(raMs, decMs), nil, 0)
            }
            var rest = nudge
            if raMs < decMs {
                rest.ra = nil
                rest.raSiderealMultiple = 0
                return (raMs, rest, decMs - raMs)
            }
            rest.dec = nil
            rest.decSiderealMultiple = 0
            return (decMs, rest, raMs - decMs)
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
        lastSign: Double? = nil,
        travelPixels: Double? = nil
    ) -> Plan? {
        guard !isAxisCentered(remainingPixels),
              let direction = Self.direction(axis: axis, remainingPixels: remainingPixels)
        else { return nil }
        let didOvershoot = Self.overshot(remaining: remainingPixels, previousSign: lastSign)
        // Crossing the target is evidence that the last command moved too far.
        // Do not add the same uncertain backlash estimate on the return move.
        let commanded = didOvershoot
            ? iterationFraction / 2 * abs(remainingPixels)
            : commandedPixels(remaining: remainingPixels, travel: travelPixels ?? abs(remainingPixels))
        let speed = MountGuide.slewSpeed(
            remainingPixels: commanded,
            pixelsPerMsAt1x: pixelsPerMsAt1x
        )
        return Plan(
            axis: axis,
            direction: direction,
            siderealMultiple: speed.siderealMultiple,
            durationMs: speed.durationMs,
            overshot: didOvershoot
        )
    }

    /// Command both axes that still have remaining error, with bounded backlash
    /// take-up and a reduced correction after an overshoot.
    public static func plan(
        calibration: GuideCalibration,
        movingStarBy delta: SIMD2<Double>,
        lastDirections: AxisDirectionMemory = AxisDirectionMemory(),
        lastRASign: Double? = nil,
        lastDecSign: Double? = nil
    ) -> DualPlan? {
        guard let pixels = calibration.signedAxisPixels(toMoveStarBy: delta) else { return nil }
        let ra = plan(
            axis: .ra,
            remainingPixels: pixels.ra,
            pixelsPerMsAt1x: calibration.pixelsPerMillisecond(on: .ra),
            lastSign: lastRASign,
            travelPixels: calibration.travelPixels(
                on: .ra,
                remaining: pixels.ra,
                lastDirection: lastDirections.last(on: .ra)
            )
        )
        let dec = plan(
            axis: .dec,
            remainingPixels: pixels.dec,
            pixelsPerMsAt1x: calibration.pixelsPerMillisecond(on: .dec),
            lastSign: lastDecSign,
            travelPixels: calibration.travelPixels(
                on: .dec,
                remaining: pixels.dec,
                lastDirection: lastDirections.last(on: .dec)
            )
        )
        guard ra != nil || dec != nil else { return nil }
        return DualPlan(ra: ra, dec: dec)
    }

    public static func commandedPixels(remaining: Double, travel: Double) -> Double {
        // Take up large backlash over measured iterations rather than allowing
        // a dubious return measurement to dominate a small correction.
        let takeup = min(max(0, travel - abs(remaining)), abs(remaining) / 2)
        return iterationFraction * abs(remaining) + takeup
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

    /// On-axis leftover after an outbound pulse and an equal reverse pulse.
    /// The leftover is the backlash: reverse motion spent taking up slack
    /// instead of moving the star back to `start`.
    public static func backlashPixels(
        start: SIMD2<Double>,
        afterOutbound: SIMD2<Double>,
        afterReturn: SIMD2<Double>
    ) -> Double {
        let outbound = afterOutbound - start
        let length = hypot(outbound.x, outbound.y)
        guard length > 1e-6 else { return 0 }
        let residual = afterReturn - start
        let along = (residual.x * outbound.x + residual.y * outbound.y) / length
        return max(0, along)
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
    /// RA motor speed in units of sidereal (1×).
    public var raSiderealMultiple: Double
    /// Dec motor speed in units of sidereal (1×).
    public var decSiderealMultiple: Double

    public init(ra: GuideDirection?, dec: GuideDirection?, siderealMultiple: Double) {
        self.init(
            ra: ra,
            dec: dec,
            raSiderealMultiple: siderealMultiple,
            decSiderealMultiple: siderealMultiple
        )
    }

    public init(
        ra: GuideDirection?,
        dec: GuideDirection?,
        raSiderealMultiple: Double,
        decSiderealMultiple: Double
    ) {
        self.ra = ra
        self.dec = dec
        self.raSiderealMultiple = ra == nil ? 0 : max(raSiderealMultiple, 0)
        self.decSiderealMultiple = dec == nil ? 0 : max(decSiderealMultiple, 0)
    }

    public var siderealMultiple: Double {
        max(raSiderealMultiple, decSiderealMultiple)
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
