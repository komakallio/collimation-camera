import CImGui
import CollimationCore
import CollimationUI
import Foundation

/// The left-hand panel: Camera, Filter wheel, Mount, ROI & zoom, Stretch,
/// Collimation.
///
/// Section-for-section port of `SidebarView`. Every label comes from the
/// command catalog, every predicate from the engine, and every string from
/// `MetricText` and `HelpText`.
@MainActor
enum Sidebar {
    static let width = 300.0

    static func draw(
        engine: CollimationEngine,
        host: any UIHost,
        topOffset: Double,
        height: Double,
        pointScale: Double
    ) {
        igSetNextWindowPos(
            ImVec2(x: 0, y: Float(topOffset)),
            Int32(ImGuiCond_Always.rawValue),
            ImVec2(x: 0, y: 0)
        )
        igSetNextWindowSize(
            ImVec2(x: Float(width * pointScale), y: Float(height)),
            Int32(ImGuiCond_Always.rawValue)
        )
        let flags = Int32(
            ImGuiWindowFlags_NoTitleBar.rawValue
                | ImGuiWindowFlags_NoMove.rawValue
                | ImGuiWindowFlags_NoResize.rawValue
                | ImGuiWindowFlags_NoCollapse.rawValue
                | ImGuiWindowFlags_NoBringToFrontOnFocus.rawValue
        )
        guard "Sidebar".withCString({ igBegin($0, nil, flags) }) else {
            igEnd()
            return
        }
        defer { igEnd() }

        cameraSection(engine: engine, host: host)
        filterWheelSection(engine: engine, host: host)
        mountSection(engine: engine, host: host)
        roiSection(engine: engine, host: host)
        stretchSection(engine: engine, host: host)
        collimationSection(engine: engine, host: host)
    }

    // MARK: - Sections

    private static func cameraSection(engine: CollimationEngine, host: any UIHost) {
        guard header(SidebarText.cameraSection) else { return }

        combo(
            label: "##device",
            selection: engine.selectedDeviceID,
            options: engine.devices.map { ($0.id, $0.name) },
            enabled: engine.canSelectDevice
        ) { engine.selectedDeviceID = $0 }

        command(CommandCatalog.ID.cameraConnect, engine: engine, host: host)
        igSameLine(0, -1)
        command(CommandCatalog.ID.cameraRefreshDevices, engine: engine, host: host)

        command(CommandCatalog.ID.cameraSaveTIFF, engine: engine, host: host)

        command(CommandCatalog.ID.cameraSaveStacked, engine: engine, host: host)
        igSameLine(0, -1)
        igSetNextItemWidth(90)
        combo(
            label: "##frames",
            selection: String(engine.stackFrameCount),
            options: FrameStacker.subframeCounts.map { (String($0), MetricText.stackCount($0)) },
            enabled: engine.canSelectStackCount,
            help: HelpText.stackCount
        ) { value in
            if let count = Int(value) { engine.stackFrameCount = count }
        }

        command(CommandCatalog.ID.cameraSaveConstellation, engine: engine, host: host)

        logSlider(
            label: SidebarText.exposure,
            value: engine.exposureMicroseconds,
            bounds: engine.exposureRange,
            display: MetricText.exposureLabel(microseconds: engine.exposureMicroseconds),
            onChange: { engine.exposureMicroseconds = $0 },
            onCommit: { engine.applyExposure() }
        )
        igSameLine(0, -1)
        command(CommandCatalog.ID.cameraAutoExpose, engine: engine, host: host)

        slider(
            label: SidebarText.gain,
            value: engine.gain,
            bounds: engine.gainRange,
            display: MetricText.gain(engine.gain),
            onChange: { engine.gain = $0 },
            onCommit: { engine.applyGain() }
        )

        secondary(engine.statusText)
    }

