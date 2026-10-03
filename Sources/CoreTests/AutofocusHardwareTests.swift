import CollimationCore
import Foundation

private struct FocusHardwareAttempt: Codable {
    let policy: String
    let startPosition: Int
    let startedAt: Date
    var duration: Double = 0
    var result: AutofocusResult?
    var diagnostics: AutofocusDiagnostics?
    var error: String?
}

private struct FocusHardwareRecord: Codable {
    let cameraID: String
    let cameraName: String
    let initialPosition: Int
    let maximum: Int
    let step: Int
    let takeUp: Int
    let halfSpan: Int
    var roi = 512
    var status = "running"
    var reference: Int?
    var referenceAttempt: FocusHardwareAttempt?
    var attempts: [FocusHardwareAttempt] = []
    var mountBefore: [String] = []
    var mountAfter: [String] = []
    var restoredPosition: Int?
    var restoredMoving: Bool?
    var warning: String?
}

/// Acquisition adapter only: the shared engine owns every autofocus operation.
/// Fixing a centre ROI lets old/new trials use the same sensor pixels.
private final class FocusHardwareCamera: CameraDevice {
    let base: any CameraDevice
    init(_ base: any CameraDevice) { self.base = base }
    var descriptor: CameraDescriptor { base.descriptor }
    var controls: CameraControls { base.controls }
    var currentROI: ROI { base.currentROI }
    var supportedBins: [Int] { base.supportedBins }
    var roiAlignment: ROIAlignment { base.roiAlignment }
    func open() throws { try base.open() }
    func close() { base.close() }
    func applyExposure(_ value: Int) throws { try base.applyExposure(value) }
    func applyGain(_ value: Int) throws { try base.applyGain(value) }
    func applyROI(_ roi: ROI) throws {
        try base.applyROI(Alignment.centeredROI(around: SIMD2(Double(descriptor.sensorWidth) / 2,
            Double(descriptor.sensorHeight) / 2), size: 512, sensorWidth: descriptor.sensorWidth,
            sensorHeight: descriptor.sensorHeight, alignment: roiAlignment))
    }
    func startVideo() throws { try base.startVideo() }
    func stopVideo() { base.stopVideo() }
    func grabFrame(timeoutMs: Int) throws -> Frame { try base.grabFrame(timeoutMs: timeoutMs) }
    func cancelGrab() { base.cancelGrab() }
    func applyFrameLimit(_ value: Int) { base.applyFrameLimit(value) }
    func isStillPresent() -> Bool { base.isStillPresent() }
}

