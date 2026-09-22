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
        (
            "Save constellation TIFF",
            "Moves the star to the sensor center and eight points on a circle 80% of the frame height, stacks \(engine.stackFrameCount) frames at each 256 crop, and writes a 3×3 mosaic.",
            engine.suggestedConstellationName()
        )
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
        public static let cameraSearchFullFrame = "camera.searchFullFrame"
        public static let cameraStabilize = "camera.stabilize"
        public static let cameraAutoCenter = "camera.autoCenter"
        public static let mountConnect = "mount.connect"
        public static let mountRefreshPorts = "mount.refreshPorts"
        public static let mountCalibrate = "mount.calibrate"
        public static let mountCenter = "mount.center"
        public static let filterWheelConnect = "filterWheel.connect"
        public static let filterWheelRefresh = "filterWheel.refresh"
        public static let viewOverlay = "view.overlay"
        public static let viewFitToWindow = "view.fitToWindow"

        /// `filter.<position>` for the ⌥1…⌥9 slot commands.
        public static func filter(_ position: Int) -> String { "filter.\(position)" }
    }

    // MARK: - Catalog

    @MainActor
    public static let all: [Command] = [
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
            isEnabled: { $0.canSaveConstellation },
            perform: { engine, host in
                save(engine, host, constellationDialog(engine)) { $0.saveConstellation(to: $1) }
            }
        ),
        Command(
            id: ID.cameraSearchFullFrame,
            menu: .camera,
            kind: .toggle(get: { $0.autoSearch }, set: { $0.autoSearch = $1 }),
            title: "Search Full Frame",
            shortTitle: "Search full frame",
            help: "When on, a lost star starts a binned full-frame search. The live view shows that full frame until the star is found.",
            shortcuts: [.primary("f")],
            isEnabled: { $0.canSearchFullFrame }
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
            id: ID.cameraAutoCenter,
            menu: nil,
            kind: .toggle(get: { $0.autoCenter }, set: { $0.autoCenter = $1 }),
            title: "Auto-center star",
            shortTitle: "Auto-center star",
            help: "Keep the 2048×2048 camera window on the star. The live view is a 512×512 software crop.",
            isEnabled: { $0.canToggleAutoCenter }
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
            kind: .toggle(get: { $0.showOverlay }, set: { $0.showOverlay = $1 }),
            title: { _ in "Collimation Overlay" },
            shortTitle: { $0.showOverlay ? "Hide overlay" : "Show overlay" },
            help: "Toggle crosshairs, fitted circles, and the coma arrow on the live view",
            shortcuts: [.primary("o")]
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
