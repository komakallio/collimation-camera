import Foundation

struct ProcessedFrame: Sendable {
    var histogram: Histogram
    var tracking: TrackingStatus
    var coma: ComaResult?
    var fwhm: FWHMResult?
    var overlay: OverlayModel
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
    private var roiSize = 512
    private var sensorWidth = CameraDescriptor.simulator.sensorWidth
    private var sensorHeight = CameraDescriptor.simulator.sensorHeight
    private var lastSensorCentroid: SIMD2<Double>?
    private var generation = 0

    func configure(
        autoCenter: Bool,
        autoSearch: Bool,
        roiSize: Int,
        sensorWidth: Int,
        sensorHeight: Int,
        holdROI: Bool = false
    ) {
        lock.lock()
        self.autoCenter = autoCenter
        self.autoSearch = autoSearch
        self.roiSize = roiSize
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
        let roiSize = self.roiSize
        let sensorWidth = self.sensorWidth
        let sensorHeight = self.sensorHeight
        let seed = lastSensorCentroid.map { frame.roi.framePixel(fromSensorPoint: $0) }
        lock.unlock()

        let histogram = Histogram.compute(from: frame, stride: max(1, frame.pixelCount / 80_000))
        let detection = detector.detect(in: frame, around: seed)

        lock.lock()
        guard generation == self.generation else {
            lock.unlock()
            return nil
        }
        var next = tracker.process(
            frame: frame,
            detection: detection,
            autoCenter: autoCenter && roiSize != 0 && !holdROI,
            autoSearch: autoSearch && !holdROI,
            trackingROISize: roiSize == 0 ? min(sensorWidth, sensorHeight) : roiSize,
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
        let centroid = next.centroidInFrame
        let previousComa = smoothedComa
        let previousFWHM = smoothedFWHM
        lock.unlock()

        var result: ComaResult?
        if trackingState == .tracking,
           min(frame.width, frame.height) <= 2048,
           let detection,
           let analyzed = analyzer.analyze(frame: frame, detection: detection),
           analyzed.quality >= 0.4 {
            result = analyzer.smooth(previous: previousComa, current: analyzed)
        } else if trackingState == .tracking {
            result = previousComa
        }

        var fwhm: FWHMResult?
        if trackingState == .tracking, let centroid {
            if let measured = fwhmEstimator.measure(frame: frame, centroid: centroid) {
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
            imageWidth: frame.width,
            imageHeight: frame.height,
            centroid: next.centroidInFrame,
            outer: result?.outer,
            inner: result?.inner,
            comaVector: result?.vector,
            trackingState: next.state,
            sensorWidth: sensorWidth,
            sensorHeight: sensorHeight,
            roi: frame.roi
        )
        lock.unlock()
        return ProcessedFrame(histogram: histogram, tracking: next, coma: result, fwhm: fwhm, overlay: overlay)
    }
}
