import Foundation

public enum TiltPhase: String, Codable, Sendable {
    case idle, moving, focusing, restoringFocus, stacking, checkingDrift, saving, complete, cancelled, failed
}

public struct TiltProgress: Equatable, Sendable {
    public var phase: TiltPhase = .idle
    public var index = 0
    public var label = ""
    public var collected = 0
    public var target = 0
    public init() {}
}

public struct TiltPointResult: Equatable, Sendable, Codable {
    public var label: String
    public var row: Int
    public var column: Int
    public var targetX: Double
    public var targetY: Double
    public var startedAt: Date?
    public var finishedAt: Date?
    public var focus: AutofocusResult?
    public var focusError: String?
    public var imageCaptured = false
    public var imageError: String?
    public init(_ position: ConstellationPosition) {
        label = position.label; row = position.row; column = position.column
        targetX = position.sensorPoint.x; targetY = position.sensorPoint.y
    }
}

public struct TiltFit: Equatable, Sendable, Codable {
    public let intercept: Double
    /// Motor steps per constellation radius, X right and Y down.
    public let xSlope: Double
    public let ySlope: Double
    public let radialOffset: Double
    public let residualRMS: Double
    public let spread: Double
    /// Clockwise from sensor right, towards increasing optimal focus.
    public var directionDegrees: Double? {
        guard spread > 1e-6 else { return nil }
        let angle = atan2(ySlope, xSlope) * 180 / .pi
        return angle < 0 ? angle + 360 : angle
    }
}

public enum TiltRunStatus: String, Codable, Sendable { case running, complete, partial, cancelled, failed }

public struct TiltMeasurementReport: Equatable, Sendable, Codable {
    public var schemaVersion = 1
    public var id = UUID()
    public var startedAt = Date()
    public var finishedAt: Date?
    public var status: TiltRunStatus = .running
    public var cameraID: String
    public var cameraName: String
    public var sensorWidth: Int
    public var sensorHeight: Int
    public var focuserSerial: String
    public var mountProtocol: String
    public var autofocusStep: Int
    public var stackCount: Int
    public var gain: Int
    public var filterPosition: Int?
    public var commonFocus: Int?
    public var commonExposureMicroseconds: Int?
    public var points: [TiltPointResult]
    public var finalCenter: AutofocusResult?
    public var warning: String?
    public var fit: TiltFit? { TiltAnalysis.fit(self) }
    public var drift: Int? {
        guard let first = commonFocus, let last = finalCenter else { return nil }
        return last.position - first
    }
    public var validOuterCount: Int { points.filter { $0.label != "C" && $0.focus != nil }.count }

