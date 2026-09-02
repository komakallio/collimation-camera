import Foundation

struct ProcessedFrame: Sendable {
    var histogram: Histogram
    var tracking: TrackingStatus
    var coma: ComaResult?
    var fwhm: FWHMResult?
    var overlay: OverlayModel
    var displayFrame: Frame
}

final class FramePipeline: @unchecked Sendable {
    private let lock = NSLock()
    private var tracker = Tracker()
    private let detector = StarDetector()
    private let analyzer = ComaAnalyzer()
    private let fwhmEstimator = FWHMEstimator()
    private var smoothedComa: ComaResult?
    private var smoothedFWHM: FWHMResult?
    private var autoCenter = true
    private var autoSearch = false
    private var holdROI = false
    private var sensorWidth = CameraDescriptor.simulator.sensorWidth
    private var sensorHeight = CameraDescriptor.simulator.sensorHeight
    private var lastSensorCentroid: SIMD2<Double>?
    private var generation = 0

    func configure(
        autoCenter: Bool,
        autoSearch: Bool,
        sensorWidth: Int,
        sensorHeight: Int,
        holdROI: Bool = false
    ) {
        lock.lock()
        self.autoCenter = autoCenter
        self.autoSearch = autoSearch
        self.sensorWidth = sensorWidth
        self.sensorHeight = sensorHeight
        self.holdROI = holdROI
        lock.unlock()
    }

    func reset() {
        lock.lock()
        generation &+= 1
        tracker.reset()
        lastSensorCentroid = nil
        smoothedComa = nil
        smoothedFWHM = nil
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
        let seed = lastSensorCentroid.map { frame.roi.framePixel(fromSensorPoint: $0) }
        lock.unlock()

        let detection = detector.detect(in: frame, around: seed)

        lock.lock()
        guard generation == self.generation else {
            lock.unlock()
            return nil
        }
        var next = tracker.process(
            frame: frame,
            detection: detection,
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
        let previousComa = smoothedComa
        let previousFWHM = smoothedFWHM
        lock.unlock()

        let display = CaptureLayout.displayFrame(
            from: frame,
            tracking: trackingState,
            centroid: next.centroidInFrame
        )
        if display.width != frame.width || display.height != frame.height {
            let origin = display.origin(inParent: frame)
            next.centroidInFrame = next.centroidInFrame.map { $0 - origin }
            if let found = next.detection {
                next.detection = found.offsetBy(-origin)
            }
        }

        let histogram = Histogram.compute(from: display, stride: max(1, display.pixelCount / 80_000))

        var result: ComaResult?
        if trackingState == .tracking,
           let analysisDetection = next.detection,
           let analyzed = analyzer.analyze(frame: display, detection: analysisDetection),
           analyzed.quality >= 0.4 {
            result = analyzer.smooth(previous: previousComa, current: analyzed)
        } else if trackingState == .tracking {
            result = previousComa
        }

        var fwhm: FWHMResult?
        if trackingState == .tracking, let centroid = next.centroidInFrame {
            if let measured = fwhmEstimator.measure(frame: display, centroid: centroid) {
                fwhm = fwhmEstimator.smooth(previous: previousFWHM, current: measured)
            } else {
                fwhm = previousFWHM
            }
        }

        lock.lock()
        guard generation == self.generation else {
            lock.unlock()
            return nil
        }
        if trackingState != .tracking {
            smoothedComa = nil
            smoothedFWHM = nil
            result = nil
            fwhm = nil
        } else {
            smoothedComa = result
            smoothedFWHM = fwhm
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
            overlay: overlay,
            displayFrame: display
        )
    }
}
