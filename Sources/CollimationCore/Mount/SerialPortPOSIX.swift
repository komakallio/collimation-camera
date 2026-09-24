#if canImport(Darwin) || canImport(Glibc)
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation

/// POSIX 8N1 serial port. Non-blocking file descriptor plus `poll`.
public final class POSIXSerialPort: SerialPortDriver, @unchecked Sendable {
    private var fd: Int32 = -1
    private let lock = NSLock()

    public init() {}

    public var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fd >= 0
    }

    public func open(path: String, baud: Int) throws {
        lock.lock()
        defer { lock.unlock() }
        if fd >= 0 {
            closeDescriptor(fd)
            fd = -1
        }
        let opened = openDescriptor(path)
        guard opened >= 0 else { throw SerialPortError.openFailed }
        fd = opened

        do {
            try configureLocked(baud: Self.speed(for: baud))
        } catch {
            closeDescriptor(fd)
            fd = -1
            throw error
        }
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        if fd >= 0 {
            closeDescriptor(fd)
            fd = -1
        }
    }

    public func flush() {
        lock.lock()
        defer { lock.unlock() }
        guard fd >= 0 else { return }
        tcflush(fd, TCIOFLUSH)
    }

    public func write(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        guard fd >= 0 else { throw SerialPortError.closed }
        try data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var written = 0
            while written < raw.count {
                let n = writeDescriptor(fd, base + written, raw.count - written)
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
        SerialLog.log("TX", data)
    }

    public func readUntil(terminator: UInt8, timeout: TimeInterval, maxBytes: Int = 256) throws -> Data {
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
            let n = readDescriptor(fd, &byte, 1)
            if n == 1 {
                data.append(byte)
                if byte == terminator {
                    SerialLog.log("RX", data)
                    return data
                }
                if data.count >= maxBytes { throw SerialPortError.ioFailed }
                continue
            }
            if n == 0 { throw SerialPortError.ioFailed }
            if errno == EAGAIN || errno == EWOULDBLOCK { continue }
            throw SerialPortError.ioFailed
        }
        SerialLog.log("RX timeout", data)
        throw SerialPortError.timeout
    }

    private static func speed(for baud: Int) -> speed_t {
        baud == 115_200 ? speed_t(B115200) : speed_t(B9600)
    }

    private func openDescriptor(_ path: String) -> Int32 {
#if canImport(Darwin)
        Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
#else
        Glibc.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
#endif
    }

    private func closeDescriptor(_ descriptor: Int32) {
#if canImport(Darwin)
        _ = Darwin.close(descriptor)
#else
        _ = Glibc.close(descriptor)
#endif
    }

    private func writeDescriptor(_ descriptor: Int32, _ buffer: UnsafePointer<UInt8>, _ count: Int) -> Int {
#if canImport(Darwin)
        Darwin.write(descriptor, buffer, count)
#else
        Glibc.write(descriptor, buffer, count)
#endif
    }

    private func readDescriptor(_ descriptor: Int32, _ buffer: UnsafeMutablePointer<UInt8>, _ count: Int) -> Int {
#if canImport(Darwin)
        Darwin.read(descriptor, buffer, count)
#else
        Glibc.read(descriptor, buffer, count)
#endif
    }

    private func configureLocked(baud: speed_t) throws {
#if canImport(Darwin)
        _ = ioctl(fd, TIOCEXCL)
#endif
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
#if canImport(Darwin)
        settings.c_cflag &= ~tcflag_t(CRTSCTS)
#endif
        settings.c_iflag = 0
        settings.c_oflag = 0
        settings.c_lflag = 0
        // VMIN and VTIME. `c_cc` imports as a tuple, and the indices differ:
        // Darwin puts them at 16 and 17, Linux at 6 and 5.
#if canImport(Darwin)
        settings.c_cc.16 = 0
        settings.c_cc.17 = 0
#else
        settings.c_cc.6 = 0
        settings.c_cc.5 = 0
#endif
        guard tcsetattr(fd, TCSANOW, &settings) == 0 else { throw SerialPortError.configureFailed }

        var bits: Int32 = TIOCM_DTR | TIOCM_RTS
        // `ioctl` takes an unsigned request on both platforms, but Linux
        // imports TIOCMBIS as Int32 where Darwin already gives UInt.
        _ = ioctl(fd, UInt(bitPattern: Int(TIOCMBIS)), &bits)
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
}

public enum SerialPortScanner {
    /// macOS callout devices, minus the Bluetooth and debug pseudo-ports.
    public static func availablePaths() -> [String] {
        let skip = ["Bluetooth", "debug-console", "wlan-debug", "Bluetooth-Incoming"]
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return names
            .filter { $0.hasPrefix("cu.") }
            .filter { name in skip.contains { name.contains($0) } == false }
            .sorted()
            .map { "/dev/\($0)" }
    }
}
#endif