    public init(camera: CameraDescriptor, focuserSerial: String, mountProtocol: String,
                autofocusStep: Int, stackCount: Int, gain: Int, filterPosition: Int? = nil) {
        cameraID = camera.id; cameraName = camera.name
        sensorWidth = camera.sensorWidth; sensorHeight = camera.sensorHeight
        self.focuserSerial = focuserSerial; self.mountProtocol = mountProtocol
        self.autofocusStep = autofocusStep; self.stackCount = stackCount
        self.gain = gain; self.filterPosition = filterPosition
        points = ConstellationCapture.positions(sensorWidth: sensorWidth, sensorHeight: sensorHeight).map(TiltPointResult.init)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 256 * 1024 else { throw CameraError.unsupported("Tilt metadata is too large.") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(Self.self, from: data)
        guard report.schemaVersion == 1, report.sensorWidth > 0, report.sensorHeight > 0,
              report.sensorWidth <= 100000, report.sensorHeight <= 100000,
              report.autofocusStep > 0, report.stackCount > 0,
              report.points.count == 9 else { throw CameraError.unsupported("Unsupported tilt metadata.") }
        let positions = ConstellationCapture.positions(sensorWidth: report.sensorWidth, sensorHeight: report.sensorHeight)
        for (point, expected) in zip(report.points, positions) {
            guard point.label == expected.label, point.row == expected.row, point.column == expected.column,
                  point.targetX.isFinite, point.targetY.isFinite,
                  abs(point.targetX - expected.sensorPoint.x) < 0.01,
                  abs(point.targetY - expected.sensorPoint.y) < 0.01 else {
                throw CameraError.unsupported("Invalid tilt sampling positions.")
            }
            if let focus = point.focus { try validate(focus, width: report.sensorWidth, height: report.sensorHeight) }
        }
        if let final = report.finalCenter { try validate(final, width: report.sensorWidth, height: report.sensorHeight) }
        guard report.commonFocus == report.points.first?.focus?.position,
              report.commonExposureMicroseconds == report.points.first?.focus?.exposureMicroseconds else {
            throw CameraError.unsupported("Invalid tilt centre reference.")
        }
        return report
    }

    private static func validate(_ focus: AutofocusResult, width: Int, height: Int) throws {
        guard focus.position >= 0, focus.hfr.isFinite, focus.hfr > 0,
              focus.sensorX.isFinite, focus.sensorY.isFinite,
              focus.sensorX >= 0, focus.sensorX < Double(width), focus.sensorY >= 0, focus.sensorY < Double(height),
              focus.exposureMicroseconds > 0, focus.samples.count == AutofocusPlan.sampleCount,
              focus.samples.allSatisfy({ $0.position >= 0 && $0.hfr.isFinite && $0.hfr > 0 }) else {
            throw CameraError.unsupported("Invalid tilt focus measurement.")
        }
    }
}

public enum TiltAnalysis {
    /// A radial term prevents uneven ring coverage from turning field curvature
    /// into a false tilt. Reorthogonalised QR avoids squaring the condition number.
    public static func fit(_ report: TiltMeasurementReport) -> TiltFit? {
        guard report.points.first?.focus != nil, report.validOuterCount >= 6 else { return nil }
        let center = MountGuide.frameCenter(width: report.sensorWidth, height: report.sensorHeight)
        let radius = Double(report.sensorHeight) * ConstellationCapture.circleDiameterFraction / 2
        guard radius > 0, let reference = report.commonFocus else { return nil }
        let readings = report.points.compactMap(\.focus)
        let xy = readings.map { (($0.sensorX - center.x) / radius, ($0.sensorY - center.y) / radius) }
        let columns = [Array(repeating: 1.0, count: readings.count), xy.map { $0.0 },
                       xy.map { $0.1 }, xy.map { $0.0 * $0.0 + $0.1 * $0.1 }]
        let y = readings.map { Double($0.position - reference) }
        var q: [[Double]] = []
        var r = Array(repeating: Array(repeating: 0.0, count: 4), count: 4)
        for j in 0..<4 {
            var v = columns[j]
            for _ in 0..<2 {
                for i in 0..<j {
                    let projection = zip(q[i], v).reduce(0.0) { $0 + $1.0 * $1.1 }
                    r[i][j] += projection
                    for k in v.indices { v[k] -= projection * q[i][k] }
                }
            }
            let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
            guard norm.isFinite, norm > 1e-8 else { return nil }
            r[j][j] = norm
            q.append(v.map { $0 / norm })
        }
        var coefficients = q.map { zip($0, y).reduce(0.0) { $0 + $1.0 * $1.1 } }
        for i in stride(from: 3, through: 0, by: -1) {
            for j in (i + 1)..<4 { coefficients[i] -= r[i][j] * coefficients[j] }
            coefficients[i] /= r[i][i]
        }
        guard coefficients.allSatisfy(\.isFinite) else { return nil }
        let residual = y.indices.reduce(0.0) { sum, i in
            let predicted = (0..<4).reduce(0.0) { $0 + columns[$1][i] * coefficients[$1] }
            return sum + pow(y[i] - predicted, 2)
        }
        let directional = report.points.map {
            coefficients[1] * ($0.targetX - center.x) / radius + coefficients[2] * ($0.targetY - center.y) / radius
        }
        return TiltFit(intercept: Double(reference) + coefficients[0], xSlope: coefficients[1], ySlope: coefficients[2],
                       radialOffset: coefficients[3], residualRMS: sqrt(residual / Double(y.count)),
                       spread: directional.max()! - directional.min()!)
    }
}
