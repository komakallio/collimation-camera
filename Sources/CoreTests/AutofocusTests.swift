import CollimationCore
import CollimationUI
import Foundation

private func focusFrame(sigma: Double = 3, centerX: Double = 63.5, peak: Double = 30000,
                        binning: Int = 1, timestamp: Date = Date()) -> Frame {
    let size = 128
    let pixels = (0..<(size * size)).map { i -> UInt16 in
        let x = Double(i % size) - centerX, y = Double(i / size) - 63.5
        let value = 1000 + peak * exp(-(x * x + y * y) / (2 * sigma * sigma))
        return UInt16(min(65535, value))
    }
    return Frame(width: size, height: size, pixels: pixels,
                 roi: ROI(x: 0, y: 0, width: size, height: size, binning: binning), timestamp: timestamp)
}

func testFocusMetric() throws {
    let estimator = FocusMetricEstimator()
    for sigma in [2.0, 4.0, 10.0] {
        let frame = focusFrame(sigma: sigma)
        let detection = StarDetector().detect(in: frame)!
        let metric = estimator.measure(frame: frame, detection: detection)
        try expectUI(metric != nil, "Gaussian is measurable")
        try expectUI(abs(metric!.hfr - sqrt(2 * log(2)) * sigma) < 0.4, "Gaussian HFR matches analytic radius")
    }
    let binned = focusFrame(binning: 2)
    let binnedMetric = estimator.measure(frame: binned, detection: StarDetector().detect(in: binned)!)!
    let native = focusFrame()
    let nativeMetric = estimator.measure(frame: native, detection: StarDetector().detect(in: native)!)!
    try expectUI(abs(binnedMetric.hfr - 2 * nativeMetric.hfr) < 0.001, "HFR uses sensor pixels")
    var crowdedPixels = native.pixels
    for y in 55...72 {
        for x in 88...104 {
            let r2 = pow(Double(x) - 96.5, 2) + pow(Double(y) - 63.5, 2)
            crowdedPixels[y * 128 + x] += UInt16(50000 * exp(-r2 / 2))
        }
    }
    let crowded = Frame(width: 128, height: 128, pixels: crowdedPixels, roi: native.roi)
    let crowdedMetric = estimator.measure(frame: crowded, detection: StarDetector().detect(in: crowded)!)
    try expectUI(crowdedMetric != nil && abs(crowdedMetric!.hfr - nativeMetric.hfr) < 0.01,
                 "a compact neighbour with a higher peak cannot replace the tracked blob")
    for frame in [focusFrame(centerX: 3), focusFrame(peak: 90000), focusFrame(peak: 80)] {
        let detection = StarDetector().detect(in: frame)
        try expectUI(detection.flatMap { estimator.measure(frame: frame, detection: $0) } == nil,
                     "edge, saturation or insufficient signal is rejected")
    }
    var rng = RNG(seed: 42)
    var renderer = DonutRenderer()
    renderer.scene.starPosition = SIMD2(64, 64)
    renderer.scene.outerRadius = 25
    renderer.scene.innerRadius = 12
    renderer.scene.noiseSigma = 20
    let donut = renderer.render(roi: ROI(x: 0, y: 0, width: 128, height: 128), jitter: .zero, rng: &rng)
    let metric = StarDetector().detect(in: donut).flatMap { estimator.measure(frame: donut, detection: $0) }
    try expectUI(metric != nil && metric!.hfr > 12 && metric!.hfr < 27, "defocused annulus has a usable HFR")
}

