import CollimationCore
import CollimationUI
import Foundation

func tiltReportFixture(xSlope: Double = 200, ySlope: Double = -300, radial: Double = 400) -> TiltMeasurementReport {
    let camera = CameraDescriptor(id: "tilt-test", name: "Tilt test camera", sensorWidth: 1024,
        sensorHeight: 1024, pixelSizeMicrons: 3.76, isSimulator: false)
    var report = TiltMeasurementReport(camera: camera, focuserSerial: "TEST", mountProtocol: "Test",
        autofocusStep: 500, stackCount: 3, gain: 0)
    for i in report.points.indices {
        let point = report.points[i]
        let u = (point.targetX - 511.5) / 409.6, v = (point.targetY - 511.5) / 409.6
        let position = Int((30000 + xSlope * u + ySlope * v + radial * (u * u + v * v)).rounded())
        report.points[i].focus = AutofocusResult(position: position, hfr: 2, sensorX: point.targetX, sensorY: point.targetY,
            exposureMicroseconds: 10000, samples: (0..<9).map { AutofocusSample(position: position + ($0 - 4) * 500, hfr: 2 + Double(abs($0 - 4))) })
        report.points[i].imageCaptured = true
    }
    report.commonFocus = report.points[0].focus!.position
    report.commonExposureMicroseconds = 10000
    report.status = .complete
    return report
}

func testTiltFit() throws {
    for (a, b, k) in [(0.0, 0.0, 0.0), (200, 0, 0), (0, -300, 0), (200, -300, 400), (0, 0, 400)] {
        let report = tiltReportFixture(xSlope: a, ySlope: b, radial: k)
        guard let fit = report.fit else { throw UIModelExpectation(description: "fit missing") }
        try expectUI(abs(fit.xSlope - a) < 1 && abs(fit.ySlope - b) < 1 && abs(fit.radialOffset - k) < 1,
                     "tilt and radial components recovered")
        try expectUI(fit.residualRMS < 1, "fit residual reflects rounding only")
        if a == 0 && b == 0 { try expectUI(fit.directionDegrees == nil, "zero tilt has no direction") }
    }
    var partial = tiltReportFixture()
    partial.points[1].focus = nil; partial.points[2].focus = nil
    try expectUI(partial.fit != nil, "six outer points remain eligible")
    partial.points[3].focus = nil
    try expectUI(partial.fit == nil, "five outer points cannot produce a tilt estimate")
    partial = tiltReportFixture(xSlope: 0, ySlope: 0, radial: 600)
    partial.points[1].focus = nil; partial.points[2].focus = nil
    try expectUI(partial.fit!.spread < 1, "uneven curved field does not become tilt")
    partial = tiltReportFixture()
    partial.points[0].focus = nil
    try expectUI(partial.fit == nil, "initial centre is mandatory")
    partial = tiltReportFixture()
    for i in partial.points.indices {
        let original = partial.points[i].focus!
        partial.points[i].focus = AutofocusResult(position: original.position, hfr: 2, sensorX: 511.5,
            sensorY: 511.5, exposureMicroseconds: 10000, samples: original.samples)
    }
    try expectUI(partial.fit == nil, "degenerate coordinates rejected")
}

