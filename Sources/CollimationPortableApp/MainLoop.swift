import CImGui
import CSDL3
import CollimationCore
import CollimationUI
import Foundation

/// One frame of the portable app, in the order §9.5 fixes.
@MainActor
final class MainLoop {
    private let window: OpaquePointer
    private let device: OpaquePointer
    private let engine: CollimationEngine
    private let host: PortableUIHost
    private let renderer: GPULiveRenderer
    private var running = true

    /// Window points per window coordinate. 2.0 on Windows at 200% (window
    /// coordinates are pixels there), 1.0 on a Retina Mac (they are points).
    private var pointScale: Double = 1

    init(
        window: OpaquePointer,
        device: OpaquePointer,
        engine: CollimationEngine,
        host: PortableUIHost,
        renderer: GPULiveRenderer
    ) {
        self.window = window
        self.device = device
        self.engine = engine
        self.host = host
        self.renderer = renderer
        updatePointScale()
    }

    func updatePointScale() {
        let displayScale = Double(SDL_GetWindowDisplayScale(window))
        let pixelDensity = Double(SDL_GetWindowPixelDensity(window))
        pointScale = pixelDensity > 0 ? displayScale / pixelDensity : 1
        UIScale.pointScale = pointScale

        // The SDL3 ImGui backend does not handle content scale itself, so the
        // style is rebuilt from scratch on every change.
        if let style = igGetStyle() {
            igStyleColorsDark(style)
            ImGuiStyle_ScaleAllSizes(style, Float(pointScale))
            style.pointee.FontSizeBase = Fonts.baseSize
            style.pointee.FontScaleDpi = Float(pointScale)
        }
        Log.info("point scale \(pointScale) (display \(displayScale), density \(pixelDensity))")
    }

    func run() {
        while running {
            pumpEvents()
            // On Windows, @MainActor jobs land on the libdispatch main queue
            // and nothing drains it unless the main thread runs the run loop.
            // One non-blocking pass per frame bounds main-actor latency to a
            // frame, which the engine's polling loops tolerate.
            _ = RunLoop.main.limitDate(forMode: .default)
            host.pumpDialogResult()

            let flags = SDL_GetWindowFlags(window)
            if flags & SDL_WINDOW_MINIMIZED != 0 {
                SDL_Delay(16)
                continue
            }

            drawFrame()
        }
    }

    private func pumpEvents() {
        var event = SDL_Event()
        while SDL_PollEvent(&event) {
            _ = ImGui_ImplSDL3_ProcessEvent(&event)
            if event.type == SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED.rawValue {
                updatePointScale()
            }
            Input.handle(
                event: event,
                engine: engine,
                liveRect: liveRect(),
                pointScale: pointScale,
                shouldQuit: &running
            )
        }
    }

    /// The area right of the sidebar and below the menu bar, in view points.
    private func liveRect() -> (origin: SIMD2<Double>, size: SIMD2<Double>) {
        var width: Int32 = 0
        var height: Int32 = 0
        SDL_GetWindowSize(window, &width, &height)
        let windowPoints = SIMD2(Double(width) / pointScale, Double(height) / pointScale)
        let top = MenuBar.height / pointScale
        return (
            origin: SIMD2(Sidebar.width, top),
            size: SIMD2(
                max(windowPoints.x - Sidebar.width, 1),
                max(windowPoints.y - top, 1)
            )
        )
    }

    private func windowSizeInPoints() -> SIMD2<Double> {
        var width: Int32 = 0
        var height: Int32 = 0
        SDL_GetWindowSize(window, &width, &height)
        return SIMD2(Double(width) / pointScale, Double(height) / pointScale)
    }

    private func drawFrame() {
        cimgui_sdlgpu3_new_frame()
        ImGui_ImplSDL3_NewFrame()
        igNewFrame()

        MenuBar.draw(engine: engine, host: host)
        Input.handleShortcuts(engine: engine, host: host)

        let live = liveRect()
        var windowHeight: Int32 = 0
        var windowWidth: Int32 = 0
        SDL_GetWindowSize(window, &windowWidth, &windowHeight)
        Sidebar.draw(
            engine: engine,
            host: host,
            topOffset: MenuBar.height,
            height: Double(windowHeight) - MenuBar.height,
            pointScale: pointScale
        )
        LiveChrome.draw(engine: engine, liveRect: live, pointScale: pointScale)
        ErrorDialog.draw(engine: engine)

        // The engine lays out in view points, like the macOS app.
        engine.viewWidth = live.size.x
        engine.viewHeight = live.size.y
        engine.updateStabilization()
        Diagnostics.heartbeat(engine)

        igRender()

        renderer.draw(
            frames: engine.frameSlot,
            renderState: engine.renderStateSlot,
            stabilization: engine.stabilization,
            window: window,
            liveRect: live,
            windowSize: windowSizeInPoints(),
            drawImGui: { commandBuffer, pass in
                if let drawData = igGetDrawData() {
                    cimgui_sdlgpu3_render_draw_data(drawData, commandBuffer, pass)
                }
            },
            prepareImGui: { commandBuffer in
                if let drawData = igGetDrawData() {
                    cimgui_sdlgpu3_prepare_draw_data(drawData, commandBuffer)
                }
            }
        )
    }
}
