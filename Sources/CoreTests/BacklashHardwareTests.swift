import CollimationCore
import Foundation

private struct BacklashFrame: Codable {
    let timestamp: Double
    let hfr: Double
    let sensorX: Double
    let sensorY: Double
    let peak: UInt16
    let snr: Double
}

private struct BacklashPoint: Codable {
    let pass: String
    let direction: String
    let position: Int
    let timestamp: Double
    let hfr: Double
    let mad: Double
    let frames: [BacklashFrame]
}

private struct BacklashRecord: Codable {
    var schemaVersion = 1
    var startedAt = Date().timeIntervalSince1970
    var status = "running"
    var cameraID: String
    var focuserSerial: String
    var initialPosition: Int
    var scanCenter: Int
    var step: Int
    var halfSpan: Int
    var preload: Int
    var settleSeconds = 1.0
    var exposureMicroseconds: Int
    var gain = 0
    var samplesPerPoint = 15
    var experiment: String?
    var visitsPerPosition: Int?
    var points: [BacklashPoint] = []
    var finalPosition: Int?
    var finalHFR: Double?
    var warning: String?
}

/// A diagnostic experiment, not an application command. All blocking work runs
/// on one worker; no production compensation or controller settings are changed.
func runBacklashHardwareIfRequested() async throws -> Bool {
    let args = CommandLine.arguments
    guard args.contains("--backlash-hardware") || args.contains("--focus-jump-hardware") else { return false }
    try await Task.detached(priority: .userInitiated) {
        try measureBacklashHardware(args: args)
    }.value
    return true
}

