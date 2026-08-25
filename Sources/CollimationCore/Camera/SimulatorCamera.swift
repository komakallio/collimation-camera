import Foundation

public final class SimulatorCamera: CameraDevice {
    public let descriptor = CameraDescriptor.simulator
    public private(set) var controls = CameraControls()
    public private(set) var currentROI = ROI(x: 0, y: 0, width: 512, height: 512)
    public let supportedBins = [1, 2, 4]

    public var renderer = DonutRenderer()
    public var driftPerSecond = SIMD2<Double>(8, -3)
    public var disappearAfter: TimeInterval? = nil

    private var opened = false
    private var streaming = false
    private var rng: RNG
    private var lastGrab = Date()
    private var startedAt = Date()
    private let lock = NSLock()

    public init(seed: UInt64 = 42) {
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
        let scale = min(4, max(0.15, Double(controls.exposureMicroseconds) / 50_000))
        renderer.scene.peakADU = 42_000 * scale
    }

    public func applyGain(_ gain: Int) throws {
        controls.gain = min(max(gain, controls.gainRange.lowerBound), controls.gainRange.upperBound)
        renderer.scene.noiseSigma = max(12, 50 - Double(controls.gain) * 0.05)
        renderer.scene.peakADU = min(60_000, 30_000 + Double(controls.gain) * 80)
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
            Thread.sleep(forTimeInterval: min(wait, 0.05))
        }
        let grabbedAt = Date()
        let dt = min(0.2, grabbedAt.timeIntervalSince(lastGrab))
        lastGrab = grabbedAt

        lock.lock()
        defer { lock.unlock() }

        renderer.scene.starPosition += driftPerSecond * dt
        let sw = Double(descriptor.sensorWidth)
        let sh = Double(descriptor.sensorHeight)
        if renderer.scene.starPosition.x < 80 { renderer.scene.starPosition.x = 80; driftPerSecond.x *= -1 }
        if renderer.scene.starPosition.y < 80 { renderer.scene.starPosition.y = 80; driftPerSecond.y *= -1 }
        if renderer.scene.starPosition.x > sw - 80 { renderer.scene.starPosition.x = sw - 80; driftPerSecond.x *= -1 }
        if renderer.scene.starPosition.y > sh - 80 { renderer.scene.starPosition.y = sh - 80; driftPerSecond.y *= -1 }

        if let disappearAfter, now.timeIntervalSince(startedAt) > disappearAfter {
            renderer.scene.starPosition = SIMD2(-500, -500)
        }

        let jitter = SIMD2(rng.gaussian(), rng.gaussian()) * renderer.scene.seeingJitter
        return renderer.render(roi: currentROI, jitter: jitter, rng: &rng)
    }
}
