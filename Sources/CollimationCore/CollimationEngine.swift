import Foundation
import Observation

public struct OverlayModel: Equatable, Sendable {
    public var imageWidth: Int
    public var imageHeight: Int
    public var centroid: SIMD2<Double>?
    public var outer: FittedCircle?
    public var inner: FittedCircle?
    public var comaVector: SIMD2<Double>?
    public var trackingState: TrackingState
    public var stabilizeLock: SIMD2<Double>?
    public var stabilizeCentroid: SIMD2<Double>?
    public var sensorWidth: Int
    public var sensorHeight: Int
    public var roi: ROI
    public var starPeak: UInt16?

    public init(
        imageWidth: Int = 0,
        imageHeight: Int = 0,
        centroid: SIMD2<Double>? = nil,
        outer: FittedCircle? = nil,
        inner: FittedCircle? = nil,
        comaVector: SIMD2<Double>? = nil,
        trackingState: TrackingState = .idle,
        stabilizeLock: SIMD2<Double>? = nil,
        stabilizeCentroid: SIMD2<Double>? = nil,
        sensorWidth: Int = 0,
        sensorHeight: Int = 0,
        roi: ROI = ROI(x: 0, y: 0, width: 0, height: 0),
        starPeak: UInt16? = nil
    ) {
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.centroid = centroid
        self.outer = outer
        self.inner = inner
        self.comaVector = comaVector
        self.trackingState = trackingState
        self.stabilizeLock = stabilizeLock
        self.stabilizeCentroid = stabilizeCentroid
        self.sensorWidth = sensorWidth
        self.sensorHeight = sensorHeight
        self.roi = roi
        self.starPeak = starPeak
    }

    /// Displayed-image pixel of the physical sensor center (same point mount centering uses).
    public var sensorCenterInImage: SIMD2<Double>? {
        guard sensorWidth > 0, sensorHeight > 0, imageWidth > 0, imageHeight > 0 else { return nil }
        return roi.framePixel(
            fromSensorPoint: MountGuide.frameCenter(width: sensorWidth, height: sensorHeight)
        )
    }

    /// Frame-pixel shift that glues this overlay to a live stabilizer centroid.
    public func shift(toLiveCentroid live: SIMD2<Double>?) -> SIMD2<Double> {
        guard let live, let centroid else { return .zero }
        return live - centroid
    }
}

public enum MountWork: Equatable, Sendable {
    case calibrating
    case centering
}

public enum StackWork: Equatable, Sendable {
    case capturing(collected: Int, target: Int)
    case combining
    case constellationMoving(step: Int, steps: Int)
    case constellationCapturing(step: Int, steps: Int, collected: Int, target: Int)
    case constellationCombining
}

@Observable
@MainActor
public final class CollimationEngine {
    nonisolated public let frameSlot = FrameSlot()
    nonisolated public let renderStateSlot = RenderStateSlot()
    /// Live-view size in points. Fed by the app's resize hook, not by a view
    /// body, so it is not observed.
    @ObservationIgnored public var viewWidth = 800.0
    @ObservationIgnored public var viewHeight = 700.0

    public private(set) var devices: [CameraDescriptor] = []
    public var selectedDeviceID: String = CameraDescriptor.simulator.id
    public private(set) var isConnected = false
    public var statusText = "Disconnected"
    public var errorMessage: String?

    public var exposureMicroseconds: Double = 50_000
    public var gain: Double = 0
    public var exposureRange: ClosedRange<Double> = Double(ExposureControl.minMicroseconds)...Double(ExposureControl.maxMicroseconds)
    public var gainRange: ClosedRange<Double> = 0...400

    public var autoCenter = true {
        didSet { applyPipelineConfig() }
    }
    public var autoSearch = false {
        didSet {
            applyPipelineConfig()
            handleAutoSearchChange(autoSearch)
        }
    }
    public var stabilize = false {
        didSet { updateStabilization() }
    }
    public var showOverlay = true
    public var zoom: Double = 1 {
        didSet { updateStabilization() }
    }
    public var stretch = StretchParams.default {
        didSet { updateStabilization() }
    }
    public var histogram = Histogram()
    public var tracking = TrackingStatus()
    public var coma: ComaResult?
    public var fwhm: FWHMResult?
    public var starProfile: StarIntensityProfile?
    public var overlay = OverlayModel()
    public var frameSequence: UInt64 = 0
    public var fps: Double = 0

    public var serialPorts: [String] = []
    public var selectedSerialPort = "" {
        didSet { defaults.set(selectedSerialPort, forKey: Self.serialPortDefaultsKey) }
    }
    public private(set) var isMountConnected = false
    public private(set) var isMountBusy = false
    public private(set) var showingFullFramePreview = false
    public private(set) var mountWork: MountWork?
    public private(set) var isStacking = false

    /// Test hook, and only that: `command catalog enablement` has to reach the
    /// stacking branch of `canCalibrateMount`, `canCenterStar`, and
    /// `canSearchFullFrame`, and the only other way in is to start a real
    /// stack and wait for frames. App code must call `saveStacked` instead —
    /// this sets the flag without any of the work that goes with it.
    public func setStackingForTesting(_ value: Bool) {
        isStacking = value
    }

    public var stackFrameCount = FrameStacker.defaultSubframeCount
    public private(set) var stackWork: StackWork?
    public private(set) var isAutoExposing = false
    public var mountStatus = "No mount"
    public private(set) var guideCalibration: GuideCalibration?

    public private(set) var filterWheels: [FilterWheelDescriptor] = []
    public var selectedFilterWheelID = "" {
        didSet {
            if !selectedFilterWheelID.isEmpty {
                defaults.set(selectedFilterWheelID, forKey: Self.filterWheelDefaultsKey)
            }
        }
    }
    public private(set) var isFilterWheelConnected = false
    public private(set) var isFilterWheelMoving = false
    public var filterWheelStatus = "No filter wheel"
    public private(set) var filterSlots: [FilterSlot] = []
    public var selectedFilterPosition = 0

    /// Folder the last snapshot was written to. Both apps remember it here so
    /// the save panel and the portable app's dialog agree.
    public var snapshotDirectory: URL? {
        didSet {
            if let path = snapshotDirectory?.path {
                defaults.set(path, forKey: Self.snapshotDirectoryDefaultsKey)
            }
        }
    }

    public static let minZoom = 0.25
    /// Below `minZoom` so an unbinned full sensor can fit in a typical window.
    public static let minFullFrameZoom = 0.05
    public static let maxZoom = 8.0
    public var isMountCalibrated: Bool { guideCalibration?.isValid == true }

    // MARK: - Enablement
    //
    // Every control that either surface disables reads its predicate here, so
    // the menu, the sidebar, and the portable app cannot drift. Controls with
    // no predicate are always enabled: camera Connect and Disconnect, Auto
    // Stretch, Stabilize View, Collimation Overlay, Fit to window.

