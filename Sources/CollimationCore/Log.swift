import Foundation

/// Diagnostic output for the core. The default sink keeps the pre-port
/// behavior — a line on stdout, flushed — so `capture-cli`, `core-tests`, and
/// the macOS app are unchanged. An app that wants a log file sets `sink` once
/// at startup, before any capture, mount, or wheel thread starts.
public enum Log {
    /// Called from the capture, mount, and filter-wheel threads as well as the
    /// main actor. A replacement sink must be safe to call from any thread.
    nonisolated(unsafe) public static var sink: @Sendable (String) -> Void = { message in
        print(message)
        StandardOutput.flush()
    }

    public static func info(_ message: String) {
        sink(message)
    }
}
