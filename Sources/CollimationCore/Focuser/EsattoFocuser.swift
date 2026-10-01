import Foundation

public struct FocuserSnapshot: Equatable, Sendable {
    public var serialNumber: String
    public var position: Int
    public var maxPosition: Int
    public var isMoving: Bool

    public init(serialNumber: String, position: Int, maxPosition: Int, isMoving: Bool) {
        self.serialNumber = serialNumber
        self.position = position
        self.maxPosition = maxPosition
        self.isMoving = isMoving
    }
}

/// Blocking operations: callers must use a worker queue, including on close.
public protocol FocuserDevice: AnyObject, Sendable {
    func connect(path: String) throws -> FocuserSnapshot
    func snapshot() throws -> FocuserSnapshot
    func move(to position: Int) throws -> FocuserSnapshot
    func stop() throws -> FocuserSnapshot
    func disconnect()
}

public enum FocuserError: Error, LocalizedError, Sendable {
    case noPortSelected
    case notConnected
    case openFailed(String)
    case timeout
    case disconnected
    case unrecognized
    case invalidPosition(Int, maximum: Int)
    case protocolFailure(String)

    public var errorDescription: String? {
        switch self {
        case .noPortSelected: return "Select a serial port for the ESATTO focuser."
        case .notConnected: return "The focuser is not connected."
        case .openFailed(let path):
            return "Could not open focuser port \(path). Check the USB connection and close other applications using this port."
        case .timeout: return "Timed out waiting for the ESATTO focuser to respond."
        case .disconnected: return "Focuser communication failed. Check its power and USB connection."
        case .unrecognized: return "No ESATTO focuser was recognised on this port."
        case .invalidPosition(let position, let maximum):
            return "Focuser position \(position) is outside the calibrated range 0–\(maximum) steps."
        case .protocolFailure(let detail): return "Focuser command failed: \(detail)"
        }
    }
}

/// Native ESATTO USB JSON protocol, 115200 8N1. Uses only MOT1 (the focuser);
/// no calibration, synchronisation, motor settings, or ARCO commands are sent.
/// Transactions are locked so shutdown cannot close a port during a reply.
public final class EsattoFocuser: FocuserDevice, @unchecked Sendable {
    private let port: any SerialPortDriver
    private let startupDelayMilliseconds: Int
    private let lock = NSLock()
    private var current: FocuserSnapshot?
    public static let baud = 115_200

    public init(port: any SerialPortDriver = PlatformSerialPort(), startupDelayMilliseconds: Int = 3000) {
        self.port = port
        self.startupDelayMilliseconds = startupDelayMilliseconds
    }

    public func connect(path: String) throws -> FocuserSnapshot {
        lock.lock()
        defer { lock.unlock() }
        disconnectLocked()
        guard !path.isEmpty else { throw FocuserError.noPortSelected }
        do { try port.open(path: path, baud: Self.baud) }
        catch { throw FocuserError.openFailed(path) }
        do {
            // The USB control lines reboot the ESATTO controller on open.
            // Its boot messages precede the JSON service becoming available.
            preciseSleep(milliseconds: startupDelayMilliseconds)
            let serial = try readSerialNumber()
            // Older firmware identifies itself in SN; some revisions use MODNAME.
            if !serial.uppercased().contains("ESATTO") {
                let model = try request("get", fields: ["MODNAME": ""], motor: false)["MODNAME"] as? String
                guard model?.uppercased().contains("ESATTO") == true else { throw FocuserError.unrecognized }
            }
            let maximum = try integer(request("get", fields: ["CAL_MAXPOS": ""])["CAL_MAXPOS"])
            guard maximum > 0 else { throw FocuserError.protocolFailure("The focuser has no calibrated travel range.") }
            current = FocuserSnapshot(serialNumber: serial, position: 0, maxPosition: maximum, isMoving: false)
            return try snapshotLocked()
        } catch {
            current = nil
            port.close()
            throw error
        }
    }

