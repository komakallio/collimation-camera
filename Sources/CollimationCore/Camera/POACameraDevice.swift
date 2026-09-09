import Foundation
import POACameraC

final class POACameraDevice: CameraDevice {
    private let native: POANative
    private let cameraID: Int32
    private var opened = false
    private var streaming = false
    private(set) var descriptor: CameraDescriptor
    private(set) var controls = CameraControls()
    private(set) var currentROI = ROI(x: 0, y: 0, width: 512, height: 512)
    private(set) var supportedBins: [Int] = [1, 2, 4]
    private var format: POAImgFormat = POA_RAW16
    private var grabBuffer = Data()
    private let grabLock = NSLock()
    private var grabCancelled = false

    init(native: POANative, cameraID: Int32) {
        self.native = native
        self.cameraID = cameraID
        self.descriptor = CameraDescriptor(
            id: "poa-\(cameraID)",
            name: "Player One",
            sensorWidth: 6252,
            sensorHeight: 4176,
            pixelSizeMicrons: 3.76,
            isSimulator: false,
            hardwareID: cameraID
        )
    }

    func open() throws {
        // The properties lookup has to come first. It calls POAGetCameraCount,
        // which is what scans the bus and makes a camera id valid; without it
        // POAOpenCamera answers POA_ERROR_INVALID_ID. Enumerating and opening
        // are the same process in the app, so this was invisible there — but
        // `capture-cli --device poa-0` opens without ever listing, and failed
        // against a real Xena 585M until this was reordered.
        guard let props = native.properties(cameraID) else {
            throw CameraError.notConnected
        }
        try native.open(cameraID)
        try native.initialize(cameraID)
        opened = true
        descriptor = CameraDescriptor(
            id: "poa-\(cameraID)",
            name: cString(props.cameraModelName),
            sensorWidth: Int(props.maxWidth),
            sensorHeight: Int(props.maxHeight),
            pixelSizeMicrons: props.pixelSize,
            isSimulator: false,
            hardwareID: cameraID
        )
        var bins: [Int] = []
        withUnsafeBytes(of: props.bins) { raw in
            for v in raw.bindMemory(to: Int32.self) where v > 0 {
                bins.append(Int(v))
            }
        }
        if !bins.isEmpty { supportedBins = bins }
        if let range = native.intRange(cameraID, POA_EXPOSURE) {
            controls.exposureRange = range
        }
        if let range = native.intRange(cameraID, POA_GAIN) {
            controls.gainRange = range
        }
        try? native.setFormat(cameraID, POA_RAW16)
        format = (try? native.currentFormat(cameraID)) ?? POA_RAW16
        let roi = Alignment.centeredROI(
            around: SIMD2(Double(descriptor.sensorWidth) / 2, Double(descriptor.sensorHeight) / 2),
            size: 512,
            sensorWidth: descriptor.sensorWidth,
            sensorHeight: descriptor.sensorHeight
        )
        try applyROI(roi)
        applyFrameLimit(CaptureLayout.maxReadoutFPS)
        try applyExposure(controls.exposureMicroseconds)
        try applyGain(controls.gain)
        if let actual = native.getExposureMicroseconds(cameraID) {
            controls.exposureMicroseconds = actual
        }
    }

    func cancelGrab() {
        grabLock.lock()
        grabCancelled = true
        grabLock.unlock()
    }

    func applyExposure(_ microseconds: Int) throws {
        let clamped = min(max(microseconds, controls.exposureRange.lowerBound), controls.exposureRange.upperBound)
        try native.setExposure(id: cameraID, microseconds: clamped)
        controls.exposureMicroseconds = native.getExposureMicroseconds(cameraID) ?? clamped
    }

    func applyGain(_ gain: Int) throws {
        let clamped = min(max(gain, controls.gainRange.lowerBound), controls.gainRange.upperBound)
        try native.setInt(cameraID, POA_GAIN, clamped)
        controls.gain = clamped
    }

    func applyFrameLimit(_ fps: Int) {
        let range = native.intRange(cameraID, POA_FRAME_LIMIT)
        let value = fps <= CaptureLayout.unlimitedReadoutFPS
            ? CaptureLayout.stackingReadoutFPS(range: range)
            : CaptureLayout.clampedReadoutFPS(range: range)
        try? native.setInt(cameraID, POA_FRAME_LIMIT, value)
    }

    func applyROI(_ roi: ROI) throws {
        if roi == currentROI { return }
        let wasStreaming = streaming
        if wasStreaming { stopVideo() }
        try native.setBin(cameraID, roi.binning)
        try native.setSize(cameraID, width: roi.width, height: roi.height)
        try native.setStartPos(cameraID, x: roi.x, y: roi.y)
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
        let bytesPerPixel = format == POA_RAW16 ? 2 : 1
        let size = currentROI.width * currentROI.height * bytesPerPixel
        if grabBuffer.count < size {
            grabBuffer = Data(count: size)
        }
        try grabBuffer.withUnsafeMutableBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                throw CameraError.sdk(vendor: .playerOne, code: -1, message: "Failed to allocate frame buffer")
            }
            try native.grab(cameraID, buffer: base, size: size, timeoutMs: timeoutMs) { [weak self] in
                guard let self else { return true }
                self.grabLock.lock()
                let cancelled = self.grabCancelled
                self.grabLock.unlock()
                return cancelled
            }
        }
        let pixelCount = currentROI.width * currentROI.height
        var pixels = [UInt16](repeating: 0, count: pixelCount)
        pixels.withUnsafeMutableBytes { dest in
            grabBuffer.withUnsafeBytes { src in
                guard let d = dest.baseAddress, let s = src.baseAddress else { return }
                if format == POA_RAW16 {
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

    private func cString<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return "" }
            return String(cString: base)
        }
    }
}
