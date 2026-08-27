import Darwin
import Foundation
import POACameraC

final class POAPWNative: @unchecked Sendable {
    static let shared: POAPWNative? = {
        do {
            return try POAPWNative()
        } catch {
            return nil
        }
    }()

    private let handle: UnsafeMutableRawPointer

    private let getPWCount: @convention(c) () -> Int32
    private let getPWProperties: @convention(c) (Int32, UnsafeMutablePointer<PWProperties>) -> PWErrors
    private let openPW: @convention(c) (Int32) -> PWErrors
    private let closePW: @convention(c) (Int32) -> PWErrors
    private let getCurrentPosition: @convention(c) (Int32, UnsafeMutablePointer<Int32>) -> PWErrors
    private let gotoPosition: @convention(c) (Int32, Int32) -> PWErrors
    private let setOneWay: @convention(c) (Int32, Int32) -> PWErrors
    private let getPWState: @convention(c) (Int32, UnsafeMutablePointer<PWState>) -> PWErrors
    private let getFilterAlias: @convention(c) (Int32, Int32, UnsafeMutablePointer<CChar>, Int32) -> PWErrors
    private let resetPW: @convention(c) (Int32) -> PWErrors
    private let getErrorString: @convention(c) (PWErrors) -> UnsafePointer<CChar>?
    private let getSDKVersion: @convention(c) () -> UnsafePointer<CChar>?

    var sdkVersion: String {
        guard let ptr = getSDKVersion() else { return "unknown" }
        return String(cString: ptr)
    }

    private init() throws {
        guard let handle = Self.openLibrary() else { throw FilterWheelError.sdkNotFound }
        self.handle = handle

        func symbol<T>(_ name: String) throws -> T {
            guard let raw = dlsym(handle, name) else {
                throw FilterWheelError.sdkSymbolMissing(name)
            }
            return unsafeBitCast(raw, to: T.self)
        }

        getPWCount = try symbol("POAGetPWCount")
        getPWProperties = try symbol("POAGetPWProperties")
        openPW = try symbol("POAOpenPW")
        closePW = try symbol("POAClosePW")
        getCurrentPosition = try symbol("POAGetCurrentPosition")
        gotoPosition = try symbol("POAGotoPosition")
        setOneWay = try symbol("POASetOneWay")
        getPWState = try symbol("POAGetPWState")
        getFilterAlias = try symbol("POAGetPWFilterAlias")
        resetPW = try symbol("POAResetPW")
        getErrorString = try symbol("POAGetPWErrorString")
        getSDKVersion = try symbol("POAGetPWSDKVer")
    }

    func enumerate() -> [FilterWheelDescriptor] {
        let count = Int(getPWCount())
        var result: [FilterWheelDescriptor] = []
        for index in 0..<count {
            var props = PWProperties()
            let err = getPWProperties(Int32(index), &props)
            guard err == PW_OK else { continue }
            let serial = cString(props.SN)
            let name = cString(props.Name)
            let id = serial.isEmpty ? "pw-\(props.Handle)" : "pw-\(serial)"
            result.append(
                FilterWheelDescriptor(
                    id: id,
                    name: name.isEmpty ? "Phoenix Filter Wheel" : name,
                    handle: props.Handle,
                    positionCount: Int(props.PositionCount),
                    serialNumber: serial
                )
            )
        }
        return result
    }

    func check(_ error: PWErrors) throws {
        if error == PW_OK { return }
        if error == PW_ERROR_NOT_FOUND || error == PW_ERROR_INVALID_HANDLE {
            throw FilterWheelError.disconnected
        }
        if error == PW_ERROR_NOT_OPENED {
            throw FilterWheelError.notConnected
        }
        if error == PW_ERROR_IS_MOVING {
            throw FilterWheelError.moving
        }
        if error == PW_ERROR_INVALID_ARGU || error == PW_ERROR_INVALID_INDEX {
            throw FilterWheelError.invalidPosition
        }
        if error == PW_ERROR_FIRMWARE_ERROR {
            throw FilterWheelError.firmware
        }
        let message: String
        if let ptr = getErrorString(error) {
            message = String(cString: ptr)
        } else {
            message = "Player One filter wheel error \(error.rawValue)"
        }
        throw FilterWheelError.pw(code: Int32(error.rawValue), message: message)
    }

    func open(_ id: Int32) throws { try check(openPW(id)) }
    func close(_ id: Int32) { _ = closePW(id) }

    func state(_ id: Int32) throws -> PWState {
        var state = PW_STATE_CLOSED
        try check(getPWState(id, &state))
        return state
    }

    func position(_ id: Int32) throws -> Int {
        var value: Int32 = 0
        try check(getCurrentPosition(id, &value))
        return Int(value)
    }

    func goto(_ id: Int32, position: Int) throws {
        try check(gotoPosition(id, Int32(position)))
    }

    func setBidirectional(_ id: Int32) {
        _ = setOneWay(id, 0)
    }

    func reset(_ id: Int32) {
        _ = resetPW(id)
    }

    func alias(_ id: Int32, position: Int) -> String {
        var buf = [CChar](repeating: 0, count: Int(MAX_NAME_LEN) + 1)
        let err = buf.withUnsafeMutableBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return PW_ERROR_POINTER }
            return getFilterAlias(id, Int32(position), base, Int32(ptr.count))
        }
        guard err == PW_OK else { return "" }
        return buf.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return "" }
            return String(cString: base)
        }
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
        return dlopen("libPlayerOnePW.dylib", RTLD_NOW | RTLD_LOCAL)
    }

    private static func candidatePaths() -> [String] {
        var paths: [String] = []
        if let frameworks = Bundle.main.privateFrameworksPath {
            paths.append(frameworks + "/libPlayerOnePW.dylib")
        }
        if let exe = Bundle.main.executablePath {
            let url = URL(fileURLWithPath: exe)
            paths.append(url.deletingLastPathComponent().appendingPathComponent("libPlayerOnePW.dylib").path)
            paths.append(
                url.deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appendingPathComponent("Frameworks/libPlayerOnePW.dylib").path
            )
        }
        let cwd = FileManager.default.currentDirectoryPath
        paths.append(cwd + "/Vendor/PlayerOne/libPlayerOnePW.dylib")
        paths.append(cwd + "/libPlayerOnePW.dylib")
        paths.append("/usr/local/lib/libPlayerOnePW.dylib")
        paths.append((NSHomeDirectory() as NSString).appendingPathComponent("Library/PlayerOne/libPlayerOnePW.dylib"))
        return paths
    }
}