func testTiltTIFFMetadata() throws {
    let pixels = Array(repeating: Float(1000), count: 768 * 768)
    var report = tiltReportFixture()
    report.points[2].focus = nil; report.points[2].imageCaptured = false; report.status = .partial
    report.points[2].focusError = "Échec — optical failure"
    let data = try MonoTIFF.encode(floats: pixels, width: 768, height: 768, imageDescription: report.encoded())
    let decoded = MonoTIFF.decodeTiltMetadata(data)
    try expectUI(decoded.warning == nil && decoded.report?.points[2].focusError == report.points[2].focusError,
                 "partial report and Unicode survive TIFF ASCII metadata")
    try expectUI(decoded.report?.fit != nil && decoded.report?.commonFocus == 30000, "report restores analysis")
    try expectUI(try MonoTIFF.decodeConstellation(data).pixels == pixels, "metadata preserves pixels")
    let legacy = try MonoTIFF.encode(floats: pixels, width: 768, height: 768)
    try expectUI(MonoTIFF.decodeTiltMetadata(legacy).report == nil && MonoTIFF.decodeTiltMetadata(legacy).warning == nil,
                 "legacy TIFF needs no metadata")
    let invalid = try MonoTIFF.encode(floats: pixels, width: 768, height: 768, imageDescription: Data("invalid JSON".utf8))
    try expectUI(MonoTIFF.decodeTiltMetadata(invalid).warning != nil, "malformed metadata produces warning")
    try expectUI(try MonoTIFF.decodeConstellation(invalid).width == 768, "invalid metadata leaves image readable")
    report.schemaVersion = 99
    let future = try MonoTIFF.encode(floats: pixels, width: 768, height: 768, imageDescription: report.encoded())
    try expectUI(MonoTIFF.decodeTiltMetadata(future).warning != nil, "unknown report version produces warning")
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("tilt-roundtrip-\(UUID()).tif")
    defer { try? FileManager.default.removeItem(at: url) }
    try data.write(to: url)
    let result = try ConstellationResult.load(from: url)
    try expectUI(result.tiltReport?.validOuterCount == 7 && result.histogram.sampleCount == 8 * 256 * 256,
                 "loaded report excludes missing image from histogram")
    let scene = ConstellationScene.primitives(state: ConstellationRenderState(result: result), size: SIMD2(800, 700))
    try expectUI(!scene.isEmpty && TiltText.summary(result.tiltReport!).contains(where: { $0.contains("partial") }), "shared results describe partial fit")
    var modern = tiltReportFixture()
    modern.schemaVersion = 2
    modern.autofocusSettings = AutofocusSettings(step: 500)
    let focus = modern.points[0].focus!
    let samples = focus.samples.map { AutofocusSample(position: $0.position, hfr: hypot(2, Double($0.position - focus.position) / 1000)) }
    let fit = try AutofocusFitter.fit(samples, settings: modern.autofocusSettings!)
    var diagnostics = AutofocusDiagnostics(settings: modern.autofocusSettings!)
    diagnostics.fit = fit; diagnostics.curves = [samples]
    diagnostics.verification = (0..<3).map { _ in AutofocusSample(position: focus.position, hfr: 2.01) }
    diagnostics.recovery = [AutofocusSample(position: focus.position - 250, hfr: 2.1)]
    modern.points[0].focus = AutofocusResult(position: focus.position, hfr: 2.01, sensorX: focus.sensorX,
        sensorY: focus.sensorY, exposureMicroseconds: 10000, samples: samples, diagnostics: diagnostics)
    let decodedModern = try TiltMeasurementReport.decode(modern.encoded())
    try expectUI(decodedModern.autofocusSettings == modern.autofocusSettings && decodedModern.points[0].focus?.diagnostics == diagnostics,
                 "new settings, fit uncertainty and separate recovery samples round trip")
    try expectUI(decodedModern.points[0].focus!.samples.count == 9 && abs(decodedModern.fit!.xSlope - modern.fit!.xSlope) < 1e-9,
                 "metadata does not change plane weighting or primary sample validation")
    try expectUI(TiltText.point(decodedModern.points[0], reference: modern.commonFocus).contains("uncertainty"), "tilt presents uncertainty")
    var previousDiagnostics = modern
    previousDiagnostics.points[0].focus!.diagnostics!.verificationPolicy = nil
    let previousDecoded = try TiltMeasurementReport.decode(previousDiagnostics.encoded())
    try expectUI(previousDecoded.points[0].focus?.diagnostics?.verificationPolicy == nil
        && previousDecoded.points[0].focus?.diagnostics?.fit == fit,
        "reports without the optional verification policy remain readable")
    var diagnosticOnly = modern
    diagnosticOnly.points[0].focus = AutofocusResult(position: focus.position, hfr: nil, sensorX: focus.sensorX,
        sensorY: focus.sensorY, exposureMicroseconds: 10000, samples: samples, diagnostics: diagnostics)
    let decodedWithoutHFR = try TiltMeasurementReport.decode(diagnosticOnly.encoded())
    try expectUI(decodedWithoutHFR.points[0].focus!.hfr == nil && decodedWithoutHFR.validOuterCount == modern.validOuterCount
        && decodedWithoutHFR.fit == modern.fit,
        "missing diagnostic final HFR neither excludes a tilt focus reading nor changes plane fitting")
    diagnosticOnly.points[0].focus = AutofocusResult(position: focus.position, hfr: 20, sensorX: focus.sensorX,
        sensorY: focus.sensorY, exposureMicroseconds: 10000, samples: samples, diagnostics: diagnostics)
    let decodedHighHFR = try TiltMeasurementReport.decode(diagnosticOnly.encoded())
    try expectUI(decodedHighHFR.points[0].focus!.hfr == 20 && decodedHighHFR.fit == modern.fit,
                 "high final HFR is recorded without invalidating a tilt reading")
    let detailed = samples.map { sample in
        var point = sample
        var readings: [AutofocusReading] = []
        for i in 0..<24 {
            let instant = Date(timeIntervalSince1970: 1_700_000_000.0 + Double(i) / 30.0)
            let value: Double? = i < 19 ? nil : sample.hfr
            let rejection: String?
            if i < 3 { rejection = "startup discard" }
            else if i < 19 { rejection = "invalid HFR" }
            else { rejection = nil }
            readings.append(AutofocusReading(timestamp: instant, hfr: value, rejection: rejection))
        }
        point.readings = readings
        point.rejectedFrames = 16
        return point
    }
    modern.points[0].focus!.diagnostics!.curves = Array(repeating: detailed, count: 24)
    let largeMetadata = try modern.encoded()
    try expectUI(largeMetadata.count > 256 * 1024, "fixture exercises diagnostics above the old metadata limit")
    let detailedTIFF = try MonoTIFF.encode(floats: pixels, width: 768, height: 768, imageDescription: largeMetadata)
    try expectUI(MonoTIFF.decodeTiltMetadata(detailedTIFF).report?.points[0].focus?.diagnostics?.curves.count == 24,
                 "detailed diagnostic TIFF round trip uses bounded expanded metadata capacity")
    try expectUI(try MonoTIFF.decodeConstellation(detailedTIFF).width == 768, "expanded metadata preserves image reading")
    modern.points[0].focus!.diagnostics!.fit = nil
    modern.points[0].focus!.diagnostics!.verification = Array(repeating: AutofocusSample(position: 1, hfr: 2), count: 31)
    do { _ = try TiltMeasurementReport.decode(modern.encoded()); throw UIModelExpectation(description: "unbounded verification metadata accepted") }
    catch is CameraError { }
}

