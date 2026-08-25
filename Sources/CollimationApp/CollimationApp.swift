import CollimationCore
import SwiftUI

@main
struct CollimationApp: App {
    @StateObject private var engine = CollimationEngine()

    var body: some Scene {
        WindowGroup("Collimation Camera") {
            ContentView()
                .environmentObject(engine)
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
                Button("Search Full Frame") { engine.searchNow() }
                    .keyboardShortcut("f", modifiers: [.command])
            }
        }
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
        OverlayView(overlay: engine.overlay, zoom: engine.zoom)
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
                    .padding(10)
                    Spacer()
                }
            }
            .background(Color.black)
        }
        .alert("Camera error", isPresented: Binding(
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
