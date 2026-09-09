import Foundation

public final class SimulatorCamera: CameraDevice {
    public enum Pattern: Sendable {
        case defocusedDonut
        case airy
    }

    public let descriptor: CameraDescriptor
    public private(set) var controls = CameraControls()
    public private(set) var currentROI = ROI(x: 0, y: 0, width: 512, height: 512)
    public let supportedBins = [1, 2, 4]

    public var driftPerSecond = SIMD2<Double>(8, -3)
    public var disappearAfter: TimeInterval? = nil

    private var pattern: Pattern
    private var donut = DonutRenderer()
    private var airy = AiryRenderer()
    private var opened = false
    private var streaming = false
    private var rng: RNG
    private var lastGrab = Date()
    private var startedAt = Date()
    private let lock = NSLock()

    public init(pattern: Pattern = .defocusedDonut, seed: UInt64 = 42) {
        self.pattern = pattern
        self.descriptor = pattern == .airy ? .airySimulator : .simulator
        self.rng = RNG(seed: seed)
        let sensor = descriptor
        currentROI = Alignment.centeredROI(
            around: SIMD2(Double(sensor.sensorWidth) / 2, Double(sensor.sensorHeight) / 2),
            size: 512,
            sensorWidth: sensor.sensorWidth,
            sensorHeight: sensor.sensorHeight
        )
    }

    public func open() throws {
        opened = true
        startedAt = Date()
        lastGrab = Date()
        try applyGain(controls.gain)
        try applyExposure(controls.exposureMicroseconds)
    }

    public func close() {
        streaming = false
        opened = false
    }

    public func applyExposure(_ microseconds: Int) throws {
        controls.exposureMicroseconds = min(max(microseconds, controls.exposureRange.lowerBound), controls.exposureRange.upperBound)
        applySignalLevel()
    }

    public func applyGain(_ gain: Int) throws {
        controls.gain = min(max(gain, controls.gainRange.lowerBound), controls.gainRange.upperBound)
        setNoiseSigma(max(12, 50 - Double(controls.gain) * 0.05))
        applySignalLevel()
    }

    public func applyROI(_ roi: ROI) throws {
        if roi == currentROI { return }
        currentROI = roi
    }

    public func startVideo() throws {
        guard opened else { throw CameraError.notConnected }
        streaming = true
        lastGrab = Date()
    }

    public func stopVideo() {
        streaming = false
    }

    public func grabFrame(timeoutMs: Int) throws -> Frame {
        _ = timeoutMs
        guard opened else { throw CameraError.notConnected }
        let minInterval = 1.0 / 80.0
        let now = Date()
        let wait = minInterval - now.timeIntervalSince(lastGrab)
        if wait > 0.0005 {
            // preciseSleep, not Thread.sleep: on Windows the plain sleep is
            // quantized to the process timer resolution, so a 12.5 ms pacing
            // wait becomes 15.6 ms and the simulator caps at 62 fps instead of
            // 80 (§7.3).
            preciseSleep(microseconds: Int(min(wait, 0.05) * 1_000_000))
        }
        let grabbedAt = Date()
        let dt = min(0.2, grabbedAt.timeIntervalSince(lastGrab))
        lastGrab = grabbedAt

        lock.lock()
        defer { lock.unlock() }

        var position = starPosition + driftPerSecond * dt
        let sw = Double(descriptor.sensorWidth)
        let sh = Double(descriptor.sensorHeight)
        if position.x < 80 { position.x = 80; driftPerSecond.x *= -1 }
        if position.y < 80 { position.y = 80; driftPerSecond.y *= -1 }
        if position.x > sw - 80 { position.x = sw - 80; driftPerSecond.x *= -1 }
        if position.y > sh - 80 { position.y = sh - 80; driftPerSecond.y *= -1 }
        if let disappearAfter, now.timeIntervalSince(startedAt) > disappearAfter {
            position = SIMD2(-500, -500)
        }
        starPosition = position

        let jitter = SIMD2(rng.gaussian(), rng.gaussian()) * seeingJitter
        switch pattern {
        case .defocusedDonut:
            return donut.render(roi: currentROI, jitter: jitter, rng: &rng)
        case .airy:
            return airy.render(roi: currentROI, jitter: jitter, rng: &rng)
        }
    }

    private var starPosition: SIMD2<Double> {
        get {
            switch pattern {
            case .defocusedDonut: return donut.scene.starPosition
            case .airy: return airy.scene.starPosition
            }
        }
        set {
            switch pattern {
            case .defocusedDonut: donut.scene.starPosition = newValue
            case .airy: airy.scene.starPosition = newValue
            }
        }
    }

    private var seeingJitter: Double {
        switch pattern {
        case .defocusedDonut: return donut.scene.seeingJitter
        case .airy: return airy.scene.seeingJitter
        }
    }

    private func applySignalLevel() {
        let exposureScale = min(4, max(0.15, Double(controls.exposureMicroseconds) / 50_000))
        let gainScale = 1 + Double(controls.gain) / 400.0
        setPeakADU(42_000 * exposureScale * gainScale)
    }

    private func setPeakADU(_ value: Double) {
        donut.scene.peakADU = value
        airy.scene.peakADU = value
    }

    private func setNoiseSigma(_ value: Double) {
        donut.scene.noiseSigma = value
        airy.scene.noiseSigma = value
    }
}