private final class TiltTestFocuser: FocuserDevice, @unchecked Sendable {
    private let lock = NSLock()
    private var value = FocuserSnapshot(serialNumber: "TILT-TEST", position: 30000, maxPosition: 100000, isMoving: false)
    private var moveHistory: [Int] = []
    private var observedPositions: [MountCentroidSample] = []
    private let observeMove: (@Sendable () -> MountCentroidSample)?
    private var stops = 0
    var fault = false
    init(observeMove: (@Sendable () -> MountCentroidSample)? = nil) { self.observeMove = observeMove }
    var position: Int { lock.withLock { value.position } }
    var moves: [Int] { lock.withLock { moveHistory } }
    var mountPositions: [MountCentroidSample] { lock.withLock { observedPositions } }
    var stopCount: Int { lock.withLock { stops } }
    func connect(path: String) throws -> FocuserSnapshot { lock.withLock { value } }
    func snapshot() throws -> FocuserSnapshot { lock.withLock { value } }
    func move(to position: Int) throws -> FocuserSnapshot {
        try lock.withLock {
            if fault { throw FocuserError.timeout }
            if let observeMove { observedPositions.append(observeMove()) }
            moveHistory.append(position); value.position = position; return value
        }
    }
    func stop() throws -> FocuserSnapshot { lock.withLock { stops += 1; return value } }
    func disconnect() { }
}

