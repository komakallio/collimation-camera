import Foundation

/// Drops intermediate frames so analysis never stalls the grab loop.
final class FrameCoalescer: @unchecked Sendable {
    private let lock = NSLock()
    private let queue: DispatchQueue
    private var latest: Frame?
    private var running = false
    var handler: ((Frame) -> Void)?

    init(label: String) {
        self.queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    func submit(_ frame: Frame) {
        lock.lock()
        latest = frame
        if running {
            lock.unlock()
            return
        }
        running = true
        lock.unlock()
        queue.async { [weak self] in
            self?.drain()
        }
    }

    func cancel() {
        lock.lock()
        latest = nil
        running = false
        lock.unlock()
    }

    private func drain() {
        while true {
            lock.lock()
            guard let frame = latest else {
                running = false
                lock.unlock()
                return
            }
            latest = nil
            lock.unlock()
            handler?(frame)
        }
    }
}