    public var canRefreshDevices: Bool { !isConnected }
    public var canSelectDevice: Bool { !isConnected }
    public var canAutoExpose: Bool { isConnected && !isAutoExposing && !isStacking && !isMountBusy }
    public var canSaveSnapshot: Bool { isConnected && !isStacking }
    public var canSaveStacked: Bool {
        isConnected && !isStacking && !isMountBusy && tracking.state == .tracking
    }
    public var canSelectStackCount: Bool { !isStacking }
    public var canCalibrateMount: Bool {
        isMountConnected && isConnected && !isMountBusy && !isStacking && tracking.state == .tracking
    }
    public var canCenterStar: Bool { canCalibrateMount && isMountCalibrated }
    public var canSaveConstellation: Bool { canCenterStar }
    public var canToggleAutoCenter: Bool { !isMountBusy && !isStacking }
    public var canSearchFullFrame: Bool { isConnected && !isMountBusy && !isStacking }
    public var canConnectMount: Bool { (isMountConnected || !serialPorts.isEmpty) && !isMountBusy }
    public var canSelectSerialPort: Bool { !isMountConnected && !isMountBusy }
    public var canRefreshSerialPorts: Bool { canSelectSerialPort }
    /// Disconnect is always allowed; only connecting waits for a move to end.
    ///
    /// This is one toggle, so gating both halves on `!isFilterWheelMoving` left
    /// no way out of a move that never finished: the picker, Refresh and this
    /// button were all disabled together and quitting was the only recovery.
    /// Pulling the wheel out from under a move is the user's business.
    ///
    /// A free function so the rule can be tested for every combination without
    /// forcing the engine into a state it will not enter on its own — which is
    /// the point, since the states that matter here are the ones a bug leaves
    /// behind.
    public static func canConnectFilterWheel(
        isConnected: Bool,
        hasWheels: Bool,
        isMoving: Bool
    ) -> Bool {
        if isConnected { return true }
        return hasWheels && !isMoving
    }

    public var canConnectFilterWheel: Bool {
        Self.canConnectFilterWheel(
            isConnected: isFilterWheelConnected,
            hasWheels: !filterWheels.isEmpty,
            isMoving: isFilterWheelMoving
        )
    }
    public var canSelectFilterWheel: Bool { !isFilterWheelConnected && !isFilterWheelMoving }
    public var canRefreshFilterWheels: Bool { canSelectFilterWheel }
    public var canSelectFilter: Bool { isFilterWheelConnected && !isFilterWheelMoving }

    /// Lower zoom bound. Full-frame centering/constellation slews must go
    /// below `minZoom` or the live view still clips stars near the edges.
    public var zoomFloor: Double {
        showingFullFramePreview ? Self.minFullFrameZoom : Self.minZoom
    }

    nonisolated private let session = CaptureSession()
    nonisolated private let pipeline = FramePipeline()
    nonisolated private let coalescer = FrameCoalescer(label: "collimation.process")
    nonisolated private let fpsMeter = FPSMeter()
    nonisolated private let mount = EQ6Mount()
    nonisolated private let filterWheel = PhoenixWheel()
    @ObservationIgnored private var device: CameraDevice?
    @ObservationIgnored private var applyingControls = false
    @ObservationIgnored private var lastSentExposure: Int?
    @ObservationIgnored private var lastSentGain: Int?
    @ObservationIgnored private var sensorWidth = CameraDescriptor.simulator.sensorWidth
    @ObservationIgnored private var sensorHeight = CameraDescriptor.simulator.sensorHeight
    @ObservationIgnored private var optics = TelescopeOptics.poseidon
    @ObservationIgnored private var roiAlignment = ROIAlignment.playerOne
    /// Binning for the full-frame search. Player One cameras take 4; most ZWO
    /// cameras, the ASI120 family included, report only 1 and 2, and asking for
    /// 4 fails the ROI and drops the connection.
    @ObservationIgnored private var searchBinning = CollimationEngine.defaultSearchBinning
    nonisolated public let stabilization = StabilizationController()
    nonisolated private let softwareCrop = SoftwareCropController()
    nonisolated private let stackCapture = StackCaptureBuffer()
    @ObservationIgnored private var mountTask: Task<Void, Never>?
    @ObservationIgnored private var stackTask: Task<Void, Never>?
    @ObservationIgnored private var autoExposeTask: Task<Void, Never>?
    @ObservationIgnored private var filterWheelTask: Task<Void, Never>?
    @ObservationIgnored private var mountHoldsROI = false
    @ObservationIgnored private var zoomBeforeFullFrame: Double?
    @ObservationIgnored private var axisDirections = AxisDirectionMemory()
    @ObservationIgnored private var hardwareFilterPosition: Int?
    /// Injected so tests get their own suite and a scripted port list.
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let serialPortPaths: () -> [String]
    /// Search binning before a camera is connected, and the ceiling once one is.
    public static let defaultSearchBinning = 4
    private static let serialPortDefaultsKey = "mount.serialPort"
    private static let filterWheelDefaultsKey = "filterWheel.id"
    private static let snapshotDirectoryDefaultsKey = "snapshot.directory"

    public init(
        defaults: UserDefaults = .standard,
        serialPortPaths: @escaping () -> [String] = SerialPortScanner.availablePaths
    ) {
        self.defaults = defaults
        self.serialPortPaths = serialPortPaths
        refreshDevices()
        selectedDeviceID = DeviceCatalog.preferredDeviceID(in: devices)
        // The remembered port is read before refreshSerialPorts() so the
        // property observer cannot overwrite the key with a scanned port.
        if let saved = defaults.string(forKey: Self.serialPortDefaultsKey), !saved.isEmpty {
            selectedSerialPort = saved
        }
        refreshSerialPorts()
        if let path = defaults.string(forKey: Self.snapshotDirectoryDefaultsKey), !path.isEmpty {
            snapshotDirectory = URL(fileURLWithPath: path, isDirectory: true)
        }
        if let calibration = GuideCalibrationStore.load(), calibration.isValid {
            guideCalibration = calibration
            mountStatus = "Calibrated — connect the mount to center"
        }
        coalescer.handler = { [weak self] frame in
            self?.analyze(frame)
        }
        session.onFrame = { [weak self] frame in
            self?.ingest(frame)
        }
        session.onError = { [weak self] error in
            Task { @MainActor in
                self?.handleError(error)
            }
        }
        refreshFilterWheels()
        if let saved = defaults.string(forKey: Self.filterWheelDefaultsKey),
           filterWheels.contains(where: { $0.id == saved })
        {
            selectedFilterWheelID = saved
        }
        // The Combine sinks these observers replace also fired once on
        // subscription; keep that so the render state and the pipeline are
        // configured before the first frame.
        updateStabilization()
        applyPipelineConfig()
    }

    deinit {
        shutdown()
    }

    /// Stops grabbing and closes the camera. Safe to call from any thread,
    /// including `applicationShouldTerminate`, where a `Task` would race process exit.
    nonisolated public func stopCapture() {
        coalescer.cancel()
        session.stop()
    }

    /// Stops capture and closes the mount serial port and filter wheel. Call from app termination.
    nonisolated public func shutdown() {
        stopCapture()
        mount.disconnect()
        filterWheel.disconnect()
    }

