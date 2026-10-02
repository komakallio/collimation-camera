import CollimationCore
import CollimationUI
import Foundation

/// Opt-in acceptance harness. The normal suite never connects real hardware.
/// Uses the application engine, and writes the same TIFF the UI saves.
@MainActor
func runTiltHardwareIfRequested() async throws -> Bool {
    let args = CommandLine.arguments
    guard args.contains("--tilt-hardware") || args.contains("--tilt-hardware-check") else { return false }
    func value(_ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return nil }
        return args[i + 1]
    }
    guard let cameraID = value("--device"), let focuserPort = value("--focuser-port"), let mountPort = value("--mount-port"),
          let camera = DeviceCatalog.list().first(where: { $0.id == cameraID && !$0.isSimulator }) else {
        throw UIModelExpectation(description: "Specify --device, --focuser-port and --mount-port for hardware acceptance.")
    }
    TimerResolution.raise()
    let suite = "collimation-camera.tests.tilt-hardware.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    let calibration = value("--calibration-file").flatMap { GuideCalibrationStore.load(from: URL(fileURLWithPath: $0)) }
    let engine = CollimationEngine(defaults: defaults, initialCalibration: calibration)
    defer {
        engine.disconnect(); engine.disconnectFocuser(); engine.disconnectMount(); engine.shutdown()
        defaults.removePersistentDomain(forName: suite)
    }
    engine.selectedDeviceID = cameraID
    engine.selectedFocuserPort = focuserPort; engine.selectedSerialPort = mountPort
    engine.autofocusStepSize = value("--focus-step").flatMap(Int.init) ?? 1000
    engine.stackFrameCount = value("--stack-count").flatMap(Int.init) ?? 100
    engine.connect()
    if let exposure = value("--exposure").flatMap(Double.init) {
        engine.exposureMicroseconds = exposure * 1000; engine.applyExposure()
    }
    engine.connectFocuser(); engine.connectMount()
    let ready = Date().addingTimeInterval(30)
    while !engine.isFocuserConnected || !engine.isMountConnected || engine.isFocuserBusy || engine.isMountBusy || engine.tracking.state != .tracking {
        if let error = engine.errorMessage { throw UIModelExpectation(description: error) }
        guard Date() < ready else { throw UIModelExpectation(description: "Hardware did not acquire a tracked star within 30 seconds.") }
        try await Task.sleep(for: .milliseconds(50))
    }
    print("Tilt hardware: \(camera.name) \(cameraID), \(camera.sensorWidth)x\(camera.sensorHeight)")
    print("Focuser \(engine.focuserSnapshot!.serialNumber) on \(focuserPort), position \(engine.focuserSnapshot!.position), moving \(engine.focuserSnapshot!.isMoving)")
    print("Mount \(mountPort): \(engine.mountStatus)")
    print("Star: \(String(describing: engine.tracking.centroidOnSensor)), SNR \(engine.tracking.detection?.snr ?? 0), peak \(engine.tracking.detection?.peak ?? 0)")
    print("Calibration: \(String(describing: engine.guideCalibration))")
    _ = try AutofocusPlan(position: engine.focuserSnapshot!.position, maximum: engine.focuserSnapshot!.maxPosition, step: engine.autofocusStepSize)
    if args.contains("--tilt-hardware-check") { return true }
    guard let path = value("--tilt-output"), engine.canMeasureTilt else {
        throw UIModelExpectation(description: "Tilt unavailable: supply --tilt-output and check star, calibration and focuser limits.")
    }
    engine.startTiltMeasurement(to: URL(fileURLWithPath: path))
    var deadline = Date().addingTimeInterval(120)
    var lastProgress = TiltProgress(), lastFocus = AutofocusState.idle
    let cancelMode = value("--tilt-cancel-test")
    var requestedCancel = false
    while engine.isMeasuringTilt {
        if engine.tiltProgress != lastProgress || engine.autofocusState != lastFocus {
            lastProgress = engine.tiltProgress; lastFocus = engine.autofocusState
            print("\(TiltText.progress(lastProgress)); \(MetricText.autofocus(lastFocus, samples: engine.autofocusSamples.count))")
            deadline = Date().addingTimeInterval(120)
        }
        if !requestedCancel,
           (cancelMode == "focus" && engine.autofocusSamples.count >= 2)
            || (cancelMode == "mount" && engine.tiltProgress.index == 2 && engine.tiltProgress.phase == .moving && engine.mountStatus.hasPrefix("Centering")) {
            requestedCancel = true
            print("Hardware cancellation during \(cancelMode!)")
            engine.cancelTiltMeasurement()
        }
        if Date() >= deadline {
            engine.cancelTiltMeasurement()
            // Await the shared stop and partial-save path before closing ports.
        }
        try await Task.sleep(for: .milliseconds(100))
    }
    guard let report = engine.tiltReport else { throw UIModelExpectation(description: "No hardware report") }
    for line in TiltText.summary(report) { print(line) }
    print("Saved: \(engine.tiltSavedURL?.path ?? "no file")")
    print("Final focuser: \(engine.focuserSnapshot?.position ?? -1), moving: \(engine.focuserSnapshot?.isMoving ?? true)")
    print("Final star: \(String(describing: engine.tracking.centroidOnSensor))")
    if cancelMode != nil {
        try expectUI(requestedCancel && report.status == .cancelled && engine.focuserSnapshot?.isMoving == false,
                     "hardware cancellation stops the sequence and focuser")
        return true
    }
    guard report.status == .complete, report.validOuterCount == 8, report.finalCenter != nil, engine.tiltSavedURL != nil,
          engine.focuserSnapshot?.isMoving == false else {
        throw UIModelExpectation(description: "Hardware acceptance incomplete: \(engine.errorMessage ?? report.warning ?? report.status.rawValue)")
    }
    let reopened = try ConstellationResult.load(from: engine.tiltSavedURL!)
    try expectUI(reopened.tiltReport?.id == report.id, "hardware TIFF round trip")
    return true
}
