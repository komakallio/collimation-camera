import Combine
import Foundation

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
        roi: ROI = ROI(x: 0, y: 0, width: 0, height: 0)
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
    }
}

@MainActor
public final class CollimationEngine: ObservableObject {
    nonisolated public let frameSlot = FrameSlot()
    nonisolated public let renderStateSlot = RenderStateSlot()
    public var viewWidth = 800.0
    public var viewHeight = 700.0

    @Published public private(set) var devices: [CameraDescriptor] = []
    @Published public var selectedDeviceID: String = CameraDescriptor.simulator.id
    @Published public private(set) var isConnected = false
    @Published public var statusText = "Disconnected"
    @Published public var errorMessage: String?

    @Published public var exposureMicroseconds: Double = 50_000
    @Published public var gain: Double = 0
    @Published public var exposureRange: ClosedRange<Double> = Double(ExposureControl.minMicroseconds)...Double(ExposureControl.maxMicroseconds)
    @Published public var gainRange: ClosedRange<Double> = 0...400

    @Published public var roiSize: Int = 512
    @Published public var autoCenter = true
    @Published public var autoSearch = false
    @Published public var stabilize = false
    @Published public var showOverlay = true
    @Published public var zoom: Double = 1
    @Published public var stretch = StretchParams.default
    @Published public var histogram = Histogram()
    @Published public var tracking = TrackingStatus()
    @Published public var coma: ComaResult?
    @Published public var fwhm: FWHMResult?
    @Published public var overlay = OverlayModel()
    @Published public var frameSequence: UInt64 = 0
    @Published public var fps: Double = 0

    @Published public var serialPorts: [String] = []
    @Published public var selectedSerialPort = ""
    @Published public private(set) var isMountConnected = false
    @Published public private(set) var isMountBusy = false
    @Published public var mountStatus = "No mount"
    @Published public private(set) var guideCalibration: GuideCalibration?

    public let roiSizes = [256, 512, 1024, 2048, 0]
    public static let minZoom = 0.25
    public static let maxZoom = 8.0
    public var isMountCalibrated: Bool { guideCalibration?.isValid == true }

    nonisolated private let session = CaptureSession()
    nonisolated private let pipeline = FramePipeline()
    nonisolated private let coalescer = FrameCoalescer(label: "collimation.process")
    nonisolated private let fpsMeter = FPSMeter()
    nonisolated private let mount = EQ6Mount()
    private var device: CameraDevice?
    private var applyingControls = false
    private var lastSentExposure: Int?
    private var lastSentGain: Int?
    private var sensorWidth = CameraDescriptor.simulator.sensorWidth
    private var sensorHeight = CameraDescriptor.simulator.sensorHeight
    nonisolated public let stabilization = StabilizationController()
    private var cancellables = Set<AnyCancellable>()
    private var mountTask: Task<Void, Never>?
    private var mountHoldsROI = false
    private var restoreROIAfterMount = false
    private static let serialPortDefaultsKey = "mount.serialPort"