    public var selectedDevice: CameraDescriptor? {
        devices.first { $0.id == selectedDeviceID }
    }

    public func refreshDevices() {
        devices = DeviceCatalog.list()
        if devices.contains(where: { $0.id == selectedDeviceID }) == false {
            selectedDeviceID = DeviceCatalog.preferredDeviceID(in: devices)
        }
        if let sdk = DeviceCatalog.sdkVersionSummary, !isConnected {
            statusText = "SDK \(sdk) — disconnected"
        }
    }

    public func connect() {
        errorMessage = nil
        do {
            let newDevice = try DeviceCatalog.makeDevice(id: selectedDeviceID)
            try newDevice.open()
            device = newDevice
            sensorWidth = newDevice.descriptor.sensorWidth
            sensorHeight = newDevice.descriptor.sensorHeight
            optics = TelescopeOptics.forCamera(newDevice.descriptor)
            roiAlignment = newDevice.roiAlignment
            searchBinning = newDevice.supportedBins
                .filter { $0 >= 1 && $0 <= Self.defaultSearchBinning }
                .max() ?? 1
            exposureRange = Double(ExposureControl.minMicroseconds)...Double(ExposureControl.maxMicroseconds)
            gainRange = Double(newDevice.controls.gainRange.lowerBound)...Double(newDevice.controls.gainRange.upperBound)
            let clampedExposure = ExposureControl.clamp(newDevice.controls.exposureMicroseconds)
            try newDevice.applyExposure(clampedExposure)
            applyingControls = true
            exposureMicroseconds = Double(clampedExposure)
            gain = Double(newDevice.controls.gain)
            applyingControls = false
            applyPipelineConfig()
            pipeline.reset()
            lastSentExposure = Int(exposureMicroseconds)
            lastSentGain = Int(gain)
            session.start(device: newDevice)
            isConnected = true
            applyROISize()
            statusText = "Live — \(newDevice.descriptor.name)"
        } catch {
            handleError(error)
        }
    }

    public func suggestedSnapshotName() -> String {
        if let frame = frameSlot.peek()?.frame {
            return MonoTIFF.suggestedFileName(width: frame.width, height: frame.height, date: frame.timestamp)
        }
        let size = overlay.imageWidth > 0 ? overlay.imageWidth : CaptureLayout.displayCropSize
        let height = overlay.imageHeight > 0 ? overlay.imageHeight : size
        return MonoTIFF.suggestedFileName(width: max(size, 1), height: max(height, 1))
    }

    public func suggestedStackedName() -> String {
        let label = "stack\(FrameStacker.clampedCount(stackFrameCount))"
        let size = CaptureLayout.stackingCropSize
        if let frame = frameSlot.peek()?.frame {
            return MonoTIFF.suggestedFileName(
                width: size,
                height: size,
                date: frame.timestamp,
                label: label
            )
        }
        return MonoTIFF.suggestedFileName(width: size, height: size, label: label)
    }

    public func suggestedConstellationName() -> String {
        let frames = FrameStacker.clampedCount(stackFrameCount)
        let cell = CaptureLayout.stackingCropSize
        let side = cell * ConstellationCapture.gridSize
        let label = "constellation-stack\(frames)"
        if let frame = frameSlot.peek()?.frame {
            return MonoTIFF.suggestedFileName(
                width: side,
                height: side,
                date: frame.timestamp,
                label: label
            )
        }
        return MonoTIFF.suggestedFileName(width: side, height: side, label: label)
    }

    public func saveSnapshot(to url: URL) {
        errorMessage = nil
        guard let frame = frameSlot.peek()?.frame else {
            presentError(CameraError.notConnected)
            return
        }
        do {
            try MonoTIFF.write(frame: frame, to: url)
            statusText = "Saved \(url.lastPathComponent)"
        } catch {
            presentError(error)
        }
    }

    public func saveStackedSnapshot(to url: URL) {
        guard isConnected, !isStacking, !isMountBusy else { return }
        errorMessage = nil
        stackTask?.cancel()
        isStacking = true
        let target = FrameStacker.clampedCount(stackFrameCount)
        stackWork = .capturing(collected: 0, target: target)
        applyPipelineConfig()
        statusText = "Stacking 0/\(target)…"
        stackTask = Task { await self.runStackedSnapshot(to: url, frameCount: target) }
    }

    public func saveConstellation(to url: URL) {
        guard isConnected, !isStacking, !isMountBusy, isMountConnected, isMountCalibrated else { return }
        errorMessage = nil
        stackTask?.cancel()
        isStacking = true
        let steps = ConstellationCapture.positionCount
        stackWork = .constellationMoving(step: 1, steps: steps)
        applyPipelineConfig()
        statusText = "Constellation 1/\(steps)…"
        stackTask = Task { await self.runConstellation(to: url) }
    }

    private func runStackedSnapshot(to url: URL, frameCount: Int) async {
        defer { finishStacking() }
        do {
            let stacked = try await captureStackedImage(frameCount: frameCount) { collected, target in
                self.stackWork = .capturing(collected: collected, target: target)
                self.statusText = "Stacking \(collected)/\(target)…"
                self.fps = self.fpsMeter.current
            }
            try Task.checkCancellation()
            stackWork = .combining
            statusText = "Combining \(frameCount) frames…"
            try MonoTIFF.write(stacked, to: url)
            statusText = "Saved \(url.lastPathComponent)"
        } catch is CancellationError {
            statusText = "Stack cancelled"
        } catch {
            presentError(error)
            statusText = "Stack failed"
        }
    }

