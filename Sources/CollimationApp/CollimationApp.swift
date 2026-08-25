import AppKit
import CollimationCore
import SwiftUI

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
                Button("Search Full Frame") { engine.searchNow() }
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
            CommandMenu("View") {
                Toggle("Collimation Overlay", isOn: $engine.showOverlay)
                    .keyboardShortcut("o", modifiers: [.command])
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
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApp.windows.forEach { $0.makeKeyAndOrderFront(nil) }
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
                    liveCentroid: pose?.stabilizeCentroid
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
                    if engine.overlay.sensorWidth > 0, engine.overlay.sensorHeight > 0 {
                        ROIMapView(
                            sensorWidth: engine.overlay.sensorWidth,
                            sensorHeight: engine.overlay.sensorHeight,
                            roi: engine.overlay.roi,
                            centroidInFrame: pose?.stabilizeCentroid ?? engine.overlay.centroid
                        )
                    }
                }
            }
            .padding(10)
        }
        .allowsHitTesting(false)
    }

    private var stateChip: some View {
        let (label, color): (String, Color) = {
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
