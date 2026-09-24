import Foundation
import POACameraC

/// Player One Phoenix filter wheel (PW5 / PW7 / PW8) over `libPlayerOnePW`.
public final class PhoenixWheel: @unchecked Sendable {
    public static var sdkVersion: String? { POAPWNative.shared?.sdkVersion }

    private let lock = NSLock()
    /// Held across every SDK call, and across the close.
    ///
    /// `disconnect` used to close the handle while a detached goto or snapshot
    /// was inside a call with it. The poll loop checks `cancelled` between
    /// calls but not during one, so the SDK could be handed a handle that had
    /// just been closed underneath it. Every call here is short — the waiting
    /// is done by sleeping between them, not inside them — so a close waits for
    /// one call at most, which is what makes this safe to hold rather than a
    /// second way to freeze the app.
    private let sdkLock = NSLock()
    private var handle: Int32?
    private var name = ""
    private var positionCount = 0
    private var cancelled = false

    /// Serializes one SDK call against `close`.
    private func withSDK<T>(_ body: () throws -> T) rethrows -> T {
        sdkLock.lock()
        defer { sdkLock.unlock() }
        return try body()
    }

    public var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return handle != nil
    }

    public func enumerate() -> [FilterWheelDescriptor] {
        POAPWNative.shared?.enumerate() ?? []
    }

    public func connect(handle requested: Int32) throws {
        guard let native = POAPWNative.shared else { throw FilterWheelError.sdkNotFound }
        disconnect()
        let wheels = native.enumerate()
        guard let descriptor = wheels.first(where: { $0.handle == requested }) else {
            throw FilterWheelError.noWheelSelected
        }
        Log.info("Phoenix FW open handle=\(descriptor.handle) \(descriptor.name)")
        try withSDK { try native.open(descriptor.handle) }
        lock.lock()
        cancelled = false
        handle = descriptor.handle
        name = descriptor.name
        positionCount = max(descriptor.positionCount, 1)
        lock.unlock()
        withSDK { native.setBidirectional(descriptor.handle) }
        do {
            _ = try waitUntilSettled(native: native, handle: descriptor.handle, timeout: 12)
        } catch {
            disconnect()
            throw error
        }
    }

    public func disconnect() {
        lock.lock()
        cancelled = true
        let existing = handle
        handle = nil
        name = ""
        positionCount = 0
        lock.unlock()
        if let existing, let native = POAPWNative.shared {
            withSDK { native.close(existing) }
            Log.info("Phoenix FW close handle=\(existing)")
        }
    }

    public func goto(position: Int) throws {
        guard let native = POAPWNative.shared else { throw FilterWheelError.sdkNotFound }
        let (handle, count) = try connectedHandle()
        guard position >= 0, position < count else { throw FilterWheelError.invalidPosition }
        if let current = try? withSDK({ try native.position(handle) }), current == position {
            return
        }
        Log.info("Phoenix FW goto \(position)")
        try withSDK { try native.goto(handle, position: position) }
        let settled = try waitUntilSettled(native: native, handle: handle, timeout: 30)
        if settled != position {
            throw FilterWheelError.timeout
        }
    }

    public func snapshot() throws -> FilterWheelSnapshot {
        guard let native = POAPWNative.shared else { throw FilterWheelError.sdkNotFound }
        let (handle, count) = try connectedHandle()
        let wheelName: String = {
            lock.lock()
            defer { lock.unlock() }
            return name
        }()
        let state = try withSDK { try native.state(handle) }
        let moving = state == PW_STATE_MOVING
        let position: Int?
        if moving {
            position = nil
        } else if let value = try? withSDK({ try native.position(handle) }) {
            position = value
        } else {
            position = nil
        }
        let slots = (0..<count).map { index in
            FilterSlot(position: index, alias: withSDK { native.alias(handle, position: index) })
        }
        return FilterWheelSnapshot(name: wheelName, position: position, moving: moving, slots: slots)
    }

    private func connectedHandle() throws -> (Int32, Int) {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { throw FilterWheelError.notConnected }
        return (handle, positionCount)
    }

    private func waitUntilSettled(native: POAPWNative, handle: Int32, timeout: TimeInterval) throws -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        var resetAttempted = false
        while Date() < deadline {
            lock.lock()
            let cancelled = self.cancelled
            let stillOpen = self.handle == handle
            lock.unlock()
            if cancelled || !stillOpen { throw CancellationError() }

            let state: PWState
            do {
                state = try withSDK { try native.state(handle) }
            } catch FilterWheelError.disconnected {
                throw FilterWheelError.disconnected
            }
            if state == PW_STATE_CLOSED {
                throw FilterWheelError.disconnected
            }
            if state == PW_STATE_MOVING {
                preciseSleep(microseconds: 80_000)
                continue
            }
            do {
                let position = try withSDK { try native.position(handle) }
                Log.info("Phoenix FW position \(position)")
                return position
            } catch FilterWheelError.moving {
                preciseSleep(microseconds: 80_000)
            } catch FilterWheelError.firmware where !resetAttempted {
                Log.info("Phoenix FW firmware error — resetting")
                withSDK { native.reset(handle) }
                resetAttempted = true
                preciseSleep(microseconds: 200_000)
            }
        }
        throw FilterWheelError.timeout
    }
}
