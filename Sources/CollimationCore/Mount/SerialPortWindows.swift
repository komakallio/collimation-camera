#if os(Windows)
import Foundation
import WinSDK

/// Win32 8N1 serial port. `SetCommTimeouts` gives `ReadFile` a 50 ms slice, so
/// `readUntil` polls in short steps the way the POSIX driver polls `poll`.
public final class WindowsSerialPort: SerialPortDriver, @unchecked Sendable {
    private var handle: HANDLE?
    private let lock = NSLock()

    /// One `ReadFile` returns within this many milliseconds even with no data.
    private static let readSliceMs: DWORD = 50

    public init() {}

    public var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return handle != nil
    }

    /// Accepts `COM7` or an already-prefixed path. Ports above COM9 need the
    /// `\\.\` prefix, so it is always applied.
    public static func devicePath(for path: String) -> String {
        path.hasPrefix("\\\\.\\") ? path : "\\\\.\\" + path
    }

    public func open(path: String, baud: Int) throws {
        lock.lock()
        defer { lock.unlock() }
        closeLocked()

        // GENERIC_READ and GENERIC_WRITE cannot be combined as imported: winnt.h
        // spells them 0x80000000L and 0x40000000L, and with a 32-bit `long` the
        // first does not fit a signed long, so Swift sees UInt32 and Int32.
        let access: DWORD = 0x8000_0000 | 0x4000_0000
        let opened = Self.devicePath(for: path).withCString(encodedAs: UTF16.self) { wide in
            CreateFileW(
                wide,
                access,
                0,                      // no sharing, the POSIX driver takes TIOCEXCL
                nil,
                DWORD(OPEN_EXISTING),
                0,                      // synchronous I/O
                nil
            )
        }
        guard let opened, opened != INVALID_HANDLE_VALUE else {
            throw SerialPortError.openFailed
        }
        handle = opened

        do {
            try configureLocked(baud: baud)
        } catch {
            closeLocked()
            throw error
        }
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        closeLocked()
    }

    public func flush() {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return }
        // PURGE_RXCLEAR | PURGE_TXCLEAR
        _ = PurgeComm(handle, 0x0000_0008 | 0x0000_0004)
    }

    public func write(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { throw SerialPortError.closed }
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                var chunk: DWORD = 0
                if WriteFile(handle, base + offset, DWORD(raw.count - offset), &chunk, nil) == false {
                    throw SerialPortError.ioFailed
                }
                if chunk == 0 { throw SerialPortError.ioFailed }
                offset += Int(chunk)
            }
        }
        SerialLog.log("TX", data)
    }

    public func readUntil(terminator: UInt8, timeout: TimeInterval, maxBytes: Int = 256) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { throw SerialPortError.closed }
        var data = Data()
        let deadline = Date().addingTimeInterval(timeout)
        var byte: UInt8 = 0
        while Date() < deadline {
            var read: DWORD = 0
            if ReadFile(handle, &byte, 1, &read, nil) == false {
                throw SerialPortError.ioFailed
            }
            if read == 1 {
                data.append(byte)
                if byte == terminator {
                    SerialLog.log("RX", data)
                    return data
                }
                if data.count >= maxBytes { throw SerialPortError.ioFailed }
                continue
            }
            // read == 0: the slice expired with nothing on the wire.
        }
        SerialLog.log("RX timeout", data)
        throw SerialPortError.timeout
    }

    private func closeLocked() {
        if let handle {
            CloseHandle(handle)
        }
        handle = nil
    }

    private func configureLocked(baud: Int) throws {
        guard let handle else { throw SerialPortError.closed }

        var dcb = DCB()
        dcb.DCBlength = DWORD(MemoryLayout<DCB>.size)
        guard GetCommState(handle, &dcb) != false else { throw SerialPortError.configureFailed }

        // `dtr=on rts=on` is fDtrControl/fRtsControl = ENABLE, which matches the
        // POSIX driver asserting TIOCM_DTR and TIOCM_RTS. The mode string avoids
        // touching the DCB bitfields directly.
        let mode = "baud=\(baud) parity=N data=8 stop=1 to=off xon=off odsr=off octs=off dtr=on rts=on idsr=off"
        let built = mode.withCString(encodedAs: UTF16.self) { wide in
            BuildCommDCBW(wide, &dcb)
        }
        guard built != false else { throw SerialPortError.configureFailed }
        dcb.DCBlength = DWORD(MemoryLayout<DCB>.size)
        guard SetCommState(handle, &dcb) != false else { throw SerialPortError.configureFailed }

        // ReadIntervalTimeout and ReadTotalTimeoutMultiplier both MAXDWORD with a
        // non-zero constant is the documented "wait up to N ms for one byte".
        var timeouts = COMMTIMEOUTS()
        timeouts.ReadIntervalTimeout = DWORD.max
        timeouts.ReadTotalTimeoutMultiplier = DWORD.max
        timeouts.ReadTotalTimeoutConstant = Self.readSliceMs
        timeouts.WriteTotalTimeoutMultiplier = 0
        timeouts.WriteTotalTimeoutConstant = 1_000
        guard SetCommTimeouts(handle, &timeouts) != false else { throw SerialPortError.configureFailed }

        // PURGE_RXCLEAR | PURGE_TXCLEAR
        _ = PurgeComm(handle, 0x0000_0008 | 0x0000_0004)
    }
}

