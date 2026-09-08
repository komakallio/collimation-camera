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
    @Bindable var engine: CollimationEngine

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                cameraSection
                filterWheelSection
                mountSection
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
                Button("Save TIFF…") { SnapshotExport.present(engine: engine) }
                    .disabled(!engine.isConnected || engine.isStacking)
                    .help("Save the current ROI as an uncompressed 16-bit mono TIFF")
                HStack(spacing: 8) {
                    Button("Save Stacked") { SnapshotExport.presentStacked(engine: engine) }
                        .disabled(!engine.isConnected || engine.isStacking || engine.isMountBusy || engine.tracking.state != .tracking)
                    Picker("Frames", selection: $engine.stackFrameCount) {
                        ForEach(FrameStacker.subframeCounts, id: \.self) { count in
                            Text("\(count)").tag(count)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .disabled(engine.isStacking)
                    .help("Number of 256×256 frames to capture and average")
                }
                .help("Capture 256×256 crops at full camera readout, register them on the star centroid, average, and save a 32-bit float TIFF")
                Button("Save Constellation") { SnapshotExport.presentConstellation(engine: engine) }
                    .disabled(!canSaveConstellation)
                    .help("Move the star to the sensor center and eight points on an 80% circle, stack each 256 crop, and save a 3×3 mosaic.")

                HStack(alignment: .bottom, spacing: 8) {
                    CommitSlider(
                        title: "Exposure",
                        value: logExposureBinding,
                        range: logExposureRange,
                        format: exposureLabel(engine.exposureMicroseconds),
                        onCommit: { engine.applyExposure() }
                    )
                    Button("Auto") { engine.autoExpose() }
                        .disabled(!engine.isConnected || engine.isAutoExposing || engine.isStacking || engine.isMountBusy)
                        .help("Iterate exposure until the brightest pixels sit near 85% of 16-bit full well")
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

    private var filterWheelSection: some View {
        GroupBox("Filter wheel") {
            VStack(alignment: .leading, spacing: 8) {
                if engine.filterWheels.isEmpty {
                    Text(PhoenixWheel.sdkVersion == nil ? "SDK not found" : "No Phoenix wheel")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Wheel", selection: $engine.selectedFilterWheelID) {
                        ForEach(engine.filterWheels) { wheel in
                            Text(wheel.name).tag(wheel.id)
                        }
                    }
                    .labelsHidden()
                    .disabled(engine.isFilterWheelConnected || engine.isFilterWheelMoving)
                }

                HStack {
                    Button(engine.isFilterWheelConnected ? "Disconnect" : "Connect") {
                        if engine.isFilterWheelConnected {
                            engine.disconnectFilterWheel()
                        } else {
                            engine.connectFilterWheel()
                        }
                    }
                    .disabled((engine.filterWheels.isEmpty && !engine.isFilterWheelConnected) || engine.isFilterWheelMoving)
                    Button("Refresh") { engine.refreshFilterWheels() }
                        .disabled(engine.isFilterWheelConnected || engine.isFilterWheelMoving)
                }

                if !engine.filterSlots.isEmpty {
                    Picker("Filter", selection: filterSelection) {
                        ForEach(engine.filterSlots) { slot in
                            Text(slot.displayName).tag(slot.position)
                        }
                    }
                    .labelsHidden()
                    .disabled(!engine.isFilterWheelConnected || engine.isFilterWheelMoving)
                    .help("Stored aliases come from the wheel. Positions are 1–\(engine.filterSlots.count).")
                }

                Text(engine.filterWheelStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { engine.refreshFilterWheels() }
    }

    private var filterSelection: Binding<Int> {
        Binding(
            get: { engine.selectedFilterPosition },
            set: { engine.gotoFilter($0) }
        )
    }

    private var mountSection: some View {
        GroupBox("Mount") {
            VStack(alignment: .leading, spacing: 8) {
                if engine.serialPorts.isEmpty {
                    Text("No serial ports")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Port", selection: $engine.selectedSerialPort) {
                        ForEach(engine.serialPorts, id: \.self) { path in
                            Text(URL(fileURLWithPath: path).lastPathComponent).tag(path)
                        }
                    }
                    .labelsHidden()
                    .disabled(engine.isMountConnected || engine.isMountBusy)
                }

                HStack {
                    Button(engine.isMountConnected ? "Disconnect" : "Connect") {
                        if engine.isMountConnected {
                            engine.disconnectMount()
                        } else {
                            engine.connectMount()
                        }
                    }
                    .disabled((engine.serialPorts.isEmpty && !engine.isMountConnected) || engine.isMountBusy)
                    Button("Refresh") { engine.refreshSerialPorts() }
                        .disabled(engine.isMountConnected || engine.isMountBusy)
                }

                HStack {
                    Button("Calibrate") { engine.calibrateMount() }
                        .disabled(!canCalibrateMount)
                        .help("Pulse-guide east and north, measure how the star moves, and measure backlash from where it returns.")
                    Button("Center") { engine.centerStar() }
                        .disabled(!canCenterStar)
                        .help("Centers RA and Dec together on the full sensor. Each move covers about 90% of the remaining error and lasts about 1 s.")
                }

                Text(engine.mountStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let calibration = engine.guideCalibration, calibration.isValid {
                    Text(calibration.calibratedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if calibration.raBacklashPixels > 0.5 || calibration.decBacklashPixels > 0.5 {
                        Text(String(
                            format: "Backlash  RA %.0f px  ·  Dec %.0f px",
                            calibration.raBacklashPixels,
                            calibration.decBacklashPixels
                        ))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .onAppear { engine.refreshSerialPorts() }
    }

    // Enablement lives on the engine so every surface agrees (see PARITY.md).
    private var canCalibrateMount: Bool { engine.canCalibrateMount }
    private var canCenterStar: Bool { engine.canCenterStar }
    private var canSaveConstellation: Bool { engine.canSaveConstellation }

    private var roiSection: some View {
        GroupBox("ROI & zoom") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Camera 2048×2048, view 512×512 around the star. Full frame while searching, centering, or saving a constellation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Auto-center star", isOn: $engine.autoCenter)
                    .disabled(engine.isMountBusy || engine.isStacking)
                    .help("Keep the 2048×2048 camera window on the star. The live view is a 512×512 software crop.")
                Toggle("Stabilize view", isOn: $engine.stabilize)
                    .help("Nudge the live view so the detected centroid stays still in the window")
                Toggle("Search full frame", isOn: $engine.autoSearch)
                    .disabled(!engine.isConnected || engine.isMountBusy || engine.isStacking)
                    .help("When on, a lost star starts a binned full-frame search. The live view shows that full frame until the star is found.")

                HStack {
                    Text("Zoom")
                    Slider(value: $engine.zoom, in: engine.zoomFloor...CollimationEngine.maxZoom)
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
                Picker("Curve", selection: $engine.stretch.curve) {
                    ForEach(StretchCurve.allCases) { curve in
                        Text(curve.label).tag(curve)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                CommitSlider(title: "Black", value: $engine.stretch.black, range: StretchParams.blackRange, format: pct(engine.stretch.black))
                CommitSlider(title: "White", value: $engine.stretch.white, range: 0...1, format: pct(engine.stretch.white))
                if engine.stretch.curve == .mtf {
                    CommitSlider(title: "Midtones", value: $engine.stretch.midtones, range: StretchParams.midtonesRange, format: String(format: "%.4f", engine.stretch.midtones))
                } else {
                    CommitSlider(
                        title: "Factor",
                        value: logArcsinhBinding,
                        range: logArcsinhRange,
                        format: String(format: "%.1f", engine.stretch.arcsinh)
                    )
                    .help("asinh(αx) / asinh(α). Larger α lifts the faint background more.")
                }
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
                        metric("FWHM", value: fwhmText)
                            .help("Full width at half maximum. 1600 mm focal length, 3.76 µm pixels.")
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

    private var fwhmText: String {
        if engine.tracking.state == .lost || engine.tracking.state == .searching {
            return "—"
        }
        guard let fwhm = engine.fwhm else { return "—" }
        return String(format: "%.2f″  (%.1f px)", fwhm.arcseconds, fwhm.sensorPixels)
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
            switch engine.overlay.starPeak.map(StarQuality.from) {
            case .saturated:
                return "Star is saturating. Lower exposure or gain. Clipped pixels are red."
            case .faint:
                return "Star peak is under 10% of full well. Increase exposure."
            case .good, .none:
                break
            }
            if let q = engine.coma?.quality, q >= 0.6 {
                if engine.coma?.isDonut == false {
                    return "In-focus star. Reduce the normalized coma toward zero."
                }
                return "Donut locked. Reduce the normalized coma toward zero."
            }
            if engine.coma?.isDonut == false {
                return "In-focus star locked. Coma is the offset of the bright core from the geometric center."
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

    private var logArcsinhRange: ClosedRange<Double> {
        log10(StretchParams.arcsinhRange.lowerBound)...log10(StretchParams.arcsinhRange.upperBound)
    }

    private var logArcsinhBinding: Binding<Double> {
        Binding(
            get: {
                log10(min(max(engine.stretch.arcsinh, StretchParams.arcsinhRange.lowerBound), StretchParams.arcsinhRange.upperBound))
            },
            set: { engine.stretch.arcsinh = pow(10, $0) }
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
