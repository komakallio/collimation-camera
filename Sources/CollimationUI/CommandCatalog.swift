import CollimationCore
import Foundation

/// Every command both apps offer, declared once.
///
/// Enablement is always an `engine.can*` predicate, never a expression spelled
/// out here, so the menu, the sidebar, and the portable app cannot disagree
/// (§7.4 item 5). Commands with no predicate are always enabled.
public enum CommandCatalog {
    // MARK: - Save dialog text

    @MainActor
    static func snapshotDialog(_ engine: CollimationEngine) -> (title: String, message: String, name: String) {
        (
            "Save ROI snapshot",
            "Uncompressed 16-bit mono TIFF of the current camera ROI.",
            engine.suggestedSnapshotName()
        )
    }

    @MainActor
    static func stackedDialog(_ engine: CollimationEngine) -> (title: String, message: String, name: String) {
        (
            "Save stacked TIFF",
            "Captures \(engine.stackFrameCount) 256×256 crops at full camera readout, registers them on the star centroid, averages, and writes a 32-bit float mono TIFF.",
            engine.suggestedStackedName()
        )
    }

    @MainActor
    static func constellationDialog(_ engine: CollimationEngine) -> (title: String, message: String, name: String) {
        if engine.recordConstellationFocusSweep { return focusConstellationDialog(engine, layout: .circular) }
        return (
            "Save constellation TIFF",
            "Moves the star to the sensor center and eight points on a circle 80% of the frame height, stacks \(engine.stackFrameCount) frames at each 256 crop, and writes a 3×3 mosaic.",
            engine.suggestedConstellationName()
        )
    }

    @MainActor
    static func gridConstellationDialog(_ engine: CollimationEngine) -> (title: String, message: String, name: String) {
        if engine.recordConstellationFocusSweep { return focusConstellationDialog(engine, layout: .rectangularGrid) }
        return (
            "Save grid constellation TIFF",
            "Moves the star to 35 positions on a 7×5 rectangular grid across the full sensor, including the corners. Keeps a 128-pixel crop margin, stacks \(engine.stackFrameCount) frames at each position, and writes a 1792×1280 float mosaic.",
            engine.suggestedConstellationName(layout: .rectangularGrid)
        )
    }

    @MainActor
    static func focusConstellationDialog(_ engine: CollimationEngine, layout: ConstellationLayout) -> (title: String, message: String, name: String) {
        let count = engine.constellationFocusSweepSettings?.count ?? 0
        return ("Save focus constellation TIFF",
         "Centres the star and autofocuses, then records \(layout.positionCount) star placements at \(count) common focus positions: centre best focus ±\(engine.constellationFocusSweepRange) steps in \(engine.constellationFocusSweepStep)-step increments. Stacks \(engine.stackFrameCount) frames at each position. Uses the autofocus take-up setting for backlash, and saves all focus layers in one TIFF.",
         engine.suggestedConstellationName(layout: layout))
    }

    @MainActor
    private static func save(
        _ engine: CollimationEngine,
        _ host: any UIHost,
        _ text: (title: String, message: String, name: String),
        _ write: @escaping @MainActor (CollimationEngine, URL) -> Void
    ) {
        host.presentSaveDialog(
            title: text.title,
            message: text.message,
            suggestedName: text.name,
            directory: engine.snapshotDirectory
        ) { url in
            guard let url else { return }
            engine.snapshotDirectory = url.deletingLastPathComponent()
            write(engine, url)
        }
    }

    // MARK: - Command ids