private func measureBacklashHardware(args: [String]) throws {
    let jumpExperiment = args.contains("--focus-jump-hardware")
    func value(_ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return nil }
        return args[i + 1]
    }
    guard let cameraID = value("--device"), let focusPort = value("--focuser-port"),
          let mountPort = value("--mount-port"), let outputPath = value(jumpExperiment ? "--jump-output" : "--backlash-output"),
          let descriptor = DeviceCatalog.list().first(where: { $0.id == cameraID && !$0.isSimulator }) else {
        throw UIModelExpectation(description: "Supply real --device, --focuser-port, --mount-port and the diagnostic output path.")
    }
    let step = value("--focus-step").flatMap(Int.init) ?? 250
    let halfSpan = value("--half-span").flatMap(Int.init) ?? 2500
    let preload = value("--preload").flatMap(Int.init) ?? 4000
    let exposure = value("--exposure").flatMap(Double.init) ?? 0.5
    let visits = value("--visits-per-position").flatMap(Int.init) ?? 20
    guard step > 0, halfSpan > 0, halfSpan <= 10000, halfSpan % step == 0,
          halfSpan / step <= 40, preload > 0, preload <= 10000,
          exposure.isFinite, exposure >= 0.1, exposure <= 100,
          !jumpExperiment || (5...50).contains(visits) else {
        throw UIModelExpectation(description: "Invalid diagnostic scan parameters.")
    }
    let output = URL(fileURLWithPath: outputPath)
    let stopFile = URL(fileURLWithPath: value("--backlash-stop-file") ?? outputPath + ".stop")
    func checkStop() throws {
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: stopFile.path) { throw CancellationError() }
    }
    TimerResolution.raise()
    let mount = EQ6Mount()
    // Connect only to stop tracking and both axes. This experiment never slews.
    try mount.connect(path: mountPort)
    mount.haltMotions()
    mount.disconnect()
    let camera = try DeviceCatalog.makeDevice(id: cameraID)
    let focus = EsattoFocuser()
    defer {
        _ = try? focus.stop()
        focus.disconnect()
        camera.stopVideo()
        camera.close()
    }
    let initial = try focus.connect(path: focusPort)
    guard !initial.isMoving else { throw UIModelExpectation(description: "Focuser is already moving.") }
    let center: Int
    if jumpExperiment {
        guard let reference = value("--focus-reference").flatMap(Int.init), reference == initial.position else {
            throw UIModelExpectation(description: "Supply --focus-reference matching the stopped starting position; no jump started.")
        }
        center = reference
    } else {
        center = Int((Double(initial.position) / Double(step)).rounded()) * step
    }
    let low = center - halfSpan, high = center + halfSpan
    guard low >= preload, high <= initial.maxPosition - preload else { throw AutofocusError.invalidRange }
    var record = BacklashRecord(cameraID: cameraID, focuserSerial: initial.serialNumber,
        initialPosition: initial.position, scanCenter: center, step: step, halfSpan: halfSpan,
        preload: preload, exposureMicroseconds: Int((exposure * 1000).rounded()))
    if jumpExperiment {
        record.schemaVersion = 2
        record.samplesPerPoint = 5
        record.experiment = "alternating-defocus-jumps"
        record.visitsPerPosition = visits
    }
    func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: output, options: .atomic)
    }
    // Check the destination before any focuser movement.
    try save()
    try camera.open()
    try camera.applyExposure(record.exposureMicroseconds)
    try camera.applyGain(0)
    record.exposureMicroseconds = camera.controls.exposureMicroseconds
    record.gain = camera.controls.gain
    try camera.applyROI(Alignment.centeredROI(around: SIMD2(Double(descriptor.sensorWidth) / 2,
        Double(descriptor.sensorHeight) / 2), size: 512, sensorWidth: descriptor.sensorWidth,
        sensorHeight: descriptor.sensorHeight, alignment: camera.roiAlignment))
    let detector = StarDetector()
    let estimator = FocusMetricEstimator()
    var anchorX: Double?, anchorY: Double?

    func move(to position: Int) throws {
        try checkStop()
        camera.stopVideo()
        _ = try focus.move(to: position)
        let deadline = Date().addingTimeInterval(60)
        while true {
            try checkStop()
            let state = try focus.snapshot()
            if !state.isMoving {
                guard state.position == position else { throw AutofocusError.positionMismatch }
                return
            }
            guard Date() < deadline else { throw AutofocusError.motionTimeout }
            preciseSleep(milliseconds: 100)
        }
    }

    func measure(pass: String, direction: String, position: Int) throws -> BacklashPoint {
        try checkStop()
        // Restarting capture after idle + settling excludes frames exposed
        // during motion and removes uncertainty about the SDK's queued frames.
        camera.stopVideo()
        preciseSleep(milliseconds: 1000)
        try checkStop()
        try camera.startVideo()
        for _ in 0..<3 { _ = try camera.grabFrame(timeoutMs: 5000); try checkStop() }
        var frames: [BacklashFrame] = []
        let deadline = Date().addingTimeInterval(12)
        while frames.count < record.samplesPerPoint {
            try checkStop()
            guard Date() < deadline else { throw AutofocusError.noStar }
            let frame = try camera.grabFrame(timeoutMs: 5000)
            guard let detection = detector.detect(in: frame) else {
                if jumpExperiment { throw AutofocusError.noStar }
                continue
            }
            guard detection.peak < StarQuality.clipADU else { throw AutofocusError.exposureLimit }
            guard let metric = estimator.measure(frame: frame, detection: detection) else {
                if jumpExperiment { throw AutofocusError.noStar }
                continue
            }
            let frameCenterX = Double(descriptor.sensorWidth - 1) / 2
            let frameCenterY = Double(descriptor.sensorHeight - 1) / 2
            if anchorX == nil {
                guard hypot(metric.sensorX - frameCenterX, metric.sensorY - frameCenterY) <= MountGuide.doneRadiusSensorPixels else {
                    throw UIModelExpectation(description: "Star is outside the centre-position tolerance; no focuser scan started.")
                }
                anchorX = metric.sensorX; anchorY = metric.sensorY
            }
            guard hypot(metric.sensorX - anchorX!, metric.sensorY - anchorY!) < 32 else { throw AutofocusError.noStar }
            frames.append(BacklashFrame(timestamp: frame.timestamp.timeIntervalSince1970,
                hfr: metric.hfr, sensorX: metric.sensorX, sensorY: metric.sensorY,
                peak: detection.peak, snr: detection.snr))
        }
        camera.stopVideo()
        let median = AutofocusPlan.median(frames.map(\.hfr))
        let point = BacklashPoint(pass: pass, direction: direction, position: position,
            timestamp: frames.map(\.timestamp).reduce(0, +) / Double(frames.count), hfr: median,
            mad: AutofocusPlan.median(frames.map { abs($0.hfr - median) }), frames: frames)
        record.points.append(point)
        try save()
        print(String(format: "%@ %@ at %d: HFR %.4f px, MAD %.4f, peak %d, star %.2f, %.2f",
            pass, direction, position, median, point.mad, Int(frames.map(\.peak).max()!),
            frames.map(\.sensorX).reduce(0, +) / Double(frames.count),
            frames.map(\.sensorY).reduce(0, +) / Double(frames.count)))
        return point
    }

    do {
        let baseline = try measure(pass: "baseline", direction: "unknown", position: initial.position)
        print("Centre star ready on \(cameraID); focuser \(initial.serialNumber) on \(focusPort), mount stopped on \(mountPort)")
        if !jumpExperiment {
            print("Five alternating scans, \(low)...\(high), step \(step), preload \(preload), 15 fresh frames per point, 1 s settling")
        }
        print("Baseline HFR \(baseline.hfr), stop file \(stopFile.path)")
        if jumpExperiment {
            print("Alternating \(low) / \(high), \(visits) visits each; 5-frame median after every outward take-up of \(preload) steps")
            for cycle in 1...visits {
                for (label, position) in [("low", low), ("high", high)] {
                    try move(to: position - preload)
                    try move(to: position)
                    _ = try measure(pass: "\(label)\(cycle)", direction: "outward", position: position)
                }
            }
            try move(to: center - preload)
            try move(to: center)
            let restored = try measure(pass: "restore", direction: "outward", position: center)
            record.finalPosition = center
            record.finalHFR = restored.hfr
            record.status = "complete"
            try save()
            print("Jump experiment complete: \(visits) visits per position; stopped at reference \(center). Data: \(output.path)")
            return
        }
        let outward = Array(stride(from: low, through: high, by: step))
        for passIndex in 0..<5 {
            let isOutward = passIndex % 2 == 0
            let pass = isOutward ? "out\(passIndex / 2 + 1)" : "in\(passIndex / 2 + 1)"
            let direction = isOutward ? "outward" : "inward"
            let positions = isOutward ? outward : Array(outward.reversed())
            try move(to: isOutward ? low - preload : high + preload)
            for position in positions {
                try move(to: position)
                _ = try measure(pass: pass, direction: direction, position: position)
            }
        }
        let last = record.points.filter { $0.pass == "out3" }
        guard let best = last.min(by: { $0.hfr < $1.hfr }), best.position > low, best.position < high else {
            throw AutofocusError.minimumNotBracketed
        }
        // Finish at an actually measured minimum with the same fully engaged
        // outward direction, without imposing an unmeasured correction.
        try move(to: best.position - preload)
        try move(to: best.position)
        let final = try measure(pass: "restore", direction: "outward", position: best.position)
        record.finalPosition = best.position; record.finalHFR = final.hfr
        if final.hfr > best.hfr * 1.15 { record.warning = "Final HFR differs by more than 15% from the last scan minimum." }
        record.status = "complete"
        try save()
        print("Backlash scan complete; stopped at \(best.position), final HFR \(final.hfr). Data: \(output.path)")
    } catch {
        record.status = error is CancellationError ? "cancelled" : "failed"
        record.warning = error.localizedDescription
        try? save()
        throw error
    }
}
