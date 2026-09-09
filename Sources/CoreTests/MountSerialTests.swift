import CollimationCore
import Foundation

/// A `SerialPortDriver` that answers from a script instead of a wire (§10.3).
///
/// Every write is recorded, and the reply for a write is looked up by the
/// bytes written: a mount only ever answers a command it was given, so a
/// request-to-response table is enough to model all three protocols. A command
/// with no entry produces a timeout, which is what a real port does when the
/// mount does not speak that dialect — and what the probe order depends on.
final class ScriptedSerialPortDriver: SerialPortDriver, @unchecked Sendable {
    struct Exchange {
        var request: Data
        var response: Data
    }

    private let lock = NSLock()
    private var open = false
    private var pending = Data()
    private var script: [Data: Data]

    /// Every write in order, for asserting the probe sequence.
    private(set) var writes: [Data] = []
    private(set) var openedPaths: [String] = []
    private(set) var closeCount = 0
    private(set) var flushCount = 0

    /// Set to make `open` fail, as an unplugged adapter does.
    var openError: Error?

    init(_ exchanges: [Exchange] = []) {
        script = [:]
        for exchange in exchanges { script[exchange.request] = exchange.response }
    }

    /// `[":e1\r": "=000000\r"]`, spelled in ASCII for readability.
    convenience init(ascii table: [String: String]) {
        self.init(table.map { key, value in
            Exchange(request: Data(key.utf8), response: Data(value.utf8))
        })
    }

    func answer(_ request: Data, with response: Data) {
        lock.lock()
        defer { lock.unlock() }
        script[request] = response
    }

    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return open
    }

    var writtenASCII: [String] {
        lock.lock()
        defer { lock.unlock() }
        return writes.map { SerialLogText.describe($0) }
    }

    func open(path: String, baud: Int) throws {
        lock.lock()
        defer { lock.unlock() }
        if let openError { throw openError }
        open = true
        openedPaths.append(path)
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        open = false
        closeCount += 1
    }

    func flush() {
        lock.lock()
        defer { lock.unlock() }
        flushCount += 1
        pending.removeAll()
    }

    func write(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        guard open else { throw SerialPortError.closed }
        writes.append(data)
        if let response = script[data] { pending.append(response) }
    }

    func readUntil(terminator: UInt8, timeout: TimeInterval, maxBytes: Int) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard open else { throw SerialPortError.closed }
        guard let index = pending.firstIndex(of: terminator) else {
            // Whatever is buffered is not a complete reply, so the read blocks
            // until the deadline exactly as the real drivers do.
            pending.removeAll()
            throw SerialPortError.timeout
        }
        let end = pending.index(after: index)
        let reply = Data(pending[pending.startIndex..<end])
        pending.removeSubrange(pending.startIndex..<end)
        return reply
    }
}

