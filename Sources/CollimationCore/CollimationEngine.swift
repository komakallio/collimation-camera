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
    @Published public var gain: Double = 100
    @Published public var exposureRange: ClosedRange<Double> = Double(ExposureControl.minMicroseconds)...Double(ExposureControl.maxMicroseconds)
    @Published public var gainRange: ClosedRange<Double> = 0...400

    @Published public var roiSize: Int = 512
    @Published public var autoCenter = true
    @Published public var stabilize = false
    @Published public var showOverlay = true
    @Published public var zoom: Double = 1
    @Published public var stretch = StretchParams.default
    @Published public var histogram = Histogram()
    @Published public var tracking = TrackingStatus()
    @Published public var coma: ComaResult?
    @Published public var overlay = OverlayModel()
    @Published public var frameSequence: UInt64 = 0
    @Published public var fps: Double = 0

    public let roiSizes = [256, 512, 1024, 2048, 0]
    public static let minZoom = 0.25
    public static let maxZoom = 8.0

    nonisolated private let session = CaptureSession()
    nonisolated private let pipeline = FramePipeline()
    nonisolated private let coalescer = FrameCoalescer(label: "collimation.process")
    nonisolated private let fpsMeter = FPSMeter()
    private var device: CameraDevice?
    private var applyingControls = false
    private var lastSentExposure: Int?
    private var lastSentGain: Int?
    private var sensorWidth = CameraDescriptor.simulator.sensorWidth
    private var sensorHeight = CameraDescriptor.simulator.sensorHeight
    private var stabilizer = DigitalStabilizer()
    private var cancellables = Set<AnyCancellable>()

    public init() {
        refreshDevices()
        selectedDeviceID = DeviceCatalog.preferredDeviceID(in: devices)
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
            .combineLatest($roiSize)
            .sink { [weak self] autoCenter, roiSize in
                guard let self else { return }
                self.pipeline.configure(
                    autoCenter: autoCenter,
                    roiSize: roiSize,
                    sensorWidth: self.sensorWidth,
                    sensorHeight: self.sensorHeight
                )
            }
            .store(in: &cancellables)
    }

    deinit {
        stopCapture()
    }

    /// Stops grabbing and closes the camera. Safe to call from any thread,
    /// including `applicationShouldTerminate`, where a `Task` would race process exit.
    nonisolated public func stopCapture() {
        coalescer.cancel()
        session.stop()
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
            pipeline.configure(
                autoCenter: autoCenter,
                roiSize: roiSize,
                sensorWidth: sensorWidth,
                sensorHeight: sensorHeight
            )
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
        overlay = OverlayModel()
        frameSlot.clear()
        stabilizer.reset()
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
        guard isConnected else { return }
        pipeline.markSearching()
        let roi = Alignment.fullFrameROI(sensorWidth: sensorWidth, sensorHeight: sensorHeight, binning: 4)
        session.requestROI(roi)
        tracking.state = .searching
        statusText = "Searching full frame…"
        updateStabilization()
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
        let pose = stabilizer.update(
            enabled: stabilize,
            centroid: overlay.centroid,
            tracking: tracking.state,
            imageWidth: overlay.imageWidth,
            imageHeight: overlay.imageHeight,
            viewWidth: viewWidth,
            viewHeight: viewHeight,
            zoom: zoom
        )
        if overlay.stabilizeLock != pose.lockNormalized || overlay.stabilizeCentroid != pose.centroid {
            overlay.stabilizeLock = pose.lockNormalized
            overlay.stabilizeCentroid = pose.centroid
        }
        renderStateSlot.store(
            RenderState(
                stretch: stretch,
                zoom: zoom,
                stabilizeLock: pose.lockNormalized,
                stabilizeCentroid: pose.centroid
            )
        )
    }

    private nonisolated func ingest(_ frame: Frame) {
        frameSlot.store(frame)
        _ = fpsMeter.tick()
        coalescer.submit(frame)
    }

    private nonisolated func analyze(_ frame: Frame) {
        let processed = pipeline.process(frame)
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

    private func handleError(_ error: Error) {
        errorMessage = error.localizedDescription
        disconnect()
        statusText = "Error"
    }

}