@MainActor
func runAutofocusHardwareIfRequested() async throws -> Bool {
    let args = CommandLine.arguments
    guard args.contains("--autofocus-repeatability") || args.contains("--autofocus-preflight") else { return false }
    func value(_ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return nil }
        return args[i + 1]
    }
    guard let cameraID = value("--device"), let focusPort = value("--focuser-port"),
          let mountPort = value("--mount-port"), let outputPath = value("--focus-output"),
          let descriptor = DeviceCatalog.list().first(where: { $0.id == cameraID && !$0.isSimulator }),
          descriptor.name.lowercased().contains("xena"), descriptor.name.contains("585") else {
        throw UIModelExpectation(description: "Supply the Xena585 camera ID, focuser and mount ports, and --focus-output.")
    }
    let step = value("--focus-step").flatMap(Int.init) ?? 1000
    let takeUp = value("--focus-take-up").flatMap(Int.init) ?? 4000
    let halfSpan = value("--half-span").flatMap(Int.init) ?? 2500
    let trials = value("--trials").flatMap(Int.init) ?? 10
    let exposure = value("--exposure").flatMap(Double.init) ?? 0.5
    guard (1...10000).contains(step), (1...20000).contains(takeUp), (1...10000).contains(halfSpan),
          (10...30).contains(trials), exposure.isFinite, (0.1...100).contains(exposure) else { throw AutofocusError.invalidRange }
    let output = URL(fileURLWithPath: outputPath), stop = outputPath + ".stop"
    func checkStop() throws {
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: stop) { throw CancellationError() }
    }
    TimerResolution.raise()
    let port = PlatformSerialPort(), mount = EQ6Mount(port: PlatformSerialPort())
    // Initialise and stop through the native mount driver, then read status on
    // an exclusive serial handle. No competing engine owns the mount port.
    try await Task.detached { try mount.connect(path: mountPort); mount.haltMotions(); mount.disconnect() }.value
    try await Task.detached { try port.open(path: mountPort, baud: 9600) }.value
    defer { port.close() }
    func mountStatus() async throws -> [String] {
        try await Task.detached {
            var result: [String] = []
            for command in [":f1\r", ":f2\r", ":j1\r", ":j2\r"] {
                try port.writeASCII(command)
                let data = try port.readUntil(terminator: 13, timeout: 2)
                let text = String(data: data, encoding: .ascii)!.trimmingCharacters(in: .whitespacesAndNewlines)
                guard text.hasPrefix("=") else { throw MountError.protocolFailure(text) }
                result.append(text)
            }
            for status in result.prefix(2) {
                let characters = Array(status.dropFirst())
                guard characters.count == 3, let flags = Int(String(characters[1]), radix: 16), flags & 1 == 0 else {
                    throw UIModelExpectation(description: "Mount axis is moving: \(status)")
                }
            }
            return result
        }.value
    }
    let before = try await mountStatus()
    try await Task.sleep(for: .seconds(2))
    try expectUI(try await mountStatus() == before, "stopped mount counters stable before autofocus")
    let probe = EsattoFocuser()
    let initial = try await Task.detached { let state = try probe.connect(path: focusPort); probe.disconnect(); return state }.value
    guard !initial.isMoving else { throw AutofocusError.positionMismatch }
    _ = try AutofocusPlan(position: initial.position, maximum: initial.maxPosition, step: step, takeUp: takeUp)
    var record = FocusHardwareRecord(cameraID: cameraID, cameraName: descriptor.name,
        initialPosition: initial.position, maximum: initial.maxPosition, step: step, takeUp: takeUp, halfSpan: halfSpan)
    record.mountBefore = before
    func save() throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: output, options: .atomic)
    }
    try save()
    print("Preflight: \(descriptor.name) \(cameraID), COM focus \(focusPort): \(initial.position)/\(initial.maxPosition), stopped; mount \(before)")
    if args.contains("--autofocus-preflight") { record.status = "preflight"; try save(); return true }

    func attempt(policy: AutofocusComparisonPolicy, startPosition: Int) async throws -> FocusHardwareAttempt {
        try checkStop()
        let suite = "autofocus-hardware.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let engine = CollimationEngine(defaults: defaults,
            cameraFactory: { _ in FocusHardwareCamera(try DeviceCatalog.makeDevice(id: cameraID)) },
            autofocusComparisonPolicy: policy)
        defer {
            engine.disconnect(); engine.disconnectFocuser(); engine.shutdown()
            defaults.removePersistentDomain(forName: suite)
        }
        engine.selectedDeviceID = cameraID; engine.selectedFocuserPort = focusPort
        engine.autofocusStepSize = step; engine.autofocusTakeUpSteps = takeUp
        engine.connect(); engine.exposureMicroseconds = exposure * 1000; engine.applyExposure()
        engine.gain = 0; engine.applyGain(); engine.connectFocuser()
        let ready = Date().addingTimeInterval(30)
        while !engine.isFocuserConnected || engine.isFocuserBusy || engine.tracking.state != .tracking {
            try checkStop()
            if let error = engine.errorMessage { throw UIModelExpectation(description: error) }
            guard Date() < ready else { throw AutofocusError.noStar }
            try await Task.sleep(for: .milliseconds(40))
        }
        // Starting positions are also reached through the measured 4000-step
        // approach, independent of the policy subsequently being compared.
        for position in try AutofocusPlan.approach(target: startPosition, maximum: initial.maxPosition, takeUp: takeUp) {
            try checkStop(); engine.focuserTargetPosition = position; engine.gotoFocuser()
            let deadline = Date().addingTimeInterval(60)
            while engine.isFocuserBusy || engine.focuserSnapshot?.isMoving != false || engine.focuserSnapshot?.position != position {
                do { try checkStop() } catch { engine.stopFocuser(); throw error }
                guard Date() < deadline else { engine.stopFocuser(); throw AutofocusError.motionTimeout }
                try await Task.sleep(for: .milliseconds(40))
            }
        }
        var attempt = FocusHardwareAttempt(policy: policy == .legacy ? "legacy" : "production", startPosition: startPosition, startedAt: Date())
        engine.startAutofocus()
        let deadline = Date().addingTimeInterval(600)
        while engine.isAutofocusing {
            do { try checkStop() } catch { engine.stopFocuser(); throw error }
            if Date() > deadline { engine.stopFocuser(); attempt.error = "600-second attempt timeout"; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        attempt.duration = Date().timeIntervalSince(attempt.startedAt)
        attempt.result = engine.autofocusResult; attempt.diagnostics = engine.autofocusDiagnostics
        if attempt.result == nil { attempt.error = engine.errorMessage ?? attempt.error ?? "Autofocus unavailable or cancelled" }
        print("\(attempt.policy) from \(startPosition): \(attempt.result.map { String($0.position) } ?? attempt.error!), \(attempt.duration) s")
        return attempt
    }
    do {
        record.referenceAttempt = try await attempt(policy: .production, startPosition: initial.position)
        try save()
        guard let reference = record.referenceAttempt?.result?.position else { throw AutofocusError.unstableFit }
        record.reference = reference
        let low = reference - halfSpan, high = reference + halfSpan
        for position in [low, high] {
            _ = try AutofocusPlan(position: position, maximum: initial.maxPosition, step: step, takeUp: takeUp)
        }
        for pair in 0..<trials {
            let startPosition = pair % 2 == 0 ? low : high
            let order: [AutofocusComparisonPolicy] = args.contains("--production-only") ? [.production]
                : (pair / 2) % 2 == 0 ? [.legacy, .production] : [.production, .legacy]
            for policy in order {
                let attempt = try await attempt(policy: policy, startPosition: startPosition)
                record.attempts.append(attempt); try save()
                try expectUI(try await mountStatus() == before, "mount axes and counters unchanged during autofocus")
            }
        }
        try checkStop()
        // Restoration uses the native focuser on one worker, with the same
        // outward approach and exact-position/idle confirmation. Never on cancel.
        let restored = try await Task.detached {
            let device = EsattoFocuser(); _ = try device.connect(path: focusPort)
            defer { device.disconnect() }
            for position in try AutofocusPlan.approach(target: reference, maximum: initial.maxPosition, takeUp: takeUp) {
                if FileManager.default.fileExists(atPath: stop) { _ = try? device.stop(); throw CancellationError() }
                _ = try device.move(to: position)
                let deadline = Date().addingTimeInterval(60)
                while true {
                    if FileManager.default.fileExists(atPath: stop) { _ = try? device.stop(); throw CancellationError() }
                    let state = try device.snapshot()
                    if !state.isMoving { guard state.position == position else { throw AutofocusError.positionMismatch }; break }
                    guard Date() < deadline else { _ = try? device.stop(); throw AutofocusError.motionTimeout }
                    preciseSleep(milliseconds: 50)
                }
            }
            return try device.snapshot()
        }.value
        record.restoredPosition = restored.position; record.restoredMoving = restored.isMoving
        record.mountAfter = try await mountStatus()
        try await Task.sleep(for: .seconds(2))
        try expectUI(try await mountStatus() == before && record.mountAfter == before, "final stopped mount counters unchanged")
        record.status = "complete"; try save()
    } catch {
        record.status = error is CancellationError ? "cancelled" : "failed"
        record.warning = error.localizedDescription; try save(); throw error
    }
    return true
}