/// Same rendering the drivers use for their `EQ6 TX` lines, so an assertion
/// failure prints `:e1\r` rather than 3A 65 31 0D.
enum SerialLogText {
    static func describe(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}

// MARK: - Scripts

/// An EQDIR motor board: answers `:e1` and the initialization inquiries.
private func skyWatcherScript() -> ScriptedSerialPortDriver {
    ScriptedSerialPortDriver(ascii: [
        ":e1\r": "=020300\r",     // version inquiry, the probe
        ":F1\r": "=\r",           // initialize axis 1
        ":F2\r": "=\r",           // initialize axis 2
        ":d1\r": "=402300\r",     // sidereal period 9024, little-endian hex24
        ":K1\r": "=\r",           // stop axis 1
        ":K2\r": "=\r",           // stop axis 2
    ])
}

/// A SynScan handset: echoes the 0x55 payload for `K`, and answers `T`.
private func synScanScript() -> ScriptedSerialPortDriver {
    let driver = ScriptedSerialPortDriver()
    driver.answer(Data([UInt8(ascii: "K"), 0x55]), with: Data([0x55, UInt8(ascii: "#")]))
    driver.answer(Data([UInt8(ascii: "T"), 0]), with: Data([UInt8(ascii: "#")]))
    return driver
}

/// An LX200 mount: answers `:V#` and nothing else.
///
/// It used to script a reply to `:Td#` as well, and the pulse test scripted
/// one for `:Mg`. Neither command returns anything on a real Meade mount, so
/// the tests agreed with the code rather than checking it, and an LX200 mount
/// could not connect or pulse at all.
private func lx200Script() -> ScriptedSerialPortDriver {
    ScriptedSerialPortDriver(ascii: [":V#": "1.0#"])
}

// MARK: - Tests

func testEQ6ProbeOrder() throws {
    // SkyWatcher answers first, so nothing after it is ever sent.
    let sky = skyWatcherScript()
    let skyMount = EQ6Mount(port: sky)
    try skyMount.connect(path: "SCRIPT", baud: 9600)
    try expectUI(skyMount.protocolName == EQ6Protocol.skyWatcher.rawValue, "skyWatcher, got \(skyMount.protocolName)")
    try expectUI(sky.writtenASCII.first == ":e1\\r", "first probe was \(sky.writtenASCII.first ?? "none")")
    try expectUI(
        !sky.writtenASCII.contains(":V#") && !sky.writtenASCII.contains(":GVP#"),
        "LX200 probes sent to a SkyWatcher mount: \(sky.writtenASCII)"
    )
    try expectUI(sky.openedPaths == ["SCRIPT"], "opened \(sky.openedPaths)")
    skyMount.disconnect()

    // A SynScan handset ignores :e1, so the probe falls through to K 0x55.
    let syn = synScanScript()
    let synMount = EQ6Mount(port: syn)
    try synMount.connect(path: "SCRIPT", baud: 9600)
    try expectUI(synMount.protocolName == EQ6Protocol.synScan.rawValue, "synScan, got \(synMount.protocolName)")
    try expectUI(syn.writtenASCII.first == ":e1\\r", "SkyWatcher is probed first")
    try expectUI(
        !syn.writtenASCII.contains(":V#"),
        "LX200 probed after SynScan matched: \(syn.writtenASCII)"
    )
    synMount.disconnect()

    // LX200 is last: both earlier probes time out first.
    let lx = lx200Script()
    let lxMount = EQ6Mount(port: lx)
    try lxMount.connect(path: "SCRIPT", baud: 9600)
    try expectUI(lxMount.protocolName == EQ6Protocol.lx200.rawValue, "lx200, got \(lxMount.protocolName)")
    let order = lx.writtenASCII
    guard let skyIndex = order.firstIndex(of: ":e1\\r"),
          let lxIndex = order.firstIndex(of: ":V#") else {
        throw UIModelExpectation(description: "missing probes in \(order)")
    }
    try expectUI(skyIndex < lxIndex, "SkyWatcher probed before LX200: \(order)")
    lxMount.disconnect()
}

func testEQ6UnrecognizedMount() throws {
    // A port that answers nothing: all three probes time out.
    let silent = ScriptedSerialPortDriver()
    let mount = EQ6Mount(port: silent)
    var thrown: Error?
    do {
        try mount.connect(path: "SCRIPT", baud: 9600)
    } catch {
        thrown = error
    }
    guard case MountError.unrecognized? = thrown else {
        throw UIModelExpectation(description: "expected unrecognized, got \(String(describing: thrown))")
    }
    try expectUI(!mount.isConnected, "must not report connected")
    try expectUI(silent.closeCount >= 1, "the port must be closed again")
    // All three dialects were tried before giving up.
    let order = silent.writtenASCII
    try expectUI(order.contains(":e1\\r"), "SkyWatcher probe missing from \(order)")
    try expectUI(order.contains(":V#") || order.contains(":GVP#"), "LX200 probe missing from \(order)")
}

func testEQ6OpenFailure() throws {
    let refused = ScriptedSerialPortDriver()
    refused.openError = SerialPortError.openFailed
    let mount = EQ6Mount(port: refused)
    var thrown: Error?
    do {
        try mount.connect(path: "COM9", baud: 9600)
    } catch {
        thrown = error
    }
    guard case MountError.openFailed(let path)? = thrown else {
        throw UIModelExpectation(description: "expected openFailed, got \(String(describing: thrown))")
    }
    try expectUI(path == "COM9", "the failing path is reported: \(path)")
    try expectUI(refused.writes.isEmpty, "nothing may be written to a port that did not open")
}

/// Runs an async call from a synchronous test. `EQ6Mount.pulse` hops to a
/// global queue, so blocking the caller here cannot deadlock it.
private func runBlocking(_ body: @escaping @Sendable () async throws -> Void) throws {
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var thrown: Error?
    Task.detached {
        do { try await body() } catch { thrown = error }
        done.signal()
    }
    done.wait()
    if let thrown { throw thrown }
}

func testEQ6PulseCommands() throws {
    // LX200: one :Mg command per pulse, and no reply -- so nothing is
    // scripted for it, and a mount that stays silent must still work.
    let lx = lx200Script()
    let lxMount = EQ6Mount(port: lx)
    try lxMount.connect(path: "SCRIPT", baud: 9600)
    let beforePulse = lx.writes.count
    try runBlocking { try await lxMount.pulse(.north, milliseconds: 250) }
    let pulses = lx.writtenASCII.dropFirst(beforePulse)
    try expectUI(
        pulses.contains(LX200PulseGuide.command(.north, milliseconds: 250)),
        "expected the LX200 pulse command in \(Array(pulses))"
    )
    lxMount.disconnect()

    // SynScan: rate 1 to start, rate 0 to stop, one pair per pulse.
    let syn = synScanScript()
    let hash = Data("#".utf8)
    syn.answer(SynScanGuide.fixedRateCommand(direction: .east, rate: 1), with: hash)
    syn.answer(SynScanGuide.fixedRateCommand(direction: .east, rate: 0), with: hash)
    let synMount = EQ6Mount(port: syn)
    try synMount.connect(path: "SCRIPT", baud: 9600)
    let before = syn.writes.count
    try runBlocking { try await synMount.pulse(.east, milliseconds: 120) }
    let sent = Array(syn.writes.dropFirst(before))
    try expectUI(sent.count == 2, "one start and one stop, got \(sent.count)")
    try expectUI(sent.first == SynScanGuide.fixedRateCommand(direction: .east, rate: 1), "start at rate 1")
    try expectUI(sent.last == SynScanGuide.fixedRateCommand(direction: .east, rate: 0), "stop at rate 0")
    synMount.disconnect()

    // SkyWatcher: G/I/J to start the axis, K to stop it. The I payload carries
    // the sidereal period read during connect, which is what proves the :d1
    // reply was parsed rather than falling back to the default.
    let sky = skyWatcherScript()
    for command in [":G210\r", ":I2402300\r", ":J2\r", ":K2\r"] {
        sky.answer(Data(command.utf8), with: Data("=\r".utf8))
    }
    let skyMount = EQ6Mount(port: sky)
    try skyMount.connect(path: "SCRIPT", baud: 9600)
    let beforeSky = sky.writes.count
    try runBlocking { try await skyMount.pulse(.north, milliseconds: 60) }
    let skySent = Array(sky.writtenASCII.dropFirst(beforeSky))
    try expectUI(skySent == [":G210\\r", ":I2402300\\r", ":J2\\r", ":K2\\r"], "SkyWatcher pulse sent \(skySent)")
    skyMount.disconnect()
}

#if os(Windows)
func testWindowsCOMScannerParsing() throws {
    // Registry values are UTF-16LE with a trailing NUL, and the byte count
    // reported by RegEnumValueW includes it.
    var bytes: [UInt8] = []
    for unit in Array("COM7\u{0}".utf16) {
        bytes.append(UInt8(unit & 0xFF))
        bytes.append(UInt8(unit >> 8))
    }
    try expectUI(
        SerialPortScanner.decodeUTF16(bytes, byteCount: bytes.count) == "COM7",
        "decoded \(SerialPortScanner.decodeUTF16(bytes, byteCount: bytes.count))"
    )
    // Some drivers report the length without the terminator.
    try expectUI(
        SerialPortScanner.decodeUTF16(bytes, byteCount: bytes.count - 2) == "COM7",
        "unterminated value"
    )
    // A byte count larger than the buffer must not read past it.
    try expectUI(
        SerialPortScanner.decodeUTF16(bytes, byteCount: 4_096) == "COM7",
        "over-long byte count"
    )
    try expectUI(SerialPortScanner.decodeUTF16([], byteCount: 0).isEmpty, "empty value")

    try expectUI(SerialPortScanner.portNumber("COM3") == 3, "COM3")
    try expectUI(SerialPortScanner.portNumber("COM12") == 12, "COM12")
    try expectUI(SerialPortScanner.portNumber("com5") == 5, "lowercase")
    try expectUI(SerialPortScanner.portNumber("LPT1") == nil, "LPT1 is not a COM port")
    try expectUI(SerialPortScanner.portNumber("COM") == nil, "no number")

    // COM10 sorts after COM9, which a plain string sort gets wrong.
    let ports = ["COM10", "COM3", "COM9", "COM1", "AUX"]
    let sorted = ports.sorted(by: SerialPortScanner.comesBefore)
    try expectUI(sorted == ["AUX", "COM1", "COM3", "COM9", "COM10"], "sorted \(sorted)")
}
#endif