private final class TiltTestMount: MountDevice, @unchecked Sendable {
    private let lock = NSLock()
    private var connected = false
    private var x = 511.5, y = 511.5
    private var nudge: SlewNudge?
    private var updated = Date()
    private var starts = 0
    private var halts = 0
    init(x: Double = 511.5, y: Double = 511.5) { self.x = x; self.y = y }
    var isConnected: Bool { lock.withLock { connected } }
    let protocolName = "Test mount"
    let calibrationRAMultiple = 8.0
    var startCount: Int { lock.withLock { starts } }
    var haltCount: Int { lock.withLock { halts } }
    private func integrate() {
        let milliseconds = Date().timeIntervalSince(updated) * 1000
        if let nudge {
            if let ra = nudge.ra { x += (ra == .east ? 1 : -1) * 0.05 * nudge.raSiderealMultiple * milliseconds }
            if let dec = nudge.dec { y += (dec == .north ? 1 : -1) * 0.05 * nudge.decSiderealMultiple * milliseconds }
        }
        updated = Date()
    }
    func position() -> (Double, Double) { lock.withLock { integrate(); return (x, y) } }
    func connect(path: String, baud: Int) throws { lock.withLock { connected = true } }
    func disconnect() { lock.withLock { integrate(); nudge = nil; connected = false } }
    func haltMotions() { lock.withLock { integrate(); nudge = nil; halts += 1 } }
    func applyNudge(_ next: SlewNudge?) async throws {
        try Task.checkCancellation()
        lock.withLock { integrate(); nudge = next; if next != nil { starts += 1 } }
    }
    func pulse(_ direction: GuideDirection, milliseconds: Int) async throws { }
}

private final class TiltTestCamera: CameraDevice, @unchecked Sendable {
    let descriptor = CameraDescriptor(id: "tilt-test", name: "Tilt test camera", sensorWidth: 1024,
        sensorHeight: 1024, pixelSizeMicrons: 3.76, isSimulator: false)
    let supportedBins = [1]
    private let lock = NSLock()
    private var control = CameraControls(exposureMicroseconds: 10000)
    private var roi = ROI(x: 0, y: 0, width: 1024, height: 1024)
    private var stopped = false
    private let mount: TiltTestMount
    private let focuser: TiltTestFocuser
    private let frameDelay: Int
    private var flatNorth = false
    init(mount: TiltTestMount, focuser: TiltTestFocuser, frameDelay: Int = 12) {
        self.mount = mount; self.focuser = focuser; self.frameDelay = frameDelay
    }
    var controls: CameraControls { lock.withLock { control } }
    var currentROI: ROI { lock.withLock { roi } }
    func makeNorthFlat() { lock.withLock { flatNorth = true } }
    func open() throws { lock.withLock { stopped = false } }
    func close() { lock.withLock { stopped = true } }
    func cancelGrab() { close() }
    func applyExposure(_ value: Int) throws { lock.withLock { control.exposureMicroseconds = value } }
    func applyGain(_ value: Int) throws { lock.withLock { control.gain = value } }
    func applyROI(_ value: ROI) throws { lock.withLock { roi = value } }
    func startVideo() throws { }
    func stopVideo() { }
    func grabFrame(timeoutMs: Int) throws -> Frame {
        preciseSleep(milliseconds: frameDelay)
        let config = lock.withLock { (self.roi, stopped, control.exposureMicroseconds, flatNorth) }
        if config.1 { throw CameraError.timeout }
        let (sx, sy) = mount.position()
        let u = (sx - 511.5) / 409.6, v = (sy - 511.5) / 409.6
        let best = 30000 + 200 * u - 300 * v + 400 * (u * u + v * v)
        let isNorth = abs(u) < 0.12 && v < -0.8
        let sigma = config.3 && isNorth ? 3.0 : sqrt(4 + pow((Double(focuser.position) - best) / 450, 2))
        let peak = 30000 * Double(config.2) / 10000
        let roi = config.0
        var pixels = Array(repeating: UInt16(1000), count: roi.width * roi.height)
        // The pipeline reports sensor pixel centres (index + 0.5). Evaluate
        // the Gaussian at those centres so mount.position() is ground truth
        // in the same coordinate system, including at the 32-pixel stop bound.
        let cx = sx - Double(roi.x) - 0.5, cy = sy - Double(roi.y) - 0.5
        let reach = Int(ceil(sigma * 6))
        let x0 = max(0, Int(cx) - reach), x1 = min(roi.width - 1, Int(cx) + reach)
        let y0 = max(0, Int(cy) - reach), y1 = min(roi.height - 1, Int(cy) + reach)
        if x0 <= x1 && y0 <= y1 {
            for y in y0...y1 { for x in x0...x1 {
                let d2 = pow(Double(x) - cx, 2) + pow(Double(y) - cy, 2)
                pixels[y * roi.width + x] = UInt16(min(65535, 1000 + peak * exp(-d2 / (2 * sigma * sigma))))
            } }
        }
        return Frame(width: roi.width, height: roi.height, pixels: pixels, roi: roi)
    }
}

