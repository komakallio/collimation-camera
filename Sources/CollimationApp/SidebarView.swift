import CollimationCore
import CollimationUI
import SwiftUI

struct HistogramView: View {
    let histogram: Histogram
    let stretch: StretchParams

    var body: some View {
        Canvas { context, size in
            HUDCanvas.draw(
                HistogramScene.primitives(
                    histogram: histogram,
                    stretch: stretch,
                    size: SIMD2(size.width, size.height)
                ),
                in: &context
            )
        }
        .background(HUDCanvas.swiftUIColor(HistogramScene.background))
        .clipShape(RoundedRectangle(cornerRadius: HistogramScene.cornerRadius))
    }
}

struct CompassDial: View {
    let degrees: Double?
    let magnitude: Double

    var body: some View {
        Canvas { context, size in
            HUDCanvas.draw(
                CompassDialScene.primitives(
                    degrees: degrees,
                    magnitude: magnitude,
                    size: SIMD2(size.width, size.height)
                ),
                in: &context
            )
        }
    }
}

struct SidebarView: View {
    @Bindable var engine: CollimationEngine
    let host: any UIHost

    /// Sidebar controls are rendered from the catalog, so they cannot drift
    /// from the menu items that do the same thing.
    private func button(_ id: String, appliesShortcut: Bool = false) -> some View {
        Group {
            if let command = CommandCatalog.command(id) {
                CommandButton(
                    command: command,
                    engine: engine,
                    host: host,
                    useShortTitle: true,
                    appliesShortcut: appliesShortcut
                )
            }
        }
    }

    private func toggle(_ id: String) -> some View {
        Group {
            if let command = CommandCatalog.command(id) {
                CommandToggle(command: command, engine: engine)
            }
        }
    }