    private static func filterWheelSection(engine: CollimationEngine, host: any UIHost) {
        guard header(SidebarText.filterWheelSection) else { return }

        if engine.filterWheels.isEmpty {
            ImGuiText.disabled(
                MetricText.filterWheelPlaceholder(sdkPresent: PhoenixWheel.sdkVersion != nil)
            )
        } else {
            combo(
                label: "##wheel",
                selection: engine.selectedFilterWheelID,
                options: engine.filterWheels.map { ($0.id, $0.name) },
                enabled: engine.canSelectFilterWheel
            ) { engine.selectedFilterWheelID = $0 }
        }

        command(CommandCatalog.ID.filterWheelConnect, engine: engine, host: host)
        igSameLine(0, -1)
        command(CommandCatalog.ID.filterWheelRefresh, engine: engine, host: host)

        if !engine.filterSlots.isEmpty {
            combo(
                label: "##filter",
                selection: String(engine.selectedFilterPosition),
                options: engine.filterSlots.map { (String($0.position), $0.displayName) },
                enabled: engine.canSelectFilter,
                help: HelpText.filterPicker(slotCount: engine.filterSlots.count)
            ) { value in
                if let position = Int(value) { engine.gotoFilter(position) }
            }
        }

        secondary(engine.filterWheelStatus)
    }

    private static func mountSection(engine: CollimationEngine, host: any UIHost) {
        guard header(SidebarText.mountSection) else { return }

        if engine.serialPorts.isEmpty {
            ImGuiText.disabled(MetricText.serialPortPlaceholder)
        } else {
            combo(
                label: "##port",
                selection: engine.selectedSerialPort,
                options: engine.serialPorts.map { ($0, MetricText.serialPortName($0)) },
                enabled: engine.canSelectSerialPort
            ) { engine.selectedSerialPort = $0 }
        }

        command(CommandCatalog.ID.mountConnect, engine: engine, host: host)
        igSameLine(0, -1)
        command(CommandCatalog.ID.mountRefreshPorts, engine: engine, host: host)

        command(CommandCatalog.ID.mountCalibrate, engine: engine, host: host)
        igSameLine(0, -1)
        command(CommandCatalog.ID.mountCenter, engine: engine, host: host)

        secondary(engine.mountStatus)
        if let calibration = engine.guideCalibration, calibration.isValid {
            for line in MetricText.calibrationSummary(calibration) {
                secondary(line)
            }
        }
    }

    private static func roiSection(engine: CollimationEngine, host: any UIHost) {
        guard header(SidebarText.roiSection) else { return }
        secondary(MetricText.roiExplanation)

        command(CommandCatalog.ID.cameraAutoCenter, engine: engine, host: host)
        command(CommandCatalog.ID.cameraStabilize, engine: engine, host: host)
        command(CommandCatalog.ID.cameraSearchFullFrame, engine: engine, host: host)

        slider(
            label: SidebarText.zoom,
            value: engine.zoom,
            bounds: engine.zoomFloor...CollimationEngine.maxZoom,
            display: MetricText.zoomPercent(engine.zoom),
            onChange: { engine.zoom = engine.clampedZoom($0) },
            onCommit: { engine.updateStabilization() }
        )
        command(CommandCatalog.ID.viewFitToWindow, engine: engine, host: host)
    }

