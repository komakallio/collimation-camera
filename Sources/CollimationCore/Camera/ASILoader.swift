import ASICameraC
import Foundation

/// Runtime binding to the ZWO ASI camera SDK. Mirrors `POANative`: the app
/// links nothing, so a missing SDK is a status message rather than a launch
/// failure. All entry points are cdecl.
public final class ASINative: @unchecked Sendable {
    static let shared: ASINative? = {
        do {
            return try ASINative()
        } catch {
            return nil
        }
    }()

    private let library: DynamicLibrary

    private let getNumOfConnectedCameras: @convention(c) () -> Int32
    private let getCameraProperty: @convention(c) (UnsafeMutablePointer<ASI_CAMERA_INFO>, Int32) -> ASI_ERROR_CODE
    private let openCamera: @convention(c) (Int32) -> ASI_ERROR_CODE
    private let initCamera: @convention(c) (Int32) -> ASI_ERROR_CODE
    private let closeCamera: @convention(c) (Int32) -> ASI_ERROR_CODE
    private let getNumOfControls: @convention(c) (Int32, UnsafeMutablePointer<Int32>) -> ASI_ERROR_CODE
    private let getControlCaps: @convention(c) (Int32, Int32, UnsafeMutablePointer<ASI_CONTROL_CAPS>) -> ASI_ERROR_CODE
    private let getControlValue: @convention(c) (Int32, ASI_CONTROL_TYPE, UnsafeMutablePointer<CLong>, UnsafeMutablePointer<ASI_BOOL>) -> ASI_ERROR_CODE
    private let setControlValue: @convention(c) (Int32, ASI_CONTROL_TYPE, CLong, ASI_BOOL) -> ASI_ERROR_CODE
    private let setROIFormatFn: @convention(c) (Int32, Int32, Int32, Int32, ASI_IMG_TYPE) -> ASI_ERROR_CODE
    private let getROIFormatFn: @convention(c) (Int32, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<ASI_IMG_TYPE>) -> ASI_ERROR_CODE
    private let setStartPosFn: @convention(c) (Int32, Int32, Int32) -> ASI_ERROR_CODE
    private let getStartPosFn: @convention(c) (Int32, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> ASI_ERROR_CODE
    private let startVideoCapture: @convention(c) (Int32) -> ASI_ERROR_CODE
    private let stopVideoCapture: @convention(c) (Int32) -> ASI_ERROR_CODE
    private let getVideoData: @convention(c) (Int32, UnsafeMutablePointer<UInt8>, CLong, Int32) -> ASI_ERROR_CODE
    private let getDroppedFramesFn: @convention(c) (Int32, UnsafeMutablePointer<Int32>) -> ASI_ERROR_CODE
    private let getSDKVersion: @convention(c) () -> UnsafePointer<CChar>?

    var sdkVersion: String {
        guard let ptr = getSDKVersion() else { return "unknown" }
        return String(cString: ptr)
    }

    private init() throws {
        guard let library = DynamicLibrary(
            candidates: DynamicLibrary.candidatePaths(
                fileName: VendorLibrary.zwoCamera,
                vendorFolder: VendorLibrary.zwoFolder
            ),
            bareName: VendorLibrary.zwoCamera
        ) else {
            throw CameraError.sdkNotFound(vendor: .zwo)
        }
        self.library = library

        func symbol<T>(_ name: String) throws -> T {
            guard let resolved: T = library.symbol(name) else {
                throw CameraError.sdkSymbolMissing(name)
            }
            return resolved
        }

        getNumOfConnectedCameras = try symbol("ASIGetNumOfConnectedCameras")
        getCameraProperty = try symbol("ASIGetCameraProperty")
        openCamera = try symbol("ASIOpenCamera")
        initCamera = try symbol("ASIInitCamera")
        closeCamera = try symbol("ASICloseCamera")
        getNumOfControls = try symbol("ASIGetNumOfControls")
        getControlCaps = try symbol("ASIGetControlCaps")
        getControlValue = try symbol("ASIGetControlValue")
        setControlValue = try symbol("ASISetControlValue")
        setROIFormatFn = try symbol("ASISetROIFormat")
        getROIFormatFn = try symbol("ASIGetROIFormat")
        setStartPosFn = try symbol("ASISetStartPos")
        getStartPosFn = try symbol("ASIGetStartPos")
        startVideoCapture = try symbol("ASIStartVideoCapture")
        stopVideoCapture = try symbol("ASIStopVideoCapture")
        getVideoData = try symbol("ASIGetVideoData")
        getDroppedFramesFn = try symbol("ASIGetDroppedFrames")
        getSDKVersion = try symbol("ASIGetSDKVersion")
    }

    func enumerate() -> [CameraDescriptor] {
        let count = getNumOfConnectedCameras()
        var result: [CameraDescriptor] = []
        var index: Int32 = 0
        while index < count {
            if let info = property(atIndex: index) {
                result.append(descriptor(from: info))
            }
            index += 1
        }
        return result
    }

    func descriptor(from info: ASI_CAMERA_INFO) -> CameraDescriptor {
        CameraDescriptor(
            id: "asi-\(info.CameraID)",
            name: Self.cString(info.Name),
            sensorWidth: Int(info.MaxWidth),
            sensorHeight: Int(info.MaxHeight),
            pixelSizeMicrons: info.PixelSize,
            isSimulator: false,
            hardwareID: info.CameraID
        )
    }

    func property(atIndex index: Int32) -> ASI_CAMERA_INFO? {
        var info = ASI_CAMERA_INFO()
        guard getCameraProperty(&info, index) == ASI_SUCCESS else { return nil }
        return info
    }

    /// `ASIGetCameraProperty` is the only call that takes an index, so the
    /// camera id is matched by scanning the connected cameras.
    func property(forCameraID id: Int32) -> ASI_CAMERA_INFO? {
        let count = getNumOfConnectedCameras()
        var index: Int32 = 0
        while index < count {
            if let info = property(atIndex: index), info.CameraID == id {
                return info
            }
            index += 1
        }
        return nil
    }

    func check(_ error: ASI_ERROR_CODE) throws {
        if let mapped = ASIErrorMapping.cameraError(for: error) { throw mapped }
    }

    /// The SDK has no error-string call, so the messages live here.
    public static func message(for error: ASI_ERROR_CODE) -> String {
        if error == ASI_SUCCESS { return "Success" }
        if error == ASI_ERROR_INVALID_INDEX { return "No ZWO camera at that index" }
        if error == ASI_ERROR_INVALID_ID { return "Invalid ZWO camera id" }
        if error == ASI_ERROR_INVALID_CONTROL_TYPE { return "The camera does not support that control" }
        if error == ASI_ERROR_CAMERA_CLOSED { return "The ZWO camera is not open" }
        if error == ASI_ERROR_CAMERA_REMOVED { return "The ZWO camera was removed" }
        if error == ASI_ERROR_INVALID_PATH { return "Invalid path" }
        if error == ASI_ERROR_INVALID_FILEFORMAT { return "Invalid file format" }
        if error == ASI_ERROR_INVALID_SIZE { return "Invalid ROI size" }
        if error == ASI_ERROR_INVALID_IMGTYPE { return "Invalid image type" }
        if error == ASI_ERROR_OUTOF_BOUNDARY { return "The ROI is outside the sensor" }
        if error == ASI_ERROR_TIMEOUT { return "Timed out waiting for a ZWO frame" }
        if error == ASI_ERROR_INVALID_SEQUENCE { return "Invalid call sequence" }
        if error == ASI_ERROR_BUFFER_TOO_SMALL { return "Frame buffer too small" }
        if error == ASI_ERROR_VIDEO_MODE_ACTIVE { return "Video capture is already running" }
        if error == ASI_ERROR_EXPOSURE_IN_PROGRESS { return "An exposure is in progress" }
        if error == ASI_ERROR_GENERAL_ERROR { return "ZWO SDK general error" }
        if error == ASI_ERROR_INVALID_MODE { return "Invalid camera mode" }
        return "ZWO SDK error \(error.rawValue)"
    }

    func open(_ id: Int32) throws { try check(openCamera(id)) }
    func initialize(_ id: Int32) throws { try check(initCamera(id)) }
    func close(_ id: Int32) { _ = closeCamera(id) }

    func setControl(_ id: Int32, _ control: ASI_CONTROL_TYPE, _ value: Int, auto: Bool = false) throws {
        try check(setControlValue(id, control, CLong(value), auto ? ASI_TRUE : ASI_FALSE))
    }

    func control(_ id: Int32, _ control: ASI_CONTROL_TYPE) throws -> Int {
        var value: CLong = 0
        var isAuto = ASI_FALSE
        try check(getControlValue(id, control, &value, &isAuto))
        return Int(value)
    }

    /// Writable ranges keyed by control, read once at open. Cameras differ in
    /// which controls they expose, so a missing key means "not supported".
    func controlRanges(_ id: Int32) -> [Int32: ClosedRange<Int>] {
        var count: Int32 = 0
        guard getNumOfControls(id, &count) == ASI_SUCCESS else { return [:] }
        var result: [Int32: ClosedRange<Int>] = [:]
        var index: Int32 = 0
        while index < count {
            var caps = ASI_CONTROL_CAPS()
            if getControlCaps(id, index, &caps) == ASI_SUCCESS {
                let lo = Int(caps.MinValue)
                let hi = Int(caps.MaxValue)
                if hi >= lo {
                    result[Int32(caps.ControlType.rawValue)] = lo...hi
                }
            }
            index += 1
        }
        return result
    }

    func setROIFormat(_ id: Int32, width: Int, height: Int, bin: Int, format: ASI_IMG_TYPE) throws {
        try check(setROIFormatFn(id, Int32(width), Int32(height), Int32(bin), format))
    }

    func setStartPosition(_ id: Int32, x: Int, y: Int) throws {
        try check(setStartPosFn(id, Int32(x), Int32(y)))
    }

    func currentROI(_ id: Int32) throws -> ROI {
        var width: Int32 = 0
        var height: Int32 = 0
        var bin: Int32 = 1
        var format = ASI_IMG_RAW16
        try check(getROIFormatFn(id, &width, &height, &bin, &format))
        var x: Int32 = 0
        var y: Int32 = 0
        try check(getStartPosFn(id, &x, &y))
        return ROI(x: Int(x), y: Int(y), width: Int(width), height: Int(height), binning: Int(bin))
    }

    func currentFormat(_ id: Int32) throws -> ASI_IMG_TYPE {
        var width: Int32 = 0
        var height: Int32 = 0
        var bin: Int32 = 1
        var format = ASI_IMG_RAW16
        try check(getROIFormatFn(id, &width, &height, &bin, &format))
        return format
    }

    func startVideo(_ id: Int32) throws { try check(startVideoCapture(id)) }
    func stopVideo(_ id: Int32) { _ = stopVideoCapture(id) }

    func droppedFrames(_ id: Int32) -> Int {
        var value: Int32 = 0
        guard getDroppedFramesFn(id, &value) == ASI_SUCCESS else { return 0 }
        return Int(value)
    }

    /// Blocks up to `waitMs` for one frame. Returns false on
    /// `ASI_ERROR_TIMEOUT` so the caller can check its cancel flag and the
    /// grab deadline between short waits.
    func readVideoData(
        _ id: Int32,
        buffer: UnsafeMutablePointer<UInt8>,
        size: Int,
        waitMs: Int
    ) throws -> Bool {
        let error = getVideoData(id, buffer, CLong(size), Int32(waitMs))
        if error == ASI_SUCCESS { return true }
        if error == ASI_ERROR_TIMEOUT { return false }
        try check(error)
        return false
    }

    static func cString<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return "" }
            return String(cString: base)
        }
    }
}
