import Darwin
import Foundation

enum SerialPortError: Error {
    case openFailed
    case configureFailed
    case closed
    case timeout
    case ioFailed
}

/// POSIX 8N1 serial port used to talk to an EQ6 SynScan handset or EQDIR adapter.
final class SerialPort: @unchecked Sendable {
    private var fd: Int32 = -1
    private let lock = NSLock()

    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fd >= 0
    }

    func open(path: String, baud: speed_t = speed_t(B9600)) throws {
        lock.lock()
        defer { lock.unlock() }
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
        let opened = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard opened >= 0 else { throw SerialPortError.openFailed }
        fd = opened

        do {
            try configureLocked(baud: baud)
        } catch {
            Darwin.close(fd)
            fd = -1
            throw error
        }
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    func flush() {
        lock.lock()
        defer { lock.unlock() }
        guard fd >= 0 else { return }
        tcflush(fd, TCIOFLUSH)
    }

    func write(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        guard fd >= 0 else { throw SerialPortError.closed }
        try data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var written = 0
            while written < raw.count {
                let n = Darwin.write(fd, base + written, raw.count - written)
                if n > 0 {
                    written += n
                    continue
                }
                if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    try pollLocked(events: Int16(POLLOUT), timeout: 1.0)
                    continue
                }
                throw SerialPortError.ioFailed
            }
        }
        Self.log("TX", data)
    }

    func writeASCII(_ text: String) throws {
        guard let data = text.data(using: .ascii) else { throw SerialPortError.ioFailed }
        try write(data)
    }

    func readUntil(terminator: UInt8, timeout: TimeInterval, maxBytes: Int = 256) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard fd >= 0 else { throw SerialPortError.closed }
        var data = Data()
        let deadline = Date().addingTimeInterval(timeout)
        var byte: UInt8 = 0
        while Date() < deadline {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { break }
            do {
                try pollLocked(events: Int16(POLLIN), timeout: remaining)
            } catch SerialPortError.timeout {
                continue
            }
            let n = Darwin.read(fd, &byte, 1)
            if n == 1 {
                data.append(byte)
                if byte == terminator {
                    Self.log("RX", data)
                    return data
                }
                if data.count >= maxBytes { throw SerialPortError.ioFailed }
                continue
            }
            if n == 0 { throw SerialPortError.ioFailed }
            if errno == EAGAIN || errno == EWOULDBLOCK { continue }
            throw SerialPortError.ioFailed
        }
        Self.log("RX timeout", data)
        throw SerialPortError.timeout
    }

    private func configureLocked(baud: speed_t) throws {
        _ = ioctl(fd, TIOCEXCL)
        var flags = fcntl(fd, F_GETFL)
        guard flags >= 0 else { throw SerialPortError.configureFailed }
        flags |= O_NONBLOCK
        guard fcntl(fd, F_SETFL, flags) != -1 else { throw SerialPortError.configureFailed }

        var settings = termios()
        guard tcgetattr(fd, &settings) == 0 else { throw SerialPortError.configureFailed }
        cfmakeraw(&settings)
        cfsetspeed(&settings, baud)
        settings.c_cflag |= tcflag_t(CLOCAL | CREAD | CS8)
        settings.c_cflag &= ~tcflag_t(PARENB)
        settings.c_cflag &= ~tcflag_t(CSTOPB)
        settings.c_cflag &= ~tcflag_t(CRTSCTS)
        settings.c_iflag = 0
        settings.c_oflag = 0
        settings.c_lflag = 0
        settings.c_cc.16 = 0
        settings.c_cc.17 = 0
        guard tcsetattr(fd, TCSANOW, &settings) == 0 else { throw SerialPortError.configureFailed }

        var bits: Int32 = TIOCM_DTR | TIOCM_RTS
        _ = ioctl(fd, TIOCMBIS, &bits)
        tcflush(fd, TCIOFLUSH)
    }

    private func pollLocked(events: Int16, timeout: TimeInterval) throws {
        var pfd = pollfd(fd: fd, events: events, revents: 0)
        let ms = Int32(max(1, (timeout * 1000).rounded()))
        let rc = poll(&pfd, 1, ms)
        if rc == 0 { throw SerialPortError.timeout }
        if rc < 0 { throw SerialPortError.ioFailed }
        if pfd.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
            throw SerialPortError.ioFailed
        }
    }

    private static func log(_ direction: String, _ data: Data) {
        if data.isEmpty {
            print("EQ6 \(direction)")
        } else {
            print("EQ6 \(direction) \(describe(data))")
        }
        fflush(stdout)
    }

    private static func describe(_ data: Data) -> String {
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

enum SerialPortScanner {
    static func availablePaths() -> [String] {
        let skip = ["Bluetooth", "debug-console", "wlan-debug", "Bluetooth-Incoming"]
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return names
            .filter { $0.hasPrefix("cu.") }
            .filter { name in skip.contains { name.contains($0) } == false }
            .sorted()
            .map { "/dev/\($0)" }
    }
}