func testAutofocusPlan() throws {
    let plan = try AutofocusPlan(position: 319000, maximum: 731000, step: 1000)
    try expectUI(plan.positions == Array(stride(from: 315000, through: 323000, by: 1000)), "bounded nine-point scan")
    try expectUI(plan.preloadPosition == 314000, "preload stays below first measurement")
    for (position, maximum, step) in [(0, 731000, 1000), (731000, 731000, 1000),
                                     (319000, 731000, 0), (319000, 731000, -1),
                                     (319000, 731000, Int.max), (Int.max, Int.max, Int.max)] {
        do {
            _ = try AutofocusPlan(position: position, maximum: maximum, step: step)
            throw UIModelExpectation(description: "unsafe autofocus range accepted")
        } catch AutofocusError.invalidRange { }
    }
    let samples = plan.positions.map { AutofocusSample(position: $0, hfr: sqrt(4 + pow(Double($0 - 319350) / 700, 2))) }
    try expectUI(abs(try plan.solution(samples: samples) - 319350) <= 1, "quadratic recovers a sub-step minimum")
    try expectUI(AutofocusPlan.median([2, 2.1, 50, 1.9, 2]) == 2, "median rejects seeing outlier")
    let flat = plan.positions.map { AutofocusSample(position: $0, hfr: 2) }
    do { _ = try plan.solution(samples: flat); throw UIModelExpectation(description: "flat curve accepted") }
    catch AutofocusError.flatCurve { }
    let monotonic = plan.positions.enumerated().map { AutofocusSample(position: $0.element, hfr: Double($0.offset + 1)) }
    do { _ = try plan.solution(samples: monotonic); throw UIModelExpectation(description: "scan-edge minimum accepted") }
    catch AutofocusError.minimumNotBracketed { }
    let noisyFlat = plan.positions.enumerated().map { AutofocusSample(position: $0.element, hfr: $0.offset == 4 ? 1.99 : 2) }
    do { _ = try plan.solution(samples: noisyFlat); throw UIModelExpectation(description: "noise minimum accepted") }
    catch AutofocusError.flatCurve { }
    try AutofocusPlan.verify(hfr: 2.1, samples: samples)
    do { try AutofocusPlan.verify(hfr: 5, samples: samples); throw UIModelExpectation(description: "bad final focus accepted") }
    catch AutofocusError.verificationFailed { }
    let invalid = plan.positions.map { AutofocusSample(position: $0, hfr: .nan) }
    do { _ = try plan.solution(samples: invalid); throw UIModelExpectation(description: "NaN accepted") }
    catch AutofocusError.noStar { }
}

func testAutofocusExposurePolicy() throws {
    try expectUI(try AutofocusExposureControl.nextMicroseconds(current: 10000, peak: 65535) == 2000,
                 "clipped readings need a large backoff, not a proportional estimate")
    try expectUI(try AutofocusExposureControl.nextMicroseconds(current: 10000, peak: 32768) == 10000,
                 "half-scale exposure leaves headroom")
    try expectUI(try AutofocusExposureControl.nextMicroseconds(current: 10000, peak: 50000) < 7000,
                 "bright but unclipped readings also shorten exposure")
    try expectUI(try AutofocusExposureControl.nextMicroseconds(current: 10000, peak: 1000) == ExposureControl.maxMicroseconds,
                 "faint stars respect the camera maximum")
    try expectUI(try AutofocusExposureControl.nextMicroseconds(current: 100, peak: 60000) == ExposureControl.minMicroseconds,
                 "usable readings respect the camera minimum")
    do {
        _ = try AutofocusExposureControl.nextMicroseconds(current: 100, peak: 65535)
        throw UIModelExpectation(description: "minimum exposure saturation accepted")
    } catch AutofocusError.exposureLimit { }
}

private final class FocusTestFocuser: FocuserDevice, @unchecked Sendable {
    private let lock = NSLock()
    private var state = FocuserSnapshot(serialNumber: "ESATTO-AF-TEST", position: 12000, maxPosition: 440000, isMoving: false)
    private var history: [Int] = []
    private var stops = 0
    private var stuck = false
    private var mismatch = false
    private var failed = false
    private var moveGate: DispatchSemaphore?
    let moveEntered = DispatchSemaphore(value: 0)
    init(position: Int = 12000) { state.position = position }
    var position: Int { lock.withLock { state.position } }
    var moves: [Int] { lock.withLock { history } }
    var stopCount: Int { lock.withLock { stops } }
    func configure(stuck: Bool = false, mismatch: Bool = false, failed: Bool = false, gate: DispatchSemaphore? = nil) {
        lock.withLock { self.stuck = stuck; self.mismatch = mismatch; self.failed = failed; moveGate = gate }
    }
    func connect(path: String) throws -> FocuserSnapshot { lock.withLock { state } }
    func snapshot() throws -> FocuserSnapshot {
        try lock.withLock {
            if failed && !history.isEmpty { throw FocuserError.timeout }
            state.isMoving = stuck && !history.isEmpty
            return state
        }
    }
    func move(to position: Int) throws -> FocuserSnapshot {
        let gate = lock.withLock { let value = moveGate; moveGate = nil; return value }
        moveEntered.signal()
        if let gate { _ = gate.wait(timeout: .now() + 3) }
        return lock.withLock {
            history.append(position)
            state.position = mismatch ? position - 1 : position
            state.isMoving = true
            return state
        }
    }
    func stop() throws -> FocuserSnapshot { lock.withLock { stops += 1; state.isMoving = false; return state } }
    func disconnect() { lock.withLock { stops += 1; state.isMoving = false } }
}

