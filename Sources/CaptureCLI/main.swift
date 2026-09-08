import CollimationCore
import Foundation

@main
struct CaptureCLI {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.contains("-h") || args.contains("--help") {
            printUsage()
            return
        }

        if args.contains("--list") {
            listDevices()
            return
        }

        let deviceID = value(of: "--device", in: args)
        let useSimulator = deviceID == nil
            && (args.contains("--simulator") || !args.contains("--hardware"))
        let output = outputPath(from: args) ?? "frame.tif"
        try capture(output: output, deviceID: deviceID, simulator: useSimulator)
    }

    private static func printUsage() {
        print("""
        capture-cli — grab one frame from a Player One or ZWO camera, or the simulator.

        Usage:
          capture-cli --list
          capture-cli [--simulator|--hardware] [--device <id>] [--output frame.tif]

        Camera SDK libraries are loaded at run time from Vendor/PlayerOne and
        Vendor/ZWO, or from next to the executable. Without a camera, use
        --simulator. Device ids come from --list, for example poa-0 or asi-0.
        The output is a 16-bit mono TIFF.
        """)
    }

    private static func listDevices() {
        if let version = DeviceCatalog.playerOneSDKVersion {
            print("Player One SDK \(version)")
        } else {
            print("Player One SDK not loaded")
        }
        if let version = DeviceCatalog.zwoSDKVersion {
            print("ZWO ASI SDK \(version)")
        } else {
            print("ZWO ASI SDK not loaded")
        }
        for device in DeviceCatalog.list() {
            print("\(device.id)\t\(device.name)\t\(device.sensorWidth)x\(device.sensorHeight)")
        }
    }

    private static func value(of flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else {
            return nil
        }
        return args[index + 1]
    }

    private static func outputPath(from args: [String]) -> String? {
        if let path = value(of: "--output", in: args) { return path }
        let flagValues = Set([value(of: "--device", in: args)].compactMap { $0 })
        return args.first { !$0.hasPrefix("-") && !flagValues.contains($0) }
    }

    private static func capture(output: String, deviceID: String?, simulator: Bool) throws {
        let device: CameraDevice
        if let deviceID {
            device = try DeviceCatalog.makeDevice(id: deviceID)
        } else if simulator {
            device = SimulatorCamera()
        } else {
            guard let hardware = DeviceCatalog.list().first(where: { !$0.isSimulator }) else {
                throw CameraError.notConnected
            }
            device = try DeviceCatalog.makeDevice(id: hardware.id)
        }
        try device.open()
        defer { device.close() }
        try device.startVideo()
        defer { device.stopVideo() }
        let frame = try device.grabFrame(timeoutMs: 5000)
        try MonoTIFF.write(frame: frame, to: URL(fileURLWithPath: output))
        print("Wrote \(output) (\(frame.width)x\(frame.height), ROI \(frame.roi.width)x\(frame.roi.height) bin\(frame.roi.binning))")
    }
}