@MainActor
private func waitForTilt(_ condition: () -> Bool, timeout: Double = 120) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else { throw UIModelExpectation(description: "tilt fixture timed out") }
        try await Task.sleep(for: .milliseconds(20))
    }
}

@MainActor
func testTiltEngineSequence() async throws {
    for partial in [false, true] {
        let mount = TiltTestMount(), focus = TiltTestFocuser()
        let camera = TiltTestCamera(mount: mount, focuser: focus)
        if partial { camera.makeNorthFlat() }
        let suite = "collimation-camera.tests.tilt.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let calibration = GuideCalibration(eastRate: SIMD2(0.05, 0), northRate: SIMD2(0, 0.05), sampleDurationMs: 3000)
        let engine = CollimationEngine(defaults: defaults, serialPortPaths: { ["COM4", "COM10"] },
            focuser: focus, mount: mount, cameraFactory: { _ in camera },
            autofocusTiming: AutofocusTiming(motionTimeout: 1, frameTimeout: 2, settleSeconds: 0.01, verificationInterval: 0.01),
            initialCalibration: calibration, mountSettleMilliseconds: 30)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("tilt-engine-\(UUID()).tif")
        defer { engine.disconnect(); engine.disconnectFocuser(); engine.disconnectMount(); engine.shutdown(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: output) }
        engine.autofocusStepSize = 500; engine.stackFrameCount = 3
        engine.selectedFocuserPort = "COM4"; engine.selectedSerialPort = "COM10"
        engine.connect(); engine.connectFocuser(); engine.connectMount()
        try await waitForTilt { engine.canMeasureTilt }
        let initialStar = engine.tracking.centroidOnSensor!
        let (initialX, initialY) = mount.position()
        try expectUI(hypot(initialStar.x - initialX, initialStar.y - initialY) < 0.05,
                     "tilt fixture and pipeline share sensor pixel-centre coordinates")
        engine.startTiltMeasurement(to: output)
        engine.autofocusStepSize = 111; engine.autofocusTakeUpSteps = 222
        try expectUI(!engine.canAutofocus && !engine.canMoveFocuser && !engine.canAdjustCamera && !engine.canSaveStacked && !engine.canSelectFilter,
                     "whole sequence owns competing controls")
        try expectUI(engine.canConnectMount && engine.canConnectFocuser && engine.canStopFocuser, "escape hatches remain available")
        try await waitForTilt { !engine.isMeasuringTilt }
        guard let report = engine.tiltReport else { throw UIModelExpectation(description: "missing report") }
        try expectUI(report.status == (partial ? .partial : .complete), "sequence completes: \(report.warning ?? engine.errorMessage ?? "unknown")")
        try expectUI(report.validOuterCount == (partial ? 7 : 8), "all usable positions recorded")
        try expectUI(report.autofocusSettings?.step == 500 && report.autofocusSettings?.takeUp == 4000
            && report.points.compactMap(\.focus).allSatisfy { $0.diagnostics?.settings.step == 500 && $0.diagnostics?.settings.takeUp == 4000 },
            "whole tilt run uses its original autofocus settings")
        let focusMoves = focus.moves
        for i in 1..<(focusMoves.count - 1) where focusMoves[i] < focusMoves[i - 1] {
            try expectUI(focusMoves[i + 1] - focusMoves[i] == 4000,
                         "tilt restores common focus and all reversed approaches with full take-up")
        }
        try expectUI(report.points.allSatisfy(\.imageCaptured), "all common-focus images captured, including failed north curve")
        try expectUI(report.points.map(\.label) == ["C", "N", "NE", "E", "SE", "S", "SW", "W", "NW"], "constellation order retained")
        try expectUI(abs(report.fit!.xSlope - 200) < 40 && abs(report.fit!.ySlope + 300) < 40, "optical sequence recovers tilt")
        try expectUI(report.finalCenter != nil && focus.position == report.finalCenter!.position, "finishes at repeated centre optimum")
        let (x, y) = mount.position()
        try expectUI(hypot(x - 511.5, y - 511.5) <= MountGuide.doneRadiusSensorPixels, "star returned to centre: \(x), \(y)")
        let reopened = try ConstellationResult.load(from: output)
        try expectUI(reopened.tiltReport?.validOuterCount == report.validOuterCount, "saved TIFF restores results")
        try expectUI(engine.canMoveFocuser && !engine.isAutofocusing && !engine.isMountBusy, "all interlocks released")
    }
}

