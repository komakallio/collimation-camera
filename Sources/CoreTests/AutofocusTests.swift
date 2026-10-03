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
    try expectUI(plan.preloadPosition == 311000, "preload stays below first measurement")
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
    try AutofocusPlan.verifyLegacyHFR(hfr: 2.1, samples: samples)
    do { try AutofocusPlan.verifyLegacyHFR(hfr: 5, samples: samples); throw UIModelExpectation(description: "bad final focus accepted") }
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

func testAutofocusRecenterPolicy() throws {
    let plan = try AutofocusPlan(position: 12000, maximum: 440000, step: 500)
    func samples(_ values: [Double], for plan: AutofocusPlan) -> [AutofocusSample] {
        zip(plan.positions, values).map { AutofocusSample(position: $0, hfr: $1) }
    }
    let falling = samples([10, 9, 8, 7, 6, 5, 4, 3, 2], for: plan)
    let rising = samples([2, 3, 4, 5, 6, 7, 8, 9, 10], for: plan)
    try expectUI(try plan.recentered(samples: falling, maximum: 440000).positions[4] == 14000,
                 "falling HFR moves the scan centre outward to its best edge")
    try expectUI(try plan.recentered(samples: rising, maximum: 440000).positions[4] == 10000,
                 "rising HFR moves the scan centre inward")
    let noisy = samples([10, 9, 8, 7.5, 8, 5, 4, 3.2, 2], for: plan)
    try expectUI(try plan.recentered(samples: noisy, maximum: 440000).positions[4] == 14000,
                 "a supported slope survives a seeing outlier")
    for values in [[Double](repeating: 3, count: 9), [3, 3, 3, 3, 3, 3, 3, 3, 1],
                   (0..<9).map { 3 - Double($0) * 0.01 }, [9, 2, 8, 3, 7, 4, 6, 5, 1]] {
        do {
            _ = try plan.recentered(samples: samples(values, for: plan), maximum: 440000)
            throw UIModelExpectation(description: "unsupported edge slope was followed")
        } catch AutofocusError.invalidSlope { }
    }
    let lower = try AutofocusPlan(position: 9000, maximum: 50000, step: 1000)
    let lowerShift = try lower.recentered(samples: samples([2, 3, 4, 5, 6, 7, 8, 9, 10], for: lower), maximum: 50000)
    try expectUI(lowerShift.positions[4] == 8000 && lowerShift.preloadPosition == 0,
                 "the last inward scan preserves room for preload")
    let upper = try AutofocusPlan(position: 43000, maximum: 50000, step: 1000)
    let upperShift = try upper.recentered(samples: samples([10, 9, 8, 7, 6, 5, 4, 3, 2], for: upper), maximum: 50000)
    try expectUI(upperShift.positions[4] == 46000 && upperShift.positions.last == 50000,
                 "the last outward scan ends exactly at calibrated maximum")
    for (boundary, values) in [(lowerShift, [2.0, 3, 4, 5, 6, 7, 8, 9, 10]),
                               (upperShift, [10.0, 9, 8, 7, 6, 5, 4, 3, 2])] {
        do {
            _ = try boundary.recentered(samples: samples(values, for: boundary), maximum: 50000)
            throw UIModelExpectation(description: "search moved past a travel boundary")
        } catch AutofocusError.searchTravelLimit { }
    }
    let huge = try AutofocusPlan(position: Int.max / 2, maximum: Int.max, step: Int.max / 40)
    let hugeShift = try huge.recentered(samples: samples([10, 9, 8, 7, 6, 5, 4, 3, 2], for: huge), maximum: Int.max)
    try expectUI(hugeShift.positions[4] == huge.positions.last && hugeShift.positions.last! <= Int.max,
                 "re-centering large absolute positions cannot overflow")
    let mixed = plan.positions.enumerated().map {
        AutofocusSample(position: $0.element, hfr: Double(10 - $0.offset), exposureMicroseconds: $0.offset == 8 ? 200 : 100)
    }
    do { _ = try plan.recentered(samples: mixed, maximum: 440000); throw UIModelExpectation(description: "mixed exposures supported a slope") }
    catch AutofocusError.noStar { }
}

