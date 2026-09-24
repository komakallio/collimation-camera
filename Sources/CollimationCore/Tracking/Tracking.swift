import Foundation

public enum TrackingState: String, Equatable, Sendable {
    case idle
    case tracking
    case lost
    case searching
}

public struct TrackingConfig: Equatable, Sendable {
    public var lostFrameLimit: Int
    /// Consecutive detections in the same place before a full-frame search is
    /// believed and the camera is moved onto the star.
    ///
    /// Losing a star was debounced from the start and finding one was not, so
    /// a single noise peak above `minSNR` promoted searching to tracking, the
    /// camera moved to a 2048 window, the peak was not there, and eight frames
    /// later it went back to searching. With no optics on the camera that
    /// cycles about three times a second and the view visibly flickers between
    /// the crop and the full frame. Noise peaks jump around; a star does not,
    /// so agreeing on a position is what separates them.
    public var foundFrameLimit: Int
    /// How far apart, in sensor pixels, two detections may be and still count
    /// as the same star. Four binned pixels at the default search binning.
    public var acquireRadius: Double
    public var recenterThreshold: Double
    public var minRecenterInterval: TimeInterval
    public var searchBinning: Int
    public var minSNR: Double

    public init(
        lostFrameLimit: Int = 8,
        foundFrameLimit: Int = 3,
        acquireRadius: Double = 16,
        recenterThreshold: Double = 0.15,
        minRecenterInterval: TimeInterval = 0.4,
        searchBinning: Int = 4,
        minSNR: Double = 6
    ) {
        self.lostFrameLimit = lostFrameLimit
        self.foundFrameLimit = foundFrameLimit
        self.acquireRadius = acquireRadius
        self.recenterThreshold = recenterThreshold
        self.minRecenterInterval = minRecenterInterval
        self.searchBinning = searchBinning
        self.minSNR = minSNR
    }
}

public struct TrackingStatus: Equatable, Sendable {
    public var state: TrackingState
    public var detection: StarDetection?
    public var centroidInFrame: SIMD2<Double>?
    public var centroidOnSensor: SIMD2<Double>?
    public var lostFrames: Int
    public var requestedROI: ROI?

    public init(
        state: TrackingState = .idle,
        detection: StarDetection? = nil,
        centroidInFrame: SIMD2<Double>? = nil,
        centroidOnSensor: SIMD2<Double>? = nil,
        lostFrames: Int = 0,
        requestedROI: ROI? = nil
    ) {
        self.state = state
        self.detection = detection
        self.centroidInFrame = centroidInFrame
        self.centroidOnSensor = centroidOnSensor
        self.lostFrames = lostFrames
        self.requestedROI = requestedROI
    }
}

public struct Tracker: Sendable {
    public var config: TrackingConfig
    private var state: TrackingState = .idle
    private var lostFrames = 0
    private var lastMove: Date = .distantPast
    private var lastSensorCentroid: SIMD2<Double>?
    /// Where a candidate star has been seen while searching, and for how many
    /// consecutive frames.
    private var candidate: SIMD2<Double>?
    private var candidateFrames = 0

    public init(config: TrackingConfig = TrackingConfig()) {
        self.config = config
    }

    public mutating func reset() {
        state = .idle
        lostFrames = 0
        lastSensorCentroid = nil
        candidate = nil
        candidateFrames = 0
        lastMove = .distantPast
    }