    public enum ID {
        public static let cameraConnect = "camera.connect"
        public static let cameraRefreshDevices = "camera.refreshDevices"
        public static let cameraAutoStretch = "camera.autoStretch"
        public static let cameraAutoExpose = "camera.autoExpose"
        public static let cameraSaveTIFF = "camera.saveTIFF"
        public static let cameraSaveStacked = "camera.saveStacked"
        public static let cameraSaveConstellation = "camera.saveConstellation"
        public static let cameraSaveGridConstellation = "camera.saveGridConstellation"
        public static let cameraConstellationFocusSweep = "camera.constellationFocusSweep"
        public static let cameraCancelFocusConstellation = "camera.cancelFocusConstellation"
        public static let viewOpenConstellation = "view.openConstellation"
        public static let viewCamera = "view.camera"
        public static let viewConstellation = "view.constellation"
        public static let constellationFit = "constellation.fit"
        public static let constellationAutoStretch = "constellation.autoStretch"
        public static let cameraStabilize = "camera.stabilize"
        public static let mountConnect = "mount.connect"
        public static let mountRefreshPorts = "mount.refreshPorts"
        public static let mountCalibrate = "mount.calibrate"
        public static let mountCenter = "mount.center"
        public static let filterWheelConnect = "filterWheel.connect"
        public static let filterWheelRefresh = "filterWheel.refresh"
        public static let focuserConnect = "focuser.connect"
        public static let focuserRefreshPorts = "focuser.refreshPorts"
        public static let focuserIn = "focuser.in"
        public static let focuserOut = "focuser.out"
        public static let focuserGoto = "focuser.goto"
        public static let focuserStop = "focuser.stop"
        public static let focuserAutofocus = "focuser.autofocus"
        public static let focuserMeasureTilt = "focuser.measureTilt"
        public static let focuserCancelTilt = "focuser.cancelTilt"
        public static let viewOverlay = "view.overlay"
        public static let viewSensorMarks = "view.sensorMarks"
        public static let viewFitToWindow = "view.fitToWindow"
        public static let viewQuarter = "view.quarter"

        /// `filter.<position>` for the ⌥1…⌥9 slot commands.
        public static func filter(_ position: Int) -> String { "filter.\(position)" }
    }

    // MARK: - Catalog

