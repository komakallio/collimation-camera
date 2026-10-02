import CollimationCore
import Foundation

private struct FocusStabilityFrame: Codable {
    let index: Int
    let timestamp: Double
    let elapsedSeconds: Double
    var hfr: Double?
    var sensorX: Double?
    var sensorY: Double?
    var peak: UInt16?
    var snr: Double?
    var rejection: String?
}

private struct FocusStabilityStackBlock: Codable {
    let firstFrame: Int
    let elapsedSeconds: Double
    let frameCount: Int
    var medianIndividualHFR: Double?
    var unregisteredStackHFR: Double?
    var registeredStackHFR: Double?
    var unregisteredPeak: UInt16?
    var registeredPeak: UInt16?
    var referenceCentroidX: Double?
    var referenceCentroidY: Double?
    var centroidSpanX: Double?
    var centroidSpanY: Double?
    var rejection: String?
}

private struct FocusStabilityRecord: Codable {
    var schemaVersion = 1
    var status = "running"
    let cameraID: String
    let focuserSerial: String
    let initialPosition: Int
    let exposureMicroseconds: Int
    let gain: Int
    let requestedSeconds: Double
    var connectedPosition: Int?
    var preloadSteps: Int?
    var frames: [FocusStabilityFrame] = []
    var stackComparisonFrames: Int?
    var stackBlocks: [FocusStabilityStackBlock] = []
    var finalPosition: Int?
    var finalMotorMoving: Bool?
    var restoredPosition: Int?
    var restoredMotorMoving: Bool?
    var warning: String?
}

/// Records continuous HFR at a held position. Optional, explicitly requested
/// setup/restore moves never run during capture, or after cancellation.
func runFocusStabilityHardwareIfRequested() async throws -> Bool {
    let args = CommandLine.arguments
    guard args.contains("--focus-stability-hardware") else { return false }
    try await Task.detached(priority: .userInitiated) {
        try measureFocusStabilityHardware(args: args)
    }.value
    return true
}

