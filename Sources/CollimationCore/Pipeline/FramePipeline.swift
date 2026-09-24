import Foundation

struct ProcessedFrame: Sendable {
    var histogram: Histogram
    var tracking: TrackingStatus
    var coma: ComaResult?
    var fwhm: FWHMResult?
    var starProfile: StarIntensityProfile?
    var overlay: OverlayModel
    var displayFrame: Frame
    var captureROI: ROI
}

final class FramePipeline: @unchecked Sendable {
    private let lock = NSLock()
    private var tracker = Tracker()
    private let detector = StarDetector()
    private let analyzer = ComaAnalyzer()
    private let fwhmEstimator = FWHMEstimator()
    private let profileSampler = StarProfileSampler()
    private var holdROI = false
    private var sensorWidth = CameraDescriptor.simulator.sensorWidth
    private var sensorHeight = CameraDescriptor.simulator.sensorHeight
    private var optics = TelescopeOptics.poseidon
    private var roiAlignment = ROIAlignment.playerOne
    private var lastSensorCentroid: SIMD2<Double>?
    private var generation = 0

    func configure(
        sensorWidth: Int,
        sensorHeight: Int,
        holdROI: Bool = false,
        optics: TelescopeOptics = .poseidon,
        roiAlignment: ROIAlignment = .playerOne,
        searchBinning: Int = 4
    ) {
        lock.lock()
        self.sensorWidth = sensorWidth
        self.sensorHeight = sensorHeight
        self.holdROI = holdROI
        self.optics = optics
        self.roiAlignment = roiAlignment
        // The tracker's own full-frame search builds a full-frame ROI too, so it
        // needs the same device-legal binning.
        tracker.config.searchBinning = max(1, searchBinning)
        lock.unlock()
    }

    func reset() {
        lock.lock()
        generation &+= 1
        tracker.reset()
        lastSensorCentroid = nil
        lock.unlock()
    }

    /// Drop analysis that is already in `process` so it cannot apply a stale ROI.
    func dropInFlight() {
        lock.lock()
        generation &+= 1
        lock.unlock()
    }

    func process(_ frame: Frame) -> ProcessedFrame? {
        lock.lock()
        let generation = self.generation
        let sensorWidth = self.sensorWidth
        let sensorHeight = self.sensorHeight
        let optics = self.optics
        let roiAlignment = self.roiAlignment
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
        // Full-frame centering/constellation slews: a 1 s move can jump the
        // star out of the 512 analysis crop. Search the whole sensor, then crop.
        if found == nil, !CaptureLayout.isTrackingCapture(frame),
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
            holdROI: self.holdROI,
            trackingROISize: CaptureLayout.trackingHardwareSize,
            sensorWidth: sensorWidth,
            sensorHeight: sensorHeight,
            alignment: roiAlignment
        )
        // Re-read after detection: Center can raise holdROI while this frame
        // was still being searched, and a stale 2048 request would win.
        if self.holdROI {
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

        let metricsOnDisplay = display.width == window.width && display.height == window.height
        var result: ComaResult?
        if trackingState == .tracking, metricsOnDisplay,
           let analysisDetection = next.detection,
           let analyzed = analyzer.analyze(frame: display, detection: analysisDetection),
           analyzed.quality >= 0.4 {
            result = analyzed
        }

        var fwhm: FWHMResult?
        if trackingState == .tracking, metricsOnDisplay, let centroid = next.centroidInFrame {
            fwhm = fwhmEstimator.measure(frame: display, centroid: centroid, optics: optics)
        }

        var starProfile: StarIntensityProfile?
        if trackingState == .tracking, metricsOnDisplay, let centroid = next.centroidInFrame {
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
            displayFrame: display,
            captureROI: frame.roi
        )
    }
}