    public func snapshot() throws -> FocuserSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return try snapshotLocked()
    }

    public func move(to position: Int) throws -> FocuserSnapshot {
        lock.lock()
        defer { lock.unlock() }
        guard var state = current else { throw FocuserError.notConnected }
        guard (0...state.maxPosition).contains(position) else {
            throw FocuserError.invalidPosition(position, maximum: state.maxPosition)
        }
        let reply = try request("cmd", fields: ["MOVE_ABS": ["STEP": position]])
        // Firmware versions return the acknowledgement under STEP or MOVE_ABS.
        let nested = reply["MOVE_ABS"] as? [String: Any]
        try acknowledge(nested?["STEP"] ?? reply["STEP"] ?? reply["MOVE_ABS"])
        state.isMoving = true
        current = state
        return state
    }

    public func stop() throws -> FocuserSnapshot {
        lock.lock()
        defer { lock.unlock() }
        guard current != nil else { throw FocuserError.notConnected }
        try acknowledge(request("cmd", fields: ["MOT_STOP": ""])["MOT_STOP"])
        // BUSY may remain set while the motor decelerates; poll until idle.
        return try snapshotLocked()
    }

    public func disconnect() {
        lock.lock()
        defer { lock.unlock() }
        disconnectLocked()
    }

    private func disconnectLocked() {
        if current != nil, port.isOpen {
            // A close during a move must leave the motor stopped if it answers.
            _ = try? request("cmd", fields: ["MOT_STOP": ""])
        }
        current = nil
        port.close()
    }

    private func snapshotLocked() throws -> FocuserSnapshot {
        guard var state = current, port.isOpen else { throw FocuserError.notConnected }
        let status = try request("get", fields: ["STATUS": ""])["STATUS"] as? [String: Any]
        let busy = try integer(status?["BUSY"])
        guard busy == 0 || busy == 1 else { throw FocuserError.protocolFailure("Invalid motor status.") }
        // BUSY drops before deceleration finishes on ESATTO firmware 3.05.28.
        // Require the motor phase to stop as well, otherwise a new command can
        // interrupt travel even when ABS_POS momentarily equals the target.
        var isMoving = busy == 1
        if let phase = status?["MST"] {
            guard let name = phase as? String, !name.isEmpty else {
                throw FocuserError.protocolFailure("Invalid motor phase.")
            }
            isMoving = isMoving || name != "stop"
        }
        // Read the position after status so an idle snapshot has the final position.
        state.position = try integer(request("get", fields: ["ABS_POS": ""])["ABS_POS"])
        guard (0...state.maxPosition).contains(state.position) else {
            throw FocuserError.protocolFailure("Position is outside the calibrated travel range.")
        }
        state.isMoving = isMoving
        current = state
        return state
    }

    private func readSerialNumber() throws -> String {
        // Boot duration varies. Retry only the read-only handshake; never
        // retry a motion command whose acknowledgement might have been lost.
        let deadline = Date().addingTimeInterval(5)
        var lastError = FocuserError.timeout
        repeat {
            do {
                let reply = try request("get", fields: ["SN": ""], motor: false,
                                        timeout: min(2, max(0.01, deadline.timeIntervalSinceNow)))
                guard let serial = reply["SN"] as? String,
                      !serial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { throw FocuserError.unrecognized }
                return serial
            } catch let error as FocuserError {
                switch error {
                case .timeout, .protocolFailure: lastError = error
                default: throw error
                }
            }
            preciseSleep(milliseconds: 200)
        } while Date() < deadline
        throw lastError
    }

    private func request(_ verb: String, fields: [String: Any], motor: Bool = true,
                         timeout: TimeInterval = 2) throws -> [String: Any] {
        let body: [String: Any] = motor ? ["MOT1": fields] : fields
        let data = try JSONSerialization.data(withJSONObject: ["req": [verb: body]], options: [.sortedKeys])
        do {
            port.flush()
            try port.write(data)
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                let reply = try port.readUntil(terminator: 13, timeout: max(0.01, deadline.timeIntervalSinceNow), maxBytes: 4096)
                let text = String(decoding: reply, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                // ESATTO may emit diagnostic ERR lines ahead of its JSON reply.
                if text.hasPrefix("ERR:") { continue }
                guard let json = try? JSONSerialization.jsonObject(with: reply) as? [String: Any],
                      let res = json["res"] as? [String: Any]
                else { throw FocuserError.protocolFailure("Invalid JSON reply.") }
                try rejectErrors(res)
                guard let result = res[verb] as? [String: Any],
                      let values = motor ? result["MOT1"] as? [String: Any] : result
                else { throw FocuserError.protocolFailure("Missing \(verb) reply.") }
                return values
            }
            throw FocuserError.timeout
        } catch let error as SerialPortError {
            throw error == .timeout ? FocuserError.timeout : FocuserError.disconnected
        }
    }

    private func integer(_ value: Any?) throws -> Int {
        if let number = value as? NSNumber,
           String(cString: number.objCType) != "c",
           number.doubleValue.isFinite, number.doubleValue >= 0,
           number.doubleValue <= Double(UInt32.max), number.doubleValue.rounded() == number.doubleValue {
            return number.intValue
        }
        if let text = value as? String, let number = UInt32(text) { return Int(number) }
        throw FocuserError.protocolFailure("Missing or invalid numeric value.")
    }

    private func acknowledge(_ value: Any?) throws {
        guard value as? String == "done" else { throw FocuserError.protocolFailure("Command was not acknowledged.") }
    }

    private func rejectErrors(_ values: [String: Any]) throws {
        for (key, value) in values {
            if key.uppercased() == "ERROR" { throw FocuserError.protocolFailure(String(describing: value)) }
            if let text = value as? String, text.hasPrefix("Error:") { throw FocuserError.protocolFailure(text) }
            if let nested = value as? [String: Any] { try rejectErrors(nested) }
        }
    }
}
