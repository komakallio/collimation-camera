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
        name: "Simulator (Poseidon-M)",
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

    func open() throws
    func close()
    func applyExposure(_ microseconds: Int) throws
    func applyGain(_ gain: Int) throws
    func applyROI(_ roi: ROI) throws
    func startVideo() throws
    func stopVideo()
    func grabFrame(timeoutMs: Int) throws -> Frame
    func cancelGrab()
}

extension CameraDevice {
    public func cancelGrab() {}
}

public enum DeviceCatalog {
    public static var playerOneSDKVersion: String? {
        POANative.shared?.sdkVersion
    }

    public static func list() -> [CameraDescriptor] {
        var devices: [CameraDescriptor] = []
        if let native = POANative.shared {
            devices.append(contentsOf: native.enumerate())
        }
        devices.append(.simulator)
        return devices
    }

    public static func preferredDeviceID(in devices: [CameraDescriptor]) -> String {
        devices.first(where: { !$0.isSimulator })?.id ?? CameraDescriptor.simulator.id
    }

    public static func makeDevice(id: String) throws -> CameraDevice {
        if id == CameraDescriptor.simulator.id {
            return SimulatorCamera()
        }
        guard let native = POANative.shared else { throw CameraError.sdkNotFound }
        let hardwareID = Int32(id.replacingOccurrences(of: "poa-", with: ""))
        guard let hardwareID else { throw CameraError.unsupported("Unknown camera id \(id)") }
        return POACameraDevice(native: native, cameraID: hardwareID)
    }
}
