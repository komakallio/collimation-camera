import CollimationCore
import Foundation

/// Exercises the same engine as both GUIs, including live tracking, raw HFR,
/// device feedback, preflight, cancellation and diagnostic final HFR.
@MainActor
enum AutofocusCLI {
    private struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func runIfRequested(_ args: [String]) async throws -> Bool {
        guard args.contains("--autofocus"), !args.contains("--help"), !args.contains("-h") else { return false }
        func value(_ flag: String) -> String? {
            guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1),
                  !args[index + 1].hasPrefix("--") else { return nil }
            return args[index + 1]
        }
        guard let port = value("--autofocus"), let cameraID = value("--device"),
              let descriptor = DeviceCatalog.list().first(where: { $0.id == cameraID }), !descriptor.isSimulator else {
            throw Failure(message: "Use --autofocus <port> --device <real camera id> [--focus-step <steps>] [--exposure <ms>].")
        }
        let step = value("--focus-step").flatMap(Int.init) ?? 1000
        let takeUp = value("--focus-take-up").flatMap(Int.init) ?? 4000
        let exposure = value("--exposure").flatMap(Double.init) ?? 20
        guard step > 0, takeUp > 0, exposure.isFinite, (0.1...100).contains(exposure),
              !args.contains("--focus-take-up") || value("--focus-take-up").flatMap(Int.init) != nil,
              !args.contains("--focus-step") || value("--focus-step").flatMap(Int.init) != nil,
              !args.contains("--exposure") || value("--exposure").flatMap(Double.init) != nil else {
            throw Failure(message: "Focus step and take-up must be positive integers; exposure must be 0.1–100 ms.")
        }
        TimerResolution.raise()
        let suite = "collimation-camera.autofocus-cli"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let engine = CollimationEngine(defaults: defaults)
        defer {
            engine.disconnect()
            engine.disconnectFocuser()
            engine.shutdown()
            defaults.removePersistentDomain(forName: suite)
        }
        engine.selectedDeviceID = cameraID
        engine.selectedFocuserPort = port
        engine.autofocusStepSize = step
        engine.autofocusTakeUpSteps = takeUp
        engine.connect()
        // connect() loads the camera's current controls. Apply the requested
        // starting exposure afterwards; autofocus handles any clipping.
        engine.exposureMicroseconds = exposure * 1000
        engine.applyExposure()
        engine.connectFocuser()
        let readyDeadline = Date().addingTimeInterval(20)
        while !engine.isFocuserConnected || engine.tracking.state != .tracking
            || (engine.tracking.detection?.snr ?? 0) < 6 {
            if let error = engine.errorMessage { throw Failure(message: error) }
            guard Date() < readyDeadline else { throw Failure(message: "Camera/focuser did not acquire a tracked star within 20 seconds.") }
            try await Task.sleep(for: .milliseconds(40))
        }
        guard let state = engine.focuserSnapshot else { throw FocuserError.notConnected }
        let plan = try AutofocusPlan(position: state.position, maximum: state.maxPosition, step: step, takeUp: takeUp)
        print("Autofocus hardware: \(descriptor.name), \(state.serialNumber) on \(port)")
        print("Position \(state.position); scan \(plan.positions.first!)–\(plan.positions.last!); inward preload \(plan.preloadPosition); exposure \(exposure) ms")
        guard engine.canAutofocus else {
            throw Failure(message: "Autofocus is unavailable. Check star tracking and the calibrated focuser travel.")
        }
        engine.startAutofocus()
        var progressDeadline = Date().addingTimeInterval(120)
        var lastState = AutofocusState.idle
        while engine.isAutofocusing {
            if engine.autofocusState != lastState {
                lastState = engine.autofocusState
                progressDeadline = Date().addingTimeInterval(120)
                print("Focus: \(lastState)")
            }
            guard Date() < progressDeadline else {
                engine.stopFocuser()
                throw Failure(message: "Autofocus made no progress for two minutes and was stopped.")
            }
            try await Task.sleep(for: .milliseconds(40))
        }
        if let path = value("--focus-output"), let diagnostics = engine.autofocusDiagnostics {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(diagnostics).write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        guard case .complete(let position, let hfr) = engine.autofocusState else {
            throw Failure(message: engine.errorMessage ?? "Autofocus cancelled or failed.")
        }
        let diagnosticHFR = hfr.map { String(format: "%.3f sensor pixels", $0) } ?? "unavailable"
        print(String(format: "Autofocus complete: %d steps, diagnostic HFR %@, exposure %.3f ms, %d saturation restarts, %d scan re-centers",
                     position, diagnosticHFR, engine.exposureMicroseconds / 1000, engine.autofocusExposureRetries, engine.autofocusRecenters))
        if let fit = engine.autofocusDiagnostics?.fit {
            print(String(format: "Fit %@: %d steps, RMS %.3f px, approximate uncertainty %.1f steps, LOO maximum %.1f steps",
                fit.model.rawValue, fit.position, fit.residualRMS, fit.uncertaintySteps, fit.leaveOneOutMaximumSteps))
            print("Downweighted samples: \(fit.downweightedIndices); final diagnostic blocks: \(engine.autofocusDiagnostics?.verification.count ?? 0); unavailable blocks: \(engine.autofocusDiagnostics?.finalMeasurementIssues?.count ?? 0); acceptance: curve fit and stopped target position")
        }
        return true
    }
}
