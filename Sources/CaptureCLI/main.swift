import AppKit
import CollimationCore
import Foundation
import ImageIO

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

        let useSimulator = args.contains("--simulator") || !args.contains("--hardware")
        let output = outputPath(from: args) ?? "frame.png"
        try capture(output: output, simulator: useSimulator)
    }

    private static func printUsage() {
        print("""
        capture-cli — grab one frame from a Player One camera or the simulator.

        Usage:
          capture-cli --list
          capture-cli [--simulator|--hardware] [--output frame.png]

        The Player One SDK library is loaded from Vendor/PlayerOne/libPlayerOneCamera.dylib
        if present. Without a camera, use --simulator.
        """)
    }

    private static func listDevices() {
        if let version = DeviceCatalog.playerOneSDKVersion {
            print("Player One SDK \(version)")
        } else {
            print("Player One SDK not loaded (simulator still available)")
        }
        for device in DeviceCatalog.list() {
            print("\(device.id)\t\(device.name)\t\(device.sensorWidth)x\(device.sensorHeight)")
        }
    }

    private static func outputPath(from args: [String]) -> String? {
        if let index = args.firstIndex(of: "--output"), args.indices.contains(index + 1) {
            return args[index + 1]
        }
        return args.first { !$0.hasPrefix("-") }
    }

    private static func capture(output: String, simulator: Bool) throws {
        let device: CameraDevice
        if simulator {
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
        try writePNG(frame: frame, path: output)
        print("Wrote \(output) (\(frame.width)x\(frame.height), ROI \(frame.roi.width)x\(frame.roi.height) bin\(frame.roi.binning))")
    }

    private static func writePNG(frame: Frame, path: String) throws {
        let stretch = StretchParams.auto(from: Histogram.compute(from: frame))
        var rgba = [UInt8](repeating: 0, count: frame.width * frame.height * 4)
        let denom = max(stretch.white - stretch.black, 1e-6)
        for i in 0..<frame.pixels.count {
            let linear = min(max((Double(frame.pixels[i]) / 65535.0 - stretch.black) / denom, 0), 1)
            let v = UInt8(min(255, (StretchParams.mtf(linear, midtones: stretch.midtones) * 255).rounded()))
            let o = i * 4
            rgba[o] = v
            rgba[o + 1] = v
            rgba[o + 2] = v
            rgba[o + 3] = 255
        }

        let url = URL(fileURLWithPath: path)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw CameraError.unsupported("Could not create PNG at \(path)")
        }
        let bytesPerRow = frame.width * 4
        let data = CFDataCreate(nil, rgba, rgba.count)!
        guard let provider = CGDataProvider(data: data),
              let image = CGImage(
                width: frame.width,
                height: frame.height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              )
        else {
            throw CameraError.unsupported("Could not encode PNG")
        }
        CGImageDestinationAddImage(destination, image, nil)
        if !CGImageDestinationFinalize(destination) {
            throw CameraError.unsupported("Failed to write \(path)")
        }
    }
}
