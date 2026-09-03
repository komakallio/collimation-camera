import AppKit
import CollimationCore
import SwiftUI
import UniformTypeIdentifiers

@main
struct CollimationApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var engine = CollimationEngine()

    var body: some Scene {
        WindowGroup("Collimation Camera") {
            ContentView()
                .environmentObject(engine)
                .onAppear {
                    appDelegate.stopCapture = { engine.shutdown() }
                }
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Camera") {
                Button(engine.isConnected ? "Disconnect" : "Connect") {
                    if engine.isConnected { engine.disconnect() } else { engine.connect() }
                }
                .keyboardShortcut("k", modifiers: [.command])
                Button("Auto Stretch") { engine.autoStretch() }
                    .keyboardShortcut("a", modifiers: [.command])
                Button("Auto Exposure") { engine.autoExpose() }
                    .keyboardShortcut("e", modifiers: [.command])
                Button("Save TIFF…") { SnapshotExport.present(engine: engine) }
                    .keyboardShortcut("s", modifiers: [.command])
                    .disabled(!engine.isConnected || engine.isStacking)
                Button("Save Stacked…") { SnapshotExport.presentStacked(engine: engine) }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(!engine.isConnected || engine.isStacking || engine.isMountBusy || engine.tracking.state != .tracking)
                Toggle("Search Full Frame", isOn: $engine.autoSearch)
                    .keyboardShortcut("f", modifiers: [.command])
                Toggle("Stabilize View", isOn: $engine.stabilize)
                    .keyboardShortcut("l", modifiers: [.command])
            }
            CommandMenu("Mount") {
                Button(engine.isMountConnected ? "Disconnect Mount" : "Connect Mount") {
                    if engine.isMountConnected { engine.disconnectMount() } else { engine.connectMount() }
                }
                Button("Calibrate Mount") { engine.calibrateMount() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled(!engine.isMountConnected || engine.isMountBusy || engine.tracking.state != .tracking)
                Button("Center Star") { engine.centerStar() }
                    .keyboardShortcut("g", modifiers: [.command])
                    .disabled(!engine.isMountConnected || !engine.isMountCalibrated || engine.isMountBusy || engine.tracking.state != .tracking)
            }
            CommandMenu("Filter Wheel") {
                Button(engine.isFilterWheelConnected ? "Disconnect Filter Wheel" : "Connect Filter Wheel") {
                    if engine.isFilterWheelConnected {
                        engine.disconnectFilterWheel()
                    } else {
                        engine.connectFilterWheel()
                    }
                }
                .disabled((engine.filterWheels.isEmpty && !engine.isFilterWheelConnected) || engine.isFilterWheelMoving)
                Divider()
                ForEach(engine.filterSlots) { slot in
                    filterMenuItem(slot)
                }
            }
            CommandMenu("View") {
                Toggle("Collimation Overlay", isOn: $engine.showOverlay)
                    .keyboardShortcut("o", modifiers: [.command])
            }
        }
    }

    @ViewBuilder
    private func filterMenuItem(_ slot: FilterSlot) -> some View {
        let button = Button(slot.displayName) { engine.gotoFilter(slot.position) }
            .disabled(!engine.isFilterWheelConnected || engine.isFilterWheelMoving)
        if slot.position < 9 {
            button.keyboardShortcut(
                KeyEquivalent(Character(UnicodeScalar(0x31 + slot.position)!)),
                modifiers: [.option]
            )
        } else {
            button
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Runs synchronously on quit so `libPlayerOneCamera` is not torn down
    /// while the capture thread is still inside `POAImageReady`.
    var stopCapture: (() -> Void)?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // `swift run` launches an unbundled binary. Without this, macOS keeps
        // Terminal as the active app and the menu bar never switches over.
        ProcessInfo.processInfo.processName = "Collimation Camera"
        NSApplication.shared.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyAppIcon()
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApp.windows.forEach { $0.makeKeyAndOrderFront(nil) }
    }

    @MainActor
    private func applyAppIcon() {
        var paths: [String] = []
        if let bundled = Bundle.main.path(forResource: "AppIcon", ofType: "icns") {
            paths.append(bundled)
        }
        if let exe = Bundle.main.executablePath {
            let url = URL(fileURLWithPath: exe)
            paths.append(url.deletingLastPathComponent().appendingPathComponent("AppIcon.icns").path)
            paths.append(
                url.deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appendingPathComponent("Resources/AppIcon.icns").path
            )
        }
        paths.append(FileManager.default.currentDirectoryPath + "/Resources/AppIcon.icns")
        for path in paths {
            if let image = NSImage(contentsOfFile: path) {
                NSApp.applicationIconImage = image
                return
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        stopCapture?()
        stopCapture = nil
        return .terminateNow
    }
}

struct ContentView: View {
    @EnvironmentObject private var engine: CollimationEngine

    var body: some View {
        NavigationSplitView {
            SidebarView(engine: engine)
        } detail: {
            ZStack {
                LiveView(engine: engine)
                liveChrome
            }
            .background(Color.black)
        }
        .alert("Error", isPresented: Binding(
            get: { engine.errorMessage != nil },
            set: { if !$0 { engine.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { engine.errorMessage = nil }
        } message: {
            Text(engine.errorMessage ?? "")
        }
        .onAppear {
            if !engine.isConnected {
                engine.connect()
            }
        }
    }

    @ViewBuilder
    private var liveChrome: some View {
        if engine.stabilize {
            TimelineView(.periodic(from: .now, by: 1.0 / 60.0)) { _ in
                chrome(pose: engine.renderStateSlot.peek())
            }
        } else {
            chrome(pose: nil)
        }
    }

    private func chrome(pose: RenderState?) -> some View {
        ZStack {
            if engine.showOverlay {
                OverlayView(
                    overlay: engine.overlay,
                    zoom: engine.zoom,
                    lockNormalized: pose?.stabilizeLock,
                    liveCentroid: pose?.stabilizeCentroid,
                    displayedWidth: pose?.imageWidth,
                    displayedHeight: pose?.imageHeight
                )
            }
            VStack {
                HStack {
                    stateChip
                    Spacer()
                    Text(String(format: "%.0f%%  ·  %.1f fps", engine.zoom * 100, engine.fps))
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.45), in: Capsule())
                        .foregroundStyle(.white)
                }
                Spacer()
                HStack {
                    Spacer()
                    VStack(alignment: .trailing, spacing: 8) {
                        if engine.showOverlay {
                            OverlayLegendView()
                        }
                        if engine.overlay.sensorWidth > 0, engine.overlay.sensorHeight > 0 {
                            HStack(alignment: .bottom, spacing: 6) {
                                StarProfileView(profile: engine.starProfile)
                                ROIMapView(
                                    sensorWidth: engine.overlay.sensorWidth,
                                    sensorHeight: engine.overlay.sensorHeight,
                                    roi: pose?.roi ?? engine.overlay.roi,
                                    centroidInFrame: pose?.stabilizeCentroid ?? engine.overlay.centroid
                                )
                            }
                        }
                    }
                }
            }
            .padding(10)
        }
        .allowsHitTesting(false)
    }

    private var stateChip: some View {
        let (label, color): (String, Color) = {
            if let work = engine.mountWork {
                switch work {
                case .calibrating:
                    return ("CALIBRATING", Color(red: 0.95, green: 0.72, blue: 0.22))
                case .centering:
                    return ("CENTERING", Color(red: 0.45, green: 0.75, blue: 1))
                }
            }
            switch engine.tracking.state {
            case .tracking: return ("TRACKING", Color(red: 0.35, green: 0.85, blue: 0.45))
            case .searching: return ("SEARCHING", .orange)
            case .lost: return ("LOST", .red)
            case .idle: return ("IDLE", .gray)
            }
        }()
        return Text(label)
            .font(.caption2.weight(.bold).monospaced())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.85), in: Capsule())
            .foregroundStyle(.black)
    }
}

enum SnapshotExport {
    private static let directoryDefaultsKey = "snapshot.directory"

    @MainActor
    static func present(engine: CollimationEngine) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [.tiff]
        panel.nameFieldStringValue = engine.suggestedSnapshotName()
        panel.title = "Save ROI snapshot"
        panel.message = "Uncompressed 16-bit mono TIFF of the current camera ROI."
        if let saved = UserDefaults.standard.string(forKey: directoryDefaultsKey) {
            panel.directoryURL = URL(fileURLWithPath: saved, isDirectory: true)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: directoryDefaultsKey)
        engine.saveSnapshot(to: url)
    }

    @MainActor
    static func presentStacked(engine: CollimationEngine) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [.tiff]
        panel.nameFieldStringValue = engine.suggestedStackedName()
        panel.title = "Save stacked TIFF"
        panel.message = "Captures 100 ROI frames, registers them on the star centroid, averages, and writes a 32-bit float mono TIFF."
        if let saved = UserDefaults.standard.string(forKey: directoryDefaultsKey) {
            panel.directoryURL = URL(fileURLWithPath: saved, isDirectory: true)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: directoryDefaultsKey)
        engine.saveStackedSnapshot(to: url)
    }
}
