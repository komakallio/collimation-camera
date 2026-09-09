import Foundation

/// The log file both apps write, and where it goes on each platform.
///
/// `Log.sink` prints by default, which is enough for `swift run` and for
/// `capture-cli`. It is not enough for either app: a Windows release build is
/// a GUI subsystem image with no standard output at all, and a macOS bundle's
/// output goes wherever the launcher put it. A file is what a person can send
/// after a session went wrong, so both apps point the sink here.
///
/// Writes are serialized and safe from any thread — the capture, mount, and
/// filter-wheel threads all log.
public enum LogFile {
    /// The file the release build on each platform writes. On macOS the two
    /// apps can run side by side — that is what the HUD comparison needs — so
    /// the portable app passes a name of its own there rather than fighting
    /// over this one.
    public static let defaultBasename = "collimation"

    public static func name(_ basename: String = defaultBasename) -> String {
        "\(basename).log"
    }

    /// One generation of history, so a crash still has the run before it.
    public static func previousName(_ basename: String = defaultBasename) -> String {
        "\(basename).log.1"
    }

    nonisolated(unsafe) private static var handle: FileHandle?
    private static let lock = NSLock()
    nonisolated(unsafe) private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    /// `~/Library/Logs/Collimation Camera` on macOS, and the same directory
    /// the guide calibration uses elsewhere — `%LOCALAPPDATA%\Collimation
    /// Camera` on Windows.
    public static var directory: URL {
        let manager = FileManager.default
#if os(macOS)
        let base = manager.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return base.appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Collimation Camera", isDirectory: true)
#else
        let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return base.appendingPathComponent("Collimation Camera", isDirectory: true)
#endif
    }

    public static func url(_ basename: String = defaultBasename) -> URL {
        directory.appendingPathComponent(name(basename))
    }

    /// Rotates the previous run's file aside, opens a new one, and points
    /// `Log.sink` at it. Call once, as early as possible: a failure during
    /// startup is exactly what the file is for.
    ///
    /// Returns the file's URL, or nil when it could not be opened — the caller
    /// keeps running either way, with the default sink.
    @discardableResult
    public static func start(
        basename: String = defaultBasename,
        in directory: URL = LogFile.directory
    ) -> URL? {
        let manager = FileManager.default
        let file = directory.appendingPathComponent(name(basename))
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)

        let previous = directory.appendingPathComponent(previousName(basename))
        if manager.fileExists(atPath: file.path) {
            try? manager.removeItem(at: previous)
            try? manager.moveItem(at: file, to: previous)
        }
        guard manager.createFile(atPath: file.path, contents: nil),
              let opened = try? FileHandle(forWritingTo: file) else {
            return nil
        }

        lock.lock()
        try? handle?.close()
        handle = opened
        lock.unlock()

        Log.sink = { message in LogFile.write(message) }
        return file
    }

    public static func write(_ message: String) {
        let now = Date()
        lock.lock()
        defer { lock.unlock() }
        // Inside the lock: DateFormatter is not safe to use from two threads,
        // and the capture, mount, and filter-wheel threads all log.
        let line = "\(formatter.string(from: now))  \(message)\n"
        if let handle, let data = line.data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
        // A GUI subsystem process on Windows has no standard output, and the
        // trapping `write(_:)` would abort on the first line, so this has to be
        // the throwing call.
        try? FileHandle.standardOutput.write(contentsOf: Data(line.utf8))
    }

    public static func stop() {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.close()
        handle = nil
    }
}