@MainActor
func testTiltCancellationAndFaults() async throws {
    for mode in ["before", "moving", "focus", "disconnect", "fault", "write"] {
        let mount = TiltTestMount(), focus = TiltTestFocuser()
        let camera = TiltTestCamera(mount: mount, focuser: focus)
        let suite = "collimation-camera.tests.tilt-cancel.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let engine = CollimationEngine(defaults: defaults, serialPortPaths: { ["COM4", "COM10"] }, focuser: focus, mount: mount,
            cameraFactory: { _ in camera }, autofocusTiming: AutofocusTiming(motionTimeout: 1, frameTimeout: 2, settleSeconds: 0.01, verificationInterval: 0.01),
            initialCalibration: GuideCalibration(eastRate: SIMD2(0.05, 0), northRate: SIMD2(0, 0.05), sampleDurationMs: 3000), mountSettleMilliseconds: 30)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("tilt-cancel-\(UUID()).tif")
        defer {
            if let saved = engine.tiltSavedURL { try? FileManager.default.removeItem(at: saved) }
            engine.disconnect(); engine.disconnectFocuser(); engine.disconnectMount(); engine.shutdown(); defaults.removePersistentDomain(forName: suite)
        }
        engine.selectedFocuserPort = "COM4"; engine.selectedSerialPort = "COM10"
        engine.autofocusStepSize = 500; engine.stackFrameCount = 3
        engine.connect(); engine.connectFocuser(); engine.connectMount()
        try await waitForTilt { engine.canMeasureTilt }
        if mode == "fault" { focus.fault = true }
        let destination = mode == "write" ? FileManager.default.temporaryDirectory.appendingPathComponent("absent-\(UUID())/result.tif") : output
        engine.startTiltMeasurement(to: destination)
        if mode == "before" { engine.cancelTiltMeasurement() }
        else if mode == "moving" {
            try await waitForTilt { engine.tiltProgress.index == 2 && mount.startCount > 0 }
            engine.cancelTiltMeasurement()
        } else if mode == "focus" {
            try await waitForTilt { engine.autofocusSamples.count >= 2 }
            engine.stopFocuser()
        } else if mode == "disconnect" {
            try await waitForTilt { engine.isAutofocusing }
            engine.disconnectMount()
        }
        try await waitForTilt { !engine.isMeasuringTilt }
        let moves = focus.moves.count, nudges = mount.startCount
        try await Task.sleep(for: .milliseconds(150))
        try expectUI(focus.moves.count == moves && mount.startCount == nudges, "no stale motions after termination")
        if mode == "fault" { try expectUI(engine.tiltReport?.status == .failed && engine.errorMessage != nil, "motor communication fault aborts") }
        else if mode == "write" { try expectUI(engine.tiltReport?.fit != nil && engine.tiltSavedURL == nil && engine.errorMessage != nil, "write failure retains in-memory result") }
        else { try expectUI(engine.tiltReport?.status == .cancelled, "cancel/disconnect persists cancelled status") }
        if mode == "before" { try expectUI(moves == 0 && nudges == 0, "immediate cancellation has no motion") }
        try expectUI(!engine.isAutofocusing && !engine.isMountBusy, "termination releases busy state")
        try expectUI(mount.haltCount > 0 && engine.focuserSnapshot?.isMoving == false,
                     "both devices idle after \(mode)")
        if mode != "write" {
            try expectUI(focus.stopCount > 0, "abort sends focuser Stop after \(mode)")
        }
    }
    try expectUI(!CollimationEngine.isRecoverableTiltOpticalError(AutofocusError.motionTimeout) &&
                 !CollimationEngine.isRecoverableTiltOpticalError(AutofocusError.positionMismatch), "motor failures cannot be skipped")
}

