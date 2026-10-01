import Foundation

public enum SerialPortError: Error {
    case openFailed
    case configureFailed
    case closed
    case timeout
    case ioFailed
}

/// 8N1 serial port for mounts and focusers.
/// One implementation per platform; tests substitute a scripted double.
public protocol SerialPortDriver: AnyObject, Sendable {
    var isOpen: Bool { get }
    func open(path: String, baud: Int) throws
    func close()
    func flush()
    func write(_ data: Data) throws
    func readUntil(terminator: UInt8, timeout: TimeInterval, maxBytes: Int) throws -> Data
}

extension SerialPortDriver {
    public func writeASCII(_ text: String) throws {
        guard let data = text.data(using: .ascii) else { throw SerialPortError.ioFailed }
        try write(data)
    }

    public func readUntil(terminator: UInt8, timeout: TimeInterval) throws -> Data {
        try readUntil(terminator: terminator, timeout: timeout, maxBytes: 256)
    }
}

/// The platform's serial driver. `EQ6Mount` uses this by default.
#if os(Windows)
public typealias PlatformSerialPort = WindowsSerialPort
#else
public typealias PlatformSerialPort = POSIXSerialPort
#endif

/// Shared wire logging for both drivers and all serial equipment.
enum SerialLog {
    static func log(_ direction: String, _ data: Data) {
        if data.isEmpty {
            Log.info("SERIAL \(direction)")
        } else {
            Log.info("SERIAL \(direction) \(describe(data))")
        }
    }

    static func describe(_ data: Data) -> String {
        if let text = String(data: data, encoding: .ascii),
           text.unicodeScalars.allSatisfy({ scalar in
               scalar.isASCII && (scalar.value >= 32 || scalar == "\r" || scalar == "\n")
           })
        {
            return text
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\n", with: "\\n")
        }
        return data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
