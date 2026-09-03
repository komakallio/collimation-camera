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
    @Published public var starProfile: StarIntensityProfile?
    @Published public var overlay = OverlayModel()
    @Published public var frameSequence: UInt64 = 0
    @Published public var fps: Double = 0

    @Published public var serialPorts: [String] = []
    @Published public var selectedSerialPort = ""
    @Published public private(set) var isMountConnected = false
    @Published public private(set) var isMountBusy = false
    @Published public private(set) var mountWork: MountWork?
    @Published public private(set) var isStacking = false
    @Published public var mountStatus = "No mount"
    @Published public private(set) var guideCalibration: GuideCalibration?

    @Published public private(set) var filterWheels: [FilterWheelDescriptor] = []
    @Published public var selectedFilterWheelID = ""
    @Published public private(set) var isFilterWheelConnected = false
    @Published public private(set) var isFilterWheelMoving = false
    @Published public var filterWheelStatus = "No filter wheel"
    @Published public private(set) var filterSlots: [FilterSlot] = []
    @Published public var selectedFilterPosition = 0

    public static let minZoom = 0.25
    public static let maxZoom = 8.0
    public var isMountCalibrated: Bool { guideCalibration?.isValid == true }

    nonisolated private let session = CaptureSession()
    nonisolated private let pipeline = FramePipeline()
    nonisolated private let coalescer = FrameCoalescer(label: "collimation.process")
    nonisolated private let fpsMeter = FPSMeter()
    nonisolated private let mount = EQ6Mount()
    nonisolated private let filterWheel = PhoenixWheel()
    private var device: CameraDevice?
    private var applyingControls = false
    private var lastSentExposure: Int?
    private var lastSentGain: Int?
    private var sensorWidth = CameraDescriptor.simulator.sensorWidth
    private var sensorHeight = CameraDescriptor.simulator.sensorHeight
    private var optics = TelescopeOptics.poseidon
    nonisolated public let stabilization = StabilizationController()
    nonisolated private let softwareCrop = SoftwareCropController()
    private var cancellables = Set<AnyCancellable>()
    private var mountTask: Task<Void, Never>?
    private var stackTask: Task<Void, Never>?
    private var filterWheelTask: Task<Void, Never>?
    private var mountHoldsROI = false
    private var hardwareFilterPosition: Int?
    private static let serialPortDefaultsKey = "mount.serialPort"
    private static let filterWheelDefaultsKey = "filterWheel.id"

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
            .combineLatest($autoSearch)
            .sink { [weak self] _, _ in
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
        refreshFilterWheels()
        if let saved = UserDefaults.standard.string(forKey: Self.filterWheelDefaultsKey),
           filterWheels.contains(where: { $0.id == saved })
        {
            selectedFilterWheelID = saved
        }
        $selectedFilterWheelID
            .sink { id in
                if !id.isEmpty {
                    UserDefaults.standard.set(id, forKey: Self.filterWheelDefaultsKey)
                }
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
            optics = TelescopeOptics.forCameraName(newDevice.descriptor.name)
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
        let label = "stack\(FrameStacker.subframeCount)"
        if let frame = frameSlot.peek()?.frame {
            return MonoTIFF.suggestedFileName(
                width: frame.width,
                height: frame.height,
                date: frame.timestamp,
                label: label
            )
        }
        let size = overlay.imageWidth > 0 ? overlay.imageWidth : CaptureLayout.displayCropSize
        let height = overlay.imageHeight > 0 ? overlay.imageHeight : size
        return MonoTIFF.suggestedFileName(width: max(size, 1), height: max(height, 1), label: label)
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
        applyPipelineConfig()
        statusText = "Stacking 0/\(FrameStacker.subframeCount)…"
        stackTask = Task { await self.runStackedSnapshot(to: url) }
    }

    private func runStackedSnapshot(to url: URL) async {
        do {
            let stacked = try await collectStackedFrame()
            try Task.checkCancellation()
            try MonoTIFF.write(stacked, to: url)
            statusText = "Saved \(url.lastPathComponent)"
        } catch is CancellationError {
            statusText = "Stack cancelled"
        } catch {
            presentError(error)
            statusText = "Stack failed"
        }
        isStacking = false
        stackTask = nil
        applyPipelineConfig()
    }

    private func collectStackedFrame() async throws -> StackedImage {
        let target = FrameStacker.subframeCount
        let detector = StarDetector()
        var seed = overlay.centroid ?? tracking.centroidInFrame
        var lastSeq: UInt64 = 0
        var stack: FrameStackAccumulator?
        let frameBudget = max(2.0, exposureMicroseconds / 1_000_000.0 + 1.0)
        let deadline = Date().addingTimeInterval(frameBudget * Double(target) + 30)

        while (stack?.count ?? 0) < target {
            try Task.checkCancellation()
            guard isConnected else { throw CameraError.disconnected }
            guard Date() < deadline else { throw CameraError.timeout }

            if let peeked = frameSlot.peek(), peeked.sequence > lastSeq {
                lastSeq = peeked.sequence
                let frame = peeked.frame
                if let centroid = detector.momentCentroid(in: frame, around: seed) {
                    seed = centroid
                    if stack == nil {
                        stack = FrameStackAccumulator(frame: frame, centroid: centroid)
                    } else if var current = stack {
                        guard current.add(frame: frame, centroid: centroid) else { continue }
                        stack = current
                    }
                    statusText = "Stacking \(stack?.count ?? 0)/\(target)…"
                }
            }
            try await Task.sleep(nanoseconds: 8_000_000)
        }

        guard let stack, stack.count >= target else {
            throw CameraError.unsupported("No tracked star. Keep the artificial star in the frame to stack.")
        }
        return stack.finish()
    }

    public func disconnect() {
        stackTask?.cancel()
        stackTask = nil
        isStacking = false
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
        optics = .poseidon
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
                sensorHeight: sensorHeight
            )
        )
    }

    public func searchNow() {
        guard isConnected, !isMountBusy, !isStacking else { return }
        pipeline.markSearching()
        coalescer.cancel()
        softwareCrop.reset()
        let roi = Alignment.fullFrameROI(sensorWidth: sensorWidth, sensorHeight: sensorHeight, binning: 4)
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
            if !stabilize || tracking.state == .searching {
                state.stabilizeLock = nil
                state.stabilizeCentroid = nil
            }
        }
    }

    private nonisolated func ingest(_ frame: Frame) {
        frameSlot.store(softwareCrop.apply(frame))
        _ = fpsMeter.tick()
        coalescer.submit(frame)
    }

    private nonisolated func analyze(_ frame: Frame) {
        guard let processed = pipeline.process(frame) else { return }
        if let roi = processed.tracking.requestedROI {
            session.requestROI(roi)
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
        mount.disconnect()
        isMountConnected = false
        isMountBusy = false
        mountWork = nil
        let restoreDisplay = mountHoldsROI
        mountHoldsROI = false
        applyPipelineConfig()
        if restoreDisplay {
            restoreTrackingDisplay()
        }
        mountStatus = isMountCalibrated ? "Calibrated — mount disconnected" : "No mount"
    }

    public func refreshFilterWheels() {
        filterWheels = filterWheel.enumerate()
        let saved = UserDefaults.standard.string(forKey: Self.filterWheelDefaultsKey) ?? selectedFilterWheelID
        if let match = filterWheels.first(where: { $0.id == selectedFilterWheelID || $0.id == saved }) {
            selectedFilterWheelID = match.id
        } else if let first = filterWheels.first {
            selectedFilterWheelID = first.id
        }
        if !isFilterWheelConnected {
            if PhoenixWheel.sdkVersion == nil {
                filterWheelStatus = "SDK not found — place libPlayerOnePW.dylib in Vendor/PlayerOne"
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
            try beginMountWork("Centering on sensor…", holdROI: true, useFullFrame: true, work: .centering)
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

    private func beginMountWork(_ status: String, holdROI: Bool, useFullFrame: Bool = false, work: MountWork) throws {
        guard isMountConnected else { throw MountError.notConnected }
        guard isConnected else { throw CameraError.notConnected }
        isMountBusy = true
        mountWork = work
        mountStatus = status
        mountHoldsROI = holdROI
        applyPipelineConfig()
        if useFullFrame {
            coalescer.cancel()
            softwareCrop.reset()
            session.requestROI(
                Alignment.fullFrameROI(sensorWidth: sensorWidth, sensorHeight: sensorHeight, binning: 1)
            )
        }
    }

    private func endMountWork(_ status: String) {
        mount.haltMotions()
        mountHoldsROI = false
        applyPipelineConfig()
        isMountBusy = false
        mountWork = nil
        mountStatus = status
        mountTask = nil
        restoreTrackingDisplay()
    }

    /// Put the camera back on the 2048 tracking window so the live view is the 512 crop.
    private func restoreTrackingDisplay() {
        guard isConnected, !isStacking else { return }
        coalescer.cancel()
        let center = tracking.centroidOnSensor
            ?? SIMD2(Double(sensorWidth) / 2, Double(sensorHeight) / 2)
        softwareCrop.update(enabled: true, sensorCentroid: center)
        session.requestROI(
            Alignment.centeredROI(
                around: center,
                size: CaptureLayout.trackingHardwareSize,
                sensorWidth: sensorWidth,
                sensorHeight: sensorHeight
            )
        )
    }

    private func centerWithPadNudges(calibration: GuideCalibration) async throws {
        let target = sensorCenter()
        var centroid = try await waitForSettledCentroid()
        if MountGuide.isCentered(errorPixels: centroid - target) { return }

        let deadline = Date().addingTimeInterval(90)
        do {
            guard let first = AxisCentering.primaryAxis(
                calibration: calibration,
                movingStarBy: target - centroid
            ) else { return }
            try await centerAxis(
                first,
                calibration: calibration,
                target: target,
                centroid: &centroid,
                deadline: deadline
            )
            try await centerAxis(
                first.other,
                calibration: calibration,
                target: target,
                centroid: &centroid,
                deadline: deadline
            )
            try await centerAxis(
                first,
                calibration: calibration,
                target: target,
                centroid: &centroid,
                deadline: deadline
            )
            try await mount.applyNudge(nil)
        } catch {
            mount.haltMotions()
            throw error
        }
    }

    private func centerAxis(
        _ axis: MountAxis,
        calibration: GuideCalibration,
        target: SIMD2<Double>,
        centroid: inout SIMD2<Double>,
        deadline: Date
    ) async throws {
        var lastRate: UInt8?
        var lastSign: Double?

        while Date() < deadline {
            try Task.checkCancellation()
            if MountGuide.isCentered(errorPixels: centroid - target) { return }

            guard let axisPixels = calibration.signedAxisPixels(toMoveStarBy: target - centroid) else {
                return
            }
            let remaining = axis == .ra ? axisPixels.ra : axisPixels.dec
            guard let plan = AxisCentering.plan(
                axis: axis,
                remainingPixels: remaining,
                lastRate: lastRate,
                lastSign: lastSign
            ) else { return }

            lastRate = plan.rate
            lastSign = remaining

            let remainingOnAxis = calibration.remainingOnAxis(axis, movingStarBy: target - centroid)
                ?? (target - centroid)
            let sliceMs = MountGuide.nudgeSliceMilliseconds(
                remaining: remainingOnAxis,
                calibration: calibration,
                rate: plan.rate
            )
            mountStatus = String(
                format: "Centering %@ %.0fx — %.0f px on axis",
                axis.displayName,
                SynScanGuide.siderealMultiple(plan.rate),
                abs(remaining)
            )
            try await mount.applyNudge(plan.padNudge)
            try await sleepMilliseconds(sliceMs)
            try await mount.applyNudge(nil)

            centroid = try await waitForSettledCentroid()
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
            autoCenter: autoCenter && !holdsROI,
            autoSearch: autoSearch && !holdsROI,
            sensorWidth: sensorWidth,
            sensorHeight: sensorHeight,
            holdROI: holdsROI,
            optics: optics
        )
    }

    private var holdsROI: Bool { mountHoldsROI || isStacking }

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
