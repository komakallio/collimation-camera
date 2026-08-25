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
    private let loopGroup = DispatchGroup()

    public init() {}

    public var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    public func start(device: CameraDevice) {
        stop()
        stateLock.lock()
        self.device = device
        running = true
        pendingROI = nil
        pendingExposure = nil
        pendingGain = nil
        stateLock.unlock()

        loopGroup.enter()
        queue.async { [weak self] in
            defer { self?.loopGroup.leave() }
            self?.runLoop()
        }
    }

    public func stop() {
        stateLock.lock()
        let shouldWait = running
        running = false
        let device = self.device
        self.device = nil
        stateLock.unlock()

        device?.cancelGrab()
        if shouldWait {
            // Must not close the SDK while another thread is inside POAImageReady.
            _ = loopGroup.wait(timeout: .now() + 3)
        }
        // Close only after the capture thread has left SDK calls.
        device?.stopVideo()
        device?.close()
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
                    try device.applyExposure(exposure)
                }
                if let gain {
                    try device.applyGain(gain)
                }
                if let roi, roi != device.currentROI {
                    try device.applyROI(roi)
                }
                let timeout = max(100, device.controls.exposureMicroseconds / 1000 + 400)
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
