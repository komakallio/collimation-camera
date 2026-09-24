import ASICameraC
import Foundation

/// ZWO ASI camera. RAW16 mono only, like the Player One device.
final class ASICameraDevice: CameraDevice {
    private let native: ASINative
    private let cameraID: Int32
    private var opened = false
    private var streaming = false
    private(set) var descriptor: CameraDescriptor
    private(set) var controls = CameraControls()
    private(set) var currentROI = ROI(x: 0, y: 0, width: 512, height: 512)
    private(set) var supportedBins: [Int] = [1, 2]
    private(set) var roiAlignment = ROIAlignment.zwo
    private var format = ASI_IMG_RAW16
    private var grabBuffer = Data()
    private let grabLock = NSLock()
    private var grabCancelled = false

    /// Longest single `ASIGetVideoData` wait. Short slices keep the grab loop
    /// responsive to `cancelGrab` while `close()` waits for it.
    private static let waitSliceMs = 200

    init(native: ASINative, cameraID: Int32) {
        self.native = native
        self.cameraID = cameraID
        self.descriptor = CameraDescriptor(
            id: "asi-\(cameraID)",
            name: "ZWO ASI",
            sensorWidth: 1920,
            sensorHeight: 1080,
            pixelSizeMicrons: 3.76,
            isSimulator: false,
            hardwareID: cameraID
        )
    }

    func open() throws {
        // Same ordering as the Player One path, and for the same reason: the
        // property lookup calls ASIGetNumOfConnectedCameras, which is what
        // scans the bus and makes a camera id valid. Opening first worked only
        // because the app always enumerated in the same process beforehand.
        // Player One was confirmed to fail this way on real hardware; ZWO
        // documents the same requirement but has not been tested.
        guard let info = native.property(forCameraID: cameraID) else {
            throw CameraError.notConnected
        }
        try native.open(cameraID)
        try native.initialize(cameraID)
        opened = true

        descriptor = native.descriptor(from: info)
        var bins: [Int] = []
        withUnsafeBytes(of: info.SupportedBins) { raw in
            for value in raw.bindMemory(to: Int32.self) {
                if value <= 0 { break }
                bins.append(Int(value))
            }
        }
        if !bins.isEmpty { supportedBins = bins }
        roiAlignment = ROIAlignment.forZWOCamera(named: descriptor.name)

        let ranges = native.controlRanges(cameraID)
        if let range = ranges[Int32(ASI_EXPOSURE.rawValue)] {
            controls.exposureRange = range
        }
        if let range = ranges[Int32(ASI_GAIN.rawValue)] {
            controls.gainRange = range
        }
        // Fastest readout the link allows; the SDK exposes the ceiling per camera.
        if let range = ranges[Int32(ASI_BANDWIDTHOVERLOAD.rawValue)] {
            try? native.setControl(cameraID, ASI_BANDWIDTHOVERLOAD, range.upperBound)
        }
        // High-speed mode drops the ADC to 10 bits; keep the native depth.
        try? native.setControl(cameraID, ASI_HIGH_SPEED_MODE, 0)
        try? native.setControl(cameraID, ASI_FLIP, Int(ASI_FLIP_NONE.rawValue))

        let roi = Alignment.centeredROI(
            around: SIMD2(Double(descriptor.sensorWidth) / 2, Double(descriptor.sensorHeight) / 2),
            size: 512,
            sensorWidth: descriptor.sensorWidth,
            sensorHeight: descriptor.sensorHeight,
            binning: 1,
            alignment: roiAlignment
        )
        try applyROI(roi, force: true)
        try applyExposure(controls.exposureMicroseconds)
        try applyGain(controls.gain)
        if let actual = try? native.control(cameraID, ASI_EXPOSURE) {
            controls.exposureMicroseconds = actual
        }
    }

    func cancelGrab() {
        grabLock.lock()
        grabCancelled = true
        grabLock.unlock()
    }

    /// The property lookup enumerates, so an unplugged camera drops out of it.
    /// Untested against real ZWO hardware, like the rest of this file.
    func isStillPresent() -> Bool {
        native.property(forCameraID: cameraID) != nil
    }

