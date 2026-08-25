import Darwin
import Foundation

public protocol PulseGuider: AnyObject, Sendable {
    func pulse(_ direction: GuideDirection, milliseconds: Int) async throws
}

public enum EQ6Protocol: String, Equatable, Sendable {
    case lx200 = "LX200 pulse guide"
    case synScan = "SynScan"
    case skyWatcher = "EQDIR motor"
}

/// EQ6 pulse-guide client. Auto-detects SynScan handset, LX200 `:Mg`, or SkyWatcher motor (EQDIR).
public final class EQ6Mount: PulseGuider, @unchecked Sendable {
    private let lock = NSLock()
    private let port = SerialPort()
    private var proto: EQ6Protocol?
    private var siderealPeriod = 0

    public var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return proto != nil && port.isOpen
    }

    public var protocolName: String {
        lock.lock()
        defer { lock.unlock() }
        return proto?.rawValue ?? "Disconnected"
    }

    public func connect(path: String, baud: Int = 9600) throws {
        lock.lock()
        defer { lock.unlock() }
        proto = nil
        siderealPeriod = 0
        let speed: speed_t = baud == 115200 ? speed_t(B115200) : speed_t(B9600)
        do {
            try port.open(path: path, baud: speed)
        } catch {
            throw MountError.openFailed(path)
        }
        usleep(80_000)
        port.flush()

        if probeSkyWatcherLocked() {
            try initializeSkyWatcherLocked()
            proto = .skyWatcher
            try stopTrackingLocked()
            return
        }
        port.flush()
        if probeSynScanLocked() {
            proto = .synScan
            try stopTrackingLocked()
            return
        }
        port.flush()
        if probeLX200Locked() {
            proto = .lx200
            try stopTrackingLocked()
            return
        }
        port.close()
        throw MountError.unrecognized
    }

    public func disconnect() {
        lock.lock()
        defer { lock.unlock() }
        port.close()
        proto = nil
        siderealPeriod = 0
    }

    public func pulse(_ direction: GuideDirection, milliseconds: Int) async throws {
        let ms = max(0, milliseconds)
        guard ms > 0 else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                do {
                    try self.pulseSync(direction, milliseconds: ms)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func pulseSync(_ direction: GuideDirection, milliseconds: Int) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let proto else { throw MountError.notConnected }
        switch proto {
        case .lx200:
            try pulseLX200Locked(direction, milliseconds: milliseconds)
        case .synScan:
            try pulseSynScanLocked(direction, milliseconds: milliseconds)
        case .skyWatcher:
            try pulseSkyWatcherLocked(direction, milliseconds: milliseconds)
        }
    }

    private func pulseLX200Locked(_ direction: GuideDirection, milliseconds: Int) throws {
        try port.writeASCII(LX200PulseGuide.command(direction, milliseconds: milliseconds))
        _ = try readHashLocked(timeout: 2)
        usleep(UInt32(milliseconds + 40) * 1000)
    }

    private func pulseSynScanLocked(_ direction: GuideDirection, milliseconds: Int) throws {
        try port.write(SynScanGuide.fixedRateCommand(direction: direction, rate: 1))
        _ = try readHashLocked(timeout: 2)
        usleep(UInt32(milliseconds) * 1000)
        try port.write(SynScanGuide.fixedRateCommand(direction: direction, rate: 0))
        _ = try readHashLocked(timeout: 2)
        usleep(40_000)
    }

    private func pulseSkyWatcherLocked(_ direction: GuideDirection, milliseconds: Int) throws {
        let axis: Int
        let forward: Bool
        switch direction {
        case .east:
            axis = 1
            forward = true
        case .west:
            axis = 1
            forward = false
        case .north:
            axis = 2
            forward = true
        case .south:
            axis = 2
            forward = false
        }

        try skyCommandLocked("G", axis: axis, data: forward ? "10" : "11")
        let period = max(siderealPeriod, 6)
        try skyCommandLocked("I", axis: axis, data: SkyWatcherEncoding.hex24(period))
        try skyCommandLocked("J", axis: axis, data: "")
        usleep(UInt32(milliseconds) * 1000)
        try skyCommandLocked("K", axis: axis, data: "")
        usleep(40_000)
    }

    private func probeSkyWatcherLocked() -> Bool {
        do {
            try port.writeASCII(":e1\r")
            let response = try port.readUntil(terminator: 0x0D, timeout: 0.8)
            return response.first == UInt8(ascii: "=")
        } catch {
            return false
        }
    }

    private func probeSynScanLocked() -> Bool {
        do {
            try port.write(Data([UInt8(ascii: "K"), 0x55]))
            let response = try port.readUntil(terminator: UInt8(ascii: "#"), timeout: 0.8)
            return response.contains(0x55)
        } catch {
            return false
        }
    }

    private func probeLX200Locked() -> Bool {
        let probes = [":V#", ":GVP#"]
        for probe in probes {
            do {
                port.flush()
                try port.writeASCII(probe)
                _ = try port.readUntil(terminator: UInt8(ascii: "#"), timeout: 0.6)
                return true
            } catch {
                continue
            }
        }
        return false
    }

    private func initializeSkyWatcherLocked() throws {
        try skyCommandLocked("F", axis: 1, data: "")
        try skyCommandLocked("F", axis: 2, data: "")
        if let period = try? inquireHex24Locked("D", axis: 1), period > 0 {
            siderealPeriod = period
        } else if
            let steps = try? inquireHex24Locked("a", axis: 1),
            let freq = try? inquireHex24Locked("b", axis: 1),
            steps > 0, freq > 0
        {
            siderealPeriod = max(6, Int((Double(freq) * 86_164.0905 / Double(steps)).rounded()))
        }
    }

    private func stopTrackingLocked() throws {
        switch proto {
        case .skyWatcher:
            try skyCommandLocked("K", axis: 1, data: "")
            try skyCommandLocked("K", axis: 2, data: "")
            usleep(200_000)
        case .synScan:
            try port.write(Data([UInt8(ascii: "T"), 0]))
            _ = try readHashLocked(timeout: 2)
        case .lx200:
            try stopLX200TrackingLocked()
        case nil:
            break
        }
    }

    private func stopLX200TrackingLocked() throws {
        do {
            try port.writeASCII(":Td#")
            _ = try readHashLocked(timeout: 1.2)
        } catch {
            port.flush()
            try port.write(Data([UInt8(ascii: "T"), 0]))
            _ = try readHashLocked(timeout: 2)
        }
    }

    private func skyCommandLocked(_ command: String, axis: Int, data: String) throws {
        try port.writeASCII(":\(command)\(axis)\(data)\r")
        let response = try port.readUntil(terminator: 0x0D, timeout: 2.0)
        guard response.first == UInt8(ascii: "=") else {
            let body = String(bytes: response, encoding: .ascii) ?? "binary"
            throw MountError.protocolFailure("\(command)\(axis) → \(body)")
        }
    }

    private func inquireHex24Locked(_ command: String, axis: Int) throws -> Int {
        try port.writeASCII(":\(command)\(axis)\r")
        let response = try port.readUntil(terminator: 0x0D, timeout: 2.0)
        guard response.first == UInt8(ascii: "=") else {
            throw MountError.protocolFailure("inquire \(command)\(axis)")
        }
        let body = String(bytes: response.dropFirst().dropLast(), encoding: .ascii) ?? ""
        guard let value = SkyWatcherEncoding.parseHex24(body) else {
            throw MountError.protocolFailure("bad hex from \(command)\(axis)")
        }
        return value
    }

    private func readHashLocked(timeout: TimeInterval) throws -> Data {
        do {
            return try port.readUntil(terminator: UInt8(ascii: "#"), timeout: timeout)
        } catch SerialPortError.timeout {
            throw MountError.timeout
        } catch {
            throw MountError.protocolFailure("serial read")
        }
    }
}
