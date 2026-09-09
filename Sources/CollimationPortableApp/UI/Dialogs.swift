import CSDL3
import CollimationCore
import CollimationUI
import Foundation

/// The portable `UIHost`: SDL's native save dialog, plus the error modal.
///
/// SDL runs the callback on a worker thread on Windows and on the main thread
/// on macOS, so the result is parked and consumed by the main loop rather than
/// touching the engine from whatever thread called back. The filter array must
/// outlive the call, hence the static storage.
@MainActor
final class PortableUIHost: UIHost {
    private var dialogOpen = false
    private var pending: ((URL?) -> Void)?

    /// SDL runs the dialog callback on a worker thread on Windows, so the
    /// result is parked in a nonisolated box and picked up by the main loop.
    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: URL??

        func set(_ url: URL?) {
            lock.lock()
            value = .some(url)
            lock.unlock()
        }

        func take() -> URL?? {
            lock.lock()
            defer { lock.unlock() }
            let current = value
            value = nil
            return current
        }
    }

    private let box = ResultBox()

    /// SDL keeps the filter strings for as long as the dialog is open, so they
    /// are leaked deliberately. `strdup` is spelled `_strdup` on Windows, so
    /// this copies the bytes itself rather than picking a name per platform.
    private static func staticCString(_ text: String) -> UnsafePointer<CChar> {
        let bytes = Array(text.utf8CString)
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
        buffer.update(from: bytes, count: bytes.count)
        return UnsafePointer(buffer)
    }

    private static let filters: [SDL_DialogFileFilter] = [
        SDL_DialogFileFilter(name: staticCString("TIFF image"), pattern: staticCString("tif;tiff")),
        SDL_DialogFileFilter(name: staticCString("All files"), pattern: staticCString("*")),
    ]

    nonisolated(unsafe) private static var active: PortableUIHost?

    func presentSaveDialog(
        title: String,
        message: String,
        suggestedName: String,
        directory: URL?,
        completion: @escaping @MainActor (URL?) -> Void
    ) {
        // A second command while a dialog is open is ignored, so a repeated
        // shortcut cannot stack two dialogs.
        guard !dialogOpen else { return }
        dialogOpen = true
        pending = completion
        Self.active = self
        Log.info("save dialog: \(title) — \(message)")

        let start = directory?.appendingPathComponent(suggestedName).path ?? suggestedName
        start.withCString { location in
            Self.filters.withUnsafeBufferPointer { buffer in
                SDL_ShowSaveFileDialog(
                    { userdata, files, _ in
                        var chosen: URL?
                        if let files, let first = files.pointee {
                            chosen = URL(fileURLWithPath: String(cString: first))
                        }
                        _ = userdata
                        PortableUIHost.active?.deliver(chosen)
                    },
                    nil,
                    nil,
                    buffer.baseAddress,
                    Int32(buffer.count),
                    location
                )
            }
        }
    }

    /// Called from SDL's thread on Windows; only parks the value.
    nonisolated private func deliver(_ url: URL?) {
        box.set(url)
    }

    /// Drained once per frame by the main loop, on the main actor.
    func pumpDialogResult() {
        guard let value = box.take() else { return }
        let completion = pending
        pending = nil
        dialogOpen = false
        completion?(value)
    }
}