private func measureFocusStabilityHardware(args: [String]) throws {
    func value(_ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return nil }
        return args[i + 1]
    }
    guard let cameraID = value("--device"), let focusPort = value("--focuser-port"),
          let mountPort = value("--mount-port"), let outputPath = value("--stability-output"),
          let descriptor = DeviceCatalog.list().first(where: { $0.id == cameraID && !$0.isSimulator }) else {
        throw UIModelExpectation(description: "Supply real --device, --focuser-port, --mount-port and --stability-output.")
    }
    let seconds = value("--seconds").flatMap(Double.init) ?? 60
    let exposure = value("--exposure").flatMap(Double.init) ?? 0.5
    guard seconds.isFinite, (5...120).contains(seconds), exposure.isFinite, (0.1...100).contains(exposure) else {
        throw UIModelExpectation(description: "Duration must be 5-120 seconds; exposure must be 0.1-100 ms.")
    }
    let output = URL(fileURLWithPath: outputPath)
    let stopFile = URL(fileURLWithPath: outputPath + ".stop")
    func checkStop() throws {
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: stopFile.path) { throw CancellationError() }
    }
    TimerResolution.raise()
    let mount = EQ6Mount()
    try mount.connect(path: mountPort)
    mount.haltMotions()
    mount.disconnect()
    let camera = try DeviceCatalog.makeDevice(id: cameraID)
    let focus = EsattoFocuser()
    defer {
        camera.stopVideo()
        camera.close()
        _ = try? focus.stop()
        focus.disconnect()
    }
    let initial = try focus.connect(path: focusPort)
    guard !initial.isMoving else { throw UIModelExpectation(description: "Focuser is already moving; stability recording aborted.") }
    if let expected = value("--expected-position").flatMap(Int.init), expected != initial.position {
        throw UIModelExpectation(description: "Focuser position changed from the requested fixed position; no scan or move performed.")
    }
    let target: Int?
    if args.contains("--focus-position") {
        guard let position = value("--focus-position").flatMap(Int.init) else {
            throw UIModelExpectation(description: "Supply an integer --focus-position.")
        }
        target = position
    } else { target = nil }
    let restore: Int?
    if args.contains("--restore-position") {
        guard let position = value("--restore-position").flatMap(Int.init) else {
            throw UIModelExpectation(description: "Supply an integer --restore-position.")
        }
        restore = position
    } else { restore = nil }
    let preload = value("--preload").flatMap(Int.init) ?? 4000
    guard (1...10000).contains(preload),
          [target, restore].compactMap({ $0 }).allSatisfy({ $0 >= preload && $0 <= initial.maxPosition }) else {
        throw AutofocusError.invalidRange
    }
    try camera.open()
    try camera.applyExposure(Int((exposure * 1000).rounded()))
    try camera.applyGain(0)
    try camera.applyROI(Alignment.centeredROI(around: SIMD2(Double(descriptor.sensorWidth) / 2,
        Double(descriptor.sensorHeight) / 2), size: 512, sensorWidth: descriptor.sensorWidth,
        sensorHeight: descriptor.sensorHeight, alignment: camera.roiAlignment))
    var record = FocusStabilityRecord(cameraID: cameraID, focuserSerial: initial.serialNumber,
        initialPosition: target ?? initial.position, exposureMicroseconds: camera.controls.exposureMicroseconds,
        gain: camera.controls.gain, requestedSeconds: seconds)
    let compareStacks = args.contains("--compare-stacks")
    if compareStacks {
        record.schemaVersion = 2
        record.stackComparisonFrames = 15
    }
    if target != nil || restore != nil {
        record.schemaVersion = 3
        record.connectedPosition = initial.position
        record.preloadSteps = preload
    }
    func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: output, options: .atomic)
    }
    try save()
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
    func approachOutward(_ position: Int) throws {
        print("Preparing held position \(position), outward take-up \(preload) steps")
        try move(to: position - preload)
        try move(to: position)
    }
    let detector = StarDetector()
    let estimator = FocusMetricEstimator()
    var anchorX: Double?, anchorY: Double?
    var stackFrames: [(frame: Frame, centroid: SIMD2<Double>)] = []
    func stackFrame(_ image: StackedImage) -> Frame {
        // Average pixels stay in the original ADU scale. One-ADU rounding is
        // needed only because the existing HFR estimator consumes UInt16.
        Frame(width: image.width, height: image.height,
            pixels: image.pixels.map { UInt16(clamping: Int($0.rounded())) },
            roi: image.roi, timestamp: image.timestamp)
    }
    func finishStackBlock() throws {
        let firstIndex = record.frames.count - 15
        let individual = record.frames.suffix(15)
        var block = FocusStabilityStackBlock(firstFrame: firstIndex,
            elapsedSeconds: individual.first!.elapsedSeconds, frameCount: 15)
        defer { stackFrames.removeAll(keepingCapacity: true) }
        guard stackFrames.count == 15, individual.allSatisfy({ $0.hfr != nil }) else {
            block.rejection = "one-or-more-invalid-individual-frames"
            record.stackBlocks.append(block)
            return
        }
        block.medianIndividualHFR = AutofocusPlan.median(individual.map { $0.hfr! })
        // The control averages the exact same pixels without shifts. The
        // registered variant uses the application's bilinear centroid stacker,
        // with the first frame's centroid as reference for each 15-frame block.
        let unregistered = try FrameStacker.average(stackFrames.map { (frame: $0.frame, centroid: SIMD2<Double>.zero) })
        let registered = try FrameStacker.average(stackFrames)
        let plainFrame = stackFrame(unregistered)
        let alignedFrame = stackFrame(registered)
        if let detection = detector.detect(in: plainFrame) {
            block.unregisteredPeak = detection.peak
            block.unregisteredStackHFR = estimator.measure(frame: plainFrame, detection: detection)?.hfr
        }
        if let detection = detector.detect(in: alignedFrame) {
            block.registeredPeak = detection.peak
            block.registeredStackHFR = estimator.measure(frame: alignedFrame, detection: detection)?.hfr
        }
        block.referenceCentroidX = stackFrames[0].centroid.x
        block.referenceCentroidY = stackFrames[0].centroid.y
        block.centroidSpanX = stackFrames.map { $0.centroid.x }.max()! - stackFrames.map { $0.centroid.x }.min()!
        block.centroidSpanY = stackFrames.map { $0.centroid.y }.max()! - stackFrames.map { $0.centroid.y }.min()!
        if block.unregisteredStackHFR == nil || block.registeredStackHFR == nil {
            block.rejection = "invalid-stack-metric"
        }
        if firstIndex == 0 {
            let prefix = output.deletingPathExtension().path
            try MonoTIFF.write(frame: stackFrames[0].frame, to: URL(fileURLWithPath: prefix + "-example-raw.tif"))
            try MonoTIFF.write(frame: plainFrame, to: URL(fileURLWithPath: prefix + "-example-mean.tif"))
            try MonoTIFF.write(frame: alignedFrame, to: URL(fileURLWithPath: prefix + "-example-registered.tif"))
        }
        record.stackBlocks.append(block)
    }
    do {
        try checkStop()
        if let target { try approachOutward(target) }
        let held = try focus.snapshot()
        guard !held.isMoving, held.position == record.initialPosition else {
            throw AutofocusError.positionMismatch
        }
        preciseSleep(milliseconds: 1000)
        try camera.startVideo()
        for _ in 0..<3 { _ = try camera.grabFrame(timeoutMs: 5000); try checkStop() }
        let started = Date()
        var lastSave = started
        print("Fixed-focus recording: \(held.position) steps, \(record.exposureMicroseconds) us, gain \(record.gain), \(seconds) s. No focuser movement during capture.")
        if compareStacks { print("Paired 15-frame comparison: median individual HFR, HFR of pixel mean, HFR of centroid-registered pixel mean.") }
        while Date().timeIntervalSince(started) < seconds {
            try checkStop()
            let frame = try camera.grabFrame(timeoutMs: 5000)
            var sample = FocusStabilityFrame(index: record.frames.count,
                timestamp: frame.timestamp.timeIntervalSince1970,
                elapsedSeconds: frame.timestamp.timeIntervalSince(started))
            if let detection = detector.detect(in: frame) {
                sample.peak = detection.peak
                sample.snr = detection.snr
                if detection.peak >= StarQuality.clipADU {
                    sample.rejection = "saturated"
                } else if let metric = estimator.measure(frame: frame, detection: detection) {
                    sample.sensorX = metric.sensorX
                    sample.sensorY = metric.sensorY
                    if anchorX == nil {
                        guard hypot(metric.sensorX - Double(descriptor.sensorWidth - 1) / 2,
                            metric.sensorY - Double(descriptor.sensorHeight - 1) / 2) <= MountGuide.doneRadiusSensorPixels else {
                            throw UIModelExpectation(description: "Detected star is outside the centre-position tolerance.")
                        }
                        anchorX = metric.sensorX; anchorY = metric.sensorY
                    }
                    guard hypot(metric.sensorX - anchorX!, metric.sensorY - anchorY!) < 32 else {
                        throw UIModelExpectation(description: "Centre star moved outside the fixed measurement tolerance.")
                    }
                    sample.hfr = metric.hfr
                    if compareStacks { stackFrames.append((frame, detection.centroid)) }
                } else {
                    sample.rejection = "invalid-metric"
                }
            } else {
                sample.rejection = "no-star"
            }
            record.frames.append(sample)
            if compareStacks, record.frames.count % 15 == 0 { try finishStackBlock() }
            if Date().timeIntervalSince(lastSave) >= 5 {
                try save()
                print(String(format: "%.1f s: %d consecutive frames, %d rejected", sample.elapsedSeconds,
                    record.frames.count, record.frames.filter { $0.hfr == nil }.count))
                lastSave = Date()
            }
        }
        camera.stopVideo()
        let final = try focus.snapshot()
        record.finalPosition = final.position
        record.finalMotorMoving = final.isMoving
        guard !final.isMoving, final.position == record.initialPosition else {
            throw UIModelExpectation(description: "Focuser changed position during fixed-focus recording.")
        }
        guard record.frames.filter({ $0.hfr != nil }).count >= 100 else { throw AutofocusError.noStar }
        if compareStacks, record.stackBlocks.filter({ $0.rejection == nil }).count < 10 {
            throw UIModelExpectation(description: "Too few complete, valid paired 15-frame stacks.")
        }
        if let restore {
            try checkStop()
            try approachOutward(restore)
            let restored = try focus.snapshot()
            record.restoredPosition = restored.position
            record.restoredMotorMoving = restored.isMoving
            guard !restored.isMoving, restored.position == restore else { throw AutofocusError.positionMismatch }
            print("Restored reference position \(restore), stopped")
        }
        record.status = "complete"
        try save()
        print("Fixed-focus recording complete: \(record.frames.count) frames held at \(final.position). Data: \(output.path)")
    } catch {
        record.status = error is CancellationError ? "cancelled" : "failed"
        record.warning = error.localizedDescription
        try? save()
        throw error
    }
}
