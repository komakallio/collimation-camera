import CollimationCore
import Foundation

private let esattoSN = #"{"req":{"get":{"SN":""}}}"#
private let esattoLimit = #"{"req":{"get":{"MOT1":{"CAL_MAXPOS":""}}}}"#
private let esattoStatus = #"{"req":{"get":{"MOT1":{"STATUS":""}}}}"#
private let esattoPosition = #"{"req":{"get":{"MOT1":{"ABS_POS":""}}}}"#
private let esattoStop = #"{"req":{"cmd":{"MOT1":{"MOT_STOP":""}}}}"#
private let esattoMove = #"{"req":{"cmd":{"MOT1":{"MOVE_ABS":{"STEP":12500}}}}}"#

private func esattoPort() -> ScriptedSerialPortDriver {
    ScriptedSerialPortDriver(ascii: [
        esattoSN: #"{"res":{"get":{"SN":"ESATTO30001"}}}"# + "\r\n",
        esattoLimit: #"{"res":{"get":{"MOT1":{"CAL_MAXPOS":440000}}}}"# + "\r\n",
        esattoStatus: #"{"res":{"get":{"MOT1":{"STATUS":{"BUSY":0}}}}}"# + "\r\n",
        esattoPosition: #"{"res":{"get":{"MOT1":{"ABS_POS":12000}}}}"# + "\r\n",
        esattoStop: #"{"res":{"cmd":{"MOT1":{"MOT_STOP":"done"}}}}"# + "\r\n",
        esattoMove: #"{"res":{"cmd":{"MOT1":{"STEP":"done"}}}}"# + "\r\n",
    ])
}

