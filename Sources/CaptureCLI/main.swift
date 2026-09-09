import CollimationCore
import Foundation

@main
struct CaptureCLI {
    static func main() throws {
        // Every wait in this process rounds up to the process timer resolution
        // on Windows, which is 15.6 ms until something asks for better. The apps
        // get this from SDL_Init; a command-line tool has to ask (§6.2).
        TimerResolution.raise()

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
        let exposure = value(of: "--exposure", in: args).flatMap(Double.init)
        let gain = value(of: "--gain", in: args).flatMap(Int.init)
        let roiSize = value(of: "--roi", in: args).flatMap(Int.init)

        if let frames = value(of: "--frames", in: args).flatMap(Int.init) {
            try benchmark(
                frames: max(1, frames),
                deviceID: deviceID,
                simulator: useSimulator,
                exposureMilliseconds: exposure,
                gain: gain,
                roiSize: roiSize
            )
            return
        }

        let output = outputPath(from: args) ?? "frame.tif"
        try capture(
            output: output,
            deviceID: deviceID,
            simulator: useSimulator,
            exposureMilliseconds: exposure,
            gain: gain,
            roiSize: roiSize
        )
    }

    private static func printUsage() {
        print("""
        capture-cli — grab frames from a Player One or ZWO camera, or the simulator.

        Usage:
          capture-cli --list
          capture-cli [--simulator|--hardware] [--device <id>] [--output frame.tif]
          capture-cli --frames <n> [--device <id>] [--exposure <ms>] [--gain <n>] [--roi <px>]

        Options:
          --frames <n>     grab n frames and report the rate, instead of writing one
          --exposure <ms>  exposure in milliseconds
          --gain <n>       gain in the camera's own units
          --roi <px>       square ROI centered on the sensor, rounded to what the
                           camera accepts; 2048 is what the app uses while tracking

        Camera SDK libraries are loaded at run time from Vendor/PlayerOne and
        Vendor/ZWO, or from next to the executable. Without a camera, use
        --simulator. Device ids come from --list, for example poa-0 or asi-0.
        The output is a 16-bit mono TIFF.

        --frames is the headless version of the live-view rate check: it needs
        no window, so it works over a remote desktop session.
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

    private static func makeDevice(deviceID: String?, simulator: Bool) throws -> CameraDevice {
        if let deviceID {
            return try DeviceCatalog.makeDevice(id: deviceID)
        }
        if simulator {
            return SimulatorCamera()
        }
        guard let hardware = DeviceCatalog.list().first(where: { !$0.isSimulator }) else {
            throw CameraError.notConnected
        }
        return try DeviceCatalog.makeDevice(id: hardware.id)
    }

    /// Applies whatever the caller asked for, in the order the app uses:
    /// exposure and gain first, then the ROI, since the ROI can change the
    /// rate the camera will accept.
    private static func configure(
        _ device: CameraDevice,
        exposureMilliseconds: Double?,
        gain: Int?,
        roiSize: Int?
    ) throws {
        if let exposureMilliseconds {
            try device.applyExposure(Int((exposureMilliseconds * 1000).rounded()))
        }
        if let gain {
            try device.applyGain(gain)
        }
        if let roiSize {
            let descriptor = device.descriptor
            let roi = Alignment.centeredROI(
                around: SIMD2(Double(descriptor.sensorWidth) / 2, Double(descriptor.sensorHeight) / 2),
                size: roiSize,
                sensorWidth: descriptor.sensorWidth,
                sensorHeight: descriptor.sensorHeight,
                alignment: device.roiAlignment
            )
            try device.applyROI(roi)
        }
    }

    private static func capture(
        output: String,
        deviceID: String?,
        simulator: Bool,
        exposureMilliseconds: Double?,
        gain: Int?,
        roiSize: Int?
    ) throws {
        let device = try makeDevice(deviceID: deviceID, simulator: simulator)
        try device.open()
        defer { device.close() }
        try configure(device, exposureMilliseconds: exposureMilliseconds, gain: gain, roiSize: roiSize)
        try device.startVideo()
        defer { device.stopVideo() }
        let frame = try device.grabFrame(timeoutMs: 5000)
        try MonoTIFF.write(frame: frame, to: URL(fileURLWithPath: output))
        print("Wrote \(output) (\(frame.width)x\(frame.height), ROI \(frame.roi.width)x\(frame.roi.height) bin\(frame.roi.binning))")
    }

    /// Grabs `frames` frames and reports the rate. The first grab is excluded
    /// from the timing: it carries the stream start-up, which is not part of
    /// the steady-state rate the acceptance checks are about.
    private static func benchmark(
        frames: Int,
        deviceID: String?,
        simulator: Bool,
        exposureMilliseconds: Double?,
        gain: Int?,
        roiSize: Int?
    ) throws {
        let device = try makeDevice(deviceID: deviceID, simulator: simulator)
        try device.open()
        defer { device.close() }
        try configure(device, exposureMilliseconds: exposureMilliseconds, gain: gain, roiSize: roiSize)

        let controls = device.controls
        let roi = device.currentROI
        print("\(device.descriptor.name): ROI \(roi.width)x\(roi.height) bin\(roi.binning) at \(roi.x),\(roi.y)")
        print("exposure \(Double(controls.exposureMicroseconds) / 1000) ms, gain \(controls.gain)")

        try device.startVideo()
        defer { device.stopVideo() }

        var intervals: [Double] = []
        intervals.reserveCapacity(frames)
        var last = Date()
        var lastFrame: Frame?
        for index in 0..<frames {
            let frame = try device.grabFrame(timeoutMs: 5000)
            let now = Date()
            if index > 0 { intervals.append(now.timeIntervalSince(last)) }
            last = now
            lastFrame = frame
        }

        guard !intervals.isEmpty else {
            print("one frame only; ask for --frames 2 or more to measure a rate")
            return
        }
        let total = intervals.reduce(0, +)
        let mean = total / Double(intervals.count)
        let low = intervals.min() ?? 0
        let high = intervals.max() ?? 0
        print(String(format: "%d frames in %.2f s", intervals.count + 1, total))
        print(String(format: "rate %.1f fps (interval mean %.1f ms, min %.1f, max %.1f)",
                     1 / mean, mean * 1000, low * 1000, high * 1000))

        if let lastFrame {
            let low = lastFrame.pixels.min() ?? 0
            let high = lastFrame.pixels.max() ?? 0
            print("last frame \(lastFrame.width)x\(lastFrame.height), ADU \(low) to \(high)")
            if high >= StarQuality.clipADU {
                print("clipped: lower the exposure or the gain")
            }
        }
    }
}
