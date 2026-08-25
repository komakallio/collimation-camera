import Foundation

final class FPSMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var stamps: [TimeInterval] = []
    private var last: Double = 0

    func tick() -> Double {
        let now = Date().timeIntervalSinceReferenceDate
        lock.lock()
        stamps.append(now)
        stamps.removeAll { now - $0 > 1 }
        last = Double(stamps.count)
        let value = last
        lock.unlock()
        return value
    }

    var current: Double {
        lock.lock()
        defer { lock.unlock() }
        return last
    }
}
