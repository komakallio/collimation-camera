import Foundation

public struct CameraDescriptor: Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var sensorWidth: Int
    public var sensorHeight: Int
    public var pixelSizeMicrons: Double
    public var isSimulator: Bool
    public var hardwareID: Int32?

    public init(
        id: String,
        name: String,
        sensorWidth: Int,
        sensorHeight: Int,
        pixelSizeMicrons: Double,
        isSimulator: Bool,
        hardwareID: Int32? = nil
    ) {
        self.id = id
        self.name = name
        self.sensorWidth = sensorWidth
        self.sensorHeight = sensorHeight
        self.pixelSizeMicrons = pixelSizeMicrons
        self.isSimulator = isSimulator
        self.hardwareID = hardwareID
    }

    public static let simulator = CameraDescriptor(
        id: "simulator",
        name: "Simulator (defocused donut)",
        sensorWidth: 6252,
        sensorHeight: 4176,
        pixelSizeMicrons: 3.76,
        isSimulator: true
    )

    public static let airySimulator = CameraDescriptor(
        id: "simulator-airy",
        name: "Simulator (Airy)",
        sensorWidth: 6252,
        sensorHeight: 4176,
        pixelSizeMicrons: 3.76,
        isSimulator: true
    )
}

public struct CameraControls: Equatable, Sendable {
    public var exposureMicroseconds: Int
    public var gain: Int
    public var exposureRange: ClosedRange<Int>
    public var gainRange: ClosedRange<Int>

    public init(
        exposureMicroseconds: Int = 50_000,
        gain: Int = 0,
        exposureRange: ClosedRange<Int> = ExposureControl.range,
        gainRange: ClosedRange<Int> = 0...400
    ) {
        self.exposureMicroseconds = exposureMicroseconds
        self.gain = gain
        self.exposureRange = exposureRange
        self.gainRange = gainRange
    }
}

public protocol CameraDevice: AnyObject {
    var descriptor: CameraDescriptor { get }
    var controls: CameraControls { get }
    var currentROI: ROI { get }
    var supportedBins: [Int] { get }
    /// ROI granularity this camera accepts. Player One and ZWO differ (§7.5).
    var roiAlignment: ROIAlignment { get }

    func open() throws
    func close()
    func applyExposure(_ microseconds: Int) throws
    func applyGain(_ gain: Int) throws
    func applyROI(_ roi: ROI) throws
    func startVideo() throws
    func stopVideo()
    func grabFrame(timeoutMs: Int) throws -> Frame
    func cancelGrab()
    /// Soft frame-rate cap. `0` means unlimited where the camera supports it.
    func applyFrameLimit(_ fps: Int)
    /// Whether the camera is still on the bus.
    ///
    /// An unplugged camera does not report an error: it simply stops saying a
    /// frame is ready, which is indistinguishable from a slow one. Asking the
    /// SDK to enumerate is what tells the two apart, so the capture loop calls
    /// this after a run of timeouts rather than guessing. Only called when
    /// something already looks wrong, since enumerating mid-stream is not free.
    func isStillPresent() -> Bool
}

extension CameraDevice {
    public func cancelGrab() {}
    public func applyFrameLimit(_ fps: Int) {}
    public var roiAlignment: ROIAlignment { .playerOne }
    /// The simulator cannot be unplugged, and a device that cannot tell should
    /// not claim its camera has gone.
    public func isStillPresent() -> Bool { true }
}

public enum DeviceCatalog {
    /// Device-id prefix per vendor. Ids are `poa-<cameraID>` and `asi-<CameraID>`.
    static func idPrefix(_ vendor: CameraVendor) -> String {
        switch vendor {
        case .playerOne: return "poa-"
        case .zwo: return "asi-"
        }
    }

    public static var playerOneSDKVersion: String? {
        POANative.shared?.sdkVersion
    }

    public static var zwoSDKVersion: String? {
        ASINative.shared?.sdkVersion
    }

    /// Both SDK versions, in vendor order, for the disconnected status line.
    public static var sdkVersionSummary: String? {
        var parts: [String] = []
        if let version = playerOneSDKVersion {
            parts.append("POA \(version)")
        }
        if let version = zwoSDKVersion {
            parts.append("ASI \(version)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    public static func list() -> [CameraDescriptor] {
        var devices: [CameraDescriptor] = []
        if let native = POANative.shared {
            devices.append(contentsOf: native.enumerate())
        }
        if let native = ASINative.shared {
            devices.append(contentsOf: native.enumerate())
        }
        devices.append(.simulator)
        devices.append(.airySimulator)
        return devices
    }

    public static func preferredDeviceID(in devices: [CameraDescriptor]) -> String {
        devices.first(where: { !$0.isSimulator })?.id ?? CameraDescriptor.simulator.id
    }

    /// The vendor a hardware device id belongs to, or nil for the simulators
    /// and for ids that match no vendor.
    public static func vendor(forID id: String) -> CameraVendor? {
        for vendor in CameraVendor.allCases where id.hasPrefix(idPrefix(vendor)) {
            let suffix = id.dropFirst(idPrefix(vendor).count)
            guard !suffix.isEmpty, Int32(suffix) != nil else { return nil }
            return vendor
        }
        return nil
    }

    public static func makeDevice(id: String) throws -> CameraDevice {
        if id == CameraDescriptor.simulator.id {
            return SimulatorCamera(pattern: .defocusedDonut)
        }
        if id == CameraDescriptor.airySimulator.id {
            return SimulatorCamera(pattern: .airy)
        }
        guard let vendor = vendor(forID: id) else {
            throw CameraError.unsupported("Unknown camera id \(id)")
        }
        guard let hardwareID = Int32(id.dropFirst(idPrefix(vendor).count)) else {
            throw CameraError.unsupported("Unknown camera id \(id)")
        }
        switch vendor {
        case .playerOne:
            guard let native = POANative.shared else {
                throw CameraError.sdkNotFound(vendor: .playerOne)
            }
            return POACameraDevice(native: native, cameraID: hardwareID)
        case .zwo:
            guard let native = ASINative.shared else {
                throw CameraError.sdkNotFound(vendor: .zwo)
            }
            return ASICameraDevice(native: native, cameraID: hardwareID)
        }
    }
}