func testEsattoProtocol() throws {
    let port = esattoPort()
    let focuser = EsattoFocuser(port: port, startupDelayMilliseconds: 0)
    let initial = try focuser.connect(path: "COM4")
    try expectUI(initial.position == 12000 && initial.maxPosition == 440000 && !initial.isMoving, "read calibrated position")
    try expectUI(port.openedPaths == ["COM4"] && port.openedBauds == [115200], "ESATTO uses COM4 at 115200")
    try expectUI(!port.writes.contains(where: { String(decoding: $0, as: UTF8.self).contains("cmd") }), "connect sends no motor commands")
    let moving = try focuser.move(to: 12500)
    try expectUI(moving.isMoving && moving.position == 12000, "move acknowledgement does not invent a position")
    port.answer(Data(esattoStatus.utf8), with: Data((#"{"res":{"get":{"MOT1":{"STATUS":{"BUSY":1}}}}}"# + "\r").utf8))
    try expectUI(try focuser.snapshot().isMoving, "moving comes from BUSY")
    port.answer(Data(esattoStatus.utf8), with: Data((#"{"res":{"get":{"MOT1":{"STATUS":{"BUSY":0}}}}}"# + "\r").utf8))
    port.answer(Data(esattoPosition.utf8), with: Data((#"{"res":{"get":{"MOT1":{"ABS_POS":12500}}}}"# + "\r").utf8))
    try expectUI(try focuser.stop().position == 12500, "stop reads final position")
    focuser.disconnect()
    try expectUI(!port.isOpen && port.writes.last == Data(esattoStop.utf8), "disconnect stops and closes")
}

func testEsattoLimitsAndErrors() throws {
    let port = esattoPort()
    let focuser = EsattoFocuser(port: port, startupDelayMilliseconds: 0)
    _ = try focuser.connect(path: "COM4")
    defer { focuser.disconnect() }
    for invalid in [-1, 440001, Int.max] {
        let writes = port.writes.count
        do {
            _ = try focuser.move(to: invalid)
            throw UIModelExpectation(description: "accepted invalid position \(invalid)")
        } catch FocuserError.invalidPosition { }
        try expectUI(port.writes.count == writes, "invalid move must not reach the motor")
    }
    for reply in [
        #"{"res":{"cmd":{"MOT1":{"ERROR":"motor disabled"}}}}"#,
        #"{"res":{"cmd":{"MOT1":{"STEP":"Error: motor disabled"}}}}"#,
        #"{"res":{"cmd":{"MOT2":{"STEP":"done"}}}}"#,
        #"{"res":{"cmd":{"MOT1":{"STEP":"busy"}}}}"#,
        "not JSON",
    ] {
        port.answer(Data(esattoMove.utf8), with: Data((reply + "\r").utf8))
        do {
            _ = try focuser.move(to: 12500)
            throw UIModelExpectation(description: "accepted failed response \(reply)")
        } catch FocuserError.protocolFailure { }
    }
    for reply in [
        #"{"res":{"cmd":{"MOT1":{"MOVE_ABS":{"STEP":"done"}}}}}"#,
        #"{"res":{"cmd":{"MOT1":{"MOVE_ABS":"done"}}}}"#,
    ] {
        port.answer(Data(esattoMove.utf8), with: Data((reply + "\r").utf8))
        try expectUI(try focuser.move(to: 12500).isMoving, "accept explicit move acknowledgement")
    }
    port.answer(Data(esattoPosition.utf8), with: Data((#"{"res":{"get":{"MOT1":{"ABS_POS":true}}}}"# + "\r").utf8))
    do {
        _ = try focuser.snapshot()
        throw UIModelExpectation(description: "boolean is not a position")
    } catch FocuserError.protocolFailure { }
}

func testEsattoConnectionFailures() throws {
    let silent = ScriptedSerialPortDriver()
    do {
        _ = try EsattoFocuser(port: silent, startupDelayMilliseconds: 0).connect(path: "COM4")
        throw UIModelExpectation(description: "silent port connected")
    } catch FocuserError.timeout { }
    try expectUI(!silent.isOpen, "failed handshake closes port")
    let wrong = esattoPort()
    wrong.answer(Data(esattoSN.utf8), with: Data((#"{"res":{"get":{"SN":"OTHER123"}}}"# + "\r").utf8))
    wrong.answer(Data(#"{"req":{"get":{"MODNAME":""}}}"#.utf8), with: Data((#"{"res":{"get":{"MODNAME":"SESTOSENSO2"}}}"# + "\r").utf8))
    do {
        _ = try EsattoFocuser(port: wrong, startupDelayMilliseconds: 0).connect(path: "COM4")
        throw UIModelExpectation(description: "wrong device connected")
    } catch FocuserError.unrecognized { }
    try expectUI(!wrong.isOpen && !wrong.writes.contains(Data(esattoStop.utf8)), "wrong device receives no motor commands")
    let diagnostics = esattoPort()
    diagnostics.answer(Data(esattoSN.utf8), with: Data(("ERR: diagnostic\r" + #"{"res":{"get":{"SN":"ESATTO30001"}}}"# + "\r").utf8))
    let focuser = EsattoFocuser(port: diagnostics, startupDelayMilliseconds: 0)
    _ = try focuser.connect(path: "COM4")
    focuser.disconnect()
}

private final class StartingEsattoPort: SerialPortDriver, @unchecked Sendable {
    let wire = esattoPort()
    private var serialRequests = 0
    var isOpen: Bool { wire.isOpen }
    func open(path: String, baud: Int) throws { try wire.open(path: path, baud: baud) }
    func close() { wire.close() }
    func flush() { wire.flush() }
    func write(_ data: Data) throws {
        if data == Data(esattoSN.utf8) {
            let reply = serialRequests == 0 ? "ets Jun 8 2016\r" : #"{"res":{"get":{"SN":"ESATTO30136"}}}"# + "\r"
            wire.answer(data, with: Data(reply.utf8))
            serialRequests += 1
        }
        try wire.write(data)
    }
    func readUntil(terminator: UInt8, timeout: TimeInterval, maxBytes: Int) throws -> Data {
        try wire.readUntil(terminator: terminator, timeout: timeout, maxBytes: maxBytes)
    }
}

func testEsattoStartupRetry() throws {
    let port = StartingEsattoPort()
    let focuser = EsattoFocuser(port: port, startupDelayMilliseconds: 0)
    _ = try focuser.connect(path: "COM4")
    try expectUI(port.wire.writes.filter { $0 == Data(esattoSN.utf8) }.count == 2, "retry identity after boot chatter")
    try expectUI(!port.wire.writes.contains(Data(esattoMove.utf8)), "handshake sends no motion commands")
    focuser.disconnect()
}

private final class TestFocuser: FocuserDevice, @unchecked Sendable {
    private let lock = NSLock()
    private var state = FocuserSnapshot(serialNumber: "ESATTO-TEST", position: 12000, maxPosition: 440000, isMoving: false)
    private var history: [String] = []
    private var failure: Error?
    private var gate: DispatchSemaphore?
    let connectEntered = DispatchSemaphore(value: 0)

    init(gate: DispatchSemaphore? = nil) { self.gate = gate }
    var events: [String] { lock.withLock { history } }
    func failPoll() { lock.withLock { failure = FocuserError.timeout } }

    func connect(path: String) throws -> FocuserSnapshot {
        let gate = lock.withLock { let value = self.gate; self.gate = nil; return value }
        connectEntered.signal()
        if let gate, gate.wait(timeout: .now() + 3) != .success { throw FocuserError.timeout }
        return lock.withLock { history.append("connect \(path)"); return state }
    }
    func snapshot() throws -> FocuserSnapshot {
        try lock.withLock {
            if let failure { throw failure }
            return state
        }
    }
    func move(to position: Int) throws -> FocuserSnapshot {
        lock.withLock {
            history.append("move \(position)")
            state.position = position
            state.isMoving = true
            return state
        }
    }
    func stop() throws -> FocuserSnapshot {
        lock.withLock { history.append("stop"); state.isMoving = false; return state }
    }
    func disconnect() {
        lock.withLock { history.append("disconnect"); state.isMoving = false; failure = nil }
    }
}

@MainActor
private func waitForFocuser(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(4)
    while !condition() {
        guard Date() < deadline else { throw UIModelExpectation(description: "focuser state did not arrive") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
func testFocuserEngineLifecycle() async throws {
    let suite = "collimation-camera.tests.focuser.lifecycle"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    let device = TestFocuser()
    let engine = CollimationEngine(defaults: defaults, serialPortPaths: { ["COM1", "COM4"] }, focuser: device)
    defer { engine.disconnectFocuser(); engine.shutdown() }
    try expectUI(engine.selectedFocuserPort == "COM4", "prefer COM4 without changing mount selection")
    try expectUI(!engine.canMoveFocuser && !engine.canStopFocuser, "no movement while disconnected")
    engine.connectFocuser()
    try expectUI(engine.canConnectFocuser && engine.isFocuserBusy, "opening is cancellable")
    try await waitForFocuser { engine.isFocuserConnected }
    try expectUI(engine.focuserTargetPosition == 12000, "target initialises to current position")
    engine.focuserStepSize = Int.max
    try expectUI(!engine.canMoveFocuserIn && !engine.canMoveFocuserOut, "large step cannot overflow or exceed limits")
    engine.focuserStepSize = -1
    try expectUI(!engine.canMoveFocuserIn && !engine.canMoveFocuserOut, "step must be positive")
    engine.focuserStepSize = 500
    engine.moveFocuserOut()
    try await waitForFocuser { engine.focuserSnapshot?.isMoving == true && !engine.isFocuserBusy }
    try expectUI(!engine.canMoveFocuser && engine.canStopFocuser && engine.canConnectFocuser, "moving locks moves but preserves escape controls")
    engine.stopFocuser()
    try await waitForFocuser { engine.canMoveFocuser }
    try expectUI(device.events.contains("move 12500") && device.events.contains("stop"), "step and stop reached driver")
    engine.focuserTargetPosition = 440001
    try expectUI(!engine.canGotoFocuser, "invalid absolute target disabled")
    engine.setStackingForTesting(true)
    try expectUI(!engine.canMoveFocuser && engine.canStopFocuser, "stack blocks new moves")
    engine.setStackingForTesting(false)
    device.failPoll()
    try await waitForFocuser { !engine.isFocuserConnected }
    try expectUI(engine.errorMessage != nil && engine.canConnectFocuser, "poll failure reports error and permits reconnect")
    engine.connectFocuser()
    try await waitForFocuser { engine.isFocuserConnected }
}

@MainActor
func testFocuserCancelledConnect() async throws {
    let suite = "collimation-camera.tests.focuser.cancel"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    let gate = DispatchSemaphore(value: 0)
    let device = TestFocuser(gate: gate)
    let engine = CollimationEngine(defaults: defaults, serialPortPaths: { ["COM4"] }, focuser: device)
    defer { gate.signal(); engine.disconnectFocuser(); engine.shutdown() }
    engine.connectFocuser()
    try await waitForFocuser { device.connectEntered.wait(timeout: .now()) == .success }
    // The main actor still runs while the serial driver is blocked.
    engine.disconnectFocuser()
    try expectUI(!engine.isFocuserBusy && !engine.isFocuserConnected, "disconnect clears immediately")
    engine.connectFocuser()
    gate.signal()
    try await waitForFocuser { engine.isFocuserConnected }
    try expectUI(Array(device.events.prefix(3)) == ["connect COM4", "disconnect", "connect COM4"], "close precedes reconnect and stale connection result is ignored")
}

@MainActor
func testRememberedFocuserPort() throws {
    let suite = "collimation-camera.tests.focuser.port"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("COM9", forKey: "focuser.serialPort")
    defaults.set("COM1", forKey: "mount.serialPort")
    let engine = CollimationEngine(defaults: defaults, serialPortPaths: { ["COM1", "COM4"] })
    defer { engine.shutdown() }
    try expectUI(engine.selectedFocuserPort == "COM9" && engine.focuserPorts.contains("COM9"), "remember absent focuser port")
    try expectUI(engine.selectedSerialPort == "COM1", "focuser selection independent of mount")
}