    private func runConstellation(to url: URL) async {
        let frameCount = FrameStacker.clampedCount(stackFrameCount)
        let steps = ConstellationCapture.positionCount
        var startedMount = false
        defer {
            finishStacking()
            if startedMount {
                if statusText.hasPrefix("Saved") {
                    endMountWorkWithoutWaiting("Constellation saved")
                } else if statusText.contains("cancelled") {
                    endMountWorkWithoutWaiting("Constellation cancelled")
                } else {
                    endMountWorkWithoutWaiting("Constellation stopped")
                }
            } else {
                restoreTrackingDisplay()
            }
        }
        do {
            guard let calibration = guideCalibration, calibration.isValid else {
                throw MountError.notCalibrated
            }
            let positions = ConstellationCapture.positions(
                sensorWidth: sensorWidth,
                sensorHeight: sensorHeight
            )
            try beginMountWork(
                "Constellation 1/\(steps)…",
                holdROI: true,
                useFullFrame: true,
                work: .centering
            )
            startedMount = true

            var tiles: [(row: Int, column: Int, image: StackedImage)] = []
            tiles.reserveCapacity(positions.count)

            for (index, position) in positions.enumerated() {
                let step = index + 1
                try Task.checkCancellation()
                stackWork = .constellationMoving(step: step, steps: steps)
                statusText = "Constellation \(step)/\(steps) — moving to \(position.label)…"
                mountStatus = statusText

                if index == 0 {
                    _ = try await waitForCentroid(minNewFrames: 2, timeout: 12)
                } else {
                    try await enterFullFrame()
                }
                try await moveStar(to: position.sensorPoint, calibration: calibration)
                let around = tracking.centroidOnSensor ?? position.sensorPoint
                try await prepareStackWindow(around: around)

                stackWork = .constellationCapturing(
                    step: step,
                    steps: steps,
                    collected: 0,
                    target: frameCount
                )
                statusText = "Constellation \(step)/\(steps) — stacking 0/\(frameCount)…"
                let stacked = try await captureStackedImage(frameCount: frameCount) { collected, target in
                    self.stackWork = .constellationCapturing(
                        step: step,
                        steps: steps,
                        collected: collected,
                        target: target
                    )
                    self.statusText = "Constellation \(step)/\(steps) — stacking \(collected)/\(target)…"
                    self.fps = self.fpsMeter.current
                }
                tiles.append((position.row, position.column, stacked))
            }

            stackWork = .constellationCombining
            statusText = "Combining constellation…"
            let mosaic = try ConstellationCapture.mosaic(tiles)
            try MonoTIFF.write(mosaic, to: url)
            statusText = "Saved \(url.lastPathComponent)"
        } catch is CancellationError {
            statusText = "Constellation cancelled"
        } catch {
            // The constellation reaches the mount through `moveStar`, so it can
            // fail on a pulled cable exactly as calibration and centering can.
            noteMountFailure(error)
            presentError(error)
            statusText = "Constellation failed"
        }
    }

    private func finishStacking() {
        stackCapture.cancel()
        session.requestFrameLimit(CaptureLayout.maxReadoutFPS)
        isStacking = false
        stackWork = nil
        stackTask = nil
        applyPipelineConfig()
    }

    private func captureStackedImage(
        frameCount: Int,
        onProgress: @escaping (Int, Int) -> Void
    ) async throws -> StackedImage {
        coalescer.cancel()
        stackCapture.begin(target: frameCount)
        session.requestFrameLimit(CaptureLayout.unlimitedReadoutFPS)
        defer {
            stackCapture.cancel()
            session.requestFrameLimit(CaptureLayout.maxReadoutFPS)
        }
        onProgress(0, frameCount)
        let frames = try await collectStackedFrames(target: frameCount, onProgress: onProgress)
        try Task.checkCancellation()
        session.requestFrameLimit(CaptureLayout.maxReadoutFPS)
        let seed = CaptureLayout.stackingSeed()
        return try await Task.detached(priority: .userInitiated) {
            try FrameStacker.average(frames, seed: seed)
        }.value
    }

    private func collectStackedFrames(
        target: Int,
        onProgress: @escaping (Int, Int) -> Void
    ) async throws -> [Frame] {
        let frameBudget = max(2.0, exposureMicroseconds / 1_000_000.0 + 1.0)
        let deadline = Date().addingTimeInterval(frameBudget * Double(target) + 30)
        var lastCount = -1

        while true {
            try Task.checkCancellation()
            guard isConnected else { throw CameraError.disconnected }
            guard Date() < deadline else { throw CameraError.timeout }

            let count = stackCapture.count
            if count != lastCount {
                lastCount = count
                onProgress(count, target)
            }
            if let frames = stackCapture.takeIfComplete() {
                onProgress(frames.count, target)
                return frames
            }
            try await Task.sleep(nanoseconds: 8_000_000)
        }
    }

    public func disconnect() {
        stackTask?.cancel()
        stackTask = nil
        isStacking = false
        stackWork = nil
        stackCapture.cancel()
        autoExposeTask?.cancel()
        autoExposeTask = nil
        isAutoExposing = false
        // Without this an unplug during Center ends 4 s later with
        // MountError.noStar, which replaces the disconnect message.
        mountTask?.cancel()
        mountTask = nil
        stopCapture()
        device = nil
        isConnected = false
        tracking = TrackingStatus()
        coma = nil
        fwhm = nil
        starProfile = nil
        overlay = OverlayModel()
        frameSlot.clear()
        softwareCrop.reset()
        stabilization.reset()
        showingFullFramePreview = false
        zoomBeforeFullFrame = nil
        optics = .poseidon
        roiAlignment = .playerOne
        searchBinning = Self.defaultSearchBinning
        updateStabilization()
        statusText = "Disconnected"
    }

    public func applyExposure() {
        autoExposeTask?.cancel()
        guard isConnected, !applyingControls else { return }
        sendExposure(Int(exposureMicroseconds.rounded()))
    }

    public func autoExpose() {
        guard isConnected, !isStacking, !isMountBusy, !isAutoExposing else { return }
        isAutoExposing = true
        autoExposeTask = Task { await self.runAutoExposure() }
    }

    private func runAutoExposure() async {
        isAutoExposing = true
        statusText = "Auto exposure…"
        defer {
            isAutoExposing = false
            autoExposeTask = nil
        }
        do {
            if histogram.sampleCount == 0 {
                try await waitForAnalyzedFrames(1, timeout: 4)
            }
            for _ in 0..<ExposureControl.maxAutoIterations {
                try Task.checkCancellation()
                guard isConnected else { return }
                let peakADU = currentPeakADU()
                let saturated = ExposureControl.isSaturated(peakADU: peakADU)
                let peak = ExposureControl.peakNormalized(peakADU: peakADU)
                if ExposureControl.isAtTarget(peakNormalized: peak, saturated: saturated) {
                    statusText = String(format: "Auto exposure — %.0f%% full well", peak * 100)
                    return
                }
                let current = Int(exposureMicroseconds.rounded())
                let next = ExposureControl.adjustedMicroseconds(
                    current: current,
                    peakNormalized: peak,
                    saturated: saturated
                )
                if next == current {
                    statusText = String(
                        format: "Auto exposure — limited at %.1f ms, %.0f%% well",
                        Double(current) / 1_000,
                        peak * 100
                    )
                    return
                }
                sendExposure(next)
                try await waitForAnalyzedFrames(3, timeout: autoExposureSettleTimeout())
            }
            let peak = ExposureControl.peakNormalized(peakADU: currentPeakADU())
            if isConnected {
                statusText = String(format: "Auto exposure — %.0f%% full well", peak * 100)
            }
        } catch is CancellationError {
            if isConnected { statusText = "Auto exposure cancelled" }
        } catch {
            if isConnected { statusText = "Auto exposure failed" }
        }
    }

    private func currentPeakADU() -> UInt16 {
        max(histogram.maxADU, tracking.detection?.peak ?? 0)
    }

    private func sendExposure(_ microseconds: Int) {
        let value = ExposureControl.clamp(microseconds)
        applyingControls = true
        exposureMicroseconds = Double(value)
        applyingControls = false
        guard value != lastSentExposure else { return }
        lastSentExposure = value
        session.requestExposure(value)
    }