    public init() {
        refreshDevices()
        selectedDeviceID = DeviceCatalog.preferredDeviceID(in: devices)
        refreshSerialPorts()
        if let saved = UserDefaults.standard.string(forKey: Self.serialPortDefaultsKey), !saved.isEmpty {
            selectedSerialPort = saved
            if !serialPorts.contains(saved) {
                serialPorts.insert(saved, at: 0)
            }
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
        $stretch
            .combineLatest($zoom, $stabilize)
            .sink { [weak self] _, _, _ in
                self?.updateStabilization()
            }
            .store(in: &cancellables)
        $autoCenter
            .combineLatest($roiSize, $autoSearch)
            .sink { [weak self] _, _, _ in
                self?.applyPipelineConfig()
            }
            .store(in: &cancellables)
        $autoSearch
            .sink { [weak self] enabled in
                self?.handleAutoSearchChange(enabled)
            }
            .store(in: &cancellables)
        $selectedSerialPort
            .sink { path in
                UserDefaults.standard.set(path, forKey: Self.serialPortDefaultsKey)
            }
            .store(in: &cancellables)
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

    /// Stops capture and closes the mount serial port. Call from app termination.
    nonisolated public func shutdown() {
        stopCapture()
        mount.disconnect()
    }

    public var selectedDevice: CameraDescriptor? {
        devices.first { $0.id == selectedDeviceID }
    }

    public func refreshDevices() {
        devices = DeviceCatalog.list()
        if devices.contains(where: { $0.id == selectedDeviceID }) == false {
            selectedDeviceID = DeviceCatalog.preferredDeviceID(in: devices)
        }
        if let sdk = DeviceCatalog.playerOneSDKVersion, !isConnected {
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
            statusText = "Live — \(newDevice.descriptor.name)"
        } catch {
            handleError(error)
        }
    }

    public func disconnect() {
        stopCapture()
        device = nil
        isConnected = false
        tracking = TrackingStatus()
        coma = nil
        fwhm = nil
        overlay = OverlayModel()
        frameSlot.clear()
        stabilization.reset()
        updateStabilization()
        statusText = "Disconnected"
    }

    public func applyExposure() {
        guard isConnected, !applyingControls else { return }
        let value = ExposureControl.clamp(Int(exposureMicroseconds.rounded()))
        exposureMicroseconds = Double(value)
        guard value != lastSentExposure else { return }
        lastSentExposure = value
        session.requestExposure(value)
    }

    public func autoExpose() {
        guard isConnected, histogram.sampleCount > 0 else { return }
        let peak = ExposureControl.peakNormalized(
            histogram: histogram,
            detectionPeak: tracking.detection?.peak
        )
        let next = ExposureControl.adjustedMicroseconds(
            current: Int(exposureMicroseconds.rounded()),
            peakNormalized: peak
        )
        applyingControls = true
        exposureMicroseconds = Double(next)
        applyingControls = false
        lastSentExposure = nil
        applyExposure()
    }

    public func applyGain() {
        guard isConnected, !applyingControls else { return }
        let value = Int(gain)
        guard value != lastSentGain else { return }
        lastSentGain = value
        session.requestGain(value)
    }

    public func applyROISize() {
        guard isConnected else { return }
        pipeline.reset()
        coalescer.cancel()
        let roi: ROI
        if roiSize == 0 {
            roi = Alignment.fullFrameROI(sensorWidth: sensorWidth, sensorHeight: sensorHeight, binning: 1)
        } else {
            let center = tracking.centroidOnSensor
                ?? SIMD2(Double(sensorWidth) / 2, Double(sensorHeight) / 2)
            roi = Alignment.centeredROI(
                around: center,
                size: roiSize,
                sensorWidth: sensorWidth,
                sensorHeight: sensorHeight
            )
        }
        session.requestROI(roi)
    }

    public func searchNow() {
        guard isConnected, !isMountBusy else { return }
        pipeline.markSearching()
        coalescer.cancel()
        let roi = Alignment.fullFrameROI(sensorWidth: sensorWidth, sensorHeight: sensorHeight, binning: 4)
        session.requestROI(roi)
        tracking.state = .searching
        statusText = "Searching full frame…"
        updateStabilization()
    }

    private func handleAutoSearchChange(_ enabled: Bool) {
        guard isConnected, !isMountBusy else { return }
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
        let size = overlay.imageWidth == 0 ? (roiSize == 0 ? 1024 : roiSize) : overlay.imageWidth
        let height = overlay.imageHeight == 0 ? size : overlay.imageHeight
        zoom = min(
            Self.maxZoom,
            max(Self.minZoom, ImageLayout.fitZoom(
                imageWidth: size,
                imageHeight: height,
                viewWidth: viewWidth ?? self.viewWidth,
                viewHeight: viewHeight ?? self.viewHeight
            ))
        )
        updateStabilization()
    }

    public func clampZoom() {
        zoom = min(Self.maxZoom, max(Self.minZoom, zoom))
        updateStabilization()
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
                roi: overlay.roi,
                imageWidth: overlay.imageWidth,
                imageHeight: overlay.imageHeight
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
            // Lock and centroid are written by the renderer for the frame it is
            // about to draw, so the pan matches that image under jitter.
            if !stabilize {
                state.stabilizeLock = nil
                state.stabilizeCentroid = nil
            }
        }
    }

    private nonisolated func ingest(_ frame: Frame) {
        frameSlot.store(frame)
        _ = fpsMeter.tick()
        coalescer.submit(frame)
    }

    private nonisolated func analyze(_ frame: Frame) {
        guard let processed = pipeline.process(frame) else { return }
        if let roi = processed.tracking.requestedROI {
            session.requestROI(roi)
        }
        Task { @MainActor in
            self.publish(processed)
        }
    }

    private func publish(_ processed: ProcessedFrame) {
        frameSequence &+= 1
        fps = fpsMeter.current
        histogram = processed.histogram
        tracking = processed.tracking
        coma = processed.coma
        fwhm = processed.fwhm
        overlay = processed.overlay
        updateStabilization()
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
        var ports = SerialPortScanner.availablePaths()
        let saved = UserDefaults.standard.string(forKey: Self.serialPortDefaultsKey) ?? selectedSerialPort
        if !saved.isEmpty, !ports.contains(saved) {
            ports.insert(saved, at: 0)
        }
        serialPorts = ports
        if selectedSerialPort.isEmpty {
            selectedSerialPort = ports.first ?? saved
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
                mountStatus = isMountCalibrated
                    ? "Connected — \(name), tracking off"
                    : "Connected — \(name), tracking off. Calibrate before centering."
            } catch {
                isMountConnected = false
                isMountBusy = false
                mountStatus = "Not connected"
                presentError(error)
            }
        }
    }

    public func disconnectMount() {
        mountTask?.cancel()
        mountTask = nil
        mount.disconnect()
        isMountConnected = false
        isMountBusy = false
        let restoreROI = restoreROIAfterMount
        mountHoldsROI = false
        restoreROIAfterMount = false
        applyPipelineConfig()
        if restoreROI {
            applyROISize()
        }
        mountStatus = isMountCalibrated ? "Calibrated — mount disconnected" : "No mount"
    }