@MainActor
func testFocusConstellationEngine() async throws {
    let mount = TiltTestMount(x: 600, y: 560)
    let focus = TiltTestFocuser(observeMove: {
        let (x, y) = mount.position()
        return MountCentroidSample(SIMD2(x, y))
    })
    let camera = TiltTestCamera(mount: mount, focuser: focus, frameDelay: 1)
    let suite = "collimation-camera.tests.focus-constellation.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    let engine = CollimationEngine(defaults: defaults, serialPortPaths: { ["COM4", "COM10"] },
        focuser: focus, mount: mount, cameraFactory: { _ in camera },
        autofocusTiming: AutofocusTiming(motionTimeout: 1, frameTimeout: 2, settleSeconds: 0.01, verificationInterval: 0.01),
        initialCalibration: GuideCalibration(eastRate: SIMD2(0.05, 0), northRate: SIMD2(0, 0.05), sampleDurationMs: 3000),
        mountSettleMilliseconds: 30)
    let output = FileManager.default.temporaryDirectory.appendingPathComponent("focus-sequence-\(UUID()).tif")
    defer {
        engine.disconnect(); engine.disconnectFocuser(); engine.disconnectMount(); engine.shutdown()
        defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: output)
    }
    engine.selectedFocuserPort = "COM4"; engine.selectedSerialPort = "COM10"
    engine.autofocusStepSize = 500; engine.stackFrameCount = 10; engine.recordConstellationFocusSweep = true
    engine.connect(); engine.connectFocuser(); engine.connectMount()
    try await waitForTilt { engine.canRecordConstellation }
    engine.saveConstellation(to: output)
    engine.autofocusStepSize = 111; engine.autofocusTakeUpSteps = 222
    try expectUI(!engine.canAdjustCamera && !engine.canMoveFocuser && !engine.canAutofocus && !engine.canSelectFilter
        && !engine.canSelectStackCount && !engine.canSelectConstellationFocusSweep && !engine.canRecordConstellation,
        "whole sweep owns competing controls")
    try expectUI(engine.canConnectMount && engine.canConnectFocuser && engine.canStopFocuser, "disconnect and Stop remain available")
    try await waitForTilt({ !engine.isCapturingFocusConstellation }, timeout: 360)
    guard let result = engine.constellationResult, let recording = result.focusRecording else {
        throw UIModelExpectation(description: "focus capture failed: \(engine.errorMessage ?? engine.statusText)")
    }
    let metadata = recording.metadata
    try expectUI(metadata.frameCount == 10 && camera.controls.exposureMicroseconds == metadata.exposureMicroseconds
        && camera.controls.gain == metadata.gain, "all layers use the selected stack count and centre autofocus exposure/gain")
    try expectUI(engine.focusConstellationProgress.recordedImages == 9 * 33 && result.focusIndex == 16, "complete nine-star sweep opens best focus")
    try expectUI(metadata.takeUp == 4000 && metadata.autofocus?.diagnostics?.settings.step == 500,
                 "autofocus and backlash settings frozen at start")
    try expectUI(abs(metadata.bestFocus - 30000) < 70, "centre star determines shared reference")
    let moves = focus.moves, mountPositions = focus.mountPositions
    let plan = try FocusConstellationPlan(bestFocus: metadata.bestFocus, maximum: metadata.maximum, takeUp: metadata.takeUp)
    guard let first = moves.firstIndex(of: metadata.bestFocus - 8000) else {
        throw UIModelExpectation(description: "missing first sweep preload")
    }
    let perStar = [metadata.bestFocus - 8000] + plan.positions + [metadata.bestFocus - 4000, metadata.bestFocus]
    try expectUI(Array(moves[first...]) == Array(repeating: perStar, count: 9).flatMap { $0 },
                 "mount outer loop, exact 33-position inner loop, full backlash at every reversal")
    for star in metadata.targets.indices {
        let target = metadata.targets[star]
        for i in (first + star * perStar.count)..<(first + (star + 1) * perStar.count) {
            let point = mountPositions[i]
            try expectUI(hypot(point.x - target.x, point.y - target.y) <= MountGuide.doneRadiusSensorPixels + 0.2,
                         "mount remains at the same field position throughout each focus sweep")
        }
    }
    try expectUI(mountPositions.prefix(first).allSatisfy { hypot($0.x - 511.5, $0.y - 511.5) <= MountGuide.doneRadiusSensorPixels + 0.2 },
                 "star centred before the first autofocus move")
    let (x, y) = mount.position()
    try expectUI(hypot(x - 511.5, y - 511.5) <= MountGuide.doneRadiusSensorPixels && focus.position == metadata.bestFocus,
                 "completed capture restores centre star and centre best focus")
    try expectUI(engine.canMoveFocuser && !engine.isAutofocusing && !engine.isMountBusy && !engine.isStacking, "completion releases interlocks")
    for index in [0, 16, 32] {
        let layer = try recording.loadLayer(index: index)
        try expectUI(layer.tiles.count == 9 && layer.tiles.allSatisfy { $0.centerDetected }, "recorded focus layer has all stars")
    }
}