private final class FocusTestCamera: CameraDevice, @unchecked Sendable {
    let descriptor = CameraDescriptor(id: "focus-test", name: "Focus test camera", sensorWidth: 128,
                                      sensorHeight: 128, pixelSizeMicrons: 3.76, isSimulator: false)
    private var cameraControls = CameraControls(exposureMicroseconds: 10000)
    var controls: CameraControls { lock.withLock { cameraControls } }
    var currentROI = ROI(x: 0, y: 0, width: 128, height: 128)
    let supportedBins = [1]
    private let focuser: FocusTestFocuser
    private let lock = NSLock()
    private var stopped = false
    private var oldFrames = false
    private var missingStar = false
    private var duplicateFrames = false
    private var flat = false
    private var badVerification = false
    private var frames = 0
    private var exposureResponse = true
    private var brightness = 1.0
    private var constantFlux = false
    private var verificationBrightness = false
    private var permanentlyClipped = false
    private var bufferCount = 0
    private var bufferedExposures: [Int] = []
    private var exposureHistory: [Int] = []
    private let startingSigma: Double
    var exposures: [Int] { lock.withLock { exposureHistory } }
    init(focuser: FocusTestFocuser) {
        self.focuser = focuser
        startingSigma = sqrt(4 + pow(Double(focuser.position - 12350) / 450, 2))
    }
    func configureExposure(brightness: Double = 1, constantFlux: Bool = false,
                           verificationBrightness: Bool = false, permanentlyClipped: Bool = false, bufferCount: Int = 0) {
        lock.withLock {
            exposureResponse = true; self.brightness = brightness; self.constantFlux = constantFlux
            self.verificationBrightness = verificationBrightness; self.permanentlyClipped = permanentlyClipped
            self.bufferCount = bufferCount
        }
    }
    func configure(oldFrames: Bool = false, missingStar: Bool = false, duplicateFrames: Bool = false,
                   flat: Bool = false, badVerification: Bool = false) {
        lock.withLock { self.oldFrames = oldFrames; self.missingStar = missingStar; self.duplicateFrames = duplicateFrames; self.flat = flat; self.badVerification = badVerification }
    }
    func open() throws { lock.withLock { stopped = false } }
    func close() { lock.withLock { stopped = true } }
    func applyExposure(_ value: Int) throws {
        lock.withLock {
            bufferedExposures = Array(repeating: cameraControls.exposureMicroseconds, count: bufferCount)
            cameraControls.exposureMicroseconds = value; exposureHistory.append(value)
        }
    }
    func applyGain(_ value: Int) throws { lock.withLock { cameraControls.gain = value } }
    func applyROI(_ roi: ROI) throws { currentROI = roi }
    func startVideo() throws { }
    func stopVideo() { }
    func cancelGrab() { lock.withLock { stopped = true } }
    func grabFrame(timeoutMs: Int) throws -> Frame {
        preciseSleep(milliseconds: 25)
        let config = lock.withLock { frames += 1; return (stopped, oldFrames, missingStar, duplicateFrames, flat, frames, badVerification) }
        if config.0 { throw CameraError.timeout }
        let sigma = config.4 ? 3 : sqrt(4 + pow(Double(focuser.position - 12350) / 450, 2))
        // Seeing occasionally broadens a frame; five-frame medians must survive.
        let seeing = config.6 && focuser.moves.count == 12 ? 3.0 : config.5 % 7 == 0 ? 1.35 : 1.0
        let peak: Double = lock.withLock {
            let exposure = bufferedExposures.isEmpty ? cameraControls.exposureMicroseconds : bufferedExposures.removeFirst()
            if permanentlyClipped { return 100000 }
            guard exposureResponse else { return 30000 }
            let fluxScale = constantFlux ? pow(startingSigma / sigma, 2) : 1
            let finalScale = verificationBrightness && focuser.moves.count >= 12 ? 5.0 : 1.0
            return 30000 * brightness * fluxScale * finalScale * Double(exposure) / 10000
        }
        let timestamp = config.1 ? Date.distantPast : config.3 ? Date(timeIntervalSince1970: 4_000_000_000) : Date()
        return focusFrame(sigma: sigma * seeing, peak: config.2 ? 0 : peak, timestamp: timestamp)
    }
}

