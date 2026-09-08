import Foundation

public enum TrackingState: String, Equatable, Sendable {
    case idle
    case tracking
    case lost
    case searching
}

public struct TrackingConfig: Equatable, Sendable {
    public var lostFrameLimit: Int
    public var recenterThreshold: Double
    public var minRecenterInterval: TimeInterval
    public var searchBinning: Int
    public var minSNR: Double

    public init(
        lostFrameLimit: Int = 8,
        recenterThreshold: Double = 0.15,
        minRecenterInterval: TimeInterval = 0.4,
        searchBinning: Int = 4,
        minSNR: Double = 6
    ) {
        self.lostFrameLimit = lostFrameLimit
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

    public init(config: TrackingConfig = TrackingConfig()) {
        self.config = config
    }

    public mutating func reset() {
        state = .idle
        lostFrames = 0
        lastSensorCentroid = nil
        lastMove = .distantPast
    }

    public mutating func process(
        frame: Frame,
        detection: StarDetection?,
        autoCenter: Bool,
        autoSearch: Bool,
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
                let roi: ROI?
                if autoCenter || autoSearch {
                    roi = Alignment.centeredROI(
                        around: sensor,
                        size: trackingROISize,
                        sensorWidth: sensorWidth,
                        sensorHeight: sensorHeight,
                        binning: 1,
                        alignment: alignment
                    )
                } else {
                    roi = nil
                }
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
            if autoCenter, trackingROISize < min(sensorWidth, sensorHeight) {
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
            if !autoSearch {
                state = .lost
                return TrackingStatus(
                    state: .lost,
                    centroidOnSensor: lastSensorCentroid,
                    lostFrames: lostFrames
                )
            }
            return TrackingStatus(state: .searching, lostFrames: lostFrames)
        }
        if autoSearch, lostFrames >= config.lostFrameLimit {
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
