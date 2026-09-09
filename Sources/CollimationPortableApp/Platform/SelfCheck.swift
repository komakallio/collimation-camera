import CImGui
import CSDL3
import CollimationCore
import CollimationUI
import Foundation

/// `CollimationCamera --check`: everything the app needs, reported and then
/// exited, without opening a window.
///
/// This is what to run first on a machine that has never run the app —
/// especially an observatory PC reached over remote desktop, where a window is
/// awkward and a message box is worse. It answers the questions a failed
/// launch raises: which GPU driver, whether the texture format is supported,
/// whether the fonts and the vendor SDKs were found, and which serial ports
/// exist. Everything goes to the log as well, so the file can be sent on.
enum SelfCheck {
    static func isRequested(_ arguments: [String]) -> Bool {
        arguments.contains("--check")
    }

    /// Runs after `SDL_Init` and before the window. Exits the process.
    static func run(window: OpaquePointer, device: OpaquePointer) -> Never {
        Log.info("--- self check ---")

        if let driver = SDL_GetGPUDeviceDriver(device) {
            Log.info("GPU driver: \(String(cString: driver))")
        }
        Log.info("R16_UINT storage read: \(GPULiveRenderer.supportsR16UInt(device: device) ? "yes" : "no")")

        let formats = SDL_GetGPUShaderFormats(device)
        var names: [String] = []
        if formats & SDL_GPU_SHADERFORMAT_DXBC != 0 { names.append("DXBC") }
        if formats & SDL_GPU_SHADERFORMAT_DXIL != 0 { names.append("DXIL") }
        if formats & SDL_GPU_SHADERFORMAT_SPIRV != 0 { names.append("SPIRV") }
        if formats & SDL_GPU_SHADERFORMAT_MSL != 0 { names.append("MSL") }
        Log.info("shader formats: \(names.isEmpty ? "none" : names.joined(separator: ", "))")

        let swapchainFormat = SDL_GetGPUSwapchainTextureFormat(device, window)
        let pipeline = GPULiveRenderer(device: device, colorFormat: swapchainFormat)
        Log.info("stretch pipeline: \(pipeline == nil ? "FAILED — \(Diagnostics.sdlError())" : "ok")")

        for file in Fonts.files {
            if let url = AppPaths.font(file) {
                Log.info("font: \(url.path)")
            } else {
                Log.info("font MISSING: \(file)")
            }
        }

        Log.info("Player One camera SDK: \(DeviceCatalog.playerOneSDKVersion ?? "not found")")
        Log.info("ZWO camera SDK: \(DeviceCatalog.zwoSDKVersion ?? "not found")")
        Log.info("Player One filter wheel SDK: \(PhoenixWheel.sdkVersion ?? "not found")")

        let devices = DeviceCatalog.list()
        Log.info("cameras: \(devices.map(\.name).joined(separator: ", "))")

        let ports = SerialPortScanner.availablePaths()
        Log.info("serial ports: \(ports.isEmpty ? "none" : ports.joined(separator: ", "))")

        Log.info("log: \(AppPaths.logFile.path)")
        Log.info("--- self check done ---")
        Diagnostics.stop()
        exit(pipeline == nil ? 1 : 0)
    }
}
