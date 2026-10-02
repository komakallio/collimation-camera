import CollimationCore
import Foundation

private final class GatedMountPort: SerialPortDriver, @unchecked Sendable {
    let base = skyWatcherScript()
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var gate = false
    var isOpen: Bool { base.isOpen }
    func gateNextRead() { lock.withLock { gate = true } }
    func open(path: String, baud: Int) throws { try base.open(path: path, baud: baud) }
    func close() { base.close() }
    func flush() { base.flush() }
    func write(_ data: Data) throws {
        // The connection script covers inquiries and stops. This fixture also
        // acknowledges the motor configuration and start used by a real slew.
        if data.count > 1, [UInt8(ascii: "G"), UInt8(ascii: "I"), UInt8(ascii: "J")].contains(data[1]) {
            base.answer(data, with: Data("=\r".utf8))
        }
        try base.write(data)
    }
    func readUntil(terminator: UInt8, timeout: TimeInterval, maxBytes: Int) throws -> Data {
        let blocked = lock.withLock { let value = gate; gate = false; return value }
        if blocked { entered.signal(); _ = release.wait(timeout: .now() + 5) }
        return try base.readUntil(terminator: terminator, timeout: timeout, maxBytes: maxBytes)
    }
}

@MainActor
func testMountQueuedCancellation() async throws {
    let port = GatedMountPort(), mount = EQ6Mount(port: port)
    try mount.connect(path: "SCRIPT")
    defer { port.release.signal(); mount.disconnect() }
    port.gateNextRead()
    let first = Task.detached { try await mount.applyNudge(SlewNudge(ra: .east, dec: nil, siderealMultiple: 8)) }
    let deadline = Date().addingTimeInterval(3)
    while port.entered.wait(timeout: .now()) != .success {
        guard Date() < deadline else { throw UIModelExpectation(description: "mount queue gate did not enter") }
        try await Task.sleep(for: .milliseconds(10))
    }
    let queued = Task.detached { try await mount.applyNudge(SlewNudge(ra: .west, dec: nil, siderealMultiple: 8)) }
    try await Task.sleep(for: .milliseconds(30))
    queued.cancel()
    port.release.signal()
    try await first.value
    do {
        try await queued.value
        throw UIModelExpectation(description: "cancelled queued slew started")
    } catch is CancellationError { }
    try expectUI(port.base.writtenASCII.filter { $0 == ":J1\\r" }.count == 1,
                 "cancelled mount work sends no second start command")
}