    public mutating func process(
        frame: Frame,
        detection: StarDetection?,
        holdROI: Bool = false,
        trackingROISize: Int,
        sensorWidth: Int,
        sensorHeight: Int,
        alignment: ROIAlignment = .playerOne
    ) -> TrackingStatus {
        let now = Date()
        if let detection, detection.snr >= config.minSNR {
            lostFrames = 0
            let sensor = frame.roi.sensorPoint(fromFramePixel: detection.centroid)
            lastSensorCentroid = sensor

            if state == .searching {
                // Believe a full-frame detection only once it has stayed put.
                // Without this a single noise peak moves the camera.
                let sameStar = candidate.map { previous in
                    let dx = previous.x - sensor.x
                    let dy = previous.y - sensor.y
                    return dx * dx + dy * dy <= config.acquireRadius * config.acquireRadius
                } ?? false
                if sameStar {
                    candidateFrames += 1
                } else {
                    candidate = sensor
                    candidateFrames = 1
                }
                guard candidateFrames >= max(1, config.foundFrameLimit) else {
                    return TrackingStatus(
                        state: .searching,
                        detection: detection,
                        centroidInFrame: detection.centroid,
                        centroidOnSensor: sensor
                    )
                }
                candidate = nil
                candidateFrames = 0

                let roi: ROI? = holdROI ? nil : Alignment.centeredROI(
                    around: sensor,
                    size: trackingROISize,
                    sensorWidth: sensorWidth,
                    sensorHeight: sensorHeight,
                    binning: 1,
                    alignment: alignment
                )
                state = .tracking
                lastMove = now
                return TrackingStatus(
                    state: state,
                    detection: detection,
                    centroidInFrame: detection.centroid,
                    centroidOnSensor: sensor,
                    requestedROI: roi
                )
            }

            state = .tracking
            var requested: ROI?
            if !holdROI, trackingROISize < min(sensorWidth, sensorHeight) {
                requested = recenterIfNeeded(
                    detection: detection,
                    frame: frame,
                    sensor: sensor,
                    trackingROISize: trackingROISize,
                    sensorWidth: sensorWidth,
                    sensorHeight: sensorHeight,
                    alignment: alignment,
                    now: now
                )
            }
            return TrackingStatus(
                state: state,
                detection: detection,
                centroidInFrame: detection.centroid,
                centroidOnSensor: sensor,
                requestedROI: requested
            )
        }

        lostFrames += 1
        if state == .searching {
            if holdROI {
                state = .lost
                return TrackingStatus(
                    state: .lost,
                    centroidOnSensor: lastSensorCentroid,
                    lostFrames: lostFrames
                )
            }
            return TrackingStatus(state: .searching, lostFrames: lostFrames)
        }
        if !holdROI, lostFrames >= config.lostFrameLimit {
            state = .searching
            let search = Alignment.fullFrameROI(
                sensorWidth: sensorWidth,
                sensorHeight: sensorHeight,
                binning: config.searchBinning,
                alignment: alignment
            )
            lastMove = now
            return TrackingStatus(state: .searching, lostFrames: lostFrames, requestedROI: search)
        }
        state = .lost
        return TrackingStatus(
            state: .lost,
            centroidOnSensor: lastSensorCentroid,
            lostFrames: lostFrames
        )
    }

    public mutating func markSearching() {
        state = .searching
        lostFrames = config.lostFrameLimit
        candidate = nil
        candidateFrames = 0
    }

    private mutating func recenterIfNeeded(
        detection: StarDetection,
        frame: Frame,
        sensor: SIMD2<Double>,
        trackingROISize: Int,
        sensorWidth: Int,
        sensorHeight: Int,
        alignment: ROIAlignment,
        now: Date
    ) -> ROI? {
        let cx = Double(frame.width - 1) / 2
        let cy = Double(frame.height - 1) / 2
        let dx = detection.centroid.x - cx
        let dy = detection.centroid.y - cy
        let distance = sqrt(dx * dx + dy * dy)
        let threshold = config.recenterThreshold * Double(min(frame.width, frame.height))
        guard distance > threshold else { return nil }
        guard now.timeIntervalSince(lastMove) >= config.minRecenterInterval else { return nil }
        lastMove = now
        return Alignment.centeredROI(
            around: sensor,
            size: trackingROISize,
            sensorWidth: sensorWidth,
            sensorHeight: sensorHeight,
            binning: 1,
            alignment: alignment
        )
    }
}