@MainActor
private func waitForFocus(_ condition: () -> Bool, timeout: TimeInterval = 15) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else { throw UIModelExpectation(description: "autofocus state did not arrive") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
private func focusTestEngine(_ suffix: String, position: Int = 12000, timing: AutofocusTiming = AutofocusTiming(motionTimeout: 1, frameTimeout: 1, settleSeconds: 0.02)) async throws -> (CollimationEngine, FocusTestFocuser, FocusTestCamera, String) {
    let suite = "collimation-camera.tests.autofocus.\(suffix)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let focuser = FocusTestFocuser(position: position)
    let camera = FocusTestCamera(focuser: focuser)
    let engine = CollimationEngine(defaults: defaults, serialPortPaths: { ["COM4"] }, focuser: focuser,
                                   cameraFactory: { _ in camera }, autofocusTiming: timing)
    engine.exposureMicroseconds = 10000
    engine.autofocusStepSize = 500
    engine.connect()
    engine.connectFocuser()
    try await waitForFocus { engine.canAutofocus }
    return (engine, focuser, camera, suite)
}

@MainActor
func testAutofocusEngineSuccess() async throws {
    let (engine, focuser, _, suite) = try await focusTestEngine("success")
    defer { engine.disconnect(); engine.disconnectFocuser(); engine.shutdown(); UserDefaults.standard.removePersistentDomain(forName: suite) }
    engine.startAutofocus()
    try expectUI(engine.isAutofocusing && !engine.canMoveFocuser && !engine.canAutoExpose && !engine.canSaveStacked && !engine.canAdjustCamera,
                 "autofocus owns focus, camera controls and stacking")
    try expectUI(engine.canStopFocuser && engine.canConnectFocuser, "stop and disconnect remain available")
    engine.moveFocuserOut()
    engine.autoExpose()
    engine.saveStackedSnapshot(to: URL(fileURLWithPath: "unused.tif"))
    try expectUI(!engine.isStacking && !engine.isAutoExposing, "direct commands honour autofocus interlocks")
    try await waitForFocus { !engine.isAutofocusing }
    guard case .complete(let position, let hfr) = engine.autofocusState else {
        throw UIModelExpectation(description: "autofocus did not complete: \(engine.errorMessage ?? "no error")")
    }
    try expectUI(abs(position - 12350) < 120 && hfr > 0, "raw camera frames recover known optical focus")
    try expectUI(engine.autofocusSamples.count == 9, "all positions measured")
    try expectUI(focuser.moves.count == 12 && focuser.moves.first == 9500, "one preload, nine points and two final-approach moves")
    try expectUI(Array(focuser.moves.suffix(2)) == [position - 500, position], "final approach matches scan direction")
    try expectUI(engine.canMoveFocuser && engine.canAutoExpose && engine.canAdjustCamera, "success releases interlocks")
}

@MainActor
func testAutofocusExposureStartup() async throws {
    for mode in ["clipped", "buffered", "faint"] {
        let (engine, focuser, camera, suite) = try await focusTestEngine("exposure-\(mode)")
        defer { engine.disconnect(); engine.disconnectFocuser(); engine.shutdown(); UserDefaults.standard.removePersistentDomain(forName: suite) }
        camera.configureExposure(brightness: mode == "faint" ? 0.1 : 10, bufferCount: mode == "buffered" ? 2 : 0)
        try await waitForFocus { mode == "faint" ? (engine.tracking.detection?.peak ?? 65535) < 5000
                                                 : (engine.tracking.detection?.peak ?? 0) >= StarQuality.clipADU }
        try expectUI(engine.canAutofocus, "a clipped tracked star can start autofocus")
        engine.startAutofocus()
        try await waitForFocus { !focuser.moves.isEmpty || !engine.isAutofocusing }
        try expectUI(!camera.exposures.isEmpty && (mode == "faint" ? engine.exposureMicroseconds > 50000 : engine.exposureMicroseconds < 2000),
                     "exposure is selected before the first motor command")
        try await waitForFocus { !engine.isAutofocusing }
        guard case .complete(let position, _) = engine.autofocusState else {
            throw UIModelExpectation(description: "\(mode) exposure failed: \(engine.errorMessage ?? "no error")")
        }
        try expectUI(abs(position - 12350) < 120 && focuser.moves.count == 12, "\(mode) obtains verified focus without a restart")
        try expectUI(engine.autofocusSamples.count == 9 && Set(engine.autofocusSamples.compactMap(\.exposureMicroseconds)).count == 1,
                     "all retained samples share the selected exposure")
    }
}

@MainActor
func testAutofocusExposureScanRecovery() async throws {
    let (engine, focuser, camera, suite) = try await focusTestEngine("exposure-scan", position: 14000)
    defer { engine.disconnect(); engine.disconnectFocuser(); engine.shutdown(); UserDefaults.standard.removePersistentDomain(forName: suite) }
    engine.autofocusStepSize = 750
    camera.configureExposure(constantFlux: true)
    engine.startAutofocus()
    try await waitForFocus({ !engine.isAutofocusing }, timeout: 25)
    guard case .complete(let position, _) = engine.autofocusState else {
        throw UIModelExpectation(description: "scan saturation failed: \(engine.errorMessage ?? "no error")")
    }
    try expectUI(engine.autofocusExposureRetries > 0 && abs(position - 12350) < 150,
                 "a sharpening star triggers exposure recovery and verified focus")
    try expectUI(engine.autofocusSamples.count == 9 && Set(engine.autofocusSamples.compactMap(\.exposureMicroseconds)).count == 1,
                 "partial curves at old exposures are discarded")
    try expectUI(engine.exposureMicroseconds < 4000 && focuser.moves.allSatisfy({ (10250...17000).contains($0) }),
                 "recovery keeps the shorter exposure and original travel bounds")
}

@MainActor
func testAutofocusExposureVerificationRecovery() async throws {
    let (engine, _, camera, suite) = try await focusTestEngine("exposure-verify")
    defer { engine.disconnect(); engine.disconnectFocuser(); engine.shutdown(); UserDefaults.standard.removePersistentDomain(forName: suite) }
    camera.configureExposure(verificationBrightness: true)
    engine.startAutofocus()
    try await waitForFocus({ !engine.isAutofocusing }, timeout: 25)
    guard case .complete(let position, _) = engine.autofocusState else {
        throw UIModelExpectation(description: "verification saturation failed: \(engine.errorMessage ?? "no error")")
    }
    try expectUI(engine.autofocusExposureRetries == 1 && abs(position - 12350) < 120,
                 "clipped final verification restarts the whole curve")
    try expectUI(engine.autofocusSamples.count == 9 && Set(engine.autofocusSamples.compactMap(\.exposureMicroseconds)).count == 1,
                 "verification compares a complete curve at the new exposure")
}

@MainActor
func testAutofocusExposureLimit() async throws {
    let (engine, focuser, camera, suite) = try await focusTestEngine("exposure-limit")
    defer { engine.disconnect(); engine.disconnectFocuser(); engine.shutdown(); UserDefaults.standard.removePersistentDomain(forName: suite) }
    camera.configureExposure(permanentlyClipped: true)
    engine.startAutofocus()
    try await waitForFocus { !engine.isAutofocusing }
    try await waitForFocus { !engine.isFocuserBusy }
    try expectUI(engine.autofocusState == .failed && engine.errorMessage == AutofocusError.exposureLimit.localizedDescription,
                 "unrecoverable clipping reports the exposure limit")
    try expectUI(engine.exposureMicroseconds == 100 && focuser.moves.isEmpty && focuser.stopCount > 0,
                 "minimum-exposure failure never moves the motor")
}

@MainActor
func testAutofocusExposureCancellation() async throws {
    let (engine, focuser, camera, suite) = try await focusTestEngine("exposure-cancel")
    defer { engine.disconnect(); engine.disconnectFocuser(); engine.shutdown(); UserDefaults.standard.removePersistentDomain(forName: suite) }
    camera.configureExposure(brightness: 100)
    let previousRequests = camera.exposures.count
    engine.startAutofocus()
    try await waitForFocus { camera.exposures.count > previousRequests }
    engine.stopFocuser()
    let exposure = engine.exposureMicroseconds
    try await Task.sleep(for: .milliseconds(300))
    try expectUI(engine.autofocusState == .cancelled && engine.exposureMicroseconds == exposure && focuser.moves.isEmpty,
                 "Stop cancels exposure selection and prevents subsequent commands")
    try expectUI(engine.canAdjustCamera && !engine.isAutofocusing, "cancellation releases camera controls")
    try await waitForFocus { engine.canAutofocus }
    engine.startAutofocus()
    engine.stopFocuser()
    try await Task.sleep(for: .milliseconds(100))
    try expectUI(engine.autofocusState == .cancelled && focuser.moves.isEmpty,
                 "cancelling before the autofocus task starts cannot overwrite cancelled status")
}

@MainActor
func testAutofocusCancellation() async throws {
    let (engine, focuser, _, suite) = try await focusTestEngine("cancel")
    let gate = DispatchSemaphore(value: 0)
    defer { gate.signal(); engine.disconnect(); engine.disconnectFocuser(); engine.shutdown(); UserDefaults.standard.removePersistentDomain(forName: suite) }
    focuser.configure(gate: gate)
    engine.startAutofocus()
    try await waitForFocus { focuser.moveEntered.wait(timeout: .now()) == .success }
    engine.stopFocuser()
    try expectUI(!engine.isAutofocusing && engine.autofocusState == .cancelled, "stop cancels immediately while serial command is blocked")
    gate.signal()
    try await waitForFocus { !engine.isFocuserBusy && focuser.stopCount > 0 }
    try await Task.sleep(for: .milliseconds(150))
    try expectUI(focuser.moves.count == 1 && engine.autofocusSamples.isEmpty, "cancelled run never issues next scan move")
    engine.startAutofocus()
    try await waitForFocus { focuser.moves.count > 1 }
    engine.disconnect()
    try await waitForFocus { !engine.isFocuserBusy }
    try expectUI(!engine.isAutofocusing && !engine.isConnected && focuser.stopCount >= 2, "camera disconnect stops autofocus")
    engine.connect()
    try await waitForFocus { engine.canAutofocus }
    focuser.configure(gate: gate)
    // Drain the notification from the earlier second run before the new move.
    _ = focuser.moveEntered.wait(timeout: .now())
    engine.startAutofocus()
    try await waitForFocus { focuser.moveEntered.wait(timeout: .now()) == .success }
    let movesBeforeDisconnect = focuser.moves.count
    engine.disconnectFocuser()
    gate.signal()
    try await Task.sleep(for: .milliseconds(150))
    try expectUI(!engine.isFocuserConnected && !engine.isAutofocusing && focuser.moves.count == movesBeforeDisconnect + 1,
                 "focuser disconnect ignores late results and prevents more scan moves")
}

@MainActor
func testAutofocusFailures() async throws {
    for mode in ["stuck", "mismatch", "communication", "stale", "duplicate", "noStar", "flat", "verification"] {
        let timing = AutofocusTiming(motionTimeout: 0.25, frameTimeout: 0.5, settleSeconds: 0.01)
        let (engine, focuser, camera, suite) = try await focusTestEngine(mode, timing: timing)
        defer { engine.disconnect(); engine.disconnectFocuser(); engine.shutdown(); UserDefaults.standard.removePersistentDomain(forName: suite) }
        focuser.configure(stuck: mode == "stuck", mismatch: mode == "mismatch", failed: mode == "communication")
        camera.configure(oldFrames: mode == "stale", missingStar: mode == "noStar", duplicateFrames: mode == "duplicate",
                         flat: mode == "flat", badVerification: mode == "verification")
        engine.startAutofocus()
        try await waitForFocus { !engine.isAutofocusing }
        try await waitForFocus { !engine.isFocuserBusy }
        try expectUI(engine.autofocusState == .failed && engine.errorMessage != nil, "\(mode) reports failure")
        try expectUI(focuser.stopCount > 0, "\(mode) sends stop")
        if mode != "flat" && mode != "verification" { try expectUI(focuser.moves.count <= 2, "\(mode) cannot continue scan") }
    }
}

@MainActor
func testAutofocusSimulatorInterlock() async throws {
    let defaults = UserDefaults(suiteName: "collimation-camera.tests.autofocus.simulator")!
    let focuser = FocusTestFocuser()
    let engine = CollimationEngine(defaults: defaults, serialPortPaths: { ["COM4"] }, focuser: focuser)
    defer { engine.disconnect(); engine.disconnectFocuser(); engine.shutdown(); defaults.removePersistentDomain(forName: "collimation-camera.tests.autofocus.simulator") }
    engine.selectedDeviceID = CameraDescriptor.simulator.id
    engine.connect()
    engine.connectFocuser()
    try await waitForFocus { engine.isFocuserConnected && engine.tracking.state == .tracking }
    try expectUI(!engine.canAutofocus, "unrelated simulator cannot drive a real focuser")
    engine.startAutofocus()
    try expectUI(focuser.moves.isEmpty, "disabled start sends no moves")
}
