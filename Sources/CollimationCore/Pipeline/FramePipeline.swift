import Foundation

struct ProcessedFrame: Sendable {
    var histogram: Histogram
    var tracking: TrackingStatus
    var coma: ComaResult?
    var fwhm: FWHMResult?
    var starProfile: StarIntensityProfile?
    var overlay: OverlayModel
    var displayFrame: Frame
}

final class FramePipeline: @unchecked Sendable {
    private let lock = NSLock()
    private var tracker = Tracker()
    private let detector = StarDetector()
    private let analyzer = ComaAnalyzer()
    private let fwhmEstimator = FWHMEstimator()
    private let profileSampler = StarProfileSampler()
    private var autoCenter = true
    private var autoSearch = false
    private var holdROI = false
    private var sensorWidth = CameraDescriptor.simulator.sensorWidth
    private var sensorHeight = CameraDescriptor.simulator.sensorHeight
    private var optics = TelescopeOptics.poseidon
    private var lastSensorCentroid: SIMD2<Double>?
    private var generation = 0

    func configure(
        autoCenter: Bool,
        autoSearch: Bool,
        sensorWidth: Int,
        sensorHeight: Int,
        holdROI: Bool = false,
        optics: TelescopeOptics = .poseidon
    ) {
        lock.lock()
        self.autoCenter = autoCenter
        self.autoSearch = autoSearch
        self.sensorWidth = sensorWidth
        self.sensorHeight = sensorHeight
        self.holdROI = holdROI
        self.optics = optics
        lock.unlock()
    }

    func reset() {
        lock.lock()
        generation &+= 1
        tracker.reset()
        lastSensorCentroid = nil
        lock.unlock()
    }

    func markSearching() {
        lock.lock()
        tracker.markSearching()
        lastSensorCentroid = nil
        lock.unlock()
    }

    func process(_ frame: Frame) -> ProcessedFrame? {
        lock.lock()
        let generation = self.generation
        let autoCenter = self.autoCenter
        let autoSearch = self.autoSearch
        let holdROI = self.holdROI
        let sensorWidth = self.sensorWidth
        let sensorHeight = self.sensorHeight
        let optics = self.optics
        let seed = lastSensorCentroid.map { frame.roi.framePixel(fromSensorPoint: $0) }
        lock.unlock()

        var window = CaptureLayout.analysisFrame(from: frame, seed: seed)
        var origin = window.origin(inParent: frame)
        var found = detector.detect(in: window)
        // First lock only: the star may sit in the 2048 window but outside the
        // center 512. After that, detection and metrics stay on the crop.
        if found == nil, seed == nil, CaptureLayout.isTrackingCapture(frame),
           window.width != frame.width || window.height != frame.height,
           let located = detector.detect(in: frame) {
            window = CaptureLayout.analysisFrame(from: frame, seed: located.centroid)
            origin = window.origin(inParent: frame)
            found = detector.detect(in: window) ?? located.offsetBy(-origin)
        }

        lock.lock()
        guard generation == self.generation else {
            lock.unlock()
            return nil
        }
        var next = tracker.process(
            frame: frame,
            detection: found?.offsetBy(origin),
            autoCenter: autoCenter && !holdROI,
            autoSearch: autoSearch && !holdROI,
            trackingROISize: CaptureLayout.trackingHardwareSize,
            sensorWidth: sensorWidth,
            sensorHeight: sensorHeight
        )
        if holdROI {
            next.requestedROI = nil
        }
        if let sensor = next.centroidOnSensor {
            lastSensorCentroid = sensor
        } else if next.state == .searching || next.state == .idle {
            lastSensorCentroid = nil
        }
        let trackingState = next.state
        lock.unlock()

        let display: Frame
        if CaptureLayout.isTrackingCapture(frame) {
            display = window
            next.centroidInFrame = next.centroidInFrame.map { $0 - origin }
            if let detection = next.detection {
                next.detection = detection.offsetBy(-origin)
            }
        } else {
            display = frame
        }

        let histogram = Histogram.compute(from: display, stride: max(1, display.pixelCount / 80_000))

        var result: ComaResult?
        if trackingState == .tracking,
           let analysisDetection = next.detection,
           let analyzed = analyzer.analyze(frame: display, detection: analysisDetection),
           analyzed.quality >= 0.4 {
            result = analyzed
        }

        var fwhm: FWHMResult?
        if trackingState == .tracking, let centroid = next.centroidInFrame {
            fwhm = fwhmEstimator.measure(frame: display, centroid: centroid, optics: optics)
        }

        var starProfile: StarIntensityProfile?
        if trackingState == .tracking, let centroid = next.centroidInFrame {
            let radius = result?.outer.radius
                ?? fwhm.map { max($0.framePixels * 2.5, 12) }
                ?? 32
            starProfile = profileSampler.measure(
                frame: display,
                centroid: centroid,
                radiusPixels: radius
            )
        }

        lock.lock()
        guard generation == self.generation else {
            lock.unlock()
            return nil
        }
        if trackingState != .tracking {
            result = nil
            fwhm = nil
            starProfile = nil
        }
        let overlay = OverlayModel(
            imageWidth: display.width,
            imageHeight: display.height,
            centroid: next.centroidInFrame,
            outer: result?.outer,
            inner: result?.inner,
            comaVector: result?.vector,
            trackingState: next.state,
            sensorWidth: sensorWidth,
            sensorHeight: sensorHeight,
            roi: display.roi,
            starPeak: next.detection?.peak
        )
        lock.unlock()
        return ProcessedFrame(
            histogram: histogram,
            tracking: next,
            coma: result,
            fwhm: fwhm,
            starProfile: starProfile,
            overlay: overlay,
            displayFrame: display
        )
    }
}
