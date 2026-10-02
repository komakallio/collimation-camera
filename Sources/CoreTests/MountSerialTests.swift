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
    private(set) var openedBauds: [Int] = []
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
        openedBauds.append(baud)
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
func skyWatcherScript() -> ScriptedSerialPortDriver {
    ScriptedSerialPortDriver(ascii: [
        ":e1\r": "=020300\r",     // version inquiry, the probe
        ":F1\r": "=\r",           // initialize axis 1
        ":F2\r": "=\r",           // initialize axis 2
        ":d1\r": "=402300\r",     // encoder value that looks like a plausible period
        ":a1\r": "=00A08C\r",     // 9,216,000 steps/revolution (recorded EQ6)
        ":b1\r": "=BED100\r",     // 53,694 timer ticks/second -> period 502
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
    // period derived from the recorded motor parameters. The misleading :d1
    // encoder value must never be treated as a speed.
    let sky = skyWatcherScript()
    for command in [":G210\r", ":I2F60100\r", ":J2\r", ":K2\r"] {
        sky.answer(Data(command.utf8), with: Data("=\r".utf8))
    }
    let skyMount = EQ6Mount(port: sky)
    try skyMount.connect(path: "SCRIPT", baud: 9600)
    let beforeSky = sky.writes.count
    try runBlocking { try await skyMount.pulse(.north, milliseconds: 60) }
    let skySent = Array(sky.writtenASCII.dropFirst(beforeSky))
    try expectUI(skySent == [":G210\\r", ":I2F60100\\r", ":J2\\r", ":K2\\r"], "SkyWatcher pulse sent \(skySent)")
    try expectUI(!sky.writtenASCII.contains(":d1\\r"), "encoder is not a speed inquiry")
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

/// A Meade mount answers `:V#` and then goes quiet: `:Mg` and `:Td` return
/// nothing at all.
///
/// Both used to be followed by a read for a `#`, so connect failed with
/// "Timed out waiting for the mount to respond" — leaving the port open —
/// and every calibration pulse threw two seconds after the star had already
/// moved. An LX200 mount could not be used at all. The old tests scripted the
/// replies, so they passed while the app was broken; this one scripts nothing
/// beyond the probe, which is what a real mount does.
func testLX200SilentMountConnectsAndPulses() throws {
    let port = ScriptedSerialPortDriver(ascii: [":V#": "1.0#"])
    let mount = EQ6Mount(port: port)

    try mount.connect(path: "SCRIPT", baud: 9600)
    try expectUI(
        mount.protocolName == EQ6Protocol.lx200.rawValue,
        "connected as LX200, got \(mount.protocolName)"
    )
    try expectUI(mount.isConnected, "the port stays open")

    let before = port.writes.count
    try runBlocking { try await mount.pulse(.north, milliseconds: 40) }
    let written = port.writtenASCII.dropFirst(before)
    try expectUI(
        written.contains(LX200PulseGuide.command(.north, milliseconds: 40)),
        "the pulse was sent: \(Array(written))"
    )

    // And a second one, because the first failure used to leave the port in a
    // state where everything after it timed out too.
    try runBlocking { try await mount.pulse(.east, milliseconds: 40) }
    mount.disconnect()
    try expectUI(!mount.isConnected, "disconnect closes it")
}

func testMountCentroidAsyncTransfer() throws {
    try runBlocking {
        let expected = SIMD2<Double>(1677.0061693659475, 579.4238940016818)
        let start = try await settledCentroidSample(MountCentroidSample(expected))
        for index in 1...4 {
            let next = expected + SIMD2(Double(index) * -9, Double(index) * 7)
            let sample = try await settledCentroidSample(MountCentroidSample(next))
            try expectUI(sample.x == next.x && sample.y == next.y, "both centroid coordinates survive nested async returns: expected \(next), got \(sample), start \(start), original \(expected)")
            try expectUI(start.point == expected, "original point survives subsequent suspensions")
            let rate = MountGuide.rate(before: start.point, after: sample.point, durationMs: Double(index * 3000))
            try expectUI(abs(rate.x + 0.003) < 1e-12 && abs(rate.y - 7.0 / 3000) < 1e-12, "both axes preserved in calibration rate")
        }
    }
}

@inline(never)
private func settledCentroidSample(_ point: MountCentroidSample) async throws -> MountCentroidSample {
    try await Task.sleep(nanoseconds: 1_000_000)
    return try await readCentroidSample(point)
}

@inline(never)
private func readCentroidSample(_ point: MountCentroidSample) async throws -> MountCentroidSample {
    try await Task.sleep(nanoseconds: 1_000_000)
    return MountCentroidSample(point.point)
}

func testCalibrationRAJog() throws {
    let sky = skyWatcherScript()
    for direction in ["10", "11"] {
        sky.answer(Data(":G1\(direction)\r".utf8), with: Data("=\r".utf8))
    }
    sky.answer(Data(":I13F0000\r".utf8), with: Data("=\r".utf8))
    sky.answer(Data(":J1\r".utf8), with: Data("=\r".utf8))
    let mount = EQ6Mount(port: sky)
    try mount.connect(path: "SCRIPT")
    try expectUI(mount.calibrationRAMultiple == 8, "EQDIR calibration uses 8x")
    for direction in [GuideDirection.east, .west] {
        let before = sky.writes.count
        try runBlocking {
            try await mount.applyNudge(SlewNudge(ra: direction, dec: nil, siderealMultiple: mount.calibrationRAMultiple))
            try await mount.applyNudge(nil)
        }
        let mode = direction == .east ? "10" : "11"
        try expectUI(Array(sky.writtenASCII.dropFirst(before)) == [":K1\\r", ":G1\(mode)\\r", ":I13F0000\\r", ":J1\\r", ":K1\\r"], "RA jog starts at 8x, reverses direction, then stops")
    }
    mount.disconnect()
    let syn = synScanScript()
    syn.answer(SynScanGuide.fixedRateCommand(direction: .east, rate: 2), with: Data("#".utf8))
    syn.answer(SynScanGuide.fixedRateCommand(direction: .east, rate: 0), with: Data("#".utf8))
    let handset = EQ6Mount(port: syn)
    try handset.connect(path: "SCRIPT")
    try runBlocking {
        try await handset.applyNudge(SlewNudge(ra: .east, dec: nil, siderealMultiple: handset.calibrationRAMultiple))
        try await handset.applyNudge(nil)
    }
    try expectUI(syn.writes.contains(SynScanGuide.fixedRateCommand(direction: .east, rate: 2)), "SynScan uses rate 2 for calibration")
    handset.disconnect()
    let lx = EQ6Mount(port: lx200Script())
    try lx.connect(path: "SCRIPT")
    try expectUI(lx.calibrationRAMultiple == 1, "LX200 retains supported pulse guiding")
    lx.disconnect()
}
