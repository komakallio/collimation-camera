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
    private static let formatter: DateFormatter = {
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

    /// How many concurrent instances get a log of their own before giving up.
    private static let instanceLimit = 8

    /// Rotates the previous run's file aside, opens a new one, and points
    /// `Log.sink` at it. Call once, as early as possible: a failure during
    /// startup is exactly what the file is for.
    ///
    /// Returns the file's URL, or nil when nothing could be opened — the caller
    /// keeps running either way, with the default sink.
    ///
    /// A second instance does not fight the first for the file. On Windows a
    /// file another process holds open can neither be renamed nor re-created,
    /// and the old version of this did both blind, with `try?` over each: the
    /// rotation failed, `createFile` failed, `start` returned nil, and the
    /// second instance logged **nothing at all** — while having already deleted
    /// the previous generation on the way in. That is how a mount session came
    /// to leave no trace: the app was the second instance, and a log that is
    /// only missing when two things are running is missing exactly when it is
    /// most wanted. Now a second instance takes `<basename>-2.log` and the
    /// first keeps writing to its own.
    @discardableResult
    public static func start(
        basename: String = defaultBasename,
        in directory: URL = LogFile.directory
    ) -> URL? {
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        rotate(basename: basename, in: directory, manager: manager)

        for candidate in candidates(basename: basename, in: directory) {
            // Both calls fail rather than truncate when another process holds
            // the file, which is what makes this a working instance check.
            guard manager.createFile(atPath: candidate.path, contents: nil),
                  let opened = try? FileHandle(forWritingTo: candidate) else {
                continue
            }
            lock.lock()
            try? handle?.close()
            handle = opened
            lock.unlock()

            Log.sink = { message in LogFile.write(message) }
            return candidate
        }
        return nil
    }

    /// The primary file first, then one per additional instance.
    private static func candidates(basename: String, in directory: URL) -> [URL] {
        [directory.appendingPathComponent(name(basename))]
            + (2...instanceLimit).map {
                directory.appendingPathComponent("\(basename)-\($0).log")
            }
    }

    /// Moves this run's file aside, keeping one generation.
    ///
    /// Staged through a third name so a rotation that cannot happen — another
    /// instance is holding the file — leaves the previous generation where it
    /// is. Deleting it first and then discovering the move fails threw away the
    /// run before it for nothing, which is the opposite of the point.
    private static func rotate(basename: String, in directory: URL, manager: FileManager) {
        let file = directory.appendingPathComponent(name(basename))
        guard manager.fileExists(atPath: file.path) else { return }
        let previous = directory.appendingPathComponent(previousName(basename))
        let staging = directory.appendingPathComponent("\(basename).log.rotating")
        try? manager.removeItem(at: staging)
        do {
            try manager.moveItem(at: file, to: staging)
        } catch {
            return
        }
        try? manager.removeItem(at: previous)
        try? manager.moveItem(at: staging, to: previous)
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
