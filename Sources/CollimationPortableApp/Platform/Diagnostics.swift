import CSDL3
import CollimationCore
import Foundation

/// The log file, SDL's log routing, and the startup failure box.
///
/// The portable app never calls `fatalError`: with `/SUBSYSTEM:WINDOWS` that
/// aborts with nothing on screen. Anything that fails during startup goes
/// through `fail(_:)`, which writes the reason to the log and shows a native
/// message box first.
enum Diagnostics {
    nonisolated(unsafe) private static var handle: FileHandle?
    private static let lock = NSLock()
    nonisolated(unsafe) private static var formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    /// Opens the log and points `Log.sink` at it. Call before `SDL_Init`, so a
    /// failure in SDL itself is already being recorded.
    static func start() {
        let directory = AppPaths.logDirectory
        let file = AppPaths.logFile
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)

        // One generation of history, so a crash report still has the run
        // before it.
        let previous = directory.appendingPathComponent("collimation.log.1")
        if manager.fileExists(atPath: file.path) {
            try? manager.removeItem(at: previous)
            try? manager.moveItem(at: file, to: previous)
        }
        _ = manager.createFile(atPath: file.path, contents: nil)
        handle = try? FileHandle(forWritingTo: file)

        Log.sink = { message in
            Diagnostics.write(message)
        }
        Log.info("=== Collimation Camera ===")
        Log.info("log: \(file.path)")
    }

    /// Safe from any thread: the capture, mount, and wheel threads all log.
    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date()))  \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        if let handle, let data = line.data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
        FileHandle.standardOutput.write(Data(line.utf8))
    }

    static func stop() {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.close()
        handle = nil
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