    @MainActor
    public static let all: [Command] = [
        Command(
            id: ID.focuserMeasureTilt, menu: .focuser, title: "Measure Tilt…",
            help: "Autofocus the same star at nine constellation positions. Save images at centre focus, focus offsets and a tilt fit. Requires a calibrated mount. Repeat centre focus to report drift.",
            isEnabled: { $0.canMeasureTilt },
            perform: { engine, host in
                save(engine, host, ("Save tilt constellation", "Moves the mount and focuser. Saves nine common-focus star images and focus measurements in one TIFF.", engine.suggestedTiltName())) {
                    $0.startTiltMeasurement(to: $1)
                }
            }
        ),
        Command(
            id: ID.focuserCancelTilt, menu: .focuser, title: "Cancel Tilt",
            help: "Stop both motors and save completed measurements as a partial constellation.",
            isEnabled: { $0.isMeasuringTilt },
            perform: { engine, _ in engine.cancelTiltMeasurement() }
        ),
        Command(
            id: ID.focuserAutofocus,
            menu: .focuser,
            title: "Autofocus",
            help: HelpText.autofocus,
            isEnabled: { $0.canAutofocus },
            perform: { engine, _ in engine.startAutofocus() }
        ),
        Command(
            id: ID.focuserConnect,
            menu: .focuser,
            title: { $0.isFocuserConnected || $0.isFocuserBusy ? "Disconnect Focuser" : "Connect Focuser" },
            shortTitle: { $0.isFocuserConnected || $0.isFocuserBusy ? "Disconnect" : "Connect" },
            help: HelpText.focuser,
            isEnabled: { $0.canConnectFocuser },
            perform: { engine, _ in
                if engine.isFocuserConnected || engine.isFocuserBusy { engine.disconnectFocuser() }
                else { engine.connectFocuser() }
            }
        ),
        Command(
            id: ID.focuserRefreshPorts,
            menu: nil,
            title: "Refresh",
            shortTitle: "Refresh",
            isEnabled: { $0.canRefreshFocuserPorts },
            perform: { engine, _ in engine.refreshFocuserPorts() }
        ),
        Command(
            id: ID.focuserIn,
            menu: .focuser,
            title: "Focus In",
            shortTitle: "In",
            help: "Decrease the focuser position by the step size.",
            isEnabled: { $0.canMoveFocuserIn },
            perform: { engine, _ in engine.moveFocuserIn() }
        ),
        Command(
            id: ID.focuserOut,
            menu: .focuser,
            title: "Focus Out",
            shortTitle: "Out",
            help: "Increase the focuser position by the step size.",
            isEnabled: { $0.canMoveFocuserOut },
            perform: { engine, _ in engine.moveFocuserOut() }
        ),
        Command(
            id: ID.focuserGoto,
            menu: .focuser,
            title: "Go to Focus Position",
            shortTitle: "Go to",
            isEnabled: { $0.canGotoFocuser },
            perform: { engine, _ in engine.gotoFocuser() }
        ),
        Command(
            id: ID.focuserStop,
            menu: .focuser,
            title: "Stop Focuser",
            shortTitle: "Stop",
            isEnabled: { $0.canStopFocuser },
            perform: { engine, _ in engine.stopFocuser() }
        ),
        Command(
            id: ID.cameraConnect,
            menu: .camera,
            title: { $0.isConnected ? "Disconnect" : "Connect" },
            shortcuts: [.primary("k"), .return],
            perform: { engine, _ in
                if engine.isConnected { engine.disconnect() } else { engine.connect() }
            }
        ),
        Command(
            id: ID.cameraRefreshDevices,
            menu: nil,
            title: "Refresh",
            shortTitle: "Refresh",
            isEnabled: { $0.canRefreshDevices },
            perform: { engine, _ in engine.refreshDevices() }
        ),
        Command(
            id: ID.cameraAutoStretch,
            menu: .camera,
            title: "Auto Stretch",
            shortTitle: "Auto stretch",
            shortcuts: [.primary("a")],
            perform: { engine, _ in engine.autoStretch() }
        ),
        Command(
            id: ID.cameraAutoExpose,
            menu: .camera,
            title: "Auto Exposure",
            shortTitle: "Auto",
            help: "Iterate exposure until the brightest pixels sit near 85% of 16-bit full well",
            shortcuts: [.primary("e")],
            isEnabled: { $0.canAutoExpose },
            perform: { engine, _ in engine.autoExpose() }
        ),
        Command(
            id: ID.cameraSaveTIFF,
            menu: .camera,
            title: "Save TIFF…",
            help: "Save the current ROI as an uncompressed 16-bit mono TIFF",
            shortcuts: [.primary("s")],
            isEnabled: { $0.canSaveSnapshot },
            perform: { engine, host in
                save(engine, host, snapshotDialog(engine)) { $0.saveSnapshot(to: $1) }
            }
        ),
        Command(
            id: ID.cameraSaveStacked,
            menu: .camera,
            title: "Save Stacked…",
            shortTitle: "Save Stacked",
            help: "Capture 256×256 crops at full camera readout, register them on the star centroid, average, and save a 32-bit float TIFF",
            shortcuts: [.primaryShift("s")],
            isEnabled: { $0.canSaveStacked },
            perform: { engine, host in
                save(engine, host, stackedDialog(engine)) { $0.saveStackedSnapshot(to: $1) }
            }
        ),
        Command(
            id: ID.cameraSaveConstellation,
            menu: .camera,
            title: "Save Constellation…",
            shortTitle: "Save Constellation",
            help: "Move the star to the sensor center and eight points on an 80% circle, stack each 256 crop, and save a 3×3 mosaic.",
            isEnabled: { $0.canRecordConstellation },
            perform: { engine, host in
                save(engine, host, constellationDialog(engine)) { $0.saveConstellation(to: $1) }
            }
        ),
        Command(
            id: ID.cameraSaveGridConstellation,
            menu: .camera,
            title: "Save Grid Constellation…",
            shortTitle: "Save Grid Constellation",
            help: "Sample the full camera field with 35 star placements on a 7×5 rectangular grid, including the corners. Stack each 256 crop and save a float mosaic. Requires a calibrated mount.",
            isEnabled: { $0.canRecordConstellation },
            perform: { engine, host in
                save(engine, host, gridConstellationDialog(engine)) { $0.saveConstellation(to: $1, layout: .rectangularGrid) }
            }
        ),
        Command(
            id: ID.cameraConstellationFocusSweep, menu: .camera,
            kind: .toggle(get: { $0.recordConstellationFocusSweep }, set: { $0.recordConstellationFocusSweep = $1 }),
            title: "Record Constellation Focus Sweep", shortTitle: "Record focus sweep",
            help: HelpText.constellationFocusSweep,
            isEnabled: { $0.canSelectConstellationFocusSweep }
        ),
        Command(
            id: ID.cameraCancelFocusConstellation, menu: .camera, title: "Cancel Focus Constellation",
            shortTitle: "Cancel focus capture", help: "Stop both motors and cancel the focus constellation recording.",
            isEnabled: { $0.isCapturingFocusConstellation },
            perform: { engine, _ in engine.cancelFocusConstellation() }
        ),
        Command(
            id: ID.cameraStabilize,
            menu: .camera,
            kind: .toggle(get: { $0.stabilize }, set: { $0.stabilize = $1 }),
            title: "Stabilize View",
            shortTitle: "Stabilize view",
            help: "Nudge the live 512×512 crop so the detected centroid stays still. Off while the full sensor is shown (search or centering).",
            shortcuts: [.primary("l")]
        ),
        Command(
            id: ID.viewOpenConstellation, menu: .view, title: SidebarText.openConstellation,
            help: "Open a saved circular, grid or focus-sweep float constellation TIFF", shortcuts: [.primaryShift("o")],
            isEnabled: { $0.canOpenConstellation },
            perform: { engine, host in
                host.presentOpenConstellationDialog(directory: engine.snapshotDirectory) { url in
                    if let url { engine.openConstellation(from: url) }
                }
            }
        ),
        Command(
            id: ID.viewCamera, menu: .view, title: "Camera",
            perform: { engine, _ in engine.showingConstellation = false }
        ),
        Command(
            id: ID.viewConstellation, menu: .view, title: "Constellation Results",
            isEnabled: { $0.canShowConstellation },
            perform: { engine, _ in engine.showingConstellation = true }
        ),
        Command(
            id: ID.constellationFit, menu: nil, title: "Fit", shortTitle: "Fit",
            isEnabled: { $0.canShowConstellation },
            perform: { engine, _ in engine.constellationZoom = 1 }
        ),
        Command(
            id: ID.constellationAutoStretch, menu: nil, title: "Auto stretch", shortTitle: "Auto stretch",
            isEnabled: { $0.canShowConstellation },
            perform: { engine, _ in engine.autoStretchConstellation() }
        ),
        Command(
            id: ID.mountConnect,
            menu: .mount,
            title: { $0.isMountConnected ? "Disconnect Mount" : "Connect Mount" },
            shortTitle: { $0.isMountConnected ? "Disconnect" : "Connect" },
            isEnabled: { $0.canConnectMount },
            perform: { engine, _ in
                if engine.isMountConnected { engine.disconnectMount() } else { engine.connectMount() }
            }
        ),
        Command(
            id: ID.mountRefreshPorts,
            menu: nil,
            title: "Refresh",
            shortTitle: "Refresh",
            isEnabled: { $0.canRefreshSerialPorts },
            perform: { engine, _ in engine.refreshSerialPorts() }
        ),
        Command(
            id: ID.mountCalibrate,
            menu: .mount,
            title: "Calibrate Mount",
            shortTitle: "Calibrate",
            help: "Pulse-guide east and north, measure how the star moves, and measure backlash from where it returns.",
            shortcuts: [.primaryShift("g")],
            isEnabled: { $0.canCalibrateMount },
            perform: { engine, _ in engine.calibrateMount() }
        ),
        Command(
            id: ID.mountCenter,
            menu: .mount,
            title: "Center Star",
            shortTitle: "Center",
            help: "Centers RA and Dec together on the full sensor. Each move covers about 90% of the remaining error and lasts about 1 s. Stops after five moves even if the star is not yet on center.",
            shortcuts: [.primary("g")],
            isEnabled: { $0.canCenterStar },
            perform: { engine, _ in engine.centerStar() }
        ),
        Command(
            id: ID.filterWheelConnect,
            menu: .filterWheel,
            title: { $0.isFilterWheelConnected ? "Disconnect Filter Wheel" : "Connect Filter Wheel" },
            shortTitle: { $0.isFilterWheelConnected ? "Disconnect" : "Connect" },
            isEnabled: { $0.canConnectFilterWheel },
            perform: { engine, _ in
                if engine.isFilterWheelConnected {
                    engine.disconnectFilterWheel()
                } else {
                    engine.connectFilterWheel()
                }
            }
        ),
        Command(
            id: ID.filterWheelRefresh,
            menu: nil,
            title: "Refresh",
            shortTitle: "Refresh",
            isEnabled: { $0.canRefreshFilterWheels },
            perform: { engine, _ in engine.refreshFilterWheels() }
        ),
        Command(
            id: ID.viewOverlay,
            menu: .view,
            kind: .toggle(get: { $0.showCollimation }, set: { $0.showCollimation = $1 }),
            title: { _ in "Collimation Indicators" },
            shortTitle: { $0.showCollimation ? "Hide collimation" : "Show collimation" },
            help: "Toggle the fitted rings and the coma arrow on the live view",
            shortcuts: [.primary("o")]
        ),
        Command(
            id: ID.viewSensorMarks,
            menu: .view,
            kind: .toggle(get: { $0.showSensorMarks }, set: { $0.showSensorMarks = $1 }),
            title: { _ in "Sensor Marks" },
            shortTitle: { $0.showSensorMarks ? "Hide sensor marks" : "Show sensor marks" },
            help: "Toggle the sensor-center cross, the tracking grid, and the star marker",
            shortcuts: [.primary("m")]
        ),
        Command(
            id: ID.viewQuarter,
            menu: .view,
            kind: .toggle(get: { $0.quarterView }, set: { $0.quarterView = $1 }),
            title: "Quarter View",
            shortTitle: "Quarter view",
            help: "Keep the top-left quadrant, swap the right pair above and below, then swap the lower pair left and right. Left-right and up-down mismatches each show on a seam. The star still meets in the centre.",
            shortcuts: [.primary("j")]
        ),
        Command(
            id: ID.viewFitToWindow,
            menu: nil,
            title: "Fit to window",
            shortTitle: "Fit to window",
            perform: { engine, _ in engine.fitZoom() }
        ),
    ]