@MainActor
func testFocusConstellationCancellation() async throws {
    for mode in ["immediate", "stop", "disconnect", "fault"] {
        let mount = TiltTestMount(), focus = TiltTestFocuser()
        let camera = TiltTestCamera(mount: mount, focuser: focus, frameDelay: 1)
        let suite = "collimation-camera.tests.focus-cancel.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let engine = CollimationEngine(defaults: defaults, serialPortPaths: { ["COM4", "COM10"] }, focuser: focus, mount: mount,
            cameraFactory: { _ in camera }, autofocusTiming: AutofocusTiming(motionTimeout: 1, frameTimeout: 2, settleSeconds: 0.01, verificationInterval: 0.01),
            initialCalibration: GuideCalibration(eastRate: SIMD2(0.05, 0), northRate: SIMD2(0, 0.05), sampleDurationMs: 3000), mountSettleMilliseconds: 30)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("focus-cancel-\(UUID()).tif")
        let original = Data("previous capture".utf8)
        try original.write(to: output)
        defer {
            engine.disconnect(); engine.disconnectFocuser(); engine.disconnectMount(); engine.shutdown()
            defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: output)
        }
        engine.selectedFocuserPort = "COM4"; engine.selectedSerialPort = "COM10"
        engine.autofocusStepSize = 500; engine.stackFrameCount = 10; engine.recordConstellationFocusSweep = true
        engine.connect(); engine.connectFocuser(); engine.connectMount()
        try await waitForTilt { engine.canRecordConstellation }
        if mode == "fault" { focus.fault = true }
        engine.saveConstellation(to: output, layout: .rectangularGrid)
        if mode == "immediate" { engine.cancelFocusConstellation() }
        else if mode == "stop" || mode == "disconnect" {
            try await waitForTilt { engine.focusConstellationProgress.recordedImages >= 1 || !engine.isCapturingFocusConstellation }
            try expectUI(engine.focusConstellationProgress.recordedImages >= 1, "cancellation exercises recorded sweep: \(engine.errorMessage ?? engine.statusText)")
            if mode == "stop" { engine.stopFocuser() } else { engine.disconnectMount() }
        }
        try await waitForTilt { !engine.isCapturingFocusConstellation }
        let moves = focus.moves.count, nudges = mount.startCount
        try await Task.sleep(for: .milliseconds(150))
        try expectUI(focus.moves.count == moves && mount.startCount == nudges, "no stale motions after sweep termination")
        try expectUI(try Data(contentsOf: output) == original, "cancel/fault preserves previous recording")
        try expectUI(!engine.isStacking && !engine.isMountBusy && !engine.isAutofocusing && mount.haltCount > 0 && focus.stopCount > 0,
                     "termination stops both motors and releases controls")
        if mode == "immediate" { try expectUI(moves == 0 && nudges == 0, "cancel before start has no motion") }
        if mode == "fault" { try expectUI(engine.errorMessage != nil, "motor error reported") }
        else { try expectUI(engine.mountStatus == "Focus constellation cancelled", "cancellation reported after live tracking resumes") }
    }
}
