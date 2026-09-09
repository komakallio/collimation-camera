import CollimationCore
import CollimationUI
import Foundation

struct UIModelExpectation: Error, CustomStringConvertible {
    var description: String
}

func expectUI(_ condition: Bool, _ message: String) throws {
    if !condition { throw UIModelExpectation(description: message) }
}

/// A fresh engine on the simulator with no serial ports and its own defaults
/// suite, so nothing on the developer's machine changes the result.
@MainActor
func makeTestEngine(suffix: String) throws -> (CollimationEngine, String) {
    let suiteName = "collimation-camera.tests.ui.\(suffix)"
    UserDefaults.standard.removePersistentDomain(forName: suiteName)
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        throw UIModelExpectation(description: "could not open the defaults suite")
    }
    let engine = CollimationEngine(defaults: defaults, serialPortPaths: { [] })
    // init() prefers a hardware camera, and the loader search order finds a
    // vendor library from the repo root, so pin the simulator explicitly.
    engine.selectedDeviceID = CameraDescriptor.simulator.id
    return (engine, suiteName)
}

@MainActor
func testCommandCatalogEnablement() throws {
    let (engine, suite) = try makeTestEngine(suffix: "enablement")
    defer {
        engine.disconnect()
        engine.shutdown()
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    func enabled(_ id: String) throws -> Bool {
        guard let command = CommandCatalog.command(id) else {
            throw UIModelExpectation(description: "no command with id \(id)")
        }
        return command.isEnabled(engine)
    }

    // Disconnected.
    for id in [
        CommandCatalog.ID.cameraConnect,
        CommandCatalog.ID.cameraRefreshDevices,
        CommandCatalog.ID.cameraAutoStretch,
        CommandCatalog.ID.viewOverlay,
        CommandCatalog.ID.cameraStabilize,
        CommandCatalog.ID.mountRefreshPorts,
        CommandCatalog.ID.filterWheelRefresh,
        CommandCatalog.ID.viewFitToWindow,
    ] {
        try expectUI(try enabled(id), "\(id) should be enabled while disconnected")
    }
    for id in [
        CommandCatalog.ID.cameraAutoExpose,
        CommandCatalog.ID.cameraSaveTIFF,
        CommandCatalog.ID.cameraSaveStacked,
        CommandCatalog.ID.cameraSaveConstellation,
        CommandCatalog.ID.mountCalibrate,
        CommandCatalog.ID.mountCenter,
        CommandCatalog.ID.cameraSearchFullFrame,
        CommandCatalog.ID.mountConnect,
    ] {
        try expectUI(!(try enabled(id)), "\(id) should be disabled while disconnected")
    }
    try expectUI(
        try enabled(CommandCatalog.ID.filterWheelConnect) == !engine.filterWheels.isEmpty,
        "connect filter wheel follows whether a wheel was found"
    )
    try expectUI(CommandCatalog.filterCommands(engine).allSatisfy { !$0.isEnabled(engine) },
                 "filter slots disabled while the wheel is disconnected")
    try expectUI(engine.canToggleAutoCenter, "auto-center is free while idle")

    // Connected to the simulator.
    engine.connect()
    try expectUI(engine.isConnected, "simulator connected")
    try expectUI(try enabled(CommandCatalog.ID.cameraAutoExpose), "auto exposure once connected")
    try expectUI(try enabled(CommandCatalog.ID.cameraSaveTIFF), "save TIFF once connected")
    try expectUI(try enabled(CommandCatalog.ID.cameraSearchFullFrame), "search once connected")
    try expectUI(!(try enabled(CommandCatalog.ID.cameraRefreshDevices)), "refresh devices locked while connected")
    // tracking.state stays .idle until the first async publish, which this
    // runner never drains, so these two stay off.
    try expectUI(!(try enabled(CommandCatalog.ID.cameraSaveStacked)), "save stacked needs tracking")
    try expectUI(!(try enabled(CommandCatalog.ID.mountCalibrate)), "calibrate needs a mount and tracking")
}

@MainActor
func testCommandCatalogCoverage() throws {
    let (engine, suite) = try makeTestEngine(suffix: "coverage")
    defer {
        engine.shutdown()
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    for command in CommandCatalog.all {
        try expectUI(
            command.menu != nil || command.shortTitle != nil,
            "\(command.id) is sidebar-only so it needs a shortTitle"
        )
        try expectUI(!command.title(engine).isEmpty, "\(command.id) has a title")
    }

    let ids = Set(CommandCatalog.all.map(\.id))
    try expectUI(ids.count == CommandCatalog.all.count, "command ids are unique")
    for id in [
        CommandCatalog.ID.cameraRefreshDevices,
        CommandCatalog.ID.filterWheelRefresh,
        CommandCatalog.ID.mountRefreshPorts,
        CommandCatalog.ID.viewFitToWindow,
    ] {
        guard let command = CommandCatalog.command(id) else {
            throw UIModelExpectation(description: "missing sidebar-only command \(id)")
        }
        try expectUI(command.menu == nil, "\(id) is sidebar-only")
    }

    // Every menu is populated, and the filter menu grows with the wheel.
    for menu in CommandMenu.allCases {
        try expectUI(
            !CommandCatalog.commands(in: menu, engine: engine).isEmpty,
            "\(menu.title) menu has commands"
        )
    }
}

@MainActor
func testShortcutUniqueness() throws {
    let (engine, suite) = try makeTestEngine(suffix: "shortcuts")
    defer {
        engine.shutdown()
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    var seen: [Shortcut: String] = [:]
    for command in CommandCatalog.all + CommandCatalog.filterCommands(engine) {
        for shortcut in command.shortcuts {
            if let owner = seen[shortcut] {
                throw UIModelExpectation(
                    description: "\(command.id) reuses \(shortcut.displayString) from \(owner)"
                )
            }
            seen[shortcut] = command.id
        }
    }

    // The pre-port bindings must survive the move to the catalog.
    try expectUI(seen[.primary("k")] == CommandCatalog.ID.cameraConnect, "⌘K connects")
    try expectUI(seen[.return] == CommandCatalog.ID.cameraConnect, "Return connects")
    try expectUI(seen[.primary("a")] == CommandCatalog.ID.cameraAutoStretch, "⌘A auto stretch")
    try expectUI(seen[.primary("e")] == CommandCatalog.ID.cameraAutoExpose, "⌘E auto exposure")
    try expectUI(seen[.primary("s")] == CommandCatalog.ID.cameraSaveTIFF, "⌘S save")
    try expectUI(seen[.primaryShift("s")] == CommandCatalog.ID.cameraSaveStacked, "⇧⌘S save stacked")
    try expectUI(seen[.primary("f")] == CommandCatalog.ID.cameraSearchFullFrame, "⌘F search")
    try expectUI(seen[.primary("l")] == CommandCatalog.ID.cameraStabilize, "⌘L stabilize")
    try expectUI(seen[.primaryShift("g")] == CommandCatalog.ID.mountCalibrate, "⇧⌘G calibrate")
    try expectUI(seen[.primary("g")] == CommandCatalog.ID.mountCenter, "⌘G center")
    try expectUI(seen[.primary("o")] == CommandCatalog.ID.viewOverlay, "⌘O overlay")

    // The portable app turns each shortcut into one ImGui key chord, and its
    // key table covers Return, A-Z, and 0-9. Anything else would be listed in
    // the menu and then silently never fire on Windows.
    for (shortcut, owner) in seen {
        switch shortcut.key {
        case .return:
            continue
        case .character(let character):
            let lower = Character(character.lowercased())
            try expectUI(
                lower.isASCII && (lower.isLetter || lower.isNumber),
                "\(owner) binds \(character), which the portable app's key table cannot map"
            )
        }
    }
}

func testMetricText() throws {
    try expectUI(MetricText.coma(nil) == "—", "no coma")
    try expectUI(MetricText.direction(nil) == "—", "no direction")
    try expectUI(MetricText.fwhm(nil, trackingState: .tracking) == "—", "no fwhm")
    try expectUI(MetricText.fwhm(nil, trackingState: .lost) == "—", "fwhm blank when lost")
    try expectUI(MetricText.snr(nil, trackingState: .lost) == "star lost", "snr when lost")
    try expectUI(MetricText.snr(nil, trackingState: .tracking) == "—", "snr without a detection")

    try expectUI(MetricText.exposureLabel(microseconds: 500) == "0.50 ms", "sub-ms exposure")
    try expectUI(MetricText.exposureLabel(microseconds: 5_000) == "5.0 ms", "single-digit ms")
    try expectUI(MetricText.exposureLabel(microseconds: 50_000) == "50 ms", "tens of ms")
    try expectUI(MetricText.percent(0.1234) == "12.3%", "percent")
    try expectUI(MetricText.gain(120.4) == "120", "gain")
    try expectUI(MetricText.midtones(0.123456) == "0.1235", "midtones")
    try expectUI(MetricText.arcsinhFactor(12.34) == "12.3", "arcsinh factor")
    try expectUI(MetricText.zoomPercent(1.5) == "150%", "zoom percent")
    try expectUI(MetricText.zoomAndFPS(zoom: 1, fps: 29.7) == "100%  ·  29.7 fps", "zoom and fps")

    try expectUI(MetricText.serialPortName("/dev/cu.usbserial-1") == "cu.usbserial-1", "posix port name")
    try expectUI(MetricText.serialPortName("COM3") == "COM3", "windows port name")
    try expectUI(MetricText.filterWheelPlaceholder(sdkPresent: false) == "SDK not found", "no wheel sdk")
    try expectUI(MetricText.filterWheelPlaceholder(sdkPresent: true) == "No Phoenix wheel", "wheel sdk present")

    try expectUI(
        MetricText.quality(trackingState: .idle, starPeak: nil, coma: nil)
            == "Connect a camera or the simulator to begin.",
        "idle quality text"
    )
    try expectUI(
        MetricText.quality(trackingState: .tracking, starPeak: 0xFFFF, coma: nil)
            .contains("saturating"),
        "saturated quality text"
    )

    // The backlash line appears only when an axis exceeds half a pixel.
    let quiet = GuideCalibration(
        eastRate: SIMD2(1, 0),
        northRate: SIMD2(0, 1),
        sampleDurationMs: 500,
        raBacklashPixels: 0.2,
        decBacklashPixels: 0.4
    )
    try expectUI(MetricText.calibrationSummary(quiet).count == 1, "no backlash line under 0.5 px")
    let loose = GuideCalibration(
        eastRate: SIMD2(1, 0),
        northRate: SIMD2(0, 1),
        sampleDurationMs: 500,
        raBacklashPixels: 3.4,
        decBacklashPixels: 0.1
    )
    let lines = MetricText.calibrationSummary(loose)
    try expectUI(lines.count == 2, "backlash line over 0.5 px")
    try expectUI(lines[1] == "Backlash  RA 3 px  ·  Dec 0 px", "backlash line \(lines[1])")
}

func testStatusChip() throws {
    try expectUI(
        StatusChip.model(stackWork: nil, mountWork: nil, isAutoExposing: false, trackingState: .idle).label == "IDLE",
        "idle chip"
    )
    try expectUI(
        StatusChip.model(stackWork: nil, mountWork: nil, isAutoExposing: false, trackingState: .tracking).label == "TRACKING",
        "tracking chip"
    )
    try expectUI(
        StatusChip.model(stackWork: nil, mountWork: nil, isAutoExposing: true, trackingState: .tracking).label == "AUTO-EXPOSURE",
        "auto exposure outranks tracking"
    )
    try expectUI(
        StatusChip.model(stackWork: nil, mountWork: .centering, isAutoExposing: true, trackingState: .tracking).label == "CENTERING",
        "mount work outranks auto exposure"
    )
    try expectUI(
        StatusChip.model(
            stackWork: .capturing(collected: 3, target: 10),
            mountWork: .centering,
            isAutoExposing: true,
            trackingState: .tracking
        ).label == "STACKING 3/10",
        "stack work outranks everything"
    )
    try expectUI(
        StatusChip.model(
            stackWork: .constellationCapturing(step: 2, steps: 9, collected: 4, target: 20),
            mountWork: nil,
            isAutoExposing: false,
            trackingState: .tracking
        ).label == "CONST 2/9  4/20",
        "constellation capture chip"
    )
    try expectUI(
        StatusChip.model(stackWork: nil, mountWork: nil, isAutoExposing: false, trackingState: .lost).color == .systemRed,
        "lost is system red"
    )
}

func testHUDColor() throws {
    try expectUI(HUDColor.systemOrange.packedABGR == 0xFF00_95FF, "orange packs to ABGR")
    try expectUI(HUDColor.white.packedABGR == 0xFFFF_FFFF, "white packs to ABGR")
    try expectUI(HUDColor.black.opacity(0.5).packedABGR == 0x8000_0000, "half-alpha black")
    try expectUI(HUDColor(red: 255, green: 59, blue: 48) == .systemRed, "red from 0-255 components")

    // §8.7: milestone 2 replaced the named SwiftUI system colours with
    // resolved sRGB constants, so both apps can draw the same pixels. These
    // are Apple's published light-appearance values; a drift here is a HUD
    // that no longer matches the pre-port screenshots.
    for (name, color, expected) in [
        ("systemRed", HUDColor.systemRed, (255, 59, 48)),
        ("systemOrange", HUDColor.systemOrange, (255, 149, 0)),
        ("systemYellow", HUDColor.systemYellow, (255, 204, 0)),
        ("systemBlue", HUDColor.systemBlue, (0, 122, 255)),
        ("systemGray", HUDColor.systemGray, (142, 142, 147)),
    ] {
        let packed = color.packedABGR
        let components = (Int(packed & 0xFF), Int((packed >> 8) & 0xFF), Int((packed >> 16) & 0xFF))
        try expectUI(
            components == expected,
            "\(name) is \(components), Apple's is \(expected)"
        )
        try expectUI(packed >> 24 == 0xFF, "\(name) is opaque")
    }
}

func testLogSlider() throws {
    let range = LogSlider.range(100...100_000)
    try expectUI(abs(range.lowerBound - 2) < 1e-12, "log lower bound")
    try expectUI(abs(range.upperBound - 5) < 1e-12, "log upper bound")
    try expectUI(abs(LogSlider.position(1_000, in: 100...100_000) - 3) < 1e-12, "log position")
    try expectUI(abs(LogSlider.position(1, in: 100...100_000) - 2) < 1e-12, "clamped low")
    try expectUI(abs(LogSlider.value(3) - 1_000) < 1e-9, "log value")
}

/// Both apps point `Log.sink` here, so the rotation and the write path are
/// worth pinning: a lost log is only noticed when it is needed.
func testLogFile() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("collimation-log-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }

    let previousSink = Log.sink
    defer { Log.sink = previousSink }

    guard let first = LogFile.start(in: directory) else {
        throw UIModelExpectation(description: "the log did not open in \(directory.path)")
    }
    try expectUI(first.lastPathComponent == LogFile.name(), "named \(first.lastPathComponent)")
    Log.info("first run")
    LogFile.stop()

    let firstText = try String(contentsOf: first, encoding: .utf8)
    try expectUI(firstText.contains("first run"), "the line was written: \(firstText)")
    // Each line is timestamped, so the message is not at the start.
    try expectUI(firstText.hasSuffix("first run\n"), "one line, newline terminated")

    // A second start rotates the first run aside rather than appending to it.
    guard LogFile.start(in: directory) != nil else {
        throw UIModelExpectation(description: "the log did not reopen")
    }
    Log.info("second run")
    LogFile.stop()

    let previous = directory.appendingPathComponent(LogFile.previousName())
    try expectUI(FileManager.default.fileExists(atPath: previous.path), "the previous run is kept")
    let previousText = try String(contentsOf: previous, encoding: .utf8)
    try expectUI(previousText.contains("first run"), "the previous run has the first line")
    let currentText = try String(contentsOf: first, encoding: .utf8)
    try expectUI(currentText.contains("second run"), "the current run has the second line")
    try expectUI(!currentText.contains("first run"), "the current run starts empty")

    // A third start does not accumulate: only one generation is kept.
    guard LogFile.start(in: directory) != nil else {
        throw UIModelExpectation(description: "the log did not open a third time")
    }
    LogFile.stop()
    let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    try expectUI(files == [LogFile.name(), LogFile.previousName()].sorted(), "two files, got \(files)")

    // A second app in the same directory gets its own file and its own
    // history, which is what lets both macOS apps run side by side.
    guard let other = LogFile.start(basename: "collimation-portable", in: directory) else {
        throw UIModelExpectation(description: "the second basename did not open")
    }
    Log.info("other app")
    LogFile.stop()
    try expectUI(other.lastPathComponent == "collimation-portable.log", "named \(other.lastPathComponent)")
    let untouched = try String(contentsOf: first, encoding: .utf8)
    try expectUI(!untouched.contains("other app"), "the first app's file was not written to")
}
