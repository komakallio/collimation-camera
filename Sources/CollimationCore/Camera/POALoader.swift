import Darwin
import Foundation
import POACameraC

final class POANative: @unchecked Sendable {
    static let shared: POANative? = {
        do {
            return try POANative()
        } catch {
            return nil
        }
    }()

    private let handle: UnsafeMutableRawPointer

    private let getCameraCount: @convention(c) () -> Int32
    private let getCameraProperties: @convention(c) (Int32, UnsafeMutablePointer<POACameraProperties>) -> POAErrors
    private let openCamera: @convention(c) (Int32) -> POAErrors
    private let initCamera: @convention(c) (Int32) -> POAErrors
    private let closeCamera: @convention(c) (Int32) -> POAErrors
    private let setConfig: @convention(c) (Int32, POAConfig, POAConfigValue, POABool) -> POAErrors
    private let getConfig: @convention(c) (Int32, POAConfig, UnsafeMutablePointer<POAConfigValue>, UnsafeMutablePointer<POABool>) -> POAErrors
    private let getConfigAttributesByConfigID: @convention(c) (Int32, POAConfig, UnsafeMutablePointer<POAConfigAttributes>) -> POAErrors
    private let getImageStartPos: @convention(c) (Int32, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> POAErrors
    private let setImageStartPos: @convention(c) (Int32, Int32, Int32) -> POAErrors
    private let getImageSize: @convention(c) (Int32, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> POAErrors
    private let setImageSize: @convention(c) (Int32, Int32, Int32) -> POAErrors
    private let getImageBin: @convention(c) (Int32, UnsafeMutablePointer<Int32>) -> POAErrors
    private let setImageBin: @convention(c) (Int32, Int32) -> POAErrors
    private let getImageFormat: @convention(c) (Int32, UnsafeMutablePointer<POAImgFormat>) -> POAErrors
    private let setImageFormat: @convention(c) (Int32, POAImgFormat) -> POAErrors
    private let startExposure: @convention(c) (Int32, POABool) -> POAErrors
    private let stopExposure: @convention(c) (Int32) -> POAErrors
    private let imageReady: @convention(c) (Int32, UnsafeMutablePointer<POABool>) -> POAErrors
    private let getImageData: @convention(c) (Int32, UnsafeMutablePointer<UInt8>, Int, Int32) -> POAErrors
    private let getErrorString: @convention(c) (POAErrors) -> UnsafePointer<CChar>?
    private let getSDKVersion: @convention(c) () -> UnsafePointer<CChar>?

    var sdkVersion: String {
        guard let ptr = getSDKVersion() else { return "unknown" }
        return String(cString: ptr)
    }

    private init() throws {
        guard let handle = Self.openLibrary() else { throw CameraError.sdkNotFound }
        self.handle = handle

        func symbol<T>(_ name: String) throws -> T {
            guard let raw = dlsym(handle, name) else {
                throw CameraError.sdkSymbolMissing(name)
            }
            return unsafeBitCast(raw, to: T.self)
        }

        getCameraCount = try symbol("POAGetCameraCount")
        getCameraProperties = try symbol("POAGetCameraProperties")
        openCamera = try symbol("POAOpenCamera")
        initCamera = try symbol("POAInitCamera")
        closeCamera = try symbol("POACloseCamera")
        setConfig = try symbol("POASetConfig")
        getConfig = try symbol("POAGetConfig")
        getConfigAttributesByConfigID = try symbol("POAGetConfigAttributesByConfigID")
        getImageStartPos = try symbol("POAGetImageStartPos")
        setImageStartPos = try symbol("POASetImageStartPos")
        getImageSize = try symbol("POAGetImageSize")
        setImageSize = try symbol("POASetImageSize")
        getImageBin = try symbol("POAGetImageBin")
        setImageBin = try symbol("POASetImageBin")
        getImageFormat = try symbol("POAGetImageFormat")
        setImageFormat = try symbol("POASetImageFormat")
        startExposure = try symbol("POAStartExposure")
        stopExposure = try symbol("POAStopExposure")
        imageReady = try symbol("POAImageReady")
        getImageData = try symbol("POAGetImageData")
        getErrorString = try symbol("POAGetErrorString")
        getSDKVersion = try symbol("POAGetSDKVersion")
    }

    func enumerate() -> [CameraDescriptor] {
        let count = Int(getCameraCount())
        var result: [CameraDescriptor] = []
        for index in 0..<count {
            var props = POACameraProperties()
            let err = getCameraProperties(Int32(index), &props)
            guard err == POA_OK else { continue }
            var bins: [Int] = []
            withUnsafeBytes(of: props.bins) { raw in
                let values = raw.bindMemory(to: Int32.self)
                for v in values where v > 0 {
                    bins.append(Int(v))
                }
            }
            _ = bins
            result.append(
                CameraDescriptor(
                    id: "poa-\(props.cameraID)",
                    name: cString(props.cameraModelName),
                    sensorWidth: Int(props.maxWidth),
                    sensorHeight: Int(props.maxHeight),
                    pixelSizeMicrons: props.pixelSize,
                    isSimulator: false,
                    hardwareID: props.cameraID
                )
            )
        }
        return result
    }

    func check(_ error: POAErrors) throws {
        if error == POA_OK { return }
        let message: String
        if let ptr = getErrorString(error) {
            message = String(cString: ptr)
        } else {
            message = "Player One error \(error.rawValue)"
        }
        if error == POA_ERROR_DEVICE_NOT_FOUND || error == POA_ERROR_OPERATION_FAILED {
            throw CameraError.disconnected
        }
        if error == POA_ERROR_TIMEOUT {
            throw CameraError.timeout
        }
        throw CameraError.poa(code: Int32(error.rawValue), message: message)
    }

    func open(_ id: Int32) throws { try check(openCamera(id)) }
    func initialize(_ id: Int32) throws { try check(initCamera(id)) }
    func close(_ id: Int32) { _ = closeCamera(id) }

    func setInt(_ id: Int32, _ config: POAConfig, _ value: Int, auto: Bool = false) throws {
        var v = POAConfigValue()
        v.intValue = value
        try check(setConfig(id, config, v, auto ? POA_TRUE : POA_FALSE))
    }

    func getInt(_ id: Int32, _ config: POAConfig) throws -> Int {
        var v = POAConfigValue()
        var isAuto = POA_FALSE
        try check(getConfig(id, config, &v, &isAuto))
        return Int(v.intValue)
    }

    func intRange(_ id: Int32, _ config: POAConfig) -> ClosedRange<Int>? {
        var attrs = POAConfigAttributes()
        let err = getConfigAttributesByConfigID(id, config, &attrs)
        guard err == POA_OK else { return nil }
        let lo = Int(attrs.minValue.intValue)
        let hi = Int(attrs.maxValue.intValue)
        guard hi >= lo else { return nil }
        return lo...hi
    }

    func setStartPos(_ id: Int32, x: Int, y: Int) throws {
        try check(setImageStartPos(id, Int32(x), Int32(y)))
    }

    func setSize(_ id: Int32, width: Int, height: Int) throws {
        try check(setImageSize(id, Int32(width), Int32(height)))
    }

    func setBin(_ id: Int32, _ bin: Int) throws {
        try check(setImageBin(id, Int32(bin)))
    }

    func setFormat(_ id: Int32, _ format: POAImgFormat) throws {
        try check(setImageFormat(id, format))
    }

    func currentROI(_ id: Int32) throws -> ROI {
        var x: Int32 = 0, y: Int32 = 0, w: Int32 = 0, h: Int32 = 0, bin: Int32 = 1
        try check(getImageStartPos(id, &x, &y))
        try check(getImageSize(id, &w, &h))
        try check(getImageBin(id, &bin))
        return ROI(x: Int(x), y: Int(y), width: Int(w), height: Int(h), binning: Int(bin))
    }

    func startVideo(_ id: Int32) throws {
        try check(startExposure(id, POA_FALSE))
    }

    func stopVideo(_ id: Int32) {
        _ = stopExposure(id)
    }

    func grab(_ id: Int32, buffer: UnsafeMutablePointer<UInt8>, size: Int, timeoutMs: Int) throws {
        try check(getImageData(id, buffer, size, Int32(timeoutMs)))
    }

    func currentFormat(_ id: Int32) throws -> POAImgFormat {
        var format = POA_RAW16
        try check(getImageFormat(id, &format))
        return format
    }

    func properties(_ id: Int32) -> POACameraProperties? {
        let count = Int(getCameraCount())
        for index in 0..<count {
            var props = POACameraProperties()
            if getCameraProperties(Int32(index), &props) == POA_OK, props.cameraID == id {
                return props
            }
        }
        return nil
    }

    private func cString<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return "" }
            return String(cString: base)
        }
    }

    private static func openLibrary() -> UnsafeMutableRawPointer? {
        for path in candidatePaths() {
            if let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) {
                return handle
            }
        }
        return dlopen("libPlayerOneCamera.dylib", RTLD_NOW | RTLD_LOCAL)
    }

    private static func candidatePaths() -> [String] {
        var paths: [String] = []
        if let frameworks = Bundle.main.privateFrameworksPath {
            paths.append(frameworks + "/libPlayerOneCamera.dylib")
        }
        if let exe = Bundle.main.executablePath {
            let url = URL(fileURLWithPath: exe)
            paths.append(url.deletingLastPathComponent().appendingPathComponent("libPlayerOneCamera.dylib").path)
            paths.append(
                url.deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appendingPathComponent("Frameworks/libPlayerOneCamera.dylib").path
            )
        }
        let cwd = FileManager.default.currentDirectoryPath
        paths.append(cwd + "/Vendor/PlayerOne/libPlayerOneCamera.dylib")
        paths.append(cwd + "/libPlayerOneCamera.dylib")
        paths.append("/usr/local/lib/libPlayerOneCamera.dylib")
        paths.append((NSHomeDirectory() as NSString).appendingPathComponent("Library/PlayerOne/libPlayerOneCamera.dylib"))
        return paths
    }
}