    /// One command per wheel slot. Positions below 9 get ⌥1…⌥9, matching the
    /// pre-port menu.
    @MainActor
    public static func filterCommands(_ engine: CollimationEngine) -> [Command] {
        engine.filterSlots.map { slot in
            let position = slot.position
            let label = slot.displayName
            let shortcuts: [Shortcut]
            if position < 9, let scalar = UnicodeScalar(0x31 + position) {
                shortcuts = [.option(Character(scalar))]
            } else {
                shortcuts = []
            }
            let title: @MainActor @Sendable (CollimationEngine) -> String = { _ in label }
            return Command(
                id: ID.filter(position),
                menu: .filterWheel,
                title: title,
                shortcuts: shortcuts,
                isEnabled: { $0.canSelectFilter },
                perform: { engine, _ in engine.gotoFilter(position) }
            )
        }
    }

    /// Everything in one menu, in display order, including the filter slots.
    @MainActor
    public static func commands(in menu: CommandMenu, engine: CollimationEngine) -> [Command] {
        var result = all.filter { $0.menu == menu }
        if menu == .filterWheel {
            result.append(contentsOf: filterCommands(engine))
        }
        return result
    }

    @MainActor
    public static func command(_ id: String) -> Command? {
        all.first { $0.id == id }
    }
}
