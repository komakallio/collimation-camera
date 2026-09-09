import AppKit
import CollimationCore
import CollimationUI
import SwiftUI
import UniformTypeIdentifiers

@main
struct CollimationApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var engine = CollimationEngine()
    @State private var host = MacUIHost()

    var body: some Scene {
        // The label is explicit: WindowGroup has both init(_:content:) and
        // init(_:makeContent:), and a trailing closure matches either.
        WindowGroup("Collimation Camera", content: {
            ContentView(host: host)
                .environment(engine)
                .onAppear {
                    appDelegate.stopCapture = { engine.shutdown() }
                }
        })
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}
            // Menus are built from CommandCatalog, so a shortcut or an
            // enablement rule exists in exactly one place (§8.5).
            // CollimationUI.CommandMenu is qualified throughout: SwiftUI has a
            // type of the same name.
            ForEach(CollimationUI.CommandMenu.allCases, id: \.self) { menu in
                SwiftUI.CommandMenu(menu.title) {
                    ForEach(CommandCatalog.commands(in: menu, engine: engine), id: \.id) { command in
                        CommandButton(command: command, engine: engine, host: host)
                    }
                }
            }
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
    @Environment(CollimationEngine.self) private var engine
    let host: any UIHost

    var body: some View {
        NavigationSplitView {
            SidebarView(engine: engine, host: host)
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
                    Text(MetricText.zoomAndFPS(zoom: engine.zoom, fps: engine.fps))
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
        let model = StatusChip.model(engine)
        return Text(model.label)
            .font(.caption2.weight(.bold).monospaced())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                HUDCanvas.swiftUIColor(model.color).opacity(StatusChip.backgroundOpacity),
                in: Capsule()
            )
            .foregroundStyle(.black)
    }
}
