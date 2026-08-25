import Foundation

public final class CaptureSession: @unchecked Sendable {
    public var onFrame: ((Frame) -> Void)?
    public var onError: ((Error) -> Void)?

    private let queue = DispatchQueue(label: "collimation.capture", qos: .userInitiated)
    private let stateLock = NSLock()
    private var device: CameraDevice?
    private var running = false
    private var pendingROI: ROI?
    private var pendingExposure: Int?
    private var pendingGain: Int?

    public init() {}

    public var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    public func start(device: CameraDevice) {
        stateLock.lock()
        self.device = device
        running = true
        pendingROI = nil
        pendingExposure = nil
        pendingGain = nil
        stateLock.unlock()

        queue.async { [weak self] in
            self?.runLoop()
        }
    }

    public func stop() {
        stateLock.lock()
        running = false
        let device = self.device
        stateLock.unlock()
        queue.sync {
            device?.stopVideo()
            device?.close()
        }
        stateLock.lock()
        self.device = nil
        stateLock.unlock()
    }

    public func requestROI(_ roi: ROI) {
        stateLock.lock()
        pendingROI = roi
        stateLock.unlock()
    }

    public func requestExposure(_ microseconds: Int) {
        stateLock.lock()
        pendingExposure = microseconds
        stateLock.unlock()
    }

    public func requestGain(_ gain: Int) {
        stateLock.lock()
        pendingGain = gain
        stateLock.unlock()
    }

    private func runLoop() {
        stateLock.lock()
        let device = self.device
        stateLock.unlock()
        guard let device else { return }

        do {
            try device.startVideo()
        } catch {
            DispatchQueue.main.async { self.onError?(error) }
            return
        }

        while true {
            stateLock.lock()
            let keepGoing = running
            let roi = pendingROI
            pendingROI = nil
            let exposure = pendingExposure
            pendingExposure = nil
            let gain = pendingGain
            pendingGain = nil
            stateLock.unlock()
            if !keepGoing { break }

            do {
                if let exposure {
                    device.stopVideo()
                    try device.applyExposure(exposure)
                    try device.startVideo()
                }
                if let gain {
                    try device.applyGain(gain)
                }
                if let roi {
                    try device.applyROI(roi)
                }
                let timeout = max(1500, device.controls.exposureMicroseconds / 1000 + 800)
                let frame = try device.grabFrame(timeoutMs: timeout)
                onFrame?(frame)
            } catch CameraError.timeout {
                continue
            } catch {
                DispatchQueue.main.async { self.onError?(error) }
                break
            }
        }
        device.stopVideo()
    }
}
