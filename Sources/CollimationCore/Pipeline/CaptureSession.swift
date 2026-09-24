import Foundation

public final class CaptureSession: @unchecked Sendable {
    public var onFrame: ((Frame) -> Void)?
    /// Called on the capture thread, not the main actor. The engine hops to
    /// the main actor in its handler.
    public var onError: ((Error) -> Void)?

    private let queue = DispatchQueue(label: "collimation.capture", qos: .userInitiated)
    private let stateLock = NSLock()
    private var device: CameraDevice?
    private var running = false
    private var pendingROI: ROI?
    private var pendingExposure: Int?
    private var pendingGain: Int?
    private var pendingFrameLimit: Int?
    /// When true, tracker-driven ROI changes are ignored so a full-frame
    /// centering slew cannot be snapped back to the 2048 window.
    private var holdROI = false
    private let loopGroup = DispatchGroup()

    /// Consecutive timeouts before the loop stops assuming the camera is just
    /// slow and asks whether it is still on the bus. Each timeout is the
    /// exposure plus 400 ms, so this scales with the exposure by itself.
    private static let timeoutsBeforePresenceCheck = 2
    /// Consecutive timeouts before giving up on a camera that still enumerates
    /// but has stopped delivering.
    private static let timeoutsBeforeGivingUp = 10

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
        pendingFrameLimit = nil
        holdROI = false
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
        requestROI(roi, fromTracker: false)
    }

    /// Tracker recenters. Ignored while mount work is holding the ROI.
    public func requestTrackerROI(_ roi: ROI) {
        requestROI(roi, fromTracker: true)
    }

    public func setHoldROI(_ hold: Bool) {
        stateLock.lock()
        holdROI = hold
        stateLock.unlock()
    }

    private func requestROI(_ roi: ROI, fromTracker: Bool) {
        stateLock.lock()
        defer { stateLock.unlock() }
        if fromTracker, holdROI { return }
        pendingROI = roi
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

    /// `0` removes the live-view 30 fps cap so stack capture can run at full readout.
    public func requestFrameLimit(_ fps: Int) {
        stateLock.lock()
        pendingFrameLimit = fps
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
            onError?(error)
            return
        }

        var nextFrameDeadline = Date.distantPast
        var capFPS = CaptureLayout.maxReadoutFPS
        var timeouts = 0
        while true {
            stateLock.lock()
            let keepGoing = running
            let roi = pendingROI
            pendingROI = nil
            let exposure = pendingExposure
            pendingExposure = nil
            let gain = pendingGain
            pendingGain = nil
            let frameLimitRequest = pendingFrameLimit
            pendingFrameLimit = nil
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
                if let frameLimitRequest {
                    capFPS = frameLimitRequest
                    device.applyFrameLimit(frameLimitRequest)
                    nextFrameDeadline = Date.distantPast
                }
                if !device.descriptor.isSimulator, capFPS > 0 {
                    let now = Date()
                    if now < nextFrameDeadline {
                        // Not Thread.sleep: on Windows that is quantized to the
                        // process timer resolution, which turns a 33 ms pace
                        // into about 47 ms.
                        preciseSleep(
                            microseconds: Int(nextFrameDeadline.timeIntervalSince(now) * 1_000_000)
                        )
                    }
                    stateLock.lock()
                    let stillRunning = running
                    stateLock.unlock()
                    if !stillRunning { break }
                }
                let timeout = max(100, device.controls.exposureMicroseconds / 1000 + 400)
                let frame = try device.grabFrame(timeoutMs: timeout)
                if !device.descriptor.isSimulator, capFPS > 0 {
                    nextFrameDeadline = Date().addingTimeInterval(1.0 / Double(capFPS))
                }
                timeouts = 0
                onFrame?(frame)
            } catch CameraError.timeout {
                // A single timeout is ordinary — a stream restart after an ROI
                // change can miss one. A run of them is not, and an unplugged
                // camera produces exactly that and nothing else: the SDK keeps
                // answering "no frame ready yet" rather than reporting an
                // error, for ever. Retrying for ever is what the loop used to
                // do, so pulling the cable during live view froze the picture,
                // raised no error, left the buttons saying Disconnect, and
                // replugging did nothing because nobody had noticed.
                timeouts += 1
                if timeouts >= Self.timeoutsBeforePresenceCheck, !device.isStillPresent() {
                    onError?(CameraError.disconnected)
                    break
                }
                if timeouts >= Self.timeoutsBeforeGivingUp {
                    // Still enumerated but not delivering. Just as unusable,
                    // and the alternative is a frozen view with no explanation.
                    onError?(CameraError.disconnected)
                    break
                }
                continue
            } catch {
                onError?(error)
                break
            }
        }
        device.stopVideo()
    }
}