    private func subtitle(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                resultsSection
                if engine.showingConstellation {
                    stretchSection
                } else {
                    equipmentSection
                    focuserSection
                    cameraSection
                    filterWheelSection
                    mountSection
                    roiSection
                    stabilizationSection
                    stretchSection
                    collimationSection
                }
            }
            .padding(14)
        }
        .frame(minWidth: 280, idealWidth: 300, maxWidth: 340)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var resultsSection: some View {
        GroupBox(SidebarText.resultsSection) {
            VStack(alignment: .leading, spacing: 8) {
                button(CommandCatalog.ID.viewCamera)
                button(CommandCatalog.ID.viewConstellation)
                button(CommandCatalog.ID.viewOpenConstellation)
                if engine.isLoadingConstellation { Text(SidebarText.loadingConstellation).font(.caption) }
                if engine.showingConstellation {
                    CommitSlider(title: SidebarText.resultsZoom, value: Binding(
                        get: { LogSlider.position(engine.constellationZoom, in: 1...8) },
                        set: { engine.constellationZoom = engine.clampedConstellationZoom(LogSlider.value($0)) }
                    ), range: LogSlider.range(1...8), format: MetricText.constellationZoom(engine.constellationZoom))
                    button(CommandCatalog.ID.constellationFit)
                    if let report = engine.constellationResult?.tiltReport {
                        ForEach(Array(TiltText.summary(report).enumerated()), id: \.offset) { _, line in
                            Text(line).font(.caption.monospacedDigit())
                        }
                    }
                    if let warning = engine.constellationResult?.metadataWarning {
                        Text(warning).font(.caption).foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    private var equipmentSection: some View {
        GroupBox(SidebarText.equipmentSection) {
            VStack(alignment: .leading, spacing: 8) {
                subtitle(SidebarText.cameraSection)
                Picker("Device", selection: $engine.selectedDeviceID) {
                    ForEach(engine.devices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .labelsHidden()
                .disabled(!engine.canSelectDevice)

                HStack {
                    // Return connects, on both platforms.
                    button(CommandCatalog.ID.cameraConnect, appliesShortcut: true)
                    button(CommandCatalog.ID.cameraRefreshDevices)
                }

                subtitle(SidebarText.filterWheelSection)
                if engine.filterWheels.isEmpty {
                    Text(MetricText.filterWheelPlaceholder(sdkPresent: PhoenixWheel.sdkVersion != nil))
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Wheel", selection: $engine.selectedFilterWheelID) {
                        ForEach(engine.filterWheels) { wheel in
                            Text(wheel.name).tag(wheel.id)
                        }
                    }
                    .labelsHidden()
                    .disabled(!engine.canSelectFilterWheel)
                }

                HStack {
                    button(CommandCatalog.ID.filterWheelConnect)
                    button(CommandCatalog.ID.filterWheelRefresh)
                }

                subtitle(SidebarText.mountSection)
                if engine.serialPorts.isEmpty {
                    Text(MetricText.serialPortPlaceholder)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Port", selection: $engine.selectedSerialPort) {
                        ForEach(engine.serialPorts, id: \.self) { path in
                            Text(MetricText.serialPortName(path)).tag(path)
                        }
                    }
                    .labelsHidden()
                    .disabled(!engine.canSelectSerialPort)
                }

                HStack {
                    button(CommandCatalog.ID.mountConnect)
                    button(CommandCatalog.ID.mountRefreshPorts)
                }
            }
        }
        .onAppear {
            engine.refreshFilterWheels()
            engine.refreshSerialPorts()
        }
    }

    private var focuserSection: some View {
        GroupBox(SidebarText.focuserSection) {
            VStack(alignment: .leading, spacing: 8) {
                if engine.focuserPorts.isEmpty {
                    Text(MetricText.serialPortPlaceholder).foregroundStyle(.secondary)
                } else {
                    Picker(SidebarText.focuserPort, selection: $engine.selectedFocuserPort) {
                        ForEach(engine.focuserPorts, id: \.self) { path in
                            Text(MetricText.serialPortName(path)).tag(path)
                        }
                    }
                    .labelsHidden()
                    .disabled(!engine.canSelectFocuserPort)
                    .help(HelpText.focuser)
                }
                HStack {
                    button(CommandCatalog.ID.focuserConnect)
                    button(CommandCatalog.ID.focuserRefreshPorts)
                }
                Text(engine.focuserStatus).font(.caption).foregroundStyle(.secondary)
                if let state = engine.focuserSnapshot {
                    Text(MetricText.focuserPosition(state)).font(.caption.monospacedDigit())
                }
                Text(SidebarText.focuserStepSize).font(.caption)
                TextField(SidebarText.focuserStepSize, value: $engine.focuserStepSize, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .disabled(!engine.canMoveFocuser)
                    .help(HelpText.focuserStepSize)
                HStack {
                    button(CommandCatalog.ID.focuserIn)
                    button(CommandCatalog.ID.focuserOut)
                    button(CommandCatalog.ID.focuserStop)
                }
                Text(SidebarText.focuserTarget).font(.caption)
                TextField(SidebarText.focuserTarget, value: $engine.focuserTargetPosition, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .disabled(!engine.canMoveFocuser)
                    .help(HelpText.focuserTarget)
                button(CommandCatalog.ID.focuserGoto)
                Text(SidebarText.autofocusStep).font(.caption)
                TextField(SidebarText.autofocusStep, value: $engine.autofocusStepSize, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .disabled(!engine.canEditAutofocus)
                    .help(HelpText.autofocusStep)
                button(CommandCatalog.ID.focuserAutofocus)
                button(CommandCatalog.ID.focuserMeasureTilt)
                button(CommandCatalog.ID.focuserCancelTilt)
                if engine.isMeasuringTilt {
                    Text(TiltText.progress(engine.tiltProgress)).font(.caption)
                } else if let report = engine.tiltReport {
                    ForEach(Array(TiltText.summary(report).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospacedDigit())
                    }
                }
                Text(MetricText.autofocus(engine.autofocusState, samples: engine.autofocusSamples.count))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var cameraSection: some View {
        GroupBox(SidebarText.cameraSection) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .bottom, spacing: 8) {
                    CommitSlider(
                        title: SidebarText.exposure,
                        value: logExposureBinding,
                        range: logExposureRange,
                        format: MetricText.exposureLabel(microseconds: engine.exposureMicroseconds),
                        onCommit: { engine.applyExposure() }
                    )
                    button(CommandCatalog.ID.cameraAutoExpose)
                }
                .disabled(!engine.canAdjustCamera)
                CommitSlider(
                    title: SidebarText.gain,
                    value: $engine.gain,
                    range: engine.gainRange,
                    format: MetricText.gain(engine.gain),
                    onCommit: { engine.applyGain() }
                )
                .disabled(!engine.canAdjustCamera)

                Text(engine.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                button(CommandCatalog.ID.cameraSaveTIFF)
                HStack(spacing: 8) {
                    button(CommandCatalog.ID.cameraSaveStacked)
                    Picker("Frames", selection: $engine.stackFrameCount) {
                        ForEach(FrameStacker.subframeCounts, id: \.self) { count in
                            Text(MetricText.stackCount(count)).tag(count)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .disabled(!engine.canSelectStackCount)
                    .help(HelpText.stackCount)
                }
                .help(HelpText.stackedSave)
                button(CommandCatalog.ID.cameraSaveConstellation)
            }
        }
    }

    private var filterWheelSection: some View {
        GroupBox(SidebarText.filterWheelSection) {
            VStack(alignment: .leading, spacing: 8) {
                if !engine.filterSlots.isEmpty {
                    Picker("Filter", selection: filterSelection) {
                        ForEach(engine.filterSlots) { slot in
                            Text(slot.displayName).tag(slot.position)
                        }
                    }
                    .labelsHidden()
                    .disabled(!engine.canSelectFilter)
                    .help(HelpText.filterPicker(slotCount: engine.filterSlots.count))
                }

                Text(engine.filterWheelStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var filterSelection: Binding<Int> {
        Binding(
            get: { engine.selectedFilterPosition },
            set: { engine.gotoFilter($0) }
        )
    }

    private var mountSection: some View {
        GroupBox(SidebarText.mountSection) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    button(CommandCatalog.ID.mountCalibrate)
                    button(CommandCatalog.ID.mountCenter)
                }

                Text(engine.mountStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let calibration = engine.guideCalibration, calibration.isValid {
                    ForEach(MetricText.calibrationSummary(calibration), id: \.self) { line in
                        Text(line)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private var roiSection: some View {
        GroupBox(SidebarText.roiSection) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(SidebarText.zoom)
                    Slider(value: $engine.zoom, in: engine.zoomFloor...CollimationEngine.maxZoom)
                    Text(MetricText.zoomPercent(engine.zoom))
                        .font(.caption.monospacedDigit())
                        .frame(width: 48, alignment: .trailing)
                }
                button(CommandCatalog.ID.viewFitToWindow)
            }
        }
    }

    private var stabilizationSection: some View {
        GroupBox(SidebarText.stabilizationSection) {
            toggle(CommandCatalog.ID.cameraStabilize)
            toggle(CommandCatalog.ID.viewQuarter)
        }
    }

    private var stretchSection: some View {
        GroupBox(engine.showingConstellation ? SidebarText.resultsStretchSection : SidebarText.stretchSection) {
            VStack(alignment: .leading, spacing: 8) {
                HistogramView(histogram: engine.displayHistogram, stretch: engine.displayStretch)
                    .frame(height: 56)
                Picker("Curve", selection: $engine.displayStretch.curve) {
                    ForEach(StretchCurve.allCases) { curve in
                        Text(curve.label).tag(curve)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                CommitSlider(title: SidebarText.black, value: $engine.displayStretch.black, range: StretchParams.blackRange, format: MetricText.percent(engine.displayStretch.black))
                CommitSlider(title: SidebarText.white, value: $engine.displayStretch.white, range: 0...1, format: MetricText.percent(engine.displayStretch.white))
                if engine.displayStretch.curve == .mtf {
                    CommitSlider(title: SidebarText.midtones, value: $engine.displayStretch.midtones, range: StretchParams.midtonesRange, format: MetricText.midtones(engine.displayStretch.midtones))
                } else {
                    CommitSlider(
                        title: SidebarText.arcsinhFactor,
                        value: logArcsinhBinding,
                        range: logArcsinhRange,
                        format: MetricText.arcsinhFactor(engine.displayStretch.arcsinh)
                    )
                    .help(HelpText.arcsinh)
                }
                button(engine.showingConstellation ? CommandCatalog.ID.constellationAutoStretch : CommandCatalog.ID.cameraAutoStretch, appliesShortcut: true)
            }
        }
    }

    private var collimationSection: some View {
        GroupBox(SidebarText.collimationSection) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        metric(SidebarText.coma, value: comaText)
                        metric(SidebarText.direction, value: directionText)
                        metric(SidebarText.asymmetry, value: asymmetryText)
                        metric(SidebarText.fwhm, value: fwhmText)
                            .help(HelpText.fwhm)
                        metric(SidebarText.snr, value: snrText)
                    }
                    Spacer()
                    CompassDial(degrees: engine.coma?.directionDegrees, magnitude: engine.coma?.magnitudeNormalized ?? 0)
                        .frame(width: CompassDialScene.size.x, height: CompassDialScene.size.y)
                }
                button(CommandCatalog.ID.viewOverlay)
                button(CommandCatalog.ID.viewSensorMarks)
                Text(qualityText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var comaText: String { MetricText.coma(engine.coma) }
    private var directionText: String { MetricText.direction(engine.coma) }
    private var asymmetryText: String { MetricText.asymmetry(engine.coma) }

    private var fwhmText: String {
        MetricText.fwhm(engine.fwhm, trackingState: engine.tracking.state)
    }

    private var snrText: String {
        MetricText.snr(engine.tracking.detection, trackingState: engine.tracking.state)
    }

    private var qualityText: String {
        MetricText.quality(
            trackingState: engine.tracking.state,
            starPeak: engine.overlay.starPeak,
            coma: engine.coma
        )
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
        LogSlider.range(engine.exposureRange)
    }

    private var logExposureBinding: Binding<Double> {
        Binding(
            get: { LogSlider.position(engine.exposureMicroseconds, in: engine.exposureRange) },
            set: { engine.exposureMicroseconds = LogSlider.value($0) }
        )
    }

    private var logArcsinhRange: ClosedRange<Double> {
        LogSlider.range(StretchParams.arcsinhRange)
    }

    private var logArcsinhBinding: Binding<Double> {
        Binding(
            get: { LogSlider.position(engine.displayStretch.arcsinh, in: StretchParams.arcsinhRange) },
            set: { engine.displayStretch.arcsinh = LogSlider.value($0) }
        )
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
