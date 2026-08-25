import CollimationCore
import SwiftUI

struct HistogramView: View {
    let histogram: Histogram
    let stretch: StretchParams

    var body: some View {
        Canvas { context, size in
            let maxBin = max(histogram.bins.max() ?? 1, 1)
            let barW = size.width / CGFloat(Histogram.binCount)
            for (i, value) in histogram.bins.enumerated() {
                let h = CGFloat(value) / CGFloat(maxBin) * size.height
                let rect = CGRect(x: CGFloat(i) * barW, y: size.height - h, width: max(barW, 0.5), height: h)
                context.fill(Path(rect), with: .color(Color.white.opacity(0.55)))
            }
            let blackX = stretch.black * size.width
            let whiteX = stretch.white * size.width
            var black = Path()
            black.move(to: CGPoint(x: blackX, y: 0))
            black.addLine(to: CGPoint(x: blackX, y: size.height))
            context.stroke(black, with: .color(.blue.opacity(0.9)), lineWidth: 1)
            var white = Path()
            white.move(to: CGPoint(x: whiteX, y: 0))
            white.addLine(to: CGPoint(x: whiteX, y: size.height))
            context.stroke(white, with: .color(.orange.opacity(0.9)), lineWidth: 1)
        }
        .background(Color.black.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

struct CompassDial: View {
    let degrees: Double?
    let magnitude: Double

    var body: some View {
        Canvas { context, size in
            let r = min(size.width, size.height) / 2 - 4
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let circle = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            context.stroke(circle, with: .color(.white.opacity(0.35)), lineWidth: 1)

            for (label, angle) in [("R", 0.0), ("D", 90.0), ("L", 180.0), ("U", 270.0)] {
                let rad = angle * .pi / 180
                let p = CGPoint(x: c.x + cos(rad) * (r - 10), y: c.y + sin(rad) * (r - 10))
                context.draw(
                    Text(label).font(.system(size: 8, weight: .semibold, design: .monospaced)).foregroundColor(.white.opacity(0.6)),
                    at: p
                )
            }

            if let degrees {
                let rad = degrees * .pi / 180
                let length = r * min(1, 0.25 + magnitude * 3)
                var arrow = Path()
                arrow.move(to: c)
                arrow.addLine(to: CGPoint(x: c.x + cos(rad) * length, y: c.y + sin(rad) * length))
                context.stroke(arrow, with: .color(Color(red: 1, green: 0.4, blue: 0.3)), lineWidth: 2)
            }
        }
    }
}

struct SidebarView: View {
    @ObservedObject var engine: CollimationEngine

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                cameraSection
                roiSection
                stretchSection
                collimationSection
            }
            .padding(14)
        }
        .frame(minWidth: 280, idealWidth: 300, maxWidth: 340)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var cameraSection: some View {
        GroupBox("Camera") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Device", selection: $engine.selectedDeviceID) {
                    ForEach(engine.devices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .labelsHidden()
                .disabled(engine.isConnected)

                HStack {
                    Button(engine.isConnected ? "Disconnect" : "Connect") {
                        if engine.isConnected {
                            engine.disconnect()
                        } else {
                            engine.connect()
                        }
                    }
                    .keyboardShortcut(.return)
                    Button("Refresh") { engine.refreshDevices() }
                        .disabled(engine.isConnected)
                }

                HStack(alignment: .bottom, spacing: 8) {
                    CommitSlider(
                        title: "Exposure",
                        value: logExposureBinding,
                        range: logExposureRange,
                        format: exposureLabel(engine.exposureMicroseconds),
                        onCommit: { engine.applyExposure() }
                    )
                    Button("Auto") { engine.autoExpose() }
                        .disabled(!engine.isConnected)
                        .help("Set exposure so the brightest pixels sit near 80% of saturation")
                }
                CommitSlider(
                    title: "Gain",
                    value: $engine.gain,
                    range: engine.gainRange,
                    format: String(format: "%.0f", engine.gain),
                    onCommit: { engine.applyGain() }
                )

                Text(engine.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var roiSection: some View {
        GroupBox("ROI & zoom") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("ROI", selection: $engine.roiSize) {
                    Text("256").tag(256)
                    Text("512").tag(512)
                    Text("1024").tag(1024)
                    Text("2048").tag(2048)
                    Text("Full").tag(0)
                }
                .pickerStyle(.segmented)
                .onChange(of: engine.roiSize) { _ in
                    engine.applyROISize()
                }

                Toggle("Auto-center star", isOn: $engine.autoCenter)
                Toggle("Stabilize view", isOn: $engine.stabilize)
                    .help("Nudge the live view so the detected centroid stays still in the window")
                Button("Search full frame") { engine.searchNow() }
                    .disabled(!engine.isConnected)

                HStack {
                    Text("Zoom")
                    Slider(value: $engine.zoom, in: CollimationEngine.minZoom...CollimationEngine.maxZoom)
                    Text(String(format: "%.0f%%", engine.zoom * 100))
                        .font(.caption.monospacedDigit())
                        .frame(width: 48, alignment: .trailing)
                }
                Button("Fit to window") {
                    engine.fitZoom()
                }
            }
        }
    }

    private var stretchSection: some View {
        GroupBox("Stretch") {
            VStack(alignment: .leading, spacing: 8) {
                HistogramView(histogram: engine.histogram, stretch: engine.stretch)
                    .frame(height: 56)
                CommitSlider(title: "Black", value: $engine.stretch.black, range: 0...1, format: pct(engine.stretch.black))
                CommitSlider(title: "White", value: $engine.stretch.white, range: 0...1, format: pct(engine.stretch.white))
                CommitSlider(title: "Midtones", value: $engine.stretch.midtones, range: 0.01...0.99, format: String(format: "%.3f", engine.stretch.midtones))
                Button("Auto stretch") { engine.autoStretch() }
                    .keyboardShortcut("a", modifiers: [.command])
            }
        }
    }

    private var collimationSection: some View {
        GroupBox("Collimation") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        metric("Coma", value: comaText)
                        metric("Direction", value: directionText)
                        metric("Asymmetry", value: asymmetryText)
                        metric("SNR", value: snrText)
                    }
                    Spacer()
                    CompassDial(degrees: engine.coma?.directionDegrees, magnitude: engine.coma?.magnitudeNormalized ?? 0)
                        .frame(width: 88, height: 88)
                }
                Button(engine.showOverlay ? "Hide overlay" : "Show overlay") {
                    engine.showOverlay.toggle()
                }
                .help("Toggle crosshairs, fitted circles, and the coma arrow on the live view")
                Text(qualityText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var comaText: String {
        guard let coma = engine.coma else { return "—" }
        return String(format: "%.3f  (%.1f px)", coma.magnitudeNormalized, coma.magnitudePixels)
    }

    private var directionText: String {
        guard let coma = engine.coma else { return "—" }
        return String(format: "%.0f°", coma.directionDegrees)
    }

    private var asymmetryText: String {
        guard let coma = engine.coma else { return "—" }
        return String(format: "%.2f", coma.sectorAsymmetry)
    }

    private var snrText: String {
        if engine.tracking.state == .lost || engine.tracking.state == .searching {
            return "star lost"
        }
        if let snr = engine.tracking.detection?.snr {
            return String(format: "%.0f", snr)
        }
        return "—"
    }

    private var qualityText: String {
        switch engine.tracking.state {
        case .searching:
            return "Searching the full frame for the artificial star."
        case .lost:
            return "Star dropped out of the ROI. Search starts after a few frames."
        case .tracking:
            if let q = engine.coma?.quality, q >= 0.6 {
                return "Donut locked. Reduce the normalized coma toward zero."
            }
            return "Star found. Defocus until the secondary shadow is clear."
        case .idle:
            return "Connect a camera or the simulator to begin."
        }
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title.uppercased())
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .monospaced))
        }
    }

    private var logExposureRange: ClosedRange<Double> {
        log10(engine.exposureRange.lowerBound)...log10(engine.exposureRange.upperBound)
    }

    private var logExposureBinding: Binding<Double> {
        Binding(
            get: {
                log10(min(max(engine.exposureMicroseconds, engine.exposureRange.lowerBound), engine.exposureRange.upperBound))
            },
            set: { engine.exposureMicroseconds = pow(10, $0) }
        )
    }

    private func exposureLabel(_ us: Double) -> String {
        let ms = us / 1000
        if ms < 1 {
            return String(format: "%.2f ms", ms)
        }
        if ms < 10 {
            return String(format: "%.1f ms", ms)
        }
        return String(format: "%.0f ms", ms)
    }

    private func pct(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }
}

private struct CommitSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String
    var onCommit: () -> Void = {}
    @State private var dragging = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(format)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, onEditingChanged: { editing in
                if editing {
                    dragging = true
                } else if dragging {
                    dragging = false
                    onCommit()
                }
            })
        }
    }
}
