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
    private var roiSize = 512
    private var sensorWidth = CameraDescriptor.simulator.sensorWidth
    private var sensorHeight = CameraDescriptor.simulator.sensorHeight

    func configure(autoCenter: Bool, roiSize: Int, sensorWidth: Int, sensorHeight: Int) {
        lock.lock()
        self.autoCenter = autoCenter
        self.roiSize = roiSize
        self.sensorWidth = sensorWidth
        self.sensorHeight = sensorHeight
        lock.unlock()
    }

    func reset() {
        lock.lock()
        tracker.reset()
        smoothedComa = nil
        smoothedFWHM = nil
        lock.unlock()
    }

    func markSearching() {
        lock.lock()
        tracker.markSearching()
        lock.unlock()
    }

    func process(_ frame: Frame) -> ProcessedFrame {
        lock.lock()
        defer { lock.unlock() }

        let histogram = Histogram.compute(from: frame, stride: max(1, frame.pixelCount / 80_000))
        let detection = detector.detect(in: frame)
        let next = tracker.process(
            frame: frame,
            detection: detection,
            autoCenter: autoCenter && roiSize != 0,
            trackingROISize: roiSize == 0 ? min(sensorWidth, sensorHeight) : roiSize,
            sensorWidth: sensorWidth,
            sensorHeight: sensorHeight
        )

        var result: ComaResult?
        if next.state == .tracking,
           min(frame.width, frame.height) <= 2048,
           let detection,
           let analyzed = analyzer.analyze(frame: frame, detection: detection),
           analyzed.quality >= 0.4 {
            result = analyzer.smooth(previous: smoothedComa, current: analyzed)
            smoothedComa = result
        } else if next.state != .tracking {
            smoothedComa = nil
            result = nil
        } else {
            result = smoothedComa
        }

        var fwhm: FWHMResult?
        if next.state == .tracking, let centroid = next.centroidInFrame {
            if let measured = fwhmEstimator.measure(frame: frame, centroid: centroid) {
                fwhm = fwhmEstimator.smooth(previous: smoothedFWHM, current: measured)
                smoothedFWHM = fwhm
            } else {
                fwhm = smoothedFWHM
            }
        } else {
            smoothedFWHM = nil
            fwhm = nil
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
        return ProcessedFrame(histogram: histogram, tracking: next, coma: result, fwhm: fwhm, overlay: overlay)
    }
}