    func applyExposure(_ microseconds: Int) throws {
        let clamped = min(max(microseconds, controls.exposureRange.lowerBound), controls.exposureRange.upperBound)
        try native.setControl(cameraID, ASI_EXPOSURE, clamped)
        controls.exposureMicroseconds = (try? native.control(cameraID, ASI_EXPOSURE)) ?? clamped
    }

    func applyGain(_ gain: Int) throws {
        let clamped = min(max(gain, controls.gainRange.lowerBound), controls.gainRange.upperBound)
        try native.setControl(cameraID, ASI_GAIN, clamped)
        controls.gain = clamped
    }

    func applyROI(_ roi: ROI) throws {
        try applyROI(roi, force: false)
    }

    private func applyROI(_ roi: ROI, force: Bool) throws {
        if !force, roi == currentROI { return }
        // Moving the window only: the SDK allows a start-position change while
        // streaming, so the tracker can recenter without a stream restart.
        let sizeUnchanged = !force
            && roi.width == currentROI.width
            && roi.height == currentROI.height
            && roi.binning == currentROI.binning
        if sizeUnchanged {
            try native.setStartPosition(cameraID, x: roi.x, y: roi.y)
            currentROI = try native.currentROI(cameraID)
            return
        }

        let wasStreaming = streaming
        if wasStreaming { stopVideo() }
        try native.setROIFormat(
            cameraID,
            width: roi.width,
            height: roi.height,
            bin: roi.binning,
            format: ASI_IMG_RAW16
        )
        try native.setStartPosition(cameraID, x: roi.x, y: roi.y)
        format = (try? native.currentFormat(cameraID)) ?? ASI_IMG_RAW16
        currentROI = try native.currentROI(cameraID)
        if wasStreaming { try startVideo() }
    }

    func startVideo() throws {
        guard opened else { throw CameraError.notConnected }
        try native.startVideo(cameraID)
        streaming = true
    }

    func stopVideo() {
        guard opened else { return }
        native.stopVideo(cameraID)
        streaming = false
    }

    func close() {
        cancelGrab()
        guard opened else { return }
        native.stopVideo(cameraID)
        native.close(cameraID)
        streaming = false
        opened = false
    }

    func grabFrame(timeoutMs: Int) throws -> Frame {
        guard opened else { throw CameraError.notConnected }
        grabLock.lock()
        grabCancelled = false
        grabLock.unlock()

        let bytesPerPixel = format == ASI_IMG_RAW16 ? 2 : 1
        let pixelCount = currentROI.width * currentROI.height
        let size = pixelCount * bytesPerPixel
        if grabBuffer.count < size {
            grabBuffer = Data(count: size)
        }

        let deadline = Date().addingTimeInterval(Double(max(timeoutMs, 1)) / 1000.0)
        var received = false
        while !received {
            if isCancelled() { throw CameraError.timeout }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { throw CameraError.timeout }
            let waitMs = min(Self.waitSliceMs, max(1, Int(remaining * 1000)))
            received = try grabBuffer.withUnsafeMutableBytes { raw -> Bool in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                    throw CameraError.sdk(vendor: .zwo, code: -1, message: "Failed to allocate frame buffer")
                }
                return try native.readVideoData(cameraID, buffer: base, size: size, waitMs: waitMs)
            }
        }

        var pixels = [UInt16](repeating: 0, count: pixelCount)
        pixels.withUnsafeMutableBytes { dest in
            grabBuffer.withUnsafeBytes { src in
                guard let d = dest.baseAddress, let s = src.baseAddress else { return }
                if format == ASI_IMG_RAW16 {
                    // RAW16 is little-endian and MSB-aligned, so a 12-bit
                    // camera saturates at 65520 and the clip threshold holds.
                    d.copyMemory(from: s, byteCount: pixelCount * MemoryLayout<UInt16>.size)
                } else {
                    let bytes = src.bindMemory(to: UInt8.self)
                    let out = dest.bindMemory(to: UInt16.self)
                    for i in 0..<pixelCount {
                        out[i] = UInt16(bytes[i]) << 8
                    }
                }
            }
        }
        return Frame(
            width: currentROI.width,
            height: currentROI.height,
            pixels: pixels,
            roi: currentROI
        )
    }

    private func isCancelled() -> Bool {
        grabLock.lock()
        defer { grabLock.unlock() }
        return grabCancelled
    }
}