    private func waitForAnalyzedFrames(_ count: Int, timeout: TimeInterval) async throws {
        let startSeq = frameSequence
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            if frameSequence >= startSeq + UInt64(count) { return }
            try await Task.sleep(nanoseconds: 40_000_000)
        }
    }

    private func autoExposureSettleTimeout() -> TimeInterval {
        let seconds = max(exposureMicroseconds / 1_000_000.0, 0.001)
        return max(2.5, seconds * 6 + 0.8)
    }

    public func applyGain() {
        guard isConnected, !applyingControls else { return }
        let value = Int(gain)
        guard value != lastSentGain else { return }
        lastSentGain = value
        session.requestGain(value)
    }

    public func applyROISize() {
        guard isConnected, !isStacking, !isMountBusy else { return }
        pipeline.reset()
        coalescer.cancel()
        softwareCrop.reset()
        let center = tracking.centroidOnSensor
            ?? SIMD2(Double(sensorWidth) / 2, Double(sensorHeight) / 2)
        session.requestROI(
            Alignment.centeredROI(
                around: center,
                size: CaptureLayout.trackingHardwareSize,
                sensorWidth: sensorWidth,
                sensorHeight: sensorHeight,
                binning: 1,
                alignment: roiAlignment
            )
        )
    }

    public func searchNow() {
        guard isConnected, !isMountBusy, !isStacking else { return }
        pipeline.markSearching()
        coalescer.cancel()
        softwareCrop.reset()
        let roi = Alignment.fullFrameROI(
            sensorWidth: sensorWidth,
            sensorHeight: sensorHeight,
            binning: searchBinning,
            alignment: roiAlignment
        )
        session.requestROI(roi)
        tracking.state = .searching
        statusText = "Searching full frame…"
        updateStabilization()
    }

    private func handleAutoSearchChange(_ enabled: Bool) {
        guard isConnected, !isMountBusy, !isStacking else { return }
        if enabled {
            if tracking.state == .lost || tracking.state == .searching {
                searchNow()
            }
        } else if tracking.state == .searching {
            applyROISize()
            tracking.state = .lost
            statusText = "Star lost — holding ROI"
            updateStabilization()
        }
    }

    public func autoStretch() {
        stretch = StretchParams.auto(from: histogram, curve: stretch.curve)
    }

    public func fitZoom(viewWidth: Double? = nil, viewHeight: Double? = nil) {
        let size = overlay.imageWidth == 0 ? CaptureLayout.displayCropSize : overlay.imageWidth
        let height = overlay.imageHeight == 0 ? size : overlay.imageHeight
        zoom = clampedZoom(ImageLayout.fitZoom(
            imageWidth: size,
            imageHeight: height,
            viewWidth: viewWidth ?? self.viewWidth,
            viewHeight: viewHeight ?? self.viewHeight
        ))
        updateStabilization()
    }

    public func clampZoom() {
        zoom = clampedZoom(zoom)
        updateStabilization()
    }

    public func clampedZoom(_ value: Double) -> Double {
        min(Self.maxZoom, max(zoomFloor, value))
    }

    public func updateStabilization() {
        stabilization.configure(
            enabled: stabilize,
            tracking: tracking.state,
            viewWidth: viewWidth,
            viewHeight: viewHeight,
            zoom: zoom
        )
        if let centroid = overlay.centroid, overlay.imageWidth > 0 {
            stabilization.seed(
                frameCentroid: centroid,
                roi: overlay.roi
            )
        }
        let pose = stabilization.pose()
        if overlay.stabilizeLock != pose.lockNormalized || overlay.stabilizeCentroid != pose.centroid {
            overlay.stabilizeLock = pose.lockNormalized
            overlay.stabilizeCentroid = pose.centroid
        }
        renderStateSlot.update { state in
            state.stretch = stretch
            state.zoom = zoom
            // Lock and centroid for a live frame are written by the renderer.
            // Drop them here when they must not apply: stab off, or a full-frame
            // search whose pixels are not the crop the lock was measured on.
            if !stabilize || tracking.state == .searching || showingFullFramePreview {
                state.stabilizeLock = nil
                state.stabilizeCentroid = nil
            }
        }
    }

    private nonisolated func ingest(_ frame: Frame) {
        let displayed = softwareCrop.apply(frame)
        frameSlot.store(displayed)
        _ = fpsMeter.tick()
        if stackCapture.isCapturing {
            stackCapture.offer(CaptureLayout.stackingFrame(from: displayed))
        }
        if !stackCapture.isCapturing {
            coalescer.submit(frame)
        }
    }

    private nonisolated func analyze(_ frame: Frame) {
        guard let processed = pipeline.process(frame) else { return }
        if let roi = processed.tracking.requestedROI {
            session.requestTrackerROI(roi)
        }
        softwareCrop.update(
            enabled: CaptureLayout.isTrackingCapture(frame),
            sensorCentroid: processed.tracking.centroidOnSensor
        )
        frameSlot.store(processed.displayFrame)
        Task { @MainActor in
            self.publish(processed)
        }
    }

    private func publish(_ processed: ProcessedFrame) {
        // A frame that was already in the analysis pipeline when the camera
        // went away lands here after `disconnect()` has cleared everything, and
        // puts the star, the overlay, the tracking state and a live fps reading
        // back on screen for a camera that is not there. The hop to the main
        // actor is unstructured, so there is nothing to cancel; the check has
        // to be here.
        guard isConnected else { return }
        frameSequence &+= 1
        fps = fpsMeter.current
        histogram = processed.histogram
        tracking = processed.tracking
        coma = processed.coma
        fwhm = processed.fwhm
        starProfile = processed.starProfile
        overlay = processed.overlay
        updateStabilization()
        guard !isStacking else { return }
        switch processed.tracking.state {
        case .tracking:
            statusText = String(format: "Tracking  %.0f fps", fps)
        case .lost:
            statusText = "Star lost — holding ROI"
        case .searching:
            statusText = "Searching full frame…"
        case .idle:
            statusText = "Live"
        }
    }

    public func refreshSerialPorts() {
        var ports = serialPortPaths()
        let saved = defaults.string(forKey: Self.serialPortDefaultsKey) ?? selectedSerialPort
        if !saved.isEmpty, !ports.contains(saved) {
            ports.insert(saved, at: 0)
        }
        serialPorts = ports
        if selectedSerialPort.isEmpty {
            selectedSerialPort = saved.isEmpty ? (ports.first ?? "") : saved
        } else if !ports.contains(selectedSerialPort), !saved.isEmpty {
            selectedSerialPort = saved
        }
    }

    public func connectMount() {
        errorMessage = nil
        refreshSerialPorts()
        let path = selectedSerialPort
        guard !path.isEmpty else {
            presentError(MountError.noPortSelected)
            return
        }
        guard !isMountBusy else { return }
        isMountBusy = true
        mountStatus = "Opening \(URL(fileURLWithPath: path).lastPathComponent)…"
        let mount = mount
        Task {
            do {
                let name = try await Task.detached {
                    try mount.connect(path: path)
                    return mount.protocolName
                }.value
                isMountConnected = true
                isMountBusy = false
                mountWork = nil
                mountStatus = isMountCalibrated
                    ? "Connected — \(name), tracking off"
                    : "Connected — \(name), tracking off. Calibrate before centering."
            } catch {
                isMountConnected = false
                isMountBusy = false
                mountWork = nil
                mountStatus = "Not connected"
                presentError(error)
            }
        }
    }

    public func disconnectMount() {
        mountTask?.cancel()
        mountTask = nil
        // Off the actor for the same reason as `haltMotionsOffActor`: closing
        // stops the nudges first, and that is a serial conversation which a
        // mount that has gone will not answer. The UI state below is what the
        // user sees, and it must not wait four seconds for a dead cable.
        let mount = self.mount
        Task.detached { mount.disconnect() }
        isMountConnected = false
        isMountBusy = false
        mountWork = nil
        axisDirections = AxisDirectionMemory()
        let restoreDisplay = mountHoldsROI
        if restoreDisplay {
            restoreTrackingDisplay()
        }
        mountHoldsROI = false
        applyPipelineConfig()
        mountStatus = isMountCalibrated ? "Calibrated — mount disconnected" : "No mount"
    }

    public func refreshFilterWheels() {
        filterWheels = filterWheel.enumerate()
        let saved = defaults.string(forKey: Self.filterWheelDefaultsKey) ?? selectedFilterWheelID
        if let match = filterWheels.first(where: { $0.id == selectedFilterWheelID || $0.id == saved }) {
            selectedFilterWheelID = match.id
        } else if let first = filterWheels.first {
            selectedFilterWheelID = first.id
        }
        if !isFilterWheelConnected {
            if PhoenixWheel.sdkVersion == nil {
                filterWheelStatus = "SDK not found — place \(VendorLibrary.playerOneFilterWheel) in Vendor/\(VendorLibrary.playerOneFolder)"
            } else if filterWheels.isEmpty {
                filterWheelStatus = "No Phoenix filter wheel"
            } else {
                filterWheelStatus = "SDK \(PhoenixWheel.sdkVersion ?? "") — disconnected"
            }
        }
    }

    public func connectFilterWheel() {
        errorMessage = nil
        refreshFilterWheels()
        guard let descriptor = filterWheels.first(where: { $0.id == selectedFilterWheelID }) ?? filterWheels.first else {
            if PhoenixWheel.sdkVersion == nil {
                presentError(FilterWheelError.sdkNotFound)
            } else {
                presentError(FilterWheelError.noWheelSelected)
            }
            return
        }
        selectedFilterWheelID = descriptor.id
        guard !isFilterWheelMoving else { return }
        isFilterWheelMoving = true
        filterWheelStatus = "Opening \(descriptor.name)…"
        let wheel = filterWheel
        filterWheelTask?.cancel()
        filterWheelTask = Task {
            do {
                let snapshot = try await Task.detached {
                    try wheel.connect(handle: descriptor.handle)
                    return try wheel.snapshot()
                }.value
                try Task.checkCancellation()
                // Clear the flag before the guard, not after. It gates the
                // filter picker, Refresh, and the wheel picker, so a return
                // that leaves it set kills the whole panel until the app is
                // quit — see `canConnectFilterWheel`, which now always allows
                // a disconnect for the same reason.
                isFilterWheelMoving = false
                guard wheel.isConnected else { return }
                applyFilterSnapshot(snapshot)
            } catch is CancellationError {
                isFilterWheelMoving = false
                isFilterWheelConnected = wheel.isConnected
                filterWheelStatus = isFilterWheelConnected ? filterWheelStatus : "Disconnected"
            } catch {
                isFilterWheelConnected = false
                isFilterWheelMoving = false
                hardwareFilterPosition = nil
                filterSlots = []
                filterWheelStatus = "Not connected"
                presentError(error)
            }
        }
    }

    public func disconnectFilterWheel() {
        filterWheelTask?.cancel()
        filterWheelTask = nil
        filterWheel.disconnect()
        isFilterWheelConnected = false
        isFilterWheelMoving = false
        hardwareFilterPosition = nil
        filterSlots = []
        selectedFilterPosition = 0
        filterWheelStatus = PhoenixWheel.sdkVersion == nil ? "No filter wheel" : "Disconnected"
        refreshFilterWheels()
    }

    public func gotoFilter(_ position: Int) {
        guard isFilterWheelConnected, !isFilterWheelMoving else { return }
        guard filterSlots.contains(where: { $0.position == position }) else { return }
        if hardwareFilterPosition == position { return }
        selectedFilterPosition = position
        isFilterWheelMoving = true
        let label = filterSlots.first { $0.position == position }?.displayName ?? "\(position + 1)"
        filterWheelStatus = "Moving to \(label)…"
        let wheel = filterWheel
        filterWheelTask?.cancel()
        filterWheelTask = Task {
            do {
                let snapshot = try await Task.detached {
                    try wheel.goto(position: position)
                    return try wheel.snapshot()
                }.value
                try Task.checkCancellation()
                // As in `connectFilterWheel`: clearing this after the guard
                // meant a wheel that went away mid-move left the panel dead.
                isFilterWheelMoving = false
                guard wheel.isConnected else { return }
                applyFilterSnapshot(snapshot)
            } catch is CancellationError {
                isFilterWheelMoving = false
                if !wheel.isConnected {
                    isFilterWheelConnected = false
                    filterSlots = []
                    filterWheelStatus = "Disconnected"
                }
            } catch {
                isFilterWheelMoving = false
                guard wheel.isConnected else { return }
                if let snapshot = try? await Task.detached(operation: { try wheel.snapshot() }).value {
                    applyFilterSnapshot(snapshot)
                } else {
                    filterWheelStatus = "Move failed"
                }
                presentError(error)
            }
        }
    }

    private func applyFilterSnapshot(_ snapshot: FilterWheelSnapshot) {
        isFilterWheelConnected = true
        isFilterWheelMoving = snapshot.moving
        filterSlots = snapshot.slots
        if let position = snapshot.position {
            hardwareFilterPosition = position
            selectedFilterPosition = position
        }
        let current = snapshot.slots.first { $0.position == snapshot.position }?.displayName
        if snapshot.moving {
            filterWheelStatus = "Moving…"
        } else if let current {
            filterWheelStatus = "\(snapshot.name) — filter \(current)"
        } else {
            filterWheelStatus = snapshot.name
        }
    }

    public func calibrateMount() {
        guard !isMountBusy, !isStacking else { return }
        mountTask?.cancel()
        mountTask = Task { await self.runCalibration() }
    }

    public func centerStar() {
        guard !isMountBusy, !isStacking else { return }
        mountTask?.cancel()
        mountTask = Task { await self.runCentering() }
    }

    private func runCalibration() async {
        do {
            try beginMountWork("Calibrating — measuring east…", holdROI: true, work: .calibrating)
            let duration = MountGuide.calibrationPulseMs
            let beforeEast = try await waitForCentroid()
            try await sendPulse(.east, milliseconds: duration)
            let afterEast = try await waitForSettledCentroid()
            let eastRate = MountGuide.rate(before: beforeEast, after: afterEast, durationMs: Double(duration))
            if hypot(eastRate.x, eastRate.y) * Double(duration) < MountGuide.minCalibrationMovePixels {
                throw MountError.calibrationTooSmall("east")
            }

            mountStatus = "Calibrating — returning from east…"
            try await sendPulse(.west, milliseconds: duration)
            let afterWest = try await waitForSettledCentroid()
            let raBacklash = MountGuide.backlashPixels(
                start: beforeEast,
                afterOutbound: afterEast,
                afterReturn: afterWest
            )

            mountStatus = "Calibrating — measuring north…"
            let beforeNorth = try await waitForCentroid()
            try await sendPulse(.north, milliseconds: duration)
            let afterNorth = try await waitForSettledCentroid()
            let northRate = MountGuide.rate(before: beforeNorth, after: afterNorth, durationMs: Double(duration))
            if hypot(northRate.x, northRate.y) * Double(duration) < MountGuide.minCalibrationMovePixels {
                throw MountError.calibrationTooSmall("north")
            }

            mountStatus = "Calibrating — returning from north…"
            try await sendPulse(.south, milliseconds: duration)
            let afterSouth = try await waitForSettledCentroid()
            let decBacklash = MountGuide.backlashPixels(
                start: beforeNorth,
                afterOutbound: afterNorth,
                afterReturn: afterSouth
            )

            let calibration = GuideCalibration(
                eastRate: eastRate,
                northRate: northRate,
                sampleDurationMs: duration,
                raBacklashPixels: raBacklash,
                decBacklashPixels: decBacklash
            )
            guard calibration.isValid else { throw MountError.calibrationTooSmall("mount axes") }
            try GuideCalibrationStore.save(calibration)
            guideCalibration = calibration
            await endMountWork(Self.calibratedStatus(calibration))
        } catch is CancellationError {
            await endMountWork("Calibration cancelled")
        } catch {
            await endMountWork("Calibration failed")
            noteMountFailure(error)
            presentError(error)
        }
    }

    private func runCentering() async {
        do {
            guard let calibration = guideCalibration, calibration.isValid else {
                throw MountError.notCalibrated
            }
            try beginMountWork("Centering on sensor…", holdROI: true, useFullFrame: true, work: .centering)
            try await moveStar(to: sensorCenter(), calibration: calibration)
            let centroid = try await waitForCentroid()
            let lastError = MountGuide.errorLength(centroid - sensorCenter())
            if MountGuide.isCentered(errorPixels: centroid - sensorCenter()) {
                await endMountWork(String(format: "Centered — %.1f px from sensor center", lastError))
            } else {
                await endMountWork(String(format: "Stopped — %.1f px from sensor center", lastError))
            }
        } catch is CancellationError {
            await endMountWork("Centering cancelled")
        } catch {
            await endMountWork("Centering failed")
            noteMountFailure(error)
            presentError(error)
        }
    }

    private func beginMountWork(_ status: String, holdROI: Bool, useFullFrame: Bool = false, work: MountWork) throws {
        guard isMountConnected else { throw MountError.notConnected }
        guard isConnected else { throw CameraError.notConnected }
        isMountBusy = true
        mountWork = work
        mountStatus = status
        mountHoldsROI = holdROI
        applyPipelineConfig()
        if useFullFrame {
            showFullFramePreview()
        }
    }

    /// Drops the mount when a failed command was the cable rather than the
    /// command.
    ///
    /// The camera defect, one subsystem over. Nothing reported that the mount
    /// had gone: `isMountConnected` was written only by connect and disconnect,
    /// so after an EQDIR unplug the button went on saying Disconnect, Calibrate
    /// and Center stayed enabled, and each one failed a few seconds later with
    /// a timeout. `EQ6Mount.isConnected` is no help — it is `proto != nil &&
    /// port.isOpen`, and a Windows COM handle stays valid after the device is
    /// removed — so, as with the camera, re-enumerating is the only thing that
    /// can tell a vanished mount from a slow one.
    /// Whether a failed mount command was the cable rather than the command.
    ///
    /// Free so it can be tested without a mount. A star that was not found, a
    /// calibration that came out too small and a cancellation all say nothing
    /// about the cable; a timeout or a protocol failure might, and the port
    /// list is what settles it.
    /// `SerialPortError` counts as well as `MountError`, and that is the whole
    /// point rather than belt and braces. Only `readHashLocked` maps a serial
    /// failure to a `MountError`, and only the SynScan and LX200 paths use it:
    /// `skyCommandLocked` calls `port.readUntil` directly, so an EQDIR cable —
    /// the one this project actually has — throws a raw `SerialPortError` and
    /// the first version of this check ignored exactly the case it was written
    /// for.
    public static func mountFailureMeansDisconnected(
        _ error: Error,
        port: String,
        availablePorts: [String]
    ) -> Bool {
        switch error {
        case MountError.timeout, MountError.protocolFailure, MountError.notConnected,
             SerialPortError.timeout, SerialPortError.ioFailed, SerialPortError.closed:
            return !availablePorts.contains(port)
        default:
            return false
        }
    }

    private func noteMountFailure(_ error: Error) {
        guard isMountConnected else { return }
        guard Self.mountFailureMeansDisconnected(
            error,
            port: selectedSerialPort,
            availablePorts: serialPortPaths()
        ) else { return }
        Log.info("mount port \(selectedSerialPort) is gone; disconnecting")
        disconnectMount()
        mountStatus = "Mount disconnected — check the cable"
    }

    /// Stops the motors without freezing the window.
    ///
    /// `haltMotions` is a blocking serial conversation, and the engine is
    /// main-actor isolated, so calling it directly stalled the UI at the end of
    /// every calibration and every centering: a few tens of milliseconds with a
    /// mount that answers, but 0.8 s on SynScan and up to 4 s on SkyWatcher
    /// when it has stopped answering — long enough for Windows to paint the
    /// ghost window and add "(Not Responding)". `mount` is nonisolated and
    /// Sendable, so it costs nothing to do this off the actor.
    private func haltMotionsOffActor() async {
        let mount = self.mount
        await Task.detached { mount.haltMotions() }.value
    }

    private func endMountWork(_ status: String) async {
        await haltMotionsOffActor()
        finishMountWork(status)
    }

    /// For `defer`, which cannot await. The halt still leaves the actor; it is
    /// simply not waited for, and nothing below depends on the motors having
    /// already stopped.
    private func endMountWorkWithoutWaiting(_ status: String) {
        let mount = self.mount
        Task.detached { mount.haltMotions() }
        finishMountWork(status)
    }

    private func finishMountWork(_ status: String) {
        restoreTrackingDisplay()
        mountHoldsROI = false
        applyPipelineConfig()
        isMountBusy = false
        mountWork = nil
        mountStatus = status
        mountTask = nil
    }

    /// Put the camera back on the 2048 tracking window so the live view is the 512 crop.
    private func restoreTrackingDisplay() {
        guard isConnected, !isStacking else { return }
        let center = tracking.centroidOnSensor
            ?? SIMD2(Double(sensorWidth) / 2, Double(sensorHeight) / 2)
        applyTrackingWindow(around: center)
    }

    private func applyTrackingWindow(around sensor: SIMD2<Double>) {
        showingFullFramePreview = false
        restoreZoomAfterFullFrame()
        coalescer.cancel()
        pipeline.dropInFlight()
        softwareCrop.setHoldDisabled(false)
        softwareCrop.update(enabled: true, sensorCentroid: sensor)
        session.requestROI(
            Alignment.centeredROI(
                around: sensor,
                size: CaptureLayout.trackingHardwareSize,
                sensorWidth: sensorWidth,
                sensorHeight: sensorHeight,
                binning: 1,
                alignment: roiAlignment
            )
        )
    }

    private func showFullFramePreview() {
        coalescer.cancel()
        pipeline.dropInFlight()
        softwareCrop.setHoldDisabled(true)
        showingFullFramePreview = true
        if zoomBeforeFullFrame == nil {
            zoomBeforeFullFrame = zoom
        }
        session.requestROI(
            Alignment.fullFrameROI(
                sensorWidth: sensorWidth,
                sensorHeight: sensorHeight,
                binning: 1,
                alignment: roiAlignment
            )
        )
        zoom = clampedZoom(ImageLayout.fitZoom(
            imageWidth: sensorWidth,
            imageHeight: sensorHeight,
            viewWidth: viewWidth,
            viewHeight: viewHeight
        ))
        updateStabilization()
    }

    private func restoreZoomAfterFullFrame() {
        guard let saved = zoomBeforeFullFrame else { return }
        zoomBeforeFullFrame = nil
        zoom = min(Self.maxZoom, max(Self.minZoom, saved))
        updateStabilization()
    }

    private func enterFullFrame() async throws {
        showFullFramePreview()
        _ = try await waitForCentroid(minNewFrames: 2, timeout: 12)
    }

    private func prepareStackWindow(around sensor: SIMD2<Double>) async throws {
        applyTrackingWindow(around: sensor)
        _ = try await waitForCentroid(minNewFrames: 2, timeout: 12)
    }

    private func moveStar(to target: SIMD2<Double>, calibration: GuideCalibration) async throws {
        var centroid = try await waitForSettledCentroid()
        if MountGuide.isCentered(errorPixels: centroid - target) { return }

        let deadline = Date().addingTimeInterval(90)
        var lastRASign: Double?
        var lastDecSign: Double?
        do {
            while Date() < deadline {
                try Task.checkCancellation()
                if MountGuide.isCentered(errorPixels: centroid - target) { break }

                guard let plan = AxisCentering.plan(
                    calibration: calibration,
                    movingStarBy: target - centroid,
                    lastDirections: axisDirections,
                    lastRASign: lastRASign,
                    lastDecSign: lastDecSign
                ) else { break }

                if let pixels = calibration.signedAxisPixels(toMoveStarBy: target - centroid) {
                    lastRASign = pixels.ra
                    lastDecSign = pixels.dec
                }
                mountStatus = Self.centeringStatus(plan)
                try await mount.applyNudge(plan.nudge)
                if let direction = plan.nudge.ra { axisDirections.record(direction) }
                if let direction = plan.nudge.dec { axisDirections.record(direction) }

                let schedule = plan.stopSchedule
                try await sleepMilliseconds(schedule.firstMs)
                if let remaining = schedule.remaining {
                    try await mount.applyNudge(remaining)
                    try await sleepMilliseconds(schedule.restMs)
                }
                try await mount.applyNudge(nil)

                centroid = try await waitForSettledCentroid()
            }
            try await mount.applyNudge(nil)
        } catch {
            await haltMotionsOffActor()
            throw error
        }
    }

    private static func centeringStatus(_ plan: AxisCentering.DualPlan) -> String {
        func axisText(_ plan: AxisCentering.Plan) -> String {
            String(format: "%@ %.1f×", plan.axis.displayName, plan.siderealMultiple)
        }
        switch (plan.ra, plan.dec) {
        case let (ra?, dec?):
            return "Centering \(axisText(ra)) · \(axisText(dec))"
        case let (ra?, nil):
            return "Centering \(axisText(ra))"
        case let (nil, dec?):
            return "Centering \(axisText(dec))"
        case (nil, nil):
            return "Centering"
        }
    }

    private func sendPulse(_ direction: GuideDirection, milliseconds: Int) async throws {
        try Task.checkCancellation()
        try await mount.pulse(direction, milliseconds: milliseconds)
        axisDirections.record(direction)
    }

    private static func calibratedStatus(_ calibration: GuideCalibration) -> String {
        var text = String(
            format: "Calibrated — east %.3f px/ms, north %.3f px/ms",
            hypot(calibration.eastRate.x, calibration.eastRate.y),
            hypot(calibration.northRate.x, calibration.northRate.y)
        )
        if calibration.raBacklashPixels > 0.5 || calibration.decBacklashPixels > 0.5 {
            text += String(
                format: ", backlash RA %.0f px / Dec %.0f px",
                calibration.raBacklashPixels,
                calibration.decBacklashPixels
            )
        }
        return text
    }

    private func waitForSettledCentroid() async throws -> SIMD2<Double> {
        try await sleepMilliseconds(MountGuide.settleMilliseconds)
        return try await waitForCentroid(minNewFrames: 2, timeout: 10)
    }

    private func waitForCentroid(minNewFrames: Int = 1, timeout: TimeInterval = 4) async throws -> SIMD2<Double> {
        let startSeq = frameSequence
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            if frameSequence >= startSeq + UInt64(minNewFrames),
               tracking.state == .tracking,
               let centroid = tracking.centroidOnSensor
            {
                return centroid
            }
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        throw MountError.noStar
    }

    private func sensorCenter() -> SIMD2<Double> {
        let width = overlay.sensorWidth > 0 ? overlay.sensorWidth : sensorWidth
        let height = overlay.sensorHeight > 0 ? overlay.sensorHeight : sensorHeight
        return MountGuide.frameCenter(width: width, height: height)
    }

    private func sleepMilliseconds(_ ms: Int) async throws {
        guard ms > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
    }

    private func applyPipelineConfig() {
        pipeline.configure(
            autoCenter: autoCenter && !holdsROI,
            autoSearch: autoSearch && !holdsROI,
            sensorWidth: sensorWidth,
            sensorHeight: sensorHeight,
            holdROI: holdsROI,
            optics: optics,
            roiAlignment: roiAlignment,
            searchBinning: searchBinning
        )
        session.setHoldROI(holdsROI)
    }

    private var holdsROI: Bool { mountHoldsROI || isStacking }

    private func presentError(_ error: Error) {
        if error is CancellationError { return }
        errorMessage = error.localizedDescription
        Log.info("Error: \(error.localizedDescription)")
    }

    private func handleError(_ error: Error) {
        errorMessage = error.localizedDescription
        Log.info("Error: \(error.localizedDescription)")
        disconnect()
        statusText = "Error"
    }

}