    private static func stretchSection(engine: CollimationEngine, host: any UIHost) {
        guard header(SidebarText.stretchSection) else { return }

        let histogramSize = SIMD2(width - 24, 56.0)
        histogram(engine: engine, size: histogramSize)

        for curve in StretchCurve.allCases {
            if igRadioButton_Bool(curve.label, engine.stretch.curve == curve) {
                engine.stretch.curve = curve
            }
            if curve != StretchCurve.allCases.last { igSameLine(0, -1) }
        }

        slider(
            label: SidebarText.black,
            value: engine.stretch.black,
            bounds: StretchParams.blackRange,
            display: MetricText.percent(engine.stretch.black),
            onChange: { engine.stretch.black = $0 },
            onCommit: {}
        )
        slider(
            label: SidebarText.white,
            value: engine.stretch.white,
            bounds: 0...1,
            display: MetricText.percent(engine.stretch.white),
            onChange: { engine.stretch.white = $0 },
            onCommit: {}
        )
        if engine.stretch.curve == .mtf {
            slider(
                label: SidebarText.midtones,
                value: engine.stretch.midtones,
                bounds: StretchParams.midtonesRange,
                display: MetricText.midtones(engine.stretch.midtones),
                onChange: { engine.stretch.midtones = $0 },
                onCommit: {}
            )
        } else {
            logSlider(
                label: SidebarText.arcsinhFactor,
                value: engine.stretch.arcsinh,
                bounds: StretchParams.arcsinhRange,
                display: MetricText.arcsinhFactor(engine.stretch.arcsinh),
                onChange: { engine.stretch.arcsinh = $0 },
                onCommit: {},
                help: HelpText.arcsinh
            )
        }
        command(CommandCatalog.ID.cameraAutoStretch, engine: engine, host: host)
    }

    private static func collimationSection(engine: CollimationEngine, host: any UIHost) {
        guard header(SidebarText.collimationSection) else { return }

        metric(SidebarText.coma, MetricText.coma(engine.coma))
        metric(SidebarText.direction, MetricText.direction(engine.coma))
        metric(SidebarText.asymmetry, MetricText.asymmetry(engine.coma))
        metric(SidebarText.fwhm, MetricText.fwhm(engine.fwhm, trackingState: engine.tracking.state), help: HelpText.fwhm)
        metric(SidebarText.snr, MetricText.snr(engine.tracking.detection, trackingState: engine.tracking.state))

        dial(engine: engine)

        command(CommandCatalog.ID.viewOverlay, engine: engine, host: host)
        secondary(MetricText.quality(
            trackingState: engine.tracking.state,
            starPeak: engine.overlay.starPeak,
            coma: engine.coma
        ))
    }

    // MARK: - Widgets

    private static func header(_ title: String) -> Bool {
        title.withCString { igCollapsingHeader_TreeNodeFlags($0, Int32(ImGuiTreeNodeFlags_DefaultOpen.rawValue)) }
    }

    private static func secondary(_ text: String) {
        igPushFont(nil, Fonts.captionSize)
        ImGuiText.wrapped(text)
        igPopFont()
    }

    private static func metric(_ title: String, _ value: String, help: String? = nil) {
        igPushFont(nil, Fonts.captionSize)
        // Upper case here, not in the string: the macOS app does the same in
        // its view, so `SidebarText` can hold one readable spelling.
        ImGuiText.disabled(title.uppercased())
        igPopFont()
        igPushFont(Fonts.mono, Fonts.baseSize)
        ImGuiText.plain(value)
        igPopFont()
        ImGuiText.tooltip(help)
    }

    /// A command rendered as a button, or as a checkbox when it is a toggle
    /// that the sidebar shows with its switch affordance.
    private static func command(_ id: String, engine: CollimationEngine, host: any UIHost) {
        guard let command = CommandCatalog.command(id) else { return }
        let enabled = command.isEnabled(engine)
        igBeginDisabled(!enabled)
        defer { igEndDisabled() }

        // ImGui derives a widget's identity from its label, so the camera,
        // filter wheel and mount Connect buttons were all the same widget and
        // ImGui put up a "3 visible items with conflicting ID" dialog over the
        // live view. Everything after "##" is identity only and is not drawn,
        // so the command id — which is unique and does not change when the
        // title flips between Connect and Disconnect — keys them apart.
        let label = command.sidebarTitle(engine) + "##" + command.id

        switch command.kind {
        case .action:
            if label.withCString({ igButton($0, ImVec2(x: 0, y: 0)) }) {
                command.perform(engine, host)
            }
        case .toggle(let get, let set):
            var value = get(engine)
            let changed = label.withCString { igCheckbox($0, &value) }
            if changed { set(engine, value) }
        }
        ImGuiText.tooltip(command.help)
    }

