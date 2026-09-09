import CSDL3
import CollimationCore
import Foundation

/// SDL's log routing and the startup failure box. The log file itself is
/// `LogFile` in the core, so the macOS app writes the same file in the same
/// format.
///
/// The portable app never calls `fatalError`: with `/SUBSYSTEM:WINDOWS` that
/// aborts with nothing on screen. Anything that fails during startup goes
/// through `fail(_:)`, which writes the reason to the log and shows a native
/// message box first.
enum Diagnostics {
    /// Opens the log and points `Log.sink` at it. Call before `SDL_Init`, so a
    /// failure in SDL itself is already being recorded.
    /// On macOS the SwiftUI app is the release and owns `collimation.log`, and
    /// the two run side by side for the HUD comparison, so this app writes its
    /// own file there. On Windows it is the release, and keeps the plain name.
#if os(macOS)
    static let logBasename = "collimation-portable"
#else
    static let logBasename = LogFile.defaultBasename
#endif

    static func start() {
        let file = LogFile.start(basename: logBasename)
        Log.info("=== Collimation Camera ===")
        Log.info("log: \(file?.path ?? "not opened")")
    }

    static func write(_ message: String) {
        LogFile.write(message)
    }

    static func stop() {
        LogFile.stop()
    }

    /// Routes SDL's own log lines into the same file.
    static func routeSDLLog() {
        SDL_SetLogOutputFunction({ _, category, priority, message in
            guard let message else { return }
            Diagnostics.write("SDL[\(category)/\(priority.rawValue)] \(String(cString: message))")
        }, nil)
    }

    /// Reports a fatal startup problem and exits. `SDL_ShowSimpleMessageBox`
    /// is usable before `SDL_Init` and without a window.
    static func fail(_ step: String, detail: String? = nil) -> Never {
        let reason = detail ?? sdlError()
        Log.info("FATAL \(step): \(reason)")
        let body = "\(step) failed: \(reason)\n\nLog: \(AppPaths.logFile.path)"
        _ = SDL_ShowSimpleMessageBox(
            SDL_MESSAGEBOX_ERROR,
            "Collimation Camera",
            body,
            nil
        )
        stop()
        exit(1)
    }

    static func sdlError() -> String {
        guard let message = SDL_GetError() else { return "unknown error" }
        let text = String(cString: message)
        return text.isEmpty ? "unknown error" : text
    }
}

extension Diagnostics {
    nonisolated(unsafe) private static var lastHeartbeat: Date?

    /// One line a minute while the app runs, so a session that misbehaved
    /// overnight can be read back from the log rather than reconstructed.
    /// Rate, tracking state, ROI, and zoom are the four numbers that answer
    /// "was it working": everything else is already a log line of its own.
    ///
    /// The first line comes a minute in, not on the first frame, so the rate
    /// it reports is a measured one.
    @MainActor
    static func heartbeat(_ engine: CollimationEngine) {
        let now = Date()
        guard let last = lastHeartbeat else {
            lastHeartbeat = now
            return
        }
        guard now.timeIntervalSince(last) >= 60 else { return }
        lastHeartbeat = now
        var line = "fps \(String(format: "%.1f", engine.fps))"
            + "  \(engine.tracking.state.rawValue)"
            + "  zoom \(String(format: "%.2f", engine.zoom))"
        // The frame slot, not the render state: the render state carries an ROI
        // only while stabilization is running.
        if let latest = engine.frameSlot.peek() {
            let roi = latest.frame.roi
            line += "  roi \(roi.width)x\(roi.height) bin\(roi.binning) at \(roi.x),\(roi.y)"
        }
        Log.info(line)
    }
}
