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

    public init(
        imageWidth: Int = 0,
        imageHeight: Int = 0,
        centroid: SIMD2<Double>? = nil,
        outer: FittedCircle? = nil,
        inner: FittedCircle? = nil,
        comaVector: SIMD2<Double>? = nil,
        trackingState: TrackingState = .idle
    ) {
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.centroid = centroid
        self.outer = outer
        self.inner = inner
        self.comaVector = comaVector
        self.trackingState = trackingState
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
    @Published public var exposureRange: ClosedRange<Double> = 32...2_000_000
    @Published public var gainRange: ClosedRange<Double> = 0...400

    @Published public var roiSize: Int = 512
    @Published public var autoCenter = true
    @Published public var zoom: Double = 1
    @Published public var stretch = StretchParams.default
    @Published public var histogram = Histogram()
    @Published public var tracking = TrackingStatus()
    @Published public var coma: ComaResult?
    @Published public var overlay = OverlayModel()
    @Published public var frameSequence: UInt64 = 0
    @Published public var fps: Double = 0

    public let roiSizes = [128, 256, 512, 1024, 0]
    public static let minZoom = 0.25
    public static let maxZoom = 8.0

    nonisolated private let session = CaptureSession()
    nonisolated private let pipeline = FramePipeline()
    private var device: CameraDevice?
    private var lastFPSTimestamp = Date()
    private var framesInWindow = 0
    private var applyingControls = false
    private var sensorWidth = CameraDescriptor.simulator.sensorWidth
    private var sensorHeight = CameraDescriptor.simulator.sensorHeight
    private var cancellables = Set<AnyCancellable>()

    public init() {
        refreshDevices()
        session.onFrame = { [weak self] frame in
            self?.ingest(frame)
        }
        session.onError = { [weak self] error in
            Task { @MainActor in
                self?.handleError(error)
            }
        }
        $stretch
            .combineLatest($zoom)
            .sink { [weak self] stretch, zoom in
                self?.renderStateSlot.store(RenderState(stretch: stretch, zoom: zoom))
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

    public var selectedDevice: CameraDescriptor? {
        devices.first { $0.id == selectedDeviceID }
    }

    public func refreshDevices() {
        devices = DeviceCatalog.list()
        if devices.contains(where: { $0.id == selectedDeviceID }) == false {
            selectedDeviceID = devices.first?.id ?? CameraDescriptor.simulator.id
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
            exposureRange = Double(newDevice.controls.exposureRange.lowerBound)...Double(min(newDevice.controls.exposureRange.upperBound, 2_000_000))
            gainRange = Double(newDevice.controls.gainRange.lowerBound)...Double(newDevice.controls.gainRange.upperBound)
            applyingControls = true
            exposureMicroseconds = Double(newDevice.controls.exposureMicroseconds)
            gain = Double(newDevice.controls.gain)
            applyingControls = false
            pipeline.configure(
                autoCenter: autoCenter,
                roiSize: roiSize,
                sensorWidth: sensorWidth,
                sensorHeight: sensorHeight
            )
            pipeline.reset()
            session.start(device: newDevice)
            isConnected = true
            statusText = "Live — \(newDevice.descriptor.name)"
        } catch {
            handleError(error)
        }
    }

    public func disconnect() {
        session.stop()
        device = nil
        isConnected = false
        tracking = TrackingStatus()
        coma = nil
        overlay = OverlayModel()
        frameSlot.clear()
        statusText = "Disconnected"
    }

    public func applyExposure() {
        guard isConnected, !applyingControls else { return }
        session.requestExposure(Int(exposureMicroseconds))
    }

    public func applyGain() {
        guard isConnected, !applyingControls else { return }
        session.requestGain(Int(gain))
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
    }

    public func autoStretch() {
        stretch = StretchParams.auto(from: histogram)
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
        publishRenderState()
    }

    public func clampZoom() {
        zoom = min(Self.maxZoom, max(Self.minZoom, zoom))
        publishRenderState()
    }

    private nonisolated func ingest(_ frame: Frame) {
        frameSlot.store(frame)
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
        framesInWindow += 1
        let elapsed = Date().timeIntervalSince(lastFPSTimestamp)
        if elapsed >= 0.5 {
            fps = Double(framesInWindow) / elapsed
            framesInWindow = 0
            lastFPSTimestamp = Date()
        }
        histogram = processed.histogram
        tracking = processed.tracking
        coma = processed.coma
        overlay = processed.overlay
        switch processed.tracking.state {
        case .tracking:
            statusText = String(format: "Tracking  %.1f fps", fps)
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

    private func publishRenderState() {
        renderStateSlot.store(RenderState(stretch: stretch, zoom: zoom))
    }
}