func testAutofocusSearchProgress() throws {
    var search = AutofocusSearch()
    let original = try AutofocusPlan(position: 12000, maximum: 440000, step: 500)
    func samples(_ plan: AutofocusPlan, best: Double, reversed: Bool = false) -> [AutofocusSample] {
        plan.positions.enumerated().map {
            AutofocusSample(position: $0.element, hfr: best + Double(reversed ? $0.offset : 8 - $0.offset))
        }
    }
    let next = try search.recenter(plan: original, samples: samples(original, best: 2), maximum: 440000)
    do { _ = try search.recenter(plan: next, samples: samples(next, best: 3), maximum: 440000); throw UIModelExpectation(description: "a worsening curve continued the search") }
    catch AutofocusError.searchNotImproving { }
    do { _ = try search.recenter(plan: next, samples: samples(next, best: 1, reversed: true), maximum: 440000); throw UIModelExpectation(description: "an unbracketed reversal continued the search") }
    catch AutofocusError.searchNotImproving { }
    search.exposureChanged()
    try expectUI(try search.recenter(plan: next, samples: samples(next, best: 3), maximum: 440000).positions[4] == 16000,
                 "exposure changes discard incomparable HFR progress but keep search direction")
    var continuing = AutofocusSearch()
    var plan = original
    for _ in 0..<10 {
        let curve = plan.positions.map { AutofocusSample(position: $0, hfr: 80 - Double($0) / 500) }
        plan = try continuing.recenter(plan: plan, samples: curve, maximum: 440000)
    }
    try expectUI(plan.positions[4] == 32000, "a valid improving slope can continue beyond four re-centres")
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
    private var gatedMoveNumber: Int?
    let gatedMoveEntered = DispatchSemaphore(value: 0)
    init(position: Int = 12000, maximum: Int = 440000) { state.position = position; state.maxPosition = maximum }
    var position: Int { lock.withLock { state.position } }
    var moves: [Int] { lock.withLock { history } }
    var stopCount: Int { lock.withLock { stops } }
    func configure(stuck: Bool = false, mismatch: Bool = false, failed: Bool = false,
                   gate: DispatchSemaphore? = nil, gateAtMove: Int? = nil) {
        lock.withLock { self.stuck = stuck; self.mismatch = mismatch; self.failed = failed; moveGate = gate; gatedMoveNumber = gateAtMove }
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
        let gate: DispatchSemaphore? = lock.withLock {
            guard gatedMoveNumber == nil || history.count + 1 == gatedMoveNumber else { return nil }
            let value = moveGate; moveGate = nil; return value
        }
        moveEntered.signal()
        if let gate { gatedMoveEntered.signal(); _ = gate.wait(timeout: .now() + 3) }
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
    private var edgeOutlier = false
    private var frames = 0
    private var exposureResponse = true
    private var brightness = 1.0
    private var constantFlux = false
    private var verificationBrightness = false
    private var permanentlyClipped = false
    private var bufferCount = 0
    private var bufferedExposures: [Int] = []
    private var verificationMode = ""
    private var verificationRestarts = 0
    private var streamRestarts = 0
    private var exposureHistory: [Int] = []
    private let startingSigma: Double
    private let startingPosition: Int
    private let focusPosition: Int
    var exposures: [Int] { lock.withLock { exposureHistory } }
    var restarts: Int { lock.withLock { streamRestarts } }
    func configureVerification(_ mode: String) { lock.withLock { verificationMode = mode } }
    init(focuser: FocusTestFocuser, focusPosition: Int = 12350) {
        self.focuser = focuser
        self.focusPosition = focusPosition
        startingPosition = focuser.position
        startingSigma = sqrt(4 + pow(Double(focuser.position - focusPosition) / 450, 2))
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
                   flat: Bool = false, badVerification: Bool = false, edgeOutlier: Bool = false) {
        lock.withLock { self.oldFrames = oldFrames; self.missingStar = missingStar; self.duplicateFrames = duplicateFrames; self.flat = flat; self.badVerification = badVerification; self.edgeOutlier = edgeOutlier }
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
    func startVideo() throws {
        lock.withLock {
            streamRestarts += 1
            if focuser.moves.count == 14 { verificationRestarts += 1 }
        }
    }
    func stopVideo() { }
    func cancelGrab() { lock.withLock { stopped = true } }
    func grabFrame(timeoutMs: Int) throws -> Frame {
        preciseSleep(milliseconds: 25)
        let config = lock.withLock { frames += 1; return (stopped, oldFrames, missingStar, duplicateFrames, flat, frames, badVerification, edgeOutlier) }
        if config.0 { throw CameraError.timeout }
        let verification = lock.withLock { (verificationMode, verificationRestarts) }
        let finalMeasurement = focuser.moves.count >= 14
        let sigma = config.7 ? (focuser.position == startingPosition + 2000 ? 2.0 : 3.0)
            : config.4 ? 3 : sqrt(4 + pow(Double(focuser.position - focusPosition) / 450, 2))
        // Seeing occasionally broadens a frame; five-frame medians must survive.
        let spike = finalMeasurement && verification.0 == "spike" && verification.1 == 1
        let seeing = finalMeasurement && verification.0 == "unstable" ? Double(verification.1)
            : config.6 && finalMeasurement || spike ? 3.0 : config.5 % 7 == 0 ? 1.35 : 1.0
        let peak: Double = lock.withLock {
            let exposure = bufferedExposures.isEmpty ? cameraControls.exposureMicroseconds : bufferedExposures.removeFirst()
            if permanentlyClipped { return 100000 }
            guard exposureResponse else { return 30000 }
            let fluxScale = constantFlux ? pow(startingSigma / sigma, 2) : 1
            let finalScale = verificationBrightness && focuser.moves.count >= 14 ? 5.0 : 1.0
            return 30000 * brightness * fluxScale * finalScale * Double(exposure) / 10000
        }
        let timestamp = config.1 ? Date.distantPast : config.3 ? Date(timeIntervalSince1970: 4_000_000_000) : Date()
        return focusFrame(sigma: sigma * seeing, peak: config.2 || finalMeasurement && verification.0 == "missing" ? 0 : peak, timestamp: timestamp)
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
private func focusTestEngine(_ suffix: String, position: Int = 12000, maximum: Int = 440000, opticalFocus: Int = 12350,
                             timing: AutofocusTiming = AutofocusTiming(motionTimeout: 1, frameTimeout: 1, settleSeconds: 0.02, verificationInterval: 0.02)) async throws -> (CollimationEngine, FocusTestFocuser, FocusTestCamera, String) {
    let suite = "collimation-camera.tests.autofocus.\(suffix)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let focuser = FocusTestFocuser(position: position, maximum: maximum)
    let camera = FocusTestCamera(focuser: focuser, focusPosition: opticalFocus)
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
    let (engine, focuser, camera, suite) = try await focusTestEngine("success")
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
    try expectUI(abs(position - 12350) < 120 && (hfr ?? 0) > 0, "raw camera frames recover known optical focus")
    try expectUI(engine.autofocusSamples.count == 9, "all positions measured")
    try expectUI(focuser.moves.count == 14 && focuser.moves.first == 8000, "directional baseline, one preload, nine points and final approach")
    try expectUI(Array(focuser.moves.suffix(2)) == [position - 4000, position], "final approach matches scan direction")
    try expectUI(engine.autofocusSamples.allSatisfy { sample in
        sample.readings?.filter { $0.hfr != nil }.count == 5
            && sample.readings?.filter { $0.rejection == "startup discard" }.count == 3
            && sample.startedAt != nil && sample.finishedAt != nil && sample.scatter != nil
    }, "every position retains five readings, three fresh discards and timing")
    try expectUI(engine.autofocusDiagnostics?.verification.count == 3 && engine.autofocusResult?.diagnostics?.fit != nil,
                 "supported result retains three diagnostic blocks and fitted uncertainty")
    try expectUI(Array(focuser.moves.prefix(3)) == [8000, 12000, 6000],
                 "baseline and first scan target each have a full outward approach")
    try expectUI(camera.restarts >= 14, "camera worker acknowledges fresh capture at every acquisition")
    try expectUI(engine.canMoveFocuser && engine.canAutoExpose && engine.canAdjustCamera, "success releases interlocks")
}

@MainActor
func testAutofocusRecenterSuccess() async throws {
    for (mode, start) in [("outward", 8000), ("inward", 17000), ("exposure", 8000)] {
        // Wide defocused blobs cost more to analyse than the near-focus
        // fixtures. Allow scheduling headroom without changing production
        // timing, frame counts or any curve/search acceptance criterion.
        let timing = AutofocusTiming(motionTimeout: 1, frameTimeout: 2, settleSeconds: 0.02, verificationInterval: 0.02)
        let (engine, focuser, camera, suite) = try await focusTestEngine("recenter-\(mode)", position: start, timing: timing)
        defer { engine.disconnect(); engine.disconnectFocuser(); engine.shutdown(); UserDefaults.standard.removePersistentDomain(forName: suite) }
        if mode == "exposure" { camera.configureExposure(constantFlux: true) }
        engine.startAutofocus()
        try await waitForFocus({ !engine.isAutofocusing }, timeout: 80)
        guard case .complete(let position, _) = engine.autofocusState else {
            throw UIModelExpectation(description: "\(mode) re-centering failed: \(engine.errorMessage ?? "no error"); moves \(focuser.moves); rejected \(engine.autofocusDiagnostics?.rejectedReadings.map { $0.rejection ?? "unknown" } ?? [])")
        }
        try expectUI(engine.autofocusRecenters == 2 && abs(position - 12350) < 120,
                     "\(mode) finds optical focus beyond the original scan after two shifts")
        try expectUI(engine.autofocusSamples.count == 9 && engine.autofocusSamples[4].position == (start == 8000 ? 12000 : 13000),
                     "only the complete final window is retained")
        try expectUI(Set(engine.autofocusSamples.compactMap(\.exposureMicroseconds)).count == 1,
                     "re-centering and saturation recovery preserve exposure consistency")
        try expectUI(Array(focuser.moves.suffix(2)) == [position - 4000, position],
                     "final focus keeps the outward backlash approach")
        try expectUI(focuser.moves.allSatisfy({ (0...440000).contains($0) }), "all search moves respect calibrated travel")
        if mode == "exposure" { try expectUI(engine.autofocusExposureRetries > 0, "saturation recovery works during a re-centred search") }
    }
}

@MainActor
func testAutofocusRecenterTravelLimits() async throws {
    for (mode, start, maximum, opticalFocus) in [("upper", 12000, 14000, 16000), ("lower", 7000, 440000, 3000)] {
        let (engine, focuser, _, suite) = try await focusTestEngine("recenter-limit-\(mode)", position: start, maximum: maximum, opticalFocus: opticalFocus)
        defer { engine.disconnect(); engine.disconnectFocuser(); engine.shutdown(); UserDefaults.standard.removePersistentDomain(forName: suite) }
        engine.startAutofocus()
        try await waitForFocus({ !engine.isAutofocusing }, timeout: 25)
        try await waitForFocus { !engine.isFocuserBusy }
        try expectUI(engine.autofocusState == .failed && engine.errorMessage == AutofocusError.searchTravelLimit.localizedDescription,
                     "\(mode) reports calibrated travel exhaustion")
        try expectUI(focuser.moves.allSatisfy({ (0...maximum).contains($0) }) && focuser.stopCount > 0,
                     "\(mode) search stops without issuing an out-of-range command")
        try expectUI(engine.autofocusRecenters == (mode == "lower" ? 1 : 0), "search uses the last legal window before stopping")
    }
}

@MainActor
func testAutofocusRecenterInvalidSlope() async throws {
    let (engine, focuser, camera, suite) = try await focusTestEngine("recenter-noise")
    defer { engine.disconnect(); engine.disconnectFocuser(); engine.shutdown(); UserDefaults.standard.removePersistentDomain(forName: suite) }
    camera.configure(edgeOutlier: true)
    engine.startAutofocus()
    try await waitForFocus { !engine.isAutofocusing }
    try expectUI(engine.autofocusState == .failed && engine.errorMessage == AutofocusError.invalidSlope.localizedDescription,
                 "one sharp edge outlier does not establish a focus slope")
    try expectUI(engine.autofocusRecenters == 0 && focuser.moves.count == 12, "invalid slope cannot initiate another scan")
}

@MainActor
func testAutofocusRecenterCancellation() async throws {
    let (engine, focuser, _, suite) = try await focusTestEngine("recenter-cancel", position: 8000)
    let gate = DispatchSemaphore(value: 0)
    defer { gate.signal(); engine.disconnect(); engine.disconnectFocuser(); engine.shutdown(); UserDefaults.standard.removePersistentDomain(forName: suite) }
    focuser.configure(gate: gate, gateAtMove: 13)
    engine.startAutofocus()
    try await waitForFocus { focuser.gatedMoveEntered.wait(timeout: .now()) == .success }
    try expectUI(engine.autofocusRecenters == 1, "first re-centred approach has started")
    engine.stopFocuser()
    gate.signal()
    try await waitForFocus { !engine.isFocuserBusy && focuser.stopCount > 0 }
    try await Task.sleep(for: .milliseconds(150))
    try expectUI(engine.autofocusState == .cancelled && focuser.moves.count == 13 && engine.autofocusSamples.isEmpty,
                 "Stop during re-centering prevents the new baseline and scan moves")
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
        try expectUI(abs(position - 12350) < 120 && focuser.moves.count == 14, "\(mode) obtains verified focus without a restart")
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
    try expectUI(engine.exposureMicroseconds < 4000 && focuser.moves.allSatisfy({ (7000...17000).contains($0) }),
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
    try expectUI(engine.autofocusExposureRetries == 0 && abs(position - 12350) < 120,
                 "clipped final diagnostics cannot restart or invalidate the fitted curve")
    try expectUI(engine.autofocusSamples.count == 9 && Set(engine.autofocusSamples.compactMap(\.exposureMicroseconds)).count == 1,
                 "the accepted curve keeps its original uniform exposure")
    try expectUI(engine.autofocusResult?.hfr == nil && engine.autofocusDiagnostics?.finalMeasurementIssues?.count == 3,
                 "saturated final HFR is unavailable with all three issues recorded")
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
    // The longer take-up may leave a cancelled move below the next legal scan
    // centre. Explicit test setup, never an automatic cancellation restoration.
    engine.focuserTargetPosition = 12000
    engine.gotoFocuser()
    try await waitForFocus { !engine.isFocuserBusy && engine.focuserSnapshot?.position == 12000 }
    engine.connect()
    try await waitForFocus { engine.canAutofocus }
    focuser.configure(gate: gate)
    // Ordinary setup moves also signal moveEntered. Wait for the actual gated
    // command so disconnect cannot race a stale setup notification.
    while focuser.gatedMoveEntered.wait(timeout: .now()) == .success { }
    engine.startAutofocus()
    try await waitForFocus { focuser.gatedMoveEntered.wait(timeout: .now()) == .success }
    let movesBeforeDisconnect = focuser.moves.count
    engine.disconnectFocuser()
    gate.signal()
    try await Task.sleep(for: .milliseconds(150))
    try expectUI(!engine.isFocuserConnected && !engine.isAutofocusing && focuser.moves.count == movesBeforeDisconnect + 1,
                 "focuser disconnect ignores late results and prevents more scan moves")
}

@MainActor
func testAutofocusFailures() async throws {
    for mode in ["stuck", "mismatch", "communication", "stale", "duplicate", "noStar", "flat"] {
        let timing = AutofocusTiming(motionTimeout: 0.25, frameTimeout: 0.5, settleSeconds: 0.01, verificationInterval: 0.01)
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
        if mode != "flat" { try expectUI(focuser.moves.count <= 2, "\(mode) cannot continue scan") }
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

@MainActor
func testAutofocusVerificationEngine() async throws {
    for mode in ["spike", "persistent", "unstable", "missing"] {
        let (engine, focuser, camera, suite) = try await focusTestEngine("final-diagnostic-\(mode)")
        defer { engine.disconnect(); engine.disconnectFocuser(); engine.shutdown(); UserDefaults.standard.removePersistentDomain(forName: suite) }
        if mode == "persistent" { camera.configure(badVerification: true) }
        else { camera.configureVerification(mode) }
        engine.startAutofocus()
        engine.autofocusTakeUpSteps = 1; engine.autofocusStepSize = 100
        try await waitForFocus({ !engine.isAutofocusing }, timeout: 25)
        guard let result = engine.autofocusResult, let diagnostics = result.diagnostics, let fit = diagnostics.fit else {
            throw UIModelExpectation(description: "\(mode) invalidated focus: \(engine.errorMessage ?? "no error")")
        }
        try expectUI(diagnostics.settings.takeUp == 4000 && diagnostics.settings.step == 500,
                     "run settings are snapshotted")
        try expectUI(result.position == fit.position && abs(result.position - 12350) < 120,
                     "final HFR cannot change the supported fitted position")
        try expectUI(result.samples.count == 9 && diagnostics.curves.count == 1 && diagnostics.recovery.isEmpty
            && diagnostics.recoveryOutcome == nil && focuser.moves.count == 14,
            "final HFR cannot cause recovery moves or a scan restart")
        try expectUI(diagnostics.verificationPolicy == "curve-fit-position-only" && diagnostics.failure == nil,
                     "diagnostics identify the position-only acceptance policy")
        if mode == "missing" {
            try expectUI(result.hfr == nil && diagnostics.verification.isEmpty && diagnostics.finalMeasurementIssues?.count == 3,
                         "missing final HFR cannot invalidate the fit and is explicitly recorded")
            try expectUI(diagnostics.finalMeasurementIssues!.allSatisfy { !$0.readings.isEmpty && $0.startedAt <= $0.finishedAt },
                         "unavailable blocks retain partial readings and timestamps")
            let encoder = JSONEncoder(), decoder = JSONDecoder()
            try expectUI(try decoder.decode(AutofocusResult.self, from: encoder.encode(result)) == result,
                         "a supported result without final HFR round trips")
        } else {
            try expectUI(result.hfr != nil && diagnostics.verification.count == 3,
                         "all three final diagnostic blocks are retained")
            if mode == "persistent" {
                try expectUI(result.hfr! > fit.predict(at: result.position) * 1.15,
                             "persistent final HFR above the old guard remains diagnostic only")
            }
            if mode == "unstable" {
                let values = diagnostics.verification.map(\.hfr)
                try expectUI(values.max()! > values.min()! * 1.15,
                             "unstable final HFR cannot invalidate or correct focus")
            }
        }
        try expectUI(Array(focuser.moves.suffix(2)) == [result.position - 4000, result.position] && engine.focuserSnapshot?.isMoving == false,
                     "the fit is reached through full outward take-up and remains stopped")
    }
}

@MainActor
func testAutofocusPhaseCancellation() async throws {
    for phase in ["settling", "collection", "final HFR", "final interval"] {
        let timing = AutofocusTiming(motionTimeout: 1, frameTimeout: 1, settleSeconds: phase == "settling" ? 0.4 : 0.02, verificationInterval: phase == "final interval" ? 0.4 : 0.02)
        let (engine, focuser, _, suite) = try await focusTestEngine("phase-cancel-\(phase)", timing: timing)
        defer { engine.disconnect(); engine.disconnectFocuser(); engine.shutdown(); UserDefaults.standard.removePersistentDomain(forName: suite) }
        engine.startAutofocus()
        try await waitForFocus {
            switch engine.autofocusState {
            case .moving(let position): return phase == "settling" && position == 12000 && focuser.moves.count == 2
            case .measuring(_, let frames): return phase == "collection" && frames > 0
            case .recordingFinalHFR: return phase == "final HFR" || phase == "final interval" && engine.autofocusDiagnostics?.verification.count == 1
            default: return false
            }
        }
        engine.stopFocuser()
        try await waitForFocus { !engine.isFocuserBusy }
        let moves = focuser.moves
        try await Task.sleep(for: .milliseconds(200))
        try expectUI(engine.autofocusState == .cancelled && focuser.moves == moves && focuser.stopCount > 0,
                     "cancellation in \(phase) stops promptly without restoration")
    }
}
