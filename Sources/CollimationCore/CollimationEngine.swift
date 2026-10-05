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
    nonisolated public let constellationRenderSlot = ConstellationRenderSlot()
    public private(set) var constellationResult: ConstellationResult?
    public var showingConstellation = false
    public private(set) var isLoadingConstellation = false
    public var recordConstellationFocusSweep = false
    public var constellationFocusSweepRange = FocusConstellationSettings.defaultRange
    public var constellationFocusSweepStep = FocusConstellationSettings.defaultStep
    public var constellationFocusSweepSettings: FocusConstellationSettings? {
        try? FocusConstellationSettings(range: constellationFocusSweepRange, step: constellationFocusSweepStep)
    }
    public var constellationFocusSweepWarning: String? {
        do {
            _ = try FocusConstellationSettings(range: constellationFocusSweepRange, step: constellationFocusSweepStep)
            return nil
        } catch { return error.localizedDescription }
    }
    public private(set) var isCapturingFocusConstellation = false
    public private(set) var focusConstellationProgress = FocusConstellationProgress()
    public private(set) var isLoadingConstellationFocus = false
    public private(set) var constellationFocusIndex = 0
    @ObservationIgnored private var constellationFocusTask: Task<Void, Never>?
    @ObservationIgnored private var constellationFocusRequest = UUID()
    @ObservationIgnored private var constellationFocusCache: [Int: ConstellationResult] = [:]
    @ObservationIgnored private var constellationFocusCacheOrder: [Int] = []
    private static let constellationFocusCacheLimit = 8
    @ObservationIgnored private var focusConstellationCancellation: AutofocusCancellation?
    public var canSelectConstellationFocusSweep: Bool { !isStacking && !isMeasuringTilt && !focuserIsWorking }
    public var constellationZoom: Double = 1 {
        didSet { updateConstellationDisplay() }
    }
    public var constellationStretch = StretchParams.default {
        didSet { updateConstellationDisplay() }
    }
    public var canOpenConstellation: Bool { !isLoadingConstellation && !isStacking && !isMeasuringTilt && !isCapturingFocusConstellation }
    public var canShowConstellation: Bool { constellationResult != nil }
    public var displayStretch: StretchParams {
        get { showingConstellation ? constellationStretch : stretch }
        set {
            if showingConstellation { constellationStretch = newValue } else { stretch = newValue }
        }
    }
    public var displayHistogram: Histogram { showingConstellation ? (constellationResult?.histogram ?? Histogram()) : histogram }

    public func clampedConstellationZoom(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 1), 8) : 1
    }

    private func updateConstellationDisplay() {
        constellationRenderSlot.store(ConstellationRenderState(
            result: constellationResult,
            zoom: clampedConstellationZoom(constellationZoom), stretch: constellationStretch
        ))
    }

    public func autoStretchConstellation() {
        guard let result = constellationResult else { return }
        constellationStretch = StretchParams.auto(from: result.histogram, curve: constellationStretch.curve)
    }

    public func displayConstellation(_ result: ConstellationResult) {
        constellationFocusTask?.cancel(); constellationFocusRequest = UUID()
        constellationFocusTask = nil
        constellationFocusCache = [:]; constellationFocusCacheOrder = []
        rememberConstellationFocus(result)
        isLoadingConstellationFocus = false
        constellationResult = result
        constellationFocusIndex = result.focusIndex
        constellationZoom = 1
        constellationStretch = StretchParams.auto(from: result.histogram, curve: stretch.curve)
        showingConstellation = true
        updateConstellationDisplay()
    }

    private func rememberConstellationFocus(_ result: ConstellationResult) {
        guard result.focusRecording != nil else { return }
        constellationFocusCache[result.focusIndex] = result
        constellationFocusCacheOrder.removeAll { $0 == result.focusIndex }
        constellationFocusCacheOrder.append(result.focusIndex)
        if constellationFocusCacheOrder.count > Self.constellationFocusCacheLimit {
            constellationFocusCache.removeValue(forKey: constellationFocusCacheOrder.removeFirst())
        }
    }

    public func selectConstellationFocus(_ index: Int) {
        guard let recording = constellationResult?.focusRecording else { return }
        let selected = min(max(index, 0), recording.metadata.positions.count - 1)
        guard selected != constellationFocusIndex else { return }
        constellationFocusIndex = selected
        constellationFocusTask?.cancel()
        let request = UUID(); constellationFocusRequest = request
        if let cached = constellationFocusCache[selected] {
            rememberConstellationFocus(cached)
            constellationResult = cached
            isLoadingConstellationFocus = false; constellationFocusTask = nil
            updateConstellationDisplay()
            return
        }
        isLoadingConstellationFocus = true
        constellationFocusTask = Task {
            defer {
                if constellationFocusRequest == request {
                    isLoadingConstellationFocus = false; constellationFocusTask = nil
                }
            }
            do {
                try Task.checkCancellation()
                let load = Task.detached(priority: .userInitiated) { try recording.loadLayer(index: selected) }
                let result = try await withTaskCancellationHandler {
                    try await load.value
                } onCancel: { load.cancel() }
                try Task.checkCancellation()
                guard constellationFocusRequest == request, constellationResult?.focusRecording?.id == recording.id else { return }
                rememberConstellationFocus(result)
                constellationResult = result
                updateConstellationDisplay()
            } catch is CancellationError { }
            catch {
                guard constellationFocusRequest == request else { return }
                constellationFocusIndex = constellationResult?.focusIndex ?? 0
                presentError(error)
            }
        }
    }

    public func openConstellation(from url: URL, zoom: Double = 1, curve: StretchCurve? = nil) {
        guard canOpenConstellation else { return }
        errorMessage = nil
        // Set the busy flag synchronously so repeated commands cannot queue loads.
        isLoadingConstellation = true
        Task { await loadConstellation(from: url, zoom: zoom, curve: curve) }
    }

    private func loadConstellation(from url: URL, zoom: Double, curve: StretchCurve?) async {
        defer { isLoadingConstellation = false }
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try ConstellationResult.load(from: url)
            }.value
            displayConstellation(result)
            constellationZoom = clampedConstellationZoom(zoom)
            if let curve {
                constellationStretch.curve = curve
                autoStretchConstellation()
            }
            snapshotDirectory = url.deletingLastPathComponent()
        } catch {
            presentError(error)
        }
    }
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

    public var stabilize = false {
        didSet { updateStabilization() }
    }
    /// Fitted rings and the coma arrow.
    public var showCollimation = true
    /// Sensor-center cross, tracking grid, and star marker.
    public var showSensorMarks = true
    public var quarterView = false {
        didSet { updateStabilization() }
    }
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
    @ObservationIgnored private var captureROI: ROI?
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
    /// stacking branch of `canCalibrateMount` and `canCenterStar`, and the only
    /// other way in is to start a real stack and wait for frames. App code must
    /// call `saveStacked` instead — this sets the flag without any of the work
    /// that goes with it.
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

    public var focuserPorts: [String] = []
    public var selectedFocuserPort = "" {
        didSet { defaults.set(selectedFocuserPort, forKey: Self.focuserPortDefaultsKey) }
    }
    public private(set) var isFocuserConnected = false
    public private(set) var isFocuserBusy = false
    public private(set) var focuserSnapshot: FocuserSnapshot?
    public private(set) var focuserStatus = "ESATTO — disconnected"
    public var focuserStepSize = 1000
    public var focuserTargetPosition = 0
    public var autofocusStepSize = 1000
    public var autofocusTakeUpSteps = 4000
    public private(set) var autofocusResult: AutofocusResult?
    public private(set) var autofocusDiagnostics: AutofocusDiagnostics?
    public private(set) var isAutofocusing = false
    public private(set) var autofocusState: AutofocusState = .idle
    public private(set) var autofocusSamples: [AutofocusSample] = []
    public private(set) var autofocusExposureRetries = 0
    public private(set) var autofocusRecenters = 0
    public private(set) var isMeasuringTilt = false
    public private(set) var tiltProgress = TiltProgress()
    public private(set) var tiltReport: TiltMeasurementReport?
    public private(set) var tiltSavedURL: URL?
    @ObservationIgnored private var tiltTask: Task<Void, Never>?
    @ObservationIgnored private var tiltCancellation: AutofocusCancellation?
    @ObservationIgnored private var tiltID: UUID?
    @ObservationIgnored private var tiltLastStar: MountCentroidSample?
    public var canMeasureTilt: Bool {
        guard !isMeasuringTilt, canAutofocus, canSaveConstellation else { return false }
        let points = ConstellationCapture.positions(sensorWidth: sensorWidth, sensorHeight: sensorHeight)
        return Set(points.map { "\($0.sensorPoint.x),\($0.sensorPoint.y)" }).count == 9
    }
    @ObservationIgnored private var autofocusTask: Task<Void, Never>?
    @ObservationIgnored private var autofocusID: UUID?
    @ObservationIgnored private var autofocusCancellation: AutofocusCancellation?
    @ObservationIgnored private var autofocusFrames: [(timestamp: Date, metric: FocusMetric)] = []
    @ObservationIgnored private var autofocusReadings: [AutofocusReading] = []
    @ObservationIgnored private var autofocusRejectedFrames = 0
    @ObservationIgnored private var autofocusStaleFrames = 0
    @ObservationIgnored private var autofocusBlockStarted = Date.distantPast
    @ObservationIgnored private var autofocusRunSettings = AutofocusSettings()
    @ObservationIgnored private var autofocusExposureFrames: [FocusExposureReading] = []
    @ObservationIgnored private var autofocusHasSaturation = false
    @ObservationIgnored private var autofocusDiscardFrames = 0
    @ObservationIgnored private var autofocusExposureFlushSeconds: TimeInterval = 0
    @ObservationIgnored private var autofocusAcceptAfter = Date.distantFuture
    @ObservationIgnored private var autofocusLastTimestamp = Date.distantPast
    @ObservationIgnored private var autofocusAnchorX = 0.0
    @ObservationIgnored private var autofocusAnchorY = 0.0

    public var canAutofocus: Bool {
        guard canMoveFocuser, isConnected, device?.descriptor.isSimulator == false,
              !isAutoExposing, !isFilterWheelMoving, tracking.centroidOnSensor != nil,
              tracking.state == .tracking, let state = focuserSnapshot,
              let star = tracking.detection, star.snr >= 6 else { return false }
        return (try? AutofocusPlan(position: state.position, maximum: state.maxPosition, step: autofocusStepSize,
                                  takeUp: autofocusComparisonPolicy == .legacy ? autofocusStepSize : autofocusTakeUpSteps)) != nil
    }
    public var canEditAutofocus: Bool { !isAutofocusing && !isMeasuringTilt && !isCapturingFocusConstellation }
    public var autofocusRangeWarning: String? {
        guard let state = focuserSnapshot, canEditAutofocus else { return nil }
        return (try? AutofocusPlan(position: state.position, maximum: state.maxPosition, step: autofocusStepSize,
                                  takeUp: autofocusTakeUpSteps)) == nil ? AutofocusError.invalidRange.localizedDescription : nil
    }
    public var canAdjustCamera: Bool { !isAutofocusing && !isMeasuringTilt && !isCapturingFocusConstellation }

    public var canConnectFocuser: Bool {
        isFocuserConnected || isFocuserBusy || !selectedFocuserPort.isEmpty
    }
    public var canSelectFocuserPort: Bool { !isFocuserConnected && !isFocuserBusy }
    public var canRefreshFocuserPorts: Bool { canSelectFocuserPort }
    public var canMoveFocuser: Bool {
        isFocuserConnected && !isFocuserBusy && focuserSnapshot?.isMoving == false && !isStacking && !isMountBusy && mountTask == nil && !isAutoExposing && !isAutofocusing && !isMeasuringTilt
    }
    public var canMoveFocuserIn: Bool {
        canMoveFocuser && focuserStepSize > 0 && focuserStepSize <= (focuserSnapshot?.position ?? 0)
    }
    public var canMoveFocuserOut: Bool {
        guard let state = focuserSnapshot else { return false }
        return canMoveFocuser && focuserStepSize > 0 && focuserStepSize <= state.maxPosition - state.position
    }
    public var canGotoFocuser: Bool {
        guard let state = focuserSnapshot else { return false }
        return canMoveFocuser && (0...state.maxPosition).contains(focuserTargetPosition)
    }
    /// Stop and disconnect remain available during commands and failed polls.
    public var canStopFocuser: Bool { isFocuserConnected }
    private var focuserIsWorking: Bool { isCapturingFocusConstellation || isMeasuringTilt || isAutofocusing || isFocuserBusy || focuserSnapshot?.isMoving == true }

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
    public var canAutoExpose: Bool { isConnected && !isAutoExposing && !isStacking && !isMountBusy && !focuserIsWorking }
    public var canSaveSnapshot: Bool { isConnected && !isStacking && !isMeasuringTilt }
    public var canSaveStacked: Bool {
        isConnected && !isStacking && !isMountBusy && !focuserIsWorking && tracking.state == .tracking
    }
    public var canSelectStackCount: Bool { !isStacking && !isMeasuringTilt }
    public var canCalibrateMount: Bool {
        isMountConnected && isConnected && !isMountBusy && !isStacking && !focuserIsWorking && tracking.state == .tracking
    }
    public var canCenterStar: Bool { canCalibrateMount && isMountCalibrated }
    public var canSaveConstellation: Bool { canCenterStar && !isLoadingConstellation }
    public var canRecordConstellation: Bool {
        canSaveConstellation && (!recordConstellationFocusSweep || (canAutofocus && constellationFocusSweepSettings != nil))
    }
    public var canConnectMount: Bool { isMountConnected || (!serialPorts.isEmpty && !isAutofocusing && !isMeasuringTilt && !isCapturingFocusConstellation && !isMountBusy) }
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
        if !isFilterWheelConnected && (isAutofocusing || isMeasuringTilt || isCapturingFocusConstellation) { return false }
        return Self.canConnectFilterWheel(
            isConnected: isFilterWheelConnected,
            hasWheels: !filterWheels.isEmpty,
            isMoving: isFilterWheelMoving
        )
    }
    public var canSelectFilterWheel: Bool { !isFilterWheelConnected && !isFilterWheelMoving && !isAutofocusing && !isMeasuringTilt && !isCapturingFocusConstellation }
    public var canRefreshFilterWheels: Bool { canSelectFilterWheel }
    public var canSelectFilter: Bool { isFilterWheelConnected && !isFilterWheelMoving && !isAutofocusing && !isMeasuringTilt && !isCapturingFocusConstellation }

    /// Lower zoom bound. Full-frame centering/constellation slews must go
    /// below `minZoom` or the live view still clips stars near the edges.
    public var zoomFloor: Double {
        showingFullFramePreview ? Self.minFullFrameZoom : Self.minZoom
    }

    nonisolated private let session = CaptureSession()
    nonisolated private let pipeline = FramePipeline()
    nonisolated private let coalescer = FrameCoalescer(label: "collimation.process")
    nonisolated private let fpsMeter = FPSMeter()
    nonisolated private let mount: any MountDevice
    nonisolated private let filterWheel = PhoenixWheel()
    nonisolated private let focuser: any FocuserDevice
    nonisolated private let focuserQueue = DispatchQueue(label: "collimation.focuser")
    nonisolated private let focuserShutdown = AutofocusCancellation()
    @ObservationIgnored private var focuserPollTask: Task<Void, Never>?
    @ObservationIgnored private var focuserPollID: UUID?
    @ObservationIgnored private var focuserGeneration = 0
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
    @ObservationIgnored private let cameraFactory: (String) throws -> any CameraDevice
    @ObservationIgnored private let autofocusTiming: AutofocusTiming
    @ObservationIgnored private let autofocusComparisonPolicy: AutofocusComparisonPolicy
    @ObservationIgnored private let mountSettleMilliseconds: Int
    /// Search binning before a camera is connected, and the ceiling once one is.
    public static let defaultSearchBinning = 4
    private static let serialPortDefaultsKey = "mount.serialPort"
    private static let filterWheelDefaultsKey = "filterWheel.id"
    private static let focuserPortDefaultsKey = "focuser.serialPort"
    private static let snapshotDirectoryDefaultsKey = "snapshot.directory"

    public init(
        defaults: UserDefaults = .standard,
        serialPortPaths: @escaping () -> [String] = SerialPortScanner.availablePaths,
        focuser: any FocuserDevice = EsattoFocuser(),
        mount: any MountDevice = EQ6Mount(),
        cameraFactory: @escaping (String) throws -> any CameraDevice = { try DeviceCatalog.makeDevice(id: $0) },
        autofocusTiming: AutofocusTiming = AutofocusTiming(),
        autofocusComparisonPolicy: AutofocusComparisonPolicy = .production,
        initialCalibration: GuideCalibration? = nil,
        mountSettleMilliseconds: Int = MountGuide.settleMilliseconds
    ) {
        self.defaults = defaults
        self.serialPortPaths = serialPortPaths
        self.focuser = focuser
        self.mount = mount
        self.cameraFactory = cameraFactory
        self.autofocusTiming = autofocusTiming
        self.autofocusComparisonPolicy = autofocusComparisonPolicy
        self.mountSettleMilliseconds = max(0, mountSettleMilliseconds)
        refreshDevices()
        selectedDeviceID = DeviceCatalog.preferredDeviceID(in: devices)
        // The remembered port is read before refreshSerialPorts() so the
        // property observer cannot overwrite the key with a scanned port.
        if let saved = defaults.string(forKey: Self.serialPortDefaultsKey), !saved.isEmpty {
            selectedSerialPort = saved
        }
        refreshSerialPorts()
        if let saved = defaults.string(forKey: Self.focuserPortDefaultsKey), !saved.isEmpty {
            selectedFocuserPort = saved
        }
        refreshFocuserPorts()
        if let path = defaults.string(forKey: Self.snapshotDirectoryDefaultsKey), !path.isEmpty {
            snapshotDirectory = URL(fileURLWithPath: path, isDirectory: true)
        }
        if let calibration = initialCalibration ?? GuideCalibrationStore.load(), calibration.isValid {
            guideCalibration = calibration
            mountStatus = "Calibrated — connect the mount to center"
        }
        coalescer.handler = { [weak self] frame, epoch in
            self?.analyze(frame, epoch: epoch)
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
        focuserShutdown.cancel()
        stopCapture()
        mount.disconnect()
        filterWheel.disconnect()
        // Drain queued work before close, so a pending connect cannot reopen
        // the port after shutdown. Normal UI disconnect uses the async path.
        focuserQueue.sync { focuser.disconnect() }
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
            let newDevice = try cameraFactory(selectedDeviceID)
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

    public func suggestedConstellationName(layout: ConstellationLayout = .circular) -> String {
        let frames = FrameStacker.clampedCount(stackFrameCount)
        let cell = CaptureLayout.stackingCropSize
        let width = cell * layout.columnCount, height = cell * layout.rowCount
        let pattern = layout == .circular ? "constellation" : "constellation-grid"
        let focus = recordConstellationFocusSweep ? "-focus\(constellationFocusSweepSettings?.count ?? 0)" : ""
        let label = "\(pattern)\(focus)-stack\(frames)"
        if let frame = frameSlot.peek()?.frame {
            return MonoTIFF.suggestedFileName(
                width: width,
                height: height,
                date: frame.timestamp,
                label: label
            )
        }
        return MonoTIFF.suggestedFileName(width: width, height: height, label: label)
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
        guard canSaveStacked else { return }
        errorMessage = nil
        stackTask?.cancel()
        isStacking = true
        let target = FrameStacker.clampedCount(stackFrameCount)
        stackWork = .capturing(collected: 0, target: target)
        applyPipelineConfig()
        statusText = "Stacking 0/\(target)…"
        stackTask = Task { await self.runStackedSnapshot(to: url, frameCount: target) }
    }

    public func saveConstellation(to url: URL, layout: ConstellationLayout = .circular) {
        guard canRecordConstellation else { return }
        if recordConstellationFocusSweep {
            startFocusConstellation(to: url, layout: layout)
            return
        }
        errorMessage = nil
        stackTask?.cancel()
        isStacking = true
        let steps = layout.positionCount
        stackWork = .constellationMoving(step: 1, steps: steps)
        applyPipelineConfig()
        statusText = "Constellation 1/\(steps)…"
        stackTask = Task { await self.runConstellation(to: url, layout: layout) }
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

    private func runConstellation(to url: URL, layout: ConstellationLayout) async {
        let frameCount = FrameStacker.clampedCount(stackFrameCount)
        let steps = layout.positionCount
        var startedMount = false
        var completedResult: ConstellationResult?
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
            if let completedResult { displayConstellation(completedResult) }
        }
        do {
            guard let calibration = guideCalibration, calibration.isValid else {
                throw MountError.notCalibrated
            }
            let positions = ConstellationCapture.positions(
                sensorWidth: sensorWidth,
                sensorHeight: sensorHeight,
                layout: layout
            )
            try beginMountWork(
                "Constellation 1/\(steps)…",
                holdROI: true,
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

                try await enterFullFrame()
                Log.info("constellation \(step)/\(steps) \(position.label): target \(position.sensorPoint), sensor \(sensorWidth)x\(sensorHeight)")
                try await moveStar(to: MountCentroidSample(position.sensorPoint), calibration: calibration)
                guard let reached = tracking.centroidOnSensor,
                      MountGuide.isCentered(errorPixels: reached - position.sensorPoint) else {
                    throw MountError.targetNotReached
                }
                let around = tracking.centroidOnSensor ?? position.sensorPoint
                try await prepareStackWindow(around: MountCentroidSample(around))

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
            let mosaic = try ConstellationCapture.mosaic(tiles, layout: layout)
            try MonoTIFF.write(mosaic, to: url)
            completedResult = try await Task.detached(priority: .userInitiated) {
                try ConstellationResult(
                    tiles: tiles.map { ConstellationTile(row: $0.row, column: $0.column, image: $0.image) },
                    sourceURL: url, layout: layout
                )
            }.value
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

    private func startFocusConstellation(to url: URL, layout: ConstellationLayout) {
        guard let sweep = constellationFocusSweepSettings else { return }
        let cancellation = AutofocusCancellation()
        let settings = snapshotAutofocusSettings()
        let frameCount = FrameStacker.clampedCount(stackFrameCount)
        focusConstellationCancellation = cancellation
        focusConstellationProgress = FocusConstellationProgress()
        focusConstellationProgress.stars = layout.positionCount
        focusConstellationProgress.focusCount = sweep.count
        isCapturingFocusConstellation = true; isStacking = true
        errorMessage = nil; showingConstellation = false
        focuserGeneration &+= 1
        stackWork = .constellationMoving(step: 1, steps: layout.positionCount)
        statusText = "Focus constellation — centring star…"
        applyPipelineConfig()
        stackTask = Task { await runFocusConstellation(to: url, layout: layout, frameCount: frameCount,
            settings: settings, sweep: sweep, cancellation: cancellation) }
    }

    public func cancelFocusConstellation() {
        guard isCapturingFocusConstellation, let cancellation = focusConstellationCancellation,
              !cancellation.isCancelled else { return }
        cancellation.cancel(); stackTask?.cancel(); stackCapture.cancel()
        autofocusAcceptAfter = .distantFuture
        let focus = focuser, mount = mount
        focuserQueue.async { _ = try? focus.stop() }
        Task.detached { mount.haltMotions() }
    }

    private func runFocusConstellation(to url: URL, layout: ConstellationLayout, frameCount: Int,
                                      settings: AutofocusSettings, sweep: FocusConstellationSettings,
                                      cancellation: AutofocusCancellation) async {
        var startedMount = false
        var completedResult: ConstellationResult?
        defer {
            endTiltFocus()
            isCapturingFocusConstellation = false; focusConstellationCancellation = nil
            finishStacking()
            if startedMount { endMountWorkWithoutWaiting(statusText) }
            if let completedResult { displayConstellation(completedResult) }
        }
        do {
            guard let calibration = guideCalibration, calibration.isValid else { throw MountError.notCalibrated }
            let positions = ConstellationCapture.positions(sensorWidth: sensorWidth, sensorHeight: sensorHeight, layout: layout)
            try beginMountWork(statusText, holdROI: true, work: .centering)
            startedMount = true
            try await placeFocusConstellationStar(x: positions[0].sensorPoint.x, y: positions[0].sensorPoint.y, calibration: calibration)
            statusText = "Focus constellation — autofocus at centre…"
            let best = try await tiltFocus(cancellation: cancellation, settings: settings)
            autofocusResult = best
            let state = try await autofocusOperation(cancellation: cancellation) { try $0.snapshot() }
            let plan = try FocusConstellationPlan(bestFocus: best.position, maximum: state.maxPosition,
                                                 takeUp: settings.takeUp, settings: sweep)
            let metadata = FocusConstellationMetadata(plan: plan, maximum: state.maxPosition, layout: layout,
                sensorWidth: sensorWidth, sensorHeight: sensorHeight, frameCount: frameCount,
                exposureMicroseconds: best.exposureMicroseconds, gain: settings.gain, autofocus: best)
            let writer = try await Task.detached(priority: .utility) { try FocusConstellationWriter(to: url, metadata: metadata) }.value
            // Mount outside, focus inside: each star records the complete common focus scale.
            for (index, position) in positions.enumerated() {
                try Task.checkCancellation(); try cancellation.check()
                focusConstellationProgress.star = index + 1
                if index > 0 {
                    stackWork = .constellationMoving(step: index + 1, steps: positions.count)
                    statusText = "Focus constellation \(index + 1)/\(positions.count) — moving to \(position.label)…"
                    try await placeFocusConstellationStar(x: position.sensorPoint.x, y: position.sensorPoint.y, calibration: calibration)
                }
                try await captureFocusConstellationStar(plan: plan, settings: settings, exposure: best.exposureMicroseconds,
                    maximum: state.maxPosition, frameCount: frameCount, writer: writer, cancellation: cancellation)
            }
            statusText = "Focus constellation — returning star to centre…"
            try await placeFocusConstellationStar(x: positions[0].sensorPoint.x, y: positions[0].sensorPoint.y, calibration: calibration)
            try Task.checkCancellation(); try cancellation.check()
            stackWork = .constellationCombining; statusText = "Saving focus constellation…"
            try await Task.detached(priority: .utility) { try writer.finish() }.value
            completedResult = try await Task.detached(priority: .userInitiated) { try ConstellationResult.load(from: url) }.value
            statusText = "Saved \(url.lastPathComponent)"
        } catch is CancellationError {
            statusText = "Focus constellation cancelled"
        } catch {
            noteMountFailure(error); presentError(error)
            statusText = "Focus constellation failed"
        }
        cancellation.cancel()
        await haltMotionsOffActor()
        let focus = focuser
        focuserQueue.async { _ = try? focus.stop() }
    }

    private func placeFocusConstellationStar(x: Double, y: Double, calibration: GuideCalibration) async throws {
        try await enterFullFrame()
        try await moveStar(to: MountCentroidSample(SIMD2(x, y)), calibration: calibration)
        guard let reached = tracking.centroidOnSensor,
              MountGuide.isCentered(errorPixels: reached - SIMD2(x, y)) else { throw MountError.targetNotReached }
        try await prepareStackWindow(around: MountCentroidSample(reached))
    }

    private func captureFocusConstellationStar(plan: FocusConstellationPlan, settings: AutofocusSettings,
                                              exposure: Int, maximum: Int, frameCount: Int,
                                              writer: FocusConstellationWriter, cancellation: AutofocusCancellation) async throws {
        guard let anchor = tracking.centroidOnSensor else { throw AutofocusError.noStar }
        prepareTiltFocus(anchor: MountCentroidSample(anchor), settings: settings)
        defer { endTiltFocus() }
        try autofocusSetExposure(exposure, cancellation: cancellation)
        for index in plan.positions.indices {
            focusConstellationProgress.focusIndex = index
            focusConstellationProgress.focusPosition = plan.positions[index]
            statusText = focusConstellationStatus("moving focuser…")
            for target in plan.moves(for: index) { try await autofocusMove(to: target, cancellation: cancellation) }
            try await prepareFocusConstellationFrames(cancellation: cancellation)
            let star = focusConstellationProgress.star, stars = focusConstellationProgress.stars
            let stacked = try await captureStackedImage(frameCount: frameCount) { collected, target in
                self.stackWork = .constellationCapturing(step: star, steps: stars, collected: collected, target: target)
                self.statusText = self.focusConstellationStatus("stacking \(collected)/\(target)…")
            }
            try Task.checkCancellation(); try cancellation.check()
            try await Task.detached(priority: .utility) { try writer.append(stacked) }.value
            focusConstellationProgress.recordedImages += 1
        }
        // Move the mount with a sharp star, and leave the focuser at centre best focus.
        statusText = focusConstellationStatus("restoring centre focus…")
        try await autofocusApproach(target: plan.bestFocus, maximum: maximum, cancellation: cancellation)
        try await prepareFocusConstellationFrames(cancellation: cancellation)
    }

    private func focusConstellationStatus(_ action: String) -> String {
        let p = focusConstellationProgress
        return "Constellation \(p.star)/\(p.stars) · focus \(p.focusIndex + 1)/\(p.focusCount) (\(p.focusPosition ?? 0)) — \(action)"
    }

    private func prepareFocusConstellationFrames(cancellation: AutofocusCancellation) async throws {
        let deadline = try await autofocusPrepareFreshFrames(cancellation: cancellation)
        while autofocusExposureFrames.isEmpty {
            try Task.checkCancellation(); try cancellation.check()
            guard isConnected, isFocuserConnected, isMountConnected else { throw CancellationError() }
            guard Date() < deadline else { throw AutofocusError.noStar }
            try await Task.sleep(for: .milliseconds(20))
        }
        // Defocused crops need detection, not a successful in-focus HFR measurement.
        guard !autofocusHasSaturation else { throw AutofocusError.exposureLimit }
        guard autofocusExposureFrames.allSatisfy({ $0.detected && $0.snr >= 6 }) else { throw AutofocusError.noStar }
        autofocusAcceptAfter = .distantFuture
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
        guard tracking.state == .tracking, let sensor = tracking.centroidOnSensor,
              let roi = captureROI, roi.contains(sensorPoint: sensor) else {
            throw MountError.noStar
        }
        coalescer.cancel()
        Log.info("stack capture: star \(sensor), camera ROI \(roi), frames \(frameCount)")
        stackCapture.begin(target: frameCount, sensorCentroid: sensor, expectedROI: roi)
        session.requestFrameLimit(CaptureLayout.unlimitedReadoutFPS)
        defer {
            stackCapture.cancel()
            session.requestFrameLimit(CaptureLayout.maxReadoutFPS)
        }
        onProgress(0, frameCount)
        let frames = try await collectStackedFrames(target: frameCount, onProgress: onProgress)
        try Task.checkCancellation()
        if let first = frames.first {
            Log.info("stack crop: \(first.roi), star pixel \(first.roi.framePixel(fromSensorPoint: sensor))")
        }
        session.requestFrameLimit(CaptureLayout.maxReadoutFPS)
        let seed = StackRegistrationSeed(CaptureLayout.stackingSeed())
        return try await FrameStacker.averageOffActor(frames, seed: seed)
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
        cancelFocusConstellation()
        if isMeasuringTilt { cancelTiltMeasurement() }
        if isAutofocusing { stopFocuser() }
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
        guard canAdjustCamera else { return }
        autoExposeTask?.cancel()
        guard isConnected, !applyingControls else { return }
        sendExposure(Int(exposureMicroseconds.rounded()))
    }

    public func autoExpose() {
        guard canAutoExpose else { return }
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
        guard canAdjustCamera, isConnected, !applyingControls else { return }
        let value = Int(gain)
        guard value != lastSentGain else { return }
        lastSentGain = value
        session.requestGain(value)
    }

    public func applyROISize() {
        guard !isAutofocusing, isConnected, !isStacking, !isMountBusy else { return }
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
            enabled: stabilize && !showingFullFramePreview,
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
            state.quarterView = quarterView
            state.quarterStar = overlay.centroid
            // Lock and centroid for a live frame are written by the renderer.
            // Drop them here when they must not apply: stab off, or a full-frame
            // search whose pixels are not the crop the lock was measured on.
            if !stabilize || tracking.state == .searching || showingFullFramePreview {
                state.stabilizeLock = nil
                state.stabilizeCentroid = nil
                // The ROI belongs to the centroid. Leaving the crop in place
                // made the sensor map add the full-frame star to the old origin.
                state.roi = nil
                state.imageWidth = 0
                state.imageHeight = 0
            }
        }
    }

    private nonisolated func ingest(_ frame: Frame) {
        let displayed = softwareCrop.apply(frame)
        let epoch = frameSlot.store(displayed)
        _ = fpsMeter.tick()
        if stackCapture.isCapturing {
            stackCapture.offer(frame)
        }
        if !stackCapture.isCapturing {
            coalescer.submit(frame, epoch: epoch)
        }
    }

    private nonisolated func analyze(_ frame: Frame, epoch: UInt64) {
        guard let processed = pipeline.process(frame) else { return }
        if let roi = processed.tracking.requestedROI {
            session.requestTrackerROI(roi)
        }
        softwareCrop.update(
            enabled: CaptureLayout.isTrackingCapture(frame),
            sensorCentroid: processed.tracking.centroidOnSensor
        )
        // The grab loop already showed this frame, and may have shown a newer
        // one while a full-sensor search was running. Putting this exposure
        // back would make the star jump backwards during a centering slew.
        frameSlot.replaceIfCurrent(processed.displayFrame, epoch: epoch)
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
        captureROI = processed.captureROI
        fps = fpsMeter.current
        histogram = processed.histogram
        tracking = processed.tracking
        coma = processed.coma
        fwhm = processed.fwhm
        starProfile = processed.starProfile
        overlay = processed.overlay
        receiveAutofocusFrame(timestamp: processed.displayFrame.timestamp, metric: processed.focusMetric,
                              exposure: processed.focusExposure)
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

    public func startAutofocus() {
        guard canAutofocus, let state = focuserSnapshot,
              let anchor = tracking.centroidOnSensor else { return }
        do {
            autofocusRunSettings = snapshotAutofocusSettings()
            let plan = try AutofocusPlan(position: state.position, maximum: state.maxPosition,
                                         step: autofocusRunSettings.step, takeUp: autofocusRunSettings.takeUp)
            autofocusResult = nil
            autofocusDiagnostics = AutofocusDiagnostics(settings: autofocusRunSettings,
                verificationPolicy: autofocusComparisonPolicy == .legacy ? "legacy-minimum-15-percent" : "curve-fit-position-only")
            let id = UUID()
            let cancellation = AutofocusCancellation()
            focuserGeneration &+= 1
            autofocusID = id
            autofocusCancellation = cancellation
            autofocusSamples = []
            autofocusExposureRetries = 0
            autofocusRecenters = 0
            autofocusFrames = []
            autofocusExposureFrames = []
            autofocusHasSaturation = false
            autofocusDiscardFrames = 0
            autofocusExposureFlushSeconds = 0
            autofocusAnchorX = anchor.x
            autofocusAnchorY = anchor.y
            autofocusAcceptAfter = .distantFuture
            autofocusLastTimestamp = .distantPast
            isAutofocusing = true
            errorMessage = nil
            applyPipelineConfig()
            Log.info("Autofocus start: \(state.position), step \(plan.step), scan \(plan.positions.first!)–\(plan.positions.last!)")
            autofocusTask = Task { await self.runAutofocus(plan: plan, maximum: state.maxPosition, id: id, cancellation: cancellation) }
        } catch { presentError(error) }
    }

    public func suggestedTiltName() -> String {
        MonoTIFF.suggestedFileName(width: 768, height: 768, label: "tilt")
    }

    private func snapshotAutofocusSettings() -> AutofocusSettings {
        AutofocusSettings(step: autofocusStepSize,
            takeUp: autofocusComparisonPolicy == .legacy ? autofocusStepSize : autofocusTakeUpSteps,
            settleSeconds: autofocusComparisonPolicy == .legacy ? 0.3 : autofocusTiming.settleSeconds,
            discardFrames: autofocusComparisonPolicy == .legacy ? 0 : 3,
            verificationInterval: autofocusTiming.verificationInterval, gain: Int(gain.rounded()),
            frameTimeout: autofocusTiming.frameTimeout, motionTimeout: autofocusTiming.motionTimeout)
    }

    public func startTiltMeasurement(to url: URL) {
        guard canMeasureTilt, let camera = device?.descriptor, let focus = focuserSnapshot,
              let calibration = guideCalibration, let star = tracking.centroidOnSensor else { return }
        let report = TiltMeasurementReport(camera: camera, focuserSerial: focus.serialNumber,
            mountProtocol: mount.protocolName, autofocusStep: autofocusStepSize,
            stackCount: FrameStacker.clampedCount(stackFrameCount), gain: Int(gain.rounded()),
            filterPosition: hardwareFilterPosition)
        let cancellation = AutofocusCancellation()
        tiltReport = report; tiltReport!.autofocusSettings = snapshotAutofocusSettings()
        tiltReport!.schemaVersion = 2
        tiltID = report.id; tiltCancellation = cancellation
        tiltSavedURL = nil; tiltLastStar = MountCentroidSample(star)
        isMeasuringTilt = true; errorMessage = nil
        showingConstellation = false
        focuserGeneration &+= 1
        setTiltProgress(.moving, index: 1, label: "C")
        applyPipelineConfig()
        Log.info("Tilt start: \(report.id), \(camera.name), \(focus.serialNumber), step \(report.autofocusStep)")
        tiltTask = Task { await self.runTiltMeasurement(to: url, id: report.id,
            calibration: calibration, cancellation: cancellation) }
    }

    public func cancelTiltMeasurement() {
        guard isMeasuringTilt, let cancellation = tiltCancellation, !cancellation.isCancelled else { return }
        cancellation.cancel()
        tiltTask?.cancel()
        stackCapture.cancel()
        tiltProgress.phase = .cancelled
        autofocusAcceptAfter = .distantFuture
        // Stop is queued after the short in-flight focuser transaction; queued
        // autofocus work checks the cancelled token before touching the device.
        let focus = focuser, mount = mount
        focuserQueue.async { _ = try? focus.stop() }
        Task.detached { mount.haltMotions() }
        Log.info("Tilt cancellation requested")
    }

    private func setTiltProgress(_ phase: TiltPhase, index: Int, label: String, collected: Int = 0, target: Int = 0) {
        tiltProgress.phase = phase; tiltProgress.index = index; tiltProgress.label = label
        tiltProgress.collected = collected; tiltProgress.target = target
        statusText = "Tilt \(index)/9 — \(label): \(phase.rawValue)"
    }

    private func checkTilt(_ id: UUID, _ cancellation: AutofocusCancellation) throws {
        try Task.checkCancellation(); try cancellation.check()
        guard tiltID == id, isConnected, isMountConnected, isFocuserConnected else { throw CancellationError() }
    }

    private func prepareTiltFocus(anchor: MountCentroidSample, settings: AutofocusSettings? = nil) {
        autofocusRunSettings = settings ?? tiltReport?.autofocusSettings ?? snapshotAutofocusSettings()
        autofocusDiagnostics = AutofocusDiagnostics(settings: autofocusRunSettings)
        autofocusSamples = []; autofocusExposureRetries = 0; autofocusRecenters = 0
        autofocusFrames = []; autofocusExposureFrames = []; autofocusHasSaturation = false
        autofocusDiscardFrames = 0; autofocusExposureFlushSeconds = 0
        autofocusAnchorX = anchor.x; autofocusAnchorY = anchor.y
        autofocusAcceptAfter = .distantFuture; autofocusLastTimestamp = .distantPast
        isAutofocusing = true
        applyPipelineConfig()
    }

    private func endTiltFocus() {
        isAutofocusing = false; autofocusAcceptAfter = .distantFuture
        autofocusFrames = []; autofocusExposureFrames = []; autofocusHasSaturation = false
        applyPipelineConfig()
    }

    private func tiltFocus(cancellation: AutofocusCancellation, settings: AutofocusSettings? = nil) async throws -> AutofocusResult {
        guard let state = focuserSnapshot, let anchor = tracking.centroidOnSensor else { throw AutofocusError.noStar }
        prepareTiltFocus(anchor: MountCentroidSample(anchor), settings: settings)
        defer { endTiltFocus() }
        let plan = try AutofocusPlan(position: state.position, maximum: state.maxPosition,
                                     step: autofocusRunSettings.step, takeUp: autofocusRunSettings.takeUp)
        let result = try await autofocusMinimum(plan: plan, maximum: state.maxPosition, cancellation: cancellation)
        autofocusState = .complete(position: result.position, hfr: result.hfr)
        return result
    }

    private func placeTiltStar(x: Double, y: Double, calibration: GuideCalibration) async throws {
        let expected = showFullFramePreview()
        try await waitForCaptureWindow(expected, reference: tiltLastStar)
        try await moveStar(to: MountCentroidSample(SIMD2(x, y)), calibration: calibration)
        guard tracking.state == .tracking, let reached = tracking.centroidOnSensor else { throw MountError.noStar }
        let anchor = MountCentroidSample(reached)
        tiltLastStar = anchor
        guard MountGuide.isCentered(errorPixels: reached - SIMD2(x, y)) else { throw MountError.targetNotReached }
        try await prepareStackWindow(around: anchor)
    }

    /// Restoration uses the same increasing approach as autofocus. The common
    /// image exposure is never retuned: that would change the mosaic comparison.
    private func restoreTiltImageSettings(cancellation: AutofocusCancellation) async throws {
        guard let report = tiltReport, let target = report.commonFocus,
              let exposure = report.commonExposureMicroseconds else { throw AutofocusError.noStar }
        guard let anchor = tracking.centroidOnSensor else { throw AutofocusError.noStar }
        prepareTiltFocus(anchor: MountCentroidSample(anchor))
        defer { endTiltFocus() }
        try await autofocusApproach(target: target, maximum: focuserSnapshot!.maxPosition, cancellation: cancellation)
        try autofocusSetExposure(exposure, cancellation: cancellation)
        let deadline = try await autofocusPrepareFreshFrames(cancellation: cancellation)
        while autofocusExposureFrames.count < AutofocusPlan.framesPerPosition {
            try Task.checkCancellation(); try cancellation.check()
            guard autofocusRejectedFrames < autofocusRunSettings.maximumRejectedFrames else { throw AutofocusError.noStar }
            guard isConnected, isFocuserConnected else { throw CancellationError() }
            guard Date() < deadline else { throw AutofocusError.noStar }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard !autofocusHasSaturation else { throw AutofocusError.exposureLimit }
        guard autofocusExposureFrames.allSatisfy({ $0.detected && $0.snr >= 6 }) else { throw AutofocusError.noStar }
        autofocusAcceptAfter = .distantFuture
    }

    public static func isRecoverableTiltOpticalError(_ error: Error) -> Bool {
        switch error {
        case AutofocusError.noStar, AutofocusError.invalidRange, AutofocusError.minimumNotBracketed,
             AutofocusError.flatCurve, AutofocusError.verificationFailed, AutofocusError.exposureLimit,
             AutofocusError.unstableExposure, AutofocusError.invalidSlope, AutofocusError.searchTravelLimit,
             AutofocusError.searchNotImproving, AutofocusError.unstableFit, AutofocusError.recoveryFailed,
             MountError.noStar, MountError.targetNotReached,
             MountError.starChangedDuringFrameSwitch:
            return true
        default: return false
        }
    }

    private func stopTiltDevices(cancellation: AutofocusCancellation) async throws {
        await haltMotionsOffActor()
        _ = try await autofocusOperation(cancellation: cancellation) { try $0.stop() }
        let deadline = Date().addingTimeInterval(autofocusTiming.motionTimeout)
        while true {
            let state = try await autofocusOperation(cancellation: cancellation) { try $0.snapshot() }
            if !state.isMoving { return }
            guard Date() < deadline else { throw AutofocusError.motionTimeout }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func runTiltMeasurement(to url: URL, id: UUID, calibration: GuideCalibration,
                                    cancellation: AutofocusCancellation) async {
        var tiles: [(row: Int, column: Int, image: StackedImage)] = []
        var terminal: TiltRunStatus = .complete
        do {
            try checkTilt(id, cancellation)
            try beginMountWork("Measuring tilt…", holdROI: true, work: .centering)
            for index in 0..<9 {
                try checkTilt(id, cancellation)
                let point = tiltReport!.points[index]
                var placed = false
                tiltReport!.points[index].startedAt = Date()
                do {
                    setTiltProgress(.moving, index: index + 1, label: point.label)
                    try await placeTiltStar(x: point.targetX, y: point.targetY, calibration: calibration)
                    placed = true
                    try checkTilt(id, cancellation)
                    setTiltProgress(.focusing, index: index + 1, label: point.label)
                    let result = try await tiltFocus(cancellation: cancellation)
                    try checkTilt(id, cancellation)
                    tiltReport!.points[index].focus = result
                    tiltLastStar = MountCentroidSample(SIMD2(result.sensorX, result.sensorY))
                    if index == 0 {
                        tiltReport!.commonFocus = result.position
                        tiltReport!.commonExposureMicroseconds = result.exposureMicroseconds
                    }
                    Log.info("Tilt \(point.label): focus \(result.position), diagnostic HFR \(result.hfr.map { String($0) } ?? "unavailable")")
                } catch {
                    try checkTilt(id, cancellation)
                    guard index > 0, Self.isRecoverableTiltOpticalError(error) else { throw error }
                    try await stopTiltDevices(cancellation: cancellation)
                    tiltReport!.points[index].focusError = error.localizedDescription
                    autofocusDiagnostics?.failure = error.localizedDescription
                    tiltReport!.points[index].focusDiagnostics = autofocusDiagnostics
                    Log.info("Tilt \(point.label) skipped: \(error.localizedDescription)")
                }
                // A failed curve can still have a useful common-focus image.
                do {
                    guard placed else { throw MountError.targetNotReached }
                    setTiltProgress(.restoringFocus, index: index + 1, label: point.label)
                    try await restoreTiltImageSettings(cancellation: cancellation)
                    setTiltProgress(.stacking, index: index + 1, label: point.label)
                    let image = try await captureStackedImage(frameCount: tiltReport!.stackCount) { count, target in
                        self.setTiltProgress(.stacking, index: index + 1, label: point.label, collected: count, target: target)
                    }
                    try checkTilt(id, cancellation)
                    tiles.append((point.row, point.column, image))
                    tiltReport!.points[index].imageCaptured = true
                } catch {
                    try checkTilt(id, cancellation)
                    guard Self.isRecoverableTiltOpticalError(error) else { throw error }
                    try await stopTiltDevices(cancellation: cancellation)
                    tiltReport!.points[index].imageError = error.localizedDescription
                }
                tiltReport!.points[index].finishedAt = Date()
            }
            setTiltProgress(.moving, index: 9, label: "C")
            let center = tiltReport!.points[0]
            try await placeTiltStar(x: center.targetX, y: center.targetY, calibration: calibration)
            setTiltProgress(.checkingDrift, index: 9, label: "C")
            do {
                tiltReport!.finalCenter = try await tiltFocus(cancellation: cancellation)
            } catch {
                try checkTilt(id, cancellation)
                guard Self.isRecoverableTiltOpticalError(error) else { throw error }
                try await stopTiltDevices(cancellation: cancellation)
                tiltReport!.warning = "Centre drift check failed: \(error.localizedDescription)"
                // Even a weak star must not prevent a safe absolute restoration.
                let target = tiltReport!.commonFocus!
                try await autofocusApproach(target: target, maximum: focuserSnapshot!.maxPosition, cancellation: cancellation)
            }
            try checkTilt(id, cancellation)
            if tiltReport!.validOuterCount < 8 || tiltReport!.points.contains(where: { !$0.imageCaptured }) || tiltReport!.warning != nil {
                terminal = .partial
            }
        } catch {
            terminal = error is CancellationError ? .cancelled : .failed
            if terminal == .failed {
                tiltReport?.warning = error.localizedDescription
                noteMountFailure(error)
                presentError(error)
            }
            cancellation.cancel()
            let focus = focuser
            let generation = focuserGeneration
            let stopped: FocuserSnapshot? = await withCheckedContinuation { continuation in
                focuserQueue.async { continuation.resume(returning: try? focus.stop()) }
            }
            if let stopped, isFocuserConnected, focuserGeneration == generation { publishFocuser(stopped) }
        }
        await haltMotionsOffActor()
        guard tiltID == id else { return }
        endTiltFocus()
        if terminal == .cancelled { autofocusState = .cancelled }
        else if terminal == .failed { autofocusState = .failed }
        tiltReport!.status = terminal; tiltReport!.finishedAt = Date()
        tiltProgress.phase = .saving
        let useful = tiltReport!.points.contains { $0.focus != nil || $0.imageCaptured }
        if useful {
            let output = terminal == .failed || terminal == .cancelled
                ? url.deletingLastPathComponent().appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-partial-\(id.uuidString).tif") : url
            do {
                let report = tiltReport!
                let cell = CaptureLayout.stackingCropSize
                for point in report.points where !point.imageCaptured {
                    tiles.append((point.row, point.column, StackedImage(width: cell, height: cell,
                        pixels: Array(repeating: 0, count: cell * cell), roi: ROI(x: 0, y: 0, width: cell, height: cell))))
                }
                let savedTiles = tiles
                let result = try await Task.detached(priority: .userInitiated) {
                    let mosaic = try ConstellationCapture.mosaic(savedTiles)
                    try MonoTIFF.write(mosaic, to: output, imageDescription: report.encoded())
                    return try ConstellationResult(tiles: savedTiles.map {
                        ConstellationTile(row: $0.row, column: $0.column, image: $0.image)
                    }, sourceURL: output, tiltReport: report)
                }.value
                tiltSavedURL = output
                displayConstellation(result)
            } catch { presentError(error) }
        }
        tiltCancellation = nil; tiltTask = nil; tiltID = nil; tiltLastStar = nil
        isMeasuringTilt = false
        finishMountWork("Tilt \(terminal.rawValue)")
        tiltProgress.phase = terminal == .cancelled ? .cancelled : terminal == .failed ? .failed : .complete
        statusText = "Tilt \(terminal.rawValue)\(tiltSavedURL.map { " — saved \($0.lastPathComponent)" } ?? "")"
        Log.info(statusText)
    }

    private func runAutofocus(plan: AutofocusPlan, maximum: Int, id: UUID, cancellation: AutofocusCancellation) async {
        do {
            let result = try await autofocusMinimum(plan: plan, maximum: maximum, cancellation: cancellation)
            guard autofocusID == id else { return }
            autofocusResult = result
            finishAutofocus(state: .complete(position: result.position, hfr: result.hfr))
        } catch {
            guard autofocusID == id else { return }
            autofocusDiagnostics?.failure = error.localizedDescription
            finishAutofocus(state: error is CancellationError ? .cancelled : .failed)
            stopFocuser()
            presentError(error)
        }
    }

    private func autofocusMinimum(plan initialPlan: AutofocusPlan, maximum: Int,
                                  cancellation: AutofocusCancellation) async throws -> AutofocusResult {
        if autofocusComparisonPolicy == .legacy {
            return try await autofocusLegacyMinimum(plan: initialPlan, maximum: maximum, cancellation: cancellation)
        }
        var plan = initialPlan
        var search = AutofocusSearch()
        let connected = try await autofocusOperation(cancellation: cancellation) { try $0.snapshot() }
        guard !connected.isMoving, connected.maxPosition == maximum,
              connected.position == initialPlan.positions[4] else { throw AutofocusError.positionMismatch }
        try await autofocusSelectExposure(cancellation: cancellation)
        // Separate bounds for search, exposure retries and final diagnostics.
        // No uncertainty estimate can extend any of these budgets.
        for _ in 0..<24 {
            do {
                try await autofocusApproach(target: plan.positions[4], maximum: maximum, cancellation: cancellation)
                let baseline = try await autofocusMeasurement(at: plan.positions[4], checkingStar: true, cancellation: cancellation)
                autofocusDiagnostics?.baseline = baseline
                try await autofocusMove(to: plan.preloadPosition, cancellation: cancellation)
                for position in plan.positions {
                    try await autofocusMove(to: position, cancellation: cancellation)
                    let sample = try await autofocusMeasurement(at: position, cancellation: cancellation)
                    autofocusSamples.append(sample)
                    Log.info(String(format: "Autofocus sample: %d, HFR %.3f px, scatter %.3f", position, sample.hfr, sample.scatter ?? 0))
                }
                autofocusDiagnostics?.curves.append(autofocusSamples)
                var settings = autofocusRunSettings
                // Two returns to the same position reveal variation that five
                // adjacent frames cannot. Do not divide this difference by sqrt(5).
                settings.absoluteHFRFloor = max(settings.absoluteHFRFloor,
                    abs(autofocusSamples[4].hfr - baseline.hfr))
                let fittingSettings = settings
                let fittingPlan = plan
                let samples = autofocusSamples
                // Fitting and its LOO refits need no device or actor state.
                let fit = try await Task.detached {
                    try fittingPlan.fit(samples: samples, settings: fittingSettings)
                }.value
                try Task.checkCancellation(); try cancellation.check()
                autofocusDiagnostics?.fit = fit
                let target = fit.position
                try await autofocusApproach(target: target, maximum: maximum, cancellation: cancellation)
                // Acceptance is determined by curve support, residuals and
                // position sensitivity. Near-focus HFR cannot veto the fit,
                // trigger a correction or restart its exposure/scan.
                let blocks = try await autofocusRecordFinalBlocks(at: target, cancellation: cancellation)
                let stopped = try await autofocusOperation(cancellation: cancellation) { try $0.snapshot() }
                guard !stopped.isMoving, stopped.position == target else { throw AutofocusError.positionMismatch }
                let hfr = blocks.isEmpty ? nil : AutofocusPlan.median(blocks.map(\.hfr))
                autofocusDiagnostics?.finalPosition = target
                autofocusDiagnostics?.finalHFR = hfr
                let count = Double(autofocusFrames.count)
                return AutofocusResult(position: target, hfr: hfr,
                    sensorX: count > 0 ? autofocusFrames.reduce(0) { $0 + $1.metric.sensorX } / count : autofocusAnchorX,
                    sensorY: count > 0 ? autofocusFrames.reduce(0) { $0 + $1.metric.sensorY } / count : autofocusAnchorY,
                    exposureMicroseconds: Int(exposureMicroseconds.rounded()), samples: autofocusSamples,
                    exposureRetries: autofocusExposureRetries, recenters: autofocusRecenters, diagnostics: autofocusDiagnostics)
            } catch is AutofocusExposureChanged {
                autofocusExposureRetries += 1; search.exposureChanged()
                if !autofocusSamples.isEmpty && autofocusDiagnostics?.curves.last != autofocusSamples {
                    autofocusDiagnostics?.curves.append(autofocusSamples)
                }
                autofocusSamples = []
                autofocusDiagnostics?.fit = nil
            } catch AutofocusError.minimumNotBracketed {
                guard autofocusRecenters < 16 else { throw AutofocusError.searchNotImproving }
                plan = try search.recenter(plan: plan, samples: autofocusSamples, maximum: maximum)
                autofocusRecenters += 1; autofocusSamples = []
            } catch {
                if !autofocusSamples.isEmpty && autofocusDiagnostics?.curves.last != autofocusSamples {
                    autofocusDiagnostics?.curves.append(autofocusSamples)
                }
                throw error
            }
        }
        throw AutofocusError.searchNotImproving
    }

    private func autofocusApproach(target: Int, maximum: Int, cancellation: AutofocusCancellation) async throws {
        let moves = try AutofocusPlan.approach(target: target, maximum: maximum, takeUp: autofocusRunSettings.takeUp)
        for position in moves { try await autofocusMove(to: position, cancellation: cancellation) }
    }

    private func autofocusRecordFinalBlocks(at target: Int, cancellation: AutofocusCancellation) async throws -> [AutofocusSample] {
        var blocks: [AutofocusSample] = []
        for block in 1...3 {
            if block > 1 {
                try await Task.sleep(for: .seconds(autofocusRunSettings.verificationInterval))
                try cancellation.check()
            }
            autofocusState = .recordingFinalHFR(position: target, block: block)
            do {
                let sample = try await autofocusMeasurement(at: target, verifying: true, settle: block == 1,
                    diagnosticOnly: true, cancellation: cancellation)
                blocks.append(sample); autofocusDiagnostics?.verification.append(sample)
            } catch AutofocusError.noStar {
                autofocusRecordFinalIssue(target: target, block: block, reason: "Five usable final HFR readings unavailable within acquisition bounds.")
            } catch AutofocusError.exposureLimit {
                autofocusRecordFinalIssue(target: target, block: block, reason: "Final HFR unavailable because frames were saturated.")
            }
            try Task.checkCancellation(); try cancellation.check()
        }
        return blocks
    }

    private func autofocusRecordFinalIssue(target: Int, block: Int, reason: String) {
        autofocusAcceptAfter = .distantFuture
        let issue = AutofocusFinalMeasurementIssue(position: target, block: block,
            startedAt: autofocusBlockStarted, finishedAt: Date(), readings: autofocusReadings, reason: reason)
        if autofocusDiagnostics?.finalMeasurementIssues == nil { autofocusDiagnostics?.finalMeasurementIssues = [] }
        autofocusDiagnostics?.finalMeasurementIssues?.append(issue)
        Log.info("Autofocus final diagnostic block \(block): \(reason) Fitted position retained.")
    }

    private func autofocusMeasurement(at position: Int, verifying: Bool = false, checkingStar: Bool = false,
                                      recovery: Bool = false, settle: Bool = true,
                                      diagnosticOnly: Bool = false,
                                      cancellation: AutofocusCancellation) async throws -> AutofocusSample {
        let state = try await autofocusOperation(cancellation: cancellation) { try $0.snapshot() }
        guard !state.isMoving, state.position == position else { throw AutofocusError.positionMismatch }
        let hfr = try await autofocusMeasure(at: position, verifying: verifying, checkingStar: checkingStar,
                                            recovery: recovery, settle: settle, diagnosticOnly: diagnosticOnly, cancellation: cancellation)
        var sample = AutofocusSample(position: position, hfr: hfr, exposureMicroseconds: Int(exposureMicroseconds.rounded()),
            gain: autofocusRunSettings.gain, readings: autofocusReadings, startedAt: autofocusBlockStarted,
            finishedAt: autofocusFrames.last?.timestamp, rejectedFrames: autofocusRejectedFrames)
        sample.staleFrames = autofocusStaleFrames
        return sample
    }

    private func autofocusLegacyMinimum(plan initialPlan: AutofocusPlan, maximum: Int,
                                        cancellation: AutofocusCancellation) async throws -> AutofocusResult {
        var plan = initialPlan
        var search = AutofocusSearch()
        try Task.checkCancellation()
        try cancellation.check()
        try await autofocusSelectExposure(cancellation: cancellation)
        while true {
            do {
                if autofocusExposureRetries > 0 || autofocusRecenters > 0 {
                    // Recheck the baseline after exposure or range changes,
                    // using the same approach as every scan and final move.
                    try await autofocusMove(to: plan.positions[4] - plan.step, cancellation: cancellation)
                    try await autofocusMove(to: plan.positions[4], recentering: autofocusRecenters > 0, cancellation: cancellation)
                }
                let baseline = try await autofocusMeasurement(at: plan.positions[4], checkingStar: true, cancellation: cancellation)
                autofocusDiagnostics?.baseline = baseline
                let initialHFR = baseline.hfr
                Log.info(String(format: "Autofocus initial HFR: %.3f px", initialHFR))
                try await autofocusMove(to: plan.preloadPosition, cancellation: cancellation)
                for position in plan.positions {
                    try await autofocusMove(to: position, cancellation: cancellation)
                    let sample = try await autofocusMeasurement(at: position, cancellation: cancellation)
                    let hfr = sample.hfr
                    autofocusSamples.append(sample)
                    Log.info(String(format: "Autofocus sample: %d, HFR %.3f px", position, hfr))
                }
                autofocusDiagnostics?.curves.append(autofocusSamples)
                let target = try plan.legacySolution(samples: autofocusSamples)
                try await autofocusMove(to: target - plan.step, cancellation: cancellation)
                try await autofocusMove(to: target, cancellation: cancellation)
                autofocusState = .verifying(position: target)
                let verification = try await autofocusMeasurement(at: target, verifying: true, cancellation: cancellation)
                autofocusDiagnostics?.verification.append(verification)
                let hfr = verification.hfr
                try AutofocusPlan.verifyLegacyHFR(hfr: hfr, samples: autofocusSamples)
                try AutofocusPlan.verifyLegacyHFR(hfr: hfr, samples: [AutofocusSample(position: plan.positions[4], hfr: initialHFR)])
                try cancellation.check()
                Log.info(String(format: "Autofocus complete: %d, HFR %.3f px, exposure %.3f ms", target, hfr, exposureMicroseconds / 1000))
                autofocusDiagnostics?.finalPosition = target
                autofocusDiagnostics?.finalHFR = hfr
                let count = Double(autofocusFrames.count)
                return AutofocusResult(position: target, hfr: hfr,
                    sensorX: autofocusFrames.reduce(0) { $0 + $1.metric.sensorX } / count,
                    sensorY: autofocusFrames.reduce(0) { $0 + $1.metric.sensorY } / count,
                    exposureMicroseconds: Int(exposureMicroseconds.rounded()), samples: autofocusSamples,
                    exposureRetries: autofocusExposureRetries, recenters: autofocusRecenters, diagnostics: autofocusDiagnostics)
            } catch is AutofocusExposureChanged {
                autofocusExposureRetries += 1
                search.exposureChanged()
                autofocusSamples = []
                Log.info("Autofocus restarting curve after saturation (\(autofocusExposureRetries)/\(AutofocusExposureControl.maximumRestarts))")
            } catch AutofocusError.minimumNotBracketed {
                plan = try search.recenter(plan: plan, samples: autofocusSamples, maximum: maximum)
                autofocusRecenters += 1
                autofocusSamples = []
                Log.info("Autofocus re-centering \(autofocusRecenters): center \(plan.positions[4]), scan \(plan.positions.first!)–\(plan.positions.last!)")
            }
        }
    }

    private func autofocusOperation(
        cancellation: AutofocusCancellation,
        _ work: @escaping @Sendable (any FocuserDevice) throws -> FocuserSnapshot
    ) async throws -> FocuserSnapshot {
        try Task.checkCancellation()
        try cancellation.check()
        let device = focuser
        let shutdown = focuserShutdown
        let result: FocuserSnapshot = try await withCheckedThrowingContinuation { continuation in
            focuserQueue.async {
                do {
                    try shutdown.check()
                    try cancellation.check()
                    continuation.resume(returning: try work(device))
                } catch { continuation.resume(throwing: error) }
            }
        }
        try Task.checkCancellation()
        try cancellation.check()
        publishFocuser(result)
        return result
    }

    private func autofocusMove(to position: Int, recentering: Bool = false, cancellation: AutofocusCancellation) async throws {
        try Task.checkCancellation()
        try cancellation.check()
        autofocusAcceptAfter = .distantFuture
        autofocusState = recentering ? .recentering(position: position) : .moving(position: position)
        focuserTargetPosition = position
        _ = try await autofocusOperation(cancellation: cancellation) {
            let bounds = try $0.snapshot()
            guard position >= 0, position <= bounds.maxPosition else { throw AutofocusError.invalidRange }
            return try $0.move(to: position)
        }
        let deadline = Date().addingTimeInterval(autofocusTiming.motionTimeout)
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
            let state = try await autofocusOperation(cancellation: cancellation) { try $0.snapshot() }
            if !state.isMoving {
                guard state.position == position else { throw AutofocusError.positionMismatch }
                return
            }
        }
        throw AutofocusError.motionTimeout
    }

    private func autofocusMeasure(at position: Int, verifying: Bool, checkingStar: Bool = false,
                                  recovery: Bool = false, settle: Bool = true,
                                  diagnosticOnly: Bool = false,
                                  cancellation: AutofocusCancellation) async throws -> Double {
        try Task.checkCancellation()
        try cancellation.check()
        let deadline = try await autofocusPrepareFreshFrames(settling: settle, cancellation: cancellation)
        if !verifying {
            autofocusState = checkingStar ? .checkingStar(frames: 0)
                : recovery ? .recovering(position: position) : .measuring(position: position, frames: 0)
        }
        while Date() < deadline {
            try Task.checkCancellation()
            try cancellation.check()
            guard isConnected, isFocuserConnected else { throw CancellationError() }
            guard autofocusRejectedFrames < autofocusRunSettings.maximumRejectedFrames else { throw AutofocusError.noStar }
            if autofocusHasSaturation {
                if diagnosticOnly { throw AutofocusError.exposureLimit }
                guard autofocusExposureRetries < AutofocusExposureControl.maximumRestarts else {
                    throw AutofocusError.unstableExposure
                }
                let shorter = try AutofocusExposureControl.nextMicroseconds(
                    current: Int(exposureMicroseconds.rounded()), peak: StarQuality.clipADU)
                try autofocusSetExposure(shorter, cancellation: cancellation)
                try await autofocusSelectExposure(cancellation: cancellation)
                throw AutofocusExposureChanged()
            }
            if autofocusFrames.count >= AutofocusPlan.framesPerPosition {
                autofocusAcceptAfter = .distantFuture
                return AutofocusPlan.median(autofocusFrames.map { $0.metric.hfr })
            }
            if checkingStar { autofocusState = .checkingStar(frames: autofocusFrames.count) }
            else if !verifying && !recovery { autofocusState = .measuring(position: position, frames: autofocusFrames.count) }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw AutofocusError.noStar
    }

    /// Timestamp gates exclude frames begun during motion. After a control
    /// change also drain queued SDK frames before judging the new exposure.
    private func autofocusPrepareFrames(settling: Bool = true) -> Date {
        autofocusFrames = []
        autofocusReadings = []; autofocusRejectedFrames = 0; autofocusStaleFrames = 0; autofocusBlockStarted = Date()
        autofocusExposureFrames = []
        autofocusHasSaturation = false
        let exposureSeconds = exposureMicroseconds / 1_000_000
        autofocusAcceptAfter = Date().addingTimeInterval((settling ? autofocusRunSettings.settleSeconds : 0) + exposureSeconds + autofocusExposureFlushSeconds)
        autofocusDiscardFrames = autofocusRunSettings.discardFrames
        if autofocusExposureFlushSeconds > 0 { autofocusDiscardFrames = max(3, autofocusDiscardFrames) }
        autofocusExposureFlushSeconds = 0
        return autofocusAcceptAfter.addingTimeInterval(max(autofocusTiming.frameTimeout, exposureSeconds * 12))
    }

    private func autofocusPrepareFreshFrames(settling: Bool = true, cancellation: AutofocusCancellation) async throws -> Date {
        if autofocusComparisonPolicy == .legacy { return autofocusPrepareFrames(settling: settling) }
        autofocusAcceptAfter = .distantFuture
        if settling { try await Task.sleep(for: .seconds(autofocusRunSettings.settleSeconds)) }
        try cancellation.check()
        _ = try await session.restartForFreshFrames()
        try cancellation.check()
        return autofocusPrepareFrames(settling: false)
    }

    private func autofocusSetExposure(_ microseconds: Int, cancellation: AutofocusCancellation) throws {
        try Task.checkCancellation()
        try cancellation.check()
        autofocusAcceptAfter = .distantFuture
        autofocusExposureFlushSeconds = 2 * exposureMicroseconds / 1_000_000
        sendExposure(microseconds)
        Log.info(String(format: "Autofocus exposure: %.3f ms", exposureMicroseconds / 1000))
    }

    private func autofocusSelectExposure(cancellation: AutofocusCancellation) async throws {
        for _ in 0..<AutofocusExposureControl.maximumAdjustments {
            try Task.checkCancellation()
            try cancellation.check()
            let current = Int(exposureMicroseconds.rounded())
            autofocusState = .adjustingExposure(microseconds: current)
            let deadline = try await autofocusPrepareFreshFrames(cancellation: cancellation)
            while autofocusExposureFrames.count < AutofocusPlan.framesPerPosition {
                try Task.checkCancellation()
                try cancellation.check()
                guard autofocusRejectedFrames < autofocusRunSettings.maximumRejectedFrames else { throw AutofocusError.noStar }
                guard isConnected, isFocuserConnected else { throw CancellationError() }
                guard Date() < deadline else { throw AutofocusError.noStar }
                try await Task.sleep(for: .milliseconds(20))
            }
            autofocusAcceptAfter = .distantFuture
            let peak = autofocusHasSaturation ? StarQuality.clipADU
                : UInt16(AutofocusPlan.median(autofocusExposureFrames.map { Double($0.peak) }))
            let next = try AutofocusExposureControl.nextMicroseconds(current: current, peak: peak)
            if next == current {
                guard autofocusExposureFrames.allSatisfy({ $0.detected }),
                      AutofocusPlan.median(autofocusExposureFrames.map(\.snr)) >= 10 else {
                    throw AutofocusError.noStar
                }
                Log.info(String(format: "Autofocus exposure selected: %.3f ms, peak %d ADU", Double(current) / 1000, Int(peak)))
                return
            }
            try autofocusSetExposure(next, cancellation: cancellation)
        }
        throw AutofocusError.unstableExposure
    }

    private func receiveAutofocusFrame(timestamp: Date, metric: FocusMetric?, exposure: FocusExposureReading?) {
        guard isAutofocusing, autofocusAcceptAfter != .distantFuture else { return }
        guard timestamp > autofocusAcceptAfter, timestamp <= Date(), timestamp > autofocusLastTimestamp else {
            autofocusStaleFrames += 1; return
        }
        autofocusLastTimestamp = timestamp
        if autofocusDiscardFrames > 0 {
            autofocusDiscardFrames -= 1
            autofocusReadings.append(AutofocusReading(timestamp: timestamp, hfr: nil, rejection: "startup discard"))
            return
        }
        guard let exposure else {
            autofocusRejectFrame(timestamp: timestamp, reason: "missing detection"); return
        }
        guard !exposure.detected || hypot(exposure.sensorX - autofocusAnchorX, exposure.sensorY - autofocusAnchorY) < 64 else {
            autofocusRejectFrame(timestamp: timestamp, reason: "changed star"); return
        }
        if exposure.peak >= StarQuality.clipADU { autofocusHasSaturation = true }
        if autofocusExposureFrames.count < AutofocusPlan.framesPerPosition { autofocusExposureFrames.append(exposure) }
        if autofocusFrames.count < AutofocusPlan.framesPerPosition, let metric, metric.hfr.isFinite, metric.hfr > 0,
           hypot(metric.sensorX - autofocusAnchorX, metric.sensorY - autofocusAnchorY) < 64 {
            autofocusFrames.append((timestamp, metric))
            autofocusReadings.append(AutofocusReading(timestamp: timestamp, hfr: metric.hfr))
        } else if autofocusFrames.count < AutofocusPlan.framesPerPosition {
            autofocusRejectFrame(timestamp: timestamp, reason: exposure.peak >= StarQuality.clipADU ? "saturated" : "invalid HFR or changed star")
        }
    }

    private func autofocusRejectFrame(timestamp: Date, reason: String) {
        autofocusRejectedFrames += 1
        let reading = AutofocusReading(timestamp: timestamp, hfr: nil, rejection: reason)
        if autofocusReadings.count < 40 { autofocusReadings.append(reading) }
        if let count = autofocusDiagnostics?.rejectedReadings.count, count < 120 { autofocusDiagnostics?.rejectedReadings.append(reading) }
    }

    private func finishAutofocus(state: AutofocusState) {
        autofocusCancellation?.cancel()
        autofocusCancellation = nil
        autofocusID = nil
        autofocusTask = nil
        isAutofocusing = false
        autofocusAcceptAfter = .distantFuture
        autofocusFrames = []
        autofocusExposureFrames = []
        autofocusHasSaturation = false
        autofocusDiscardFrames = 0
        autofocusExposureFlushSeconds = 0
        autofocusState = state
        applyPipelineConfig()
    }

    private func cancelAutofocus() {
        guard isAutofocusing else { return }
        autofocusTask?.cancel()
        finishAutofocus(state: .cancelled)
        Log.info("Autofocus cancelled")
    }

    public func refreshFocuserPorts() {
        guard canRefreshFocuserPorts else { return }
        var ports = serialPortPaths()
        if selectedFocuserPort.isEmpty {
            // COM4 is preferred only when present; other computers use the
            // first available port, and each focuser selection is remembered.
            selectedFocuserPort = ports.first(where: { $0.uppercased() == "COM4" }) ?? ports.first ?? ""
        }
        if !selectedFocuserPort.isEmpty, !ports.contains(selectedFocuserPort) {
            ports.insert(selectedFocuserPort, at: 0)
        }
        focuserPorts = ports
    }

    public func connectFocuser() {
        guard !isFocuserConnected, !isFocuserBusy else { return }
        refreshFocuserPorts()
        let path = selectedFocuserPort
        guard !path.isEmpty else { presentError(FocuserError.noPortSelected); return }
        errorMessage = nil
        focuserGeneration &+= 1
        isFocuserBusy = true
        focuserStatus = "Opening \(path)…"
        performFocuserOperation({ try $0.connect(path: path) }) { engine, state in
            engine.isFocuserConnected = true
            engine.focuserTargetPosition = state.position
            engine.startFocuserPolling()
        }
    }

    public func disconnectFocuser() {
        cancelFocusConstellation()
        cancelTiltMeasurement()
        cancelAutofocus()
        focuserGeneration &+= 1
        focuserPollTask?.cancel()
        focuserPollTask = nil
        focuserPollID = nil
        isFocuserConnected = false
        isFocuserBusy = false
        focuserSnapshot = nil
        focuserStatus = "ESATTO — disconnected"
        let device = focuser
        // Enqueued synchronously on the main actor. A reconnect always follows
        // this close, even when the previous request has not answered yet.
        focuserQueue.async { device.disconnect() }
    }

    public func moveFocuserIn() {
        guard canMoveFocuserIn, let state = focuserSnapshot else { return }
        moveFocuser(to: state.position - focuserStepSize)
    }

    public func moveFocuserOut() {
        guard canMoveFocuserOut, let state = focuserSnapshot else { return }
        moveFocuser(to: state.position + focuserStepSize)
    }

    public func gotoFocuser() {
        guard canGotoFocuser else { return }
        moveFocuser(to: focuserTargetPosition)
    }

    private func moveFocuser(to position: Int) {
        guard canMoveFocuser else { return }
        errorMessage = nil
        focuserGeneration &+= 1
        isFocuserBusy = true
        focuserTargetPosition = position
        focuserStatus = "Moving to \(position) steps…"
        performFocuserOperation({ try $0.move(to: position) }) { _, _ in }
    }

    public func stopFocuser() {
        cancelFocusConstellation()
        cancelTiltMeasurement()
        guard canStopFocuser else { return }
        cancelAutofocus()
        // Invalidate any pending move/poll result. Stop is queued after the
        // current short transaction, never after waiting for travel to finish.
        focuserGeneration &+= 1
        isFocuserBusy = true
        focuserStatus = "Stopping…"
        performFocuserOperation({ try $0.stop() }) { engine, state in
            engine.focuserTargetPosition = state.position
        }
    }

    private func performFocuserOperation(
        _ work: @escaping @Sendable (any FocuserDevice) throws -> FocuserSnapshot,
        completion: @escaping @MainActor @Sendable (CollimationEngine, FocuserSnapshot) -> Void
    ) {
        let generation = focuserGeneration
        let device = focuser
        focuserQueue.async { [weak self] in
            let result = Result { try work(device) }
            Task { @MainActor [weak self] in
                guard let self, self.focuserGeneration == generation else { return }
                self.isFocuserBusy = false
                switch result {
                case .success(let state):
                    self.publishFocuser(state)
                    completion(self, state)
                case .failure(let error):
                    self.disconnectFocuser()
                    self.focuserStatus = "ESATTO — connection failed"
                    self.presentError(error)
                }
            }
        }
    }

    private func startFocuserPolling() {
        focuserPollTask?.cancel()
        focuserPollTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard let self, self.isFocuserConnected else { return }
                self.pollFocuser()
            }
        }
    }

    private func pollFocuser() {
        guard !isAutofocusing, isFocuserConnected, !isFocuserBusy, focuserPollID == nil else { return }
        let pollID = UUID()
        focuserPollID = pollID
        let generation = focuserGeneration
        let device = focuser
        focuserQueue.async { [weak self] in
            let result = Result { try device.snapshot() }
            Task { @MainActor [weak self] in
                guard let self else { return }
                // An old session must not clear a new session's pending poll.
                if self.focuserPollID == pollID { self.focuserPollID = nil }
                guard self.focuserGeneration == generation, !self.isFocuserBusy else { return }
                switch result {
                case .success(let state): self.publishFocuser(state)
                case .failure(let error):
                    self.disconnectFocuser()
                    self.focuserStatus = "ESATTO — communication lost"
                    self.presentError(error)
                }
            }
        }
    }

    private func publishFocuser(_ state: FocuserSnapshot) {
        focuserSnapshot = state
        focuserStatus = state.isMoving ? "ESATTO — moving…" : "ESATTO — connected"
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
        guard canConnectMount else { return }
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
                    try mount.connect(path: path, baud: 9600)
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
        cancelFocusConstellation()
        cancelTiltMeasurement()
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
        guard canConnectFilterWheel else { return }
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
        cancelTiltMeasurement()
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
        guard canSelectFilter else { return }
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
        guard canCalibrateMount else { return }
        mountTask?.cancel()
        mountTask = Task { await self.runCalibration() }
    }

    public func centerStar() {
        guard canCenterStar else { return }
        mountTask?.cancel()
        mountTask = Task { await self.runCentering() }
    }

    private func runCalibration() async {
        do {
            try beginMountWork("Calibrating — measuring east…", holdROI: true, work: .calibrating)
            // A calibration pulse can leave the 512 analysis crop too. Use the
            // same verified full-sensor capture as a centering move.
            guideCalibration = nil
            try await enterFullFrame()
            let east = try await measureCalibrationAxis(.east)
            let north = try await measureCalibrationAxis(.north)
            let calibration = GuideCalibration(
                eastRate: east.rate.point,
                northRate: north.rate.point,
                sampleDurationMs: max(east.durationMs, north.durationMs),
                raBacklashPixels: east.backlash,
                decBacklashPixels: north.backlash
            )
            Log.info("calibration result: east \(east.rate.point), north \(north.rate.point), axis separation sine \(calibration.axisSeparationSine), backlash RA \(east.backlash) Dec \(north.backlash)")
            guard calibration.isValid else { throw MountError.calibrationAxesUnreliable }
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

    private final class CalibrationAxisMeasurement: Sendable {
        let rate: MountCentroidSample
        let durationMs: Int
        let backlash: Double

        init(rate: MountCentroidSample, durationMs: Int, backlash: Double) {
            self.rate = rate
            self.durationMs = durationMs
            self.backlash = backlash
        }
    }

    private func measureCalibrationAxis(
        _ direction: GuideDirection
    ) async throws -> CalibrationAxisMeasurement {
        let multiple = direction == .east ? mount.calibrationRAMultiple : 1
        let sliceMs = multiple > 1 ? 750 : MountGuide.calibrationPulseMs
        if direction == .east {
            try await takeUpCalibrationBacklash(direction, sliceMs: sliceMs, multiple: multiple)
        }
        let start = try await waitForSettledCentroid()
        var after = start
        var duration = 0
        while true {
            let next = min(sliceMs, MountGuide.nextCalibrationPulseMs(displacement: after.point - start.point, elapsedMs: duration))
            guard next > 0 else { break }
            mountStatus = "Calibrating — measuring \(direction.rawValue) at \(Int(multiple))×…"
            try await sendCalibrationPulse(direction, milliseconds: next, multiple: multiple)
            duration += next
            after = try await waitForSettledCentroid()
            Log.info("calibration \(direction.rawValue): before \(start), after \(after), total pulse duration \(duration) ms at \(multiple)x")
        }
        guard MountGuide.errorLength(after.point - start.point) >= MountGuide.minCalibrationMovePixels else {
            throw MountError.calibrationTooSmall(direction.rawValue)
        }
        let rate = MountCentroidSample(MountGuide.rate(before: start.point, after: after.point, durationMs: Double(duration) * multiple))
        mountStatus = "Calibrating — returning from \(direction.rawValue)…"
        // Match the outbound time, with a tracking/cancellation check between
        // chunks. In particular, never pass >9999 ms to an LX200 pulse.
        var remaining = duration
        var returned = after
        while remaining > 0 {
            let chunk = min(remaining, sliceMs)
            try await sendCalibrationPulse(direction.opposite, milliseconds: chunk, multiple: multiple)
            remaining -= chunk
            returned = try await waitForSettledCentroid()
        }
        Log.info("calibration \(direction.opposite.rawValue) return: \(returned), total pulse duration \(duration) ms")
        return CalibrationAxisMeasurement(rate: rate, durationMs: duration,
            backlash: MountGuide.backlashPixels(start: start.point, afterOutbound: after.point, afterReturn: returned.point))
    }

    private func takeUpCalibrationBacklash(_ direction: GuideDirection, sliceMs: Int, multiple: Double) async throws {
        mountStatus = "Calibrating — taking up RA backlash…"
        var previous = try await waitForSettledCentroid()
        var duration = 0
        while duration < MountGuide.maxCalibrationAxisMs {
            let chunk = min(sliceMs, MountGuide.maxCalibrationAxisMs - duration)
            try await sendCalibrationPulse(direction, milliseconds: chunk, multiple: multiple)
            duration += chunk
            let current = try await waitForSettledCentroid()
            let moved = MountGuide.errorLength(current.point - previous.point)
            Log.info("calibration RA take-up: \(moved) px this pulse, \(duration) ms total at \(multiple)x")
            if MountGuide.calibrationTakeupComplete(displacement: current.point - previous.point) { return }
            previous = current
        }
        throw MountError.calibrationTooSmall(direction.rawValue)
    }

    private func sendCalibrationPulse(_ direction: GuideDirection, milliseconds: Int, multiple: Double) async throws {
        guard multiple > 1 else {
            try await sendPulse(direction, milliseconds: milliseconds)
            return
        }
        try Task.checkCancellation()
        do {
            try await mount.applyNudge(SlewNudge(ra: direction, dec: nil, siderealMultiple: multiple))
            axisDirections.record(direction)
            try await sleepMilliseconds(milliseconds)
            try await mount.applyNudge(nil)
        } catch {
            await haltMotionsOffActor()
            throw error
        }
    }

    private func runCentering() async {
        do {
            guard let calibration = guideCalibration, calibration.isValid else {
                throw MountError.notCalibrated
            }
            try beginMountWork("Centering on sensor…", holdROI: true, work: .centering)
            try await enterFullFrame()
            try await moveStar(to: MountCentroidSample(sensorCenter()), calibration: calibration)
            let centroid = (try await waitForCentroid()).point
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

    private func beginMountWork(_ status: String, holdROI: Bool, work: MountWork) throws {
        guard isMountConnected else { throw MountError.notConnected }
        guard isConnected else { throw CameraError.notConnected }
        isMountBusy = true
        mountWork = work
        mountStatus = status
        mountHoldsROI = holdROI
        applyPipelineConfig()
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

    @discardableResult
    private func applyTrackingWindow(around sensor: SIMD2<Double>) -> ROI {
        showingFullFramePreview = false
        restoreZoomAfterFullFrame()
        coalescer.cancel()
        pipeline.dropInFlight()
        softwareCrop.setHoldDisabled(false)
        softwareCrop.update(enabled: true, sensorCentroid: sensor)
        let roi = Alignment.centeredROI(
            around: sensor,
            size: CaptureLayout.trackingHardwareSize,
            sensorWidth: sensorWidth,
            sensorHeight: sensorHeight,
            binning: 1,
            alignment: roiAlignment
        )
        session.requestROI(roi)
        return roi
    }

    @discardableResult
    private func showFullFramePreview() -> ROI {
        coalescer.cancel()
        pipeline.dropInFlight()
        softwareCrop.setHoldDisabled(true)
        showingFullFramePreview = true
        if zoomBeforeFullFrame == nil {
            zoomBeforeFullFrame = zoom
        }
        let roi = Alignment.fullFrameROI(
            sensorWidth: sensorWidth,
            sensorHeight: sensorHeight,
            binning: 1,
            alignment: roiAlignment
        )
        session.requestROI(roi)
        zoom = clampedZoom(ImageLayout.fitZoom(
            imageWidth: sensorWidth,
            imageHeight: sensorHeight,
            viewWidth: viewWidth,
            viewHeight: viewHeight
        ))
        updateStabilization()
        return roi
    }

    private func restoreZoomAfterFullFrame() {
        guard let saved = zoomBeforeFullFrame else { return }
        zoomBeforeFullFrame = nil
        zoom = min(Self.maxZoom, max(Self.minZoom, saved))
        updateStabilization()
    }

    private func enterFullFrame() async throws {
        let reference = tracking.state == .tracking ? tracking.centroidOnSensor : nil
        let expected = showFullFramePreview()
        try await waitForCaptureWindow(expected, reference: reference.map(MountCentroidSample.init))
    }

    private func waitForCaptureWindow(_ expected: ROI, reference: MountCentroidSample?) async throws {
        var gate = MountFrameGate(expectedROI: expected, reference: reference?.point)
        var sequence = frameSequence
        let deadline = Date().addingTimeInterval(12)
        Log.info("mount capture request \(expected), previous centroid \(String(describing: reference))")
        while Date() < deadline {
            try Task.checkCancellation()
            if frameSequence != sequence, let roi = captureROI {
                sequence = frameSequence
                do {
                    if let centroid = try gate.observe(roi: roi, tracking: tracking) {
                        Log.info("mount capture ready: centroid \(centroid), ROI \(roi)")
                        return
                    }
                } catch {
                    Log.info("mount frame switch rejected: centroid \(String(describing: tracking.centroidOnSensor)), ROI \(roi)")
                    throw error
                }
            }
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        throw MountError.noStar
    }

    private func prepareStackWindow(around sample: MountCentroidSample) async throws {
        let sensor = sample.point
        let roi = applyTrackingWindow(around: sensor)
        try await waitForCaptureWindow(roi, reference: sample)
    }

    private func moveStar(to targetSample: MountCentroidSample, calibration: GuideCalibration) async throws {
        let target = targetSample.point
        var centroid = (try await waitForSettledCentroid()).point
        Log.info("mount move: centroid \(centroid), target \(target), east \(calibration.eastRate), north \(calibration.northRate), backlash RA \(calibration.raBacklashPixels) Dec \(calibration.decBacklashPixels)")
        if MountGuide.isCentered(errorPixels: centroid - target) { return }

        let deadline = Date().addingTimeInterval(90)
        var lastRASign: Double?
        var lastDecSign: Double?
        var slews = 0
        do {
            while slews < AxisCentering.maxSlews, Date() < deadline {
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
                slews += 1
                Log.info("mount correction: centroid \(centroid), target \(target), RA \(String(describing: plan.ra)), Dec \(String(describing: plan.dec))")
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

                centroid = (try await waitForSettledCentroid()).point
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

    private func waitForSettledCentroid() async throws -> MountCentroidSample {
        try await sleepMilliseconds(mountSettleMilliseconds)
        return try await waitForCentroid(minNewFrames: 2, timeout: 10)
    }

    private func waitForCentroid(minNewFrames: Int = 1, timeout: TimeInterval = 4) async throws -> MountCentroidSample {
        let startSeq = frameSequence
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            if frameSequence >= startSeq + UInt64(minNewFrames),
               tracking.state == .tracking,
               tracking.detection != nil,
               let centroid = tracking.centroidOnSensor
            {
                let sample = MountCentroidSample(centroid)
                Log.info("mount centroid sample: x \(sample.x), y \(sample.y)")
                return sample
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
            sensorWidth: sensorWidth,
            sensorHeight: sensorHeight,
            holdROI: holdsROI,
            optics: optics,
            roiAlignment: roiAlignment,
            searchBinning: searchBinning,
            measureFocus: isAutofocusing
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