    public func calibrateMount() {
        guard !isMountBusy else { return }
        mountTask?.cancel()
        mountTask = Task { await self.runCalibration() }
    }

    public func centerStar() {
        guard !isMountBusy else { return }
        mountTask?.cancel()
        mountTask = Task { await self.runCentering() }
    }

    private func runCalibration() async {
        do {
            try beginMountWork("Calibrating — measuring east…", holdROI: true)
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
            _ = try await waitForSettledCentroid()

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
            _ = try await waitForSettledCentroid()

            let calibration = GuideCalibration(
                eastRate: eastRate,
                northRate: northRate,
                sampleDurationMs: duration
            )
            guard calibration.isValid else { throw MountError.calibrationTooSmall("mount axes") }
            try GuideCalibrationStore.save(calibration)
            guideCalibration = calibration
            endMountWork(String(
                format: "Calibrated — east %.3f px/ms, north %.3f px/ms",
                hypot(eastRate.x, eastRate.y),
                hypot(northRate.x, northRate.y)
            ))
        } catch is CancellationError {
            endMountWork("Calibration cancelled")
        } catch {
            endMountWork("Calibration failed")
            presentError(error)
        }
    }

    private func runCentering() async {
        do {
            guard let calibration = guideCalibration, calibration.isValid else {
                throw MountError.notCalibrated
            }
            try beginMountWork("Centering on sensor…", holdROI: true, useFullFrame: true)
            try await centerWithPadNudges(calibration: calibration)
            let centroid = try await waitForCentroid()
            let lastError = MountGuide.errorLength(centroid - sensorCenter())
            if MountGuide.isCentered(errorPixels: centroid - sensorCenter()) {
                endMountWork(String(format: "Centered — %.1f px from sensor center", lastError))
            } else {
                endMountWork(String(format: "Stopped — %.1f px from sensor center", lastError))
            }
        } catch is CancellationError {
            endMountWork("Centering cancelled")
        } catch {
            endMountWork("Centering failed")
            presentError(error)
        }
    }

    private func beginMountWork(_ status: String, holdROI: Bool, useFullFrame: Bool = false) throws {
        guard isMountConnected else { throw MountError.notConnected }
        guard isConnected else { throw CameraError.notConnected }
        isMountBusy = true
        mountStatus = status
        mountHoldsROI = holdROI
        restoreROIAfterMount = useFullFrame
        applyPipelineConfig()
        if useFullFrame {
            session.requestROI(
                Alignment.fullFrameROI(sensorWidth: sensorWidth, sensorHeight: sensorHeight, binning: 1)
            )
        }
    }

    private func endMountWork(_ status: String) {
        mount.haltMotions()
        let restoreROI = restoreROIAfterMount
        mountHoldsROI = false
        restoreROIAfterMount = false
        applyPipelineConfig()
        if restoreROI {
            applyROISize()
        }
        isMountBusy = false
        mountStatus = status
        mountTask = nil
    }

    private func centerWithPadNudges(calibration: GuideCalibration) async throws {
        let target = sensorCenter()
        var centroid = try await waitForSettledCentroid()
        var error = centroid - target
        if MountGuide.isCentered(errorPixels: error) { return }

        let deadline = Date().addingTimeInterval(90)
        do {
            while Date() < deadline {
                try Task.checkCancellation()
                let distance = MountGuide.errorLength(error)
                if MountGuide.isCentered(errorPixels: error) { break }

                let desired = calibration.slewAxes(
                    toMoveStarBy: target - centroid,
                    minAxisPixels: 1
                )
                let rate = SynScanGuide.rate(forDistancePixels: distance)
                let next = (desired.ra == nil && desired.dec == nil)
                    ? nil
                    : PadNudge(ra: desired.ra, dec: desired.dec, rate: rate)
                if next == nil { break }

                let sliceMs = MountGuide.nudgeSliceMilliseconds(
                    remaining: target - centroid,
                    calibration: calibration,
                    rate: rate
                )
                let multiple = SynScanGuide.siderealMultiple(rate)
                mountStatus = String(
                    format: "Nudging %.0fx — %.0f px from sensor center",
                    multiple,
                    distance
                )
                try await mount.applyNudge(next)
                try await sleepMilliseconds(sliceMs)
                try await mount.applyNudge(nil)

                centroid = try await waitForSettledCentroid()
                error = centroid - target
            }
            try await mount.applyNudge(nil)
        } catch {
            mount.haltMotions()
            throw error
        }
    }

    private func sendPulse(_ direction: GuideDirection, milliseconds: Int) async throws {
        try Task.checkCancellation()
        try await mount.pulse(direction, milliseconds: milliseconds)
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
            autoCenter: autoCenter && !mountHoldsROI,
            autoSearch: autoSearch && !mountHoldsROI,
            roiSize: roiSize,
            sensorWidth: sensorWidth,
            sensorHeight: sensorHeight,
            holdROI: mountHoldsROI
        )
    }

    private func presentError(_ error: Error) {
        if error is CancellationError { return }
        errorMessage = error.localizedDescription
    }

    private func handleError(_ error: Error) {
        errorMessage = error.localizedDescription
        disconnect()
        statusText = "Error"
    }

}
