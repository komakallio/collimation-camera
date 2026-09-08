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
    private let port: SerialPortDriver
    private var proto: EQ6Protocol?
    private var siderealPeriod = 0
    private var activeNudge: SlewNudge?

    public init(port: SerialPortDriver = PlatformSerialPort()) {
        self.port = port
    }

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
        activeNudge = nil
        do {
            try port.open(path: path, baud: baud)
        } catch {
            throw MountError.openFailed(path)
        }
        preciseSleep(microseconds: 80_000)
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
        try? stopAllNudgesLocked()
        port.close()
        proto = nil
        siderealPeriod = 0
        activeNudge = nil
    }

    public func haltMotions() {
        lock.lock()
        defer { lock.unlock() }
        try? stopAllNudgesLocked()
    }

    public func applyNudge(_ nudge: SlewNudge?) async throws {
        try await serial { try self.applyNudgeLocked(nudge) }
    }

    public func pulse(_ direction: GuideDirection, milliseconds: Int) async throws {
        let ms = max(0, milliseconds)
        guard ms > 0 else { return }
        try await serial { try self.pulseSync(direction, milliseconds: ms) }
    }

    private func serial(_ work: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                self.lock.lock()
                defer { self.lock.unlock() }
                do {
                    try work()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func pulseSync(_ direction: GuideDirection, milliseconds: Int) throws {
        guard proto != nil else { throw MountError.notConnected }
        switch proto {
        case .lx200:
            try pulseLX200Locked(direction, milliseconds: milliseconds)
        case .synScan:
            try pulseSynScanLocked(direction, milliseconds: milliseconds)
        case .skyWatcher:
            try pulseSkyWatcherLocked(direction, milliseconds: milliseconds)
        case nil:
            throw MountError.notConnected
        }
    }

    private func applyNudgeLocked(_ nudge: SlewNudge?) throws {
        guard proto != nil else { throw MountError.notConnected }
        let next = (nudge == nil || nudge?.isIdle == true) ? nil : nudge
        try applyAxisNudgeLocked(
            current: activeNudge?.ra,
            currentMultiple: activeNudge?.raSiderealMultiple,
            next: next?.ra,
            nextMultiple: next?.raSiderealMultiple
        )
        try applyAxisNudgeLocked(
            current: activeNudge?.dec,
            currentMultiple: activeNudge?.decSiderealMultiple,
            next: next?.dec,
            nextMultiple: next?.decSiderealMultiple
        )
        activeNudge = next
    }

    private func applyAxisNudgeLocked(
        current: GuideDirection?,
        currentMultiple: Double?,
        next: GuideDirection?,
        nextMultiple: Double?
    ) throws {
        if current == next, Self.sameMultiple(currentMultiple, nextMultiple) { return }
        if let current {
            try stopAxisNudgeLocked(current)
        }
        if let next, let nextMultiple, nextMultiple > 0 {
            try startAxisNudgeLocked(next, siderealMultiple: nextMultiple)
        }
    }

    private static func sameMultiple(_ a: Double?, _ b: Double?) -> Bool {
        abs((a ?? 0) - (b ?? 0)) < 1e-6
    }

    private func startAxisNudgeLocked(_ direction: GuideDirection, siderealMultiple: Double) throws {
        switch proto {
        case .synScan, .lx200:
            let rate = SynScanGuide.nearestFixedRate(forSiderealMultiple: siderealMultiple)
            try port.write(SynScanGuide.fixedRateCommand(direction: direction, rate: rate))
            _ = try readHashLocked(timeout: 2)
        case .skyWatcher:
            try startSkyWatcherNudgeLocked(direction, siderealMultiple: siderealMultiple)
        case nil:
            throw MountError.notConnected
        }
    }

    private func stopAxisNudgeLocked(_ direction: GuideDirection) throws {
        switch proto {
        case .synScan, .lx200:
            try port.write(SynScanGuide.fixedRateCommand(direction: direction, rate: 0))
            _ = try? readHashLocked(timeout: 0.8)
        case .skyWatcher:
            let axis = (direction == .east || direction == .west) ? 1 : 2
            try? skyCommandLocked("K", axis: axis, data: "")
        case nil:
            break
        }
    }

    private func stopAllNudgesLocked() throws {
        if let active = activeNudge {
            if let ra = active.ra { try stopAxisNudgeLocked(ra) }
            if let dec = active.dec { try stopAxisNudgeLocked(dec) }
        } else {
            switch proto {
            case .synScan, .lx200:
                for direction in GuideDirection.allCases {
                    try port.write(SynScanGuide.fixedRateCommand(direction: direction, rate: 0))
                    _ = try? readHashLocked(timeout: 0.2)
                }
            case .skyWatcher:
                try? skyCommandLocked("K", axis: 1, data: "")
                try? skyCommandLocked("K", axis: 2, data: "")
            case nil:
                break
            }
        }
        activeNudge = nil
    }

    private func startSkyWatcherNudgeLocked(_ direction: GuideDirection, siderealMultiple: Double) throws {
        let axis = (direction == .east || direction == .west) ? 1 : 2
        let forward = direction == .east || direction == .north
        let period = SkyWatcherEncoding.slowSlewPeriod(sidereal: siderealPeriod, siderealMultiple: siderealMultiple)
        try? skyCommandLocked("K", axis: axis, data: "")
        preciseSleep(microseconds: 80_000)
        try skyCommandLocked("G", axis: axis, data: forward ? "10" : "11")
        try skyCommandLocked("I", axis: axis, data: SkyWatcherEncoding.hex24(period))
        try skyCommandLocked("J", axis: axis, data: "")
    }

    private func pulseLX200Locked(_ direction: GuideDirection, milliseconds: Int) throws {
        try port.writeASCII(LX200PulseGuide.command(direction, milliseconds: milliseconds))
        _ = try readHashLocked(timeout: 2)
        preciseSleep(milliseconds: milliseconds + 40)
    }

    private func pulseSynScanLocked(_ direction: GuideDirection, milliseconds: Int) throws {
        try port.write(SynScanGuide.fixedRateCommand(direction: direction, rate: 1))
        _ = try readHashLocked(timeout: 2)
        preciseSleep(milliseconds: milliseconds)
        try port.write(SynScanGuide.fixedRateCommand(direction: direction, rate: 0))
        _ = try readHashLocked(timeout: 2)
        preciseSleep(microseconds: 40_000)
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
        let period = SkyWatcherEncoding.trackingPeriod(sidereal: siderealPeriod)
        try skyCommandLocked("I", axis: axis, data: SkyWatcherEncoding.hex24(period))
        try skyCommandLocked("J", axis: axis, data: "")
        preciseSleep(milliseconds: milliseconds)
        try skyCommandLocked("K", axis: axis, data: "")
        preciseSleep(microseconds: 40_000)
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
            // Handset echoes the payload and '#'. Do not treat a stray 0x55 as a match.
            return response == Data([0x55, UInt8(ascii: "#")]) || response == Data([UInt8(ascii: "K"), 0x55, UInt8(ascii: "#")])
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
        if let period = SkyWatcherEncoding.plausibleSiderealPeriod(try? inquireNumberLocked("d", axis: 1)) {
            siderealPeriod = period
        } else if
            let steps = try? inquireNumberLocked("a", axis: 1),
            let freq = try? inquireNumberLocked("b", axis: 1),
            steps > 0, freq > 0
        {
            siderealPeriod = SkyWatcherEncoding.plausibleSiderealPeriod(
                Int((Double(freq) * 86_164.0905 / Double(steps)).rounded())
            ) ?? SkyWatcherEncoding.defaultSiderealPeriod
        } else {
            siderealPeriod = SkyWatcherEncoding.defaultSiderealPeriod
        }
        Log.info("EQ6 sidereal period \(siderealPeriod)")
    }

    private func stopTrackingLocked() throws {
        switch proto {
        case .skyWatcher:
            try skyCommandLocked("K", axis: 1, data: "")
            try skyCommandLocked("K", axis: 2, data: "")
            preciseSleep(microseconds: 200_000)
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

    private func inquireNumberLocked(_ command: String, axis: Int) throws -> Int {
        try port.writeASCII(":\(command)\(axis)\r")
        let response = try port.readUntil(terminator: 0x0D, timeout: 2.0)
        guard response.first == UInt8(ascii: "=") else {
            throw MountError.protocolFailure("inquire \(command)\(axis)")
        }
        let body = String(bytes: response.dropFirst().dropLast(), encoding: .ascii) ?? ""
        let hex = body.filter(\.isHexDigit)
        if let value = SkyWatcherEncoding.parseHex24(hex) { return value }
        guard let value = Int(hex, radix: 16) else {
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
