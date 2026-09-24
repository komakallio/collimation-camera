import CImGui
#if os(Windows)
import WinSDK
#endif
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

extension Diagnostics {
    nonisolated(unsafe) private static var idConflictsReported = false
    nonisolated(unsafe) private(set) static var sawIDConflict = false

    /// Two widgets that share a label share an identity, so clicking one can
    /// operate the other, and ImGui puts a modal "items with conflicting ID"
    /// dialog over the app. Three sidebar Connect buttons did exactly that.
    ///
    /// Nothing in the shared UI layer can catch this — the labels come from the
    /// command catalogue and are legitimately the same word — so it is checked
    /// here, once per run, against ImGui's own count. `--snapshot` fails on it,
    /// which makes the headless screenshot a regression test for it.
    ///
    /// Call after `igRender`: the count is settled at end of frame.
    static func checkIDConflicts() {
        guard let context = igGetCurrentContext() else { return }
        guard context.pointee.DebugDrawIdConflictsCount > 0 else { return }
        sawIDConflict = true
        guard !idConflictsReported else { return }
        idConflictsReported = true
        Log.info("ImGui reports \(context.pointee.DebugDrawIdConflictsCount) widgets with a conflicting ID; two controls are sharing state")
    }
}

extension Diagnostics {
    /// Times each shutdown step into the log, and kills the process if one of
    /// them never returns.
    ///
    /// Quitting closes the camera, the mount port and the filter wheel, all of
    /// which are vendor calls on hardware that may have been unplugged, and
    /// `CaptureSession.stop` closes the camera even when the capture thread
    /// did not answer in time. A window that has already gone but a process
    /// that is still in the task list is the worst of the outcomes, so this
    /// bounds it: after `seconds` the process ends where it stands. Nothing is
    /// left to lose at that point — the settings are already written and the
    /// log is flushed line by line.
    static func armShutdownWatchdog(seconds: Double = 5) {
        let thread = Thread {
            Thread.sleep(forTimeInterval: seconds)
            Log.info("shutdown did not finish in \(seconds)s; ending the process")
            LogFile.stop()
            terminate()
        }
        thread.stackSize = 64 * 1024
        thread.start()
    }

    /// Ends the process without running exit handlers. `exit` is not safe from
    /// this thread: the hung step may hold a C runtime lock that `exit` would
    /// wait on, which is how it hung in the first place.
    private static func terminate() -> Never {
#if os(Windows)
        TerminateProcess(GetCurrentProcess(), 0)
        // Not reached; TerminateProcess does not return for the calling process.
        while true { Thread.sleep(forTimeInterval: 1) }
#else
        _exit(0)
#endif
    }

    /// Logs how long `body` took, so a slow quit names its own step.
    @discardableResult
    static func step<T>(_ name: String, _ body: () -> T) -> T {
        let started = Date()
        let result = body()
        let elapsed = Date().timeIntervalSince(started)
        if elapsed >= 0.25 {
            Log.info("shutdown: \(name) took \(String(format: "%.2f", elapsed))s")
        }
        return result
    }
}