public enum SerialPortScanner {
    /// Serial ports Windows currently has, from
    /// `HKEY_LOCAL_MACHINE\HARDWARE\DEVICEMAP\SERIALCOMM`. Values are the port
    /// names (`COM3`); the driver adds the `\\.\` prefix when opening.
    public static func availablePaths() -> [String] {
        var key: HKEY?
        // KEY_READ = STANDARD_RIGHTS_READ | KEY_QUERY_VALUE
        //          | KEY_ENUMERATE_SUB_KEYS | KEY_NOTIFY
        let status = "HARDWARE\\DEVICEMAP\\SERIALCOMM".withCString(encodedAs: UTF16.self) { path in
            RegOpenKeyExW(HKEY_LOCAL_MACHINE, path, 0, DWORD(0x0002_0019), &key)
        }
        guard status == ERROR_SUCCESS, let key else { return [] }
        defer { RegCloseKey(key) }

        var ports: [String] = []
        var index: DWORD = 0
        while true {
            var nameBuffer = [UInt16](repeating: 0, count: 256)
            var nameCount = DWORD(nameBuffer.count)
            var valueBuffer = [UInt8](repeating: 0, count: 512)
            var valueCount = DWORD(valueBuffer.count)
            var type: DWORD = 0
            let result = nameBuffer.withUnsafeMutableBufferPointer { name in
                valueBuffer.withUnsafeMutableBufferPointer { value in
                    RegEnumValueW(
                        key,
                        index,
                        name.baseAddress,
                        &nameCount,
                        nil,
                        &type,
                        value.baseAddress,
                        &valueCount
                    )
                }
            }
            if result == ERROR_NO_MORE_ITEMS { break }
            index += 1
            guard result == ERROR_SUCCESS, type == DWORD(REG_SZ) else { continue }
            let port = decodeUTF16(valueBuffer, byteCount: Int(valueCount))
            if !port.isEmpty { ports.append(port) }
        }
        return ports.sorted(by: comesBefore)
    }

    /// COM10 sorts after COM9, not between COM1 and COM2.
    public static func comesBefore(_ lhs: String, _ rhs: String) -> Bool {
        let left = portNumber(lhs)
        let right = portNumber(rhs)
        if let left, let right, left != right { return left < right }
        return lhs < rhs
    }

    public static func portNumber(_ port: String) -> Int? {
        guard port.uppercased().hasPrefix("COM") else { return nil }
        return Int(port.dropFirst(3))
    }

    public static func decodeUTF16(_ bytes: [UInt8], byteCount: Int) -> String {
        let count = min(byteCount, bytes.count) / 2
        guard count > 0 else { return "" }
        var units: [UInt16] = []
        units.reserveCapacity(count)
        for i in 0..<count {
            let unit = UInt16(bytes[i * 2]) | (UInt16(bytes[i * 2 + 1]) << 8)
            if unit == 0 { break }
            units.append(unit)
        }
        return String(decoding: units, as: UTF16.self)
    }
}
#endif