    private static func combo(
        label: String,
        selection: String,
        options: [(String, String)],
        enabled: Bool,
        help: String? = nil,
        onSelect: (String) -> Void
    ) {
        igBeginDisabled(!enabled)
        defer { igEndDisabled() }
        let current = options.first { $0.0 == selection }?.1 ?? ""
        let opened = label.withCString { labelPointer in
            current.withCString { currentPointer in
                igBeginCombo(labelPointer, currentPointer, 0)
            }
        }
        if opened {
            for (value, title) in options {
                let selected = value == selection
                let clicked = title.withCString {
                    igSelectable_Bool($0, selected, 0, ImVec2(x: 0, y: 0))
                }
                if clicked { onSelect(value) }
            }
            igEndCombo()
        }
        ImGuiText.tooltip(help)
    }

    /// Sliders commit on release, matching `CommitSlider` on macOS: the engine
    /// only sends the value to the camera when the drag ends.
    private static func slider(
        label: String,
        value: Double,
        bounds: ClosedRange<Double>,
        display: String,
        onChange: (Double) -> Void,
        onCommit: () -> Void,
        help: String? = nil
    ) {
        igPushFont(nil, Fonts.captionSize)
        ImGuiText.disabled("\(label)   \(display)")
        igPopFont()
        var current = Float(value)
        let changed = "##\(label)".withCString { labelPointer in
            "".withCString { format in
                igSliderFloat(
                    labelPointer,
                    &current,
                    Float(bounds.lowerBound),
                    Float(bounds.upperBound),
                    format,
                    0
                )
            }
        }
        if changed { onChange(Double(current)) }
        if igIsItemDeactivatedAfterEdit() { onCommit() }
        ImGuiText.tooltip(help)
    }

    private static func logSlider(
        label: String,
        value: Double,
        bounds: ClosedRange<Double>,
        display: String,
        onChange: (Double) -> Void,
        onCommit: () -> Void,
        help: String? = nil
    ) {
        let range = LogSlider.range(bounds)
        slider(
            label: label,
            value: LogSlider.position(value, in: bounds),
            bounds: range,
            display: display,
            onChange: { onChange(LogSlider.value($0)) },
            onCommit: onCommit,
            help: help
        )
    }

    private static func histogram(engine: CollimationEngine, size: SIMD2<Double>) {
        let cursor = igGetCursorScreenPos()
        let scale = UIScale.pointScale
        HUDDrawList.draw(
            [.fillRect(
                origin: .zero,
                size: size,
                color: HistogramScene.background,
                cornerRadius: HistogramScene.cornerRadius
            )] + HistogramScene.primitives(
                histogram: engine.histogram,
                stretch: engine.stretch,
                size: size
            ),
            on: igGetWindowDrawList(),
            origin: SIMD2(Double(cursor.x), Double(cursor.y)),
            pointScale: scale
        )
        igDummy(ImVec2(x: Float(size.x * scale), y: Float(size.y * scale)))
    }

    private static func dial(engine: CollimationEngine) {
        let cursor = igGetCursorScreenPos()
        let scale = UIScale.pointScale
        HUDDrawList.draw(
            CompassDialScene.primitives(
                degrees: engine.coma?.directionDegrees,
                magnitude: engine.coma?.magnitudeNormalized ?? 0
            ),
            on: igGetWindowDrawList(),
            origin: SIMD2(Double(cursor.x), Double(cursor.y)),
            pointScale: scale
        )
        igDummy(ImVec2(
            x: Float(CompassDialScene.size.x * scale),
            y: Float(CompassDialScene.size.y * scale)
        ))
    }
}

/// The current point scale, so widgets that draw scenes do not each have to be
/// handed it. Set once per frame by the main loop.
enum UIScale {
    nonisolated(unsafe) static var pointScale: Double = 1
}
