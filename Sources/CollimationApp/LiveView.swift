import AppKit
import CollimationCore
import MetalKit
import SwiftUI

struct LiveView: NSViewRepresentable {
    @ObservedObject var engine: CollimationEngine

    func makeCoordinator() -> Coordinator {
        Coordinator(engine: engine)
    }

    func makeNSView(context: Context) -> LiveMTKView {
        let view = LiveMTKView()
        view.device = context.coordinator.metalDevice
        view.framebufferOnly = true
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0.04, green: 0.045, blue: 0.055, alpha: 1)
        view.delegate = context.coordinator.renderer
        view.preferredFramesPerSecond = 30
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.onScroll = { delta in
            Task { @MainActor in
                let factor = delta > 0 ? 1.08 : 0.92
                engine.zoom = min(CollimationEngine.maxZoom, max(CollimationEngine.minZoom, engine.zoom * factor))
            }
        }
        view.onMagnify = { magnification in
            Task { @MainActor in
                engine.zoom = min(CollimationEngine.maxZoom, max(CollimationEngine.minZoom, engine.zoom * Double(magnification)))
            }
        }
        return view
    }

    func updateNSView(_ nsView: LiveMTKView, context: Context) {
        context.coordinator.renderer.viewSize = nsView.drawableSize
        let width = nsView.bounds.width
        let height = nsView.bounds.height
        Task { @MainActor in
            engine.viewWidth = width
            engine.viewHeight = height
            engine.updateStabilization()
        }
    }

    final class Coordinator {
        let metalDevice: MTLDevice
        let renderer: MetalRenderer

        init(engine: CollimationEngine) {
            guard let device = MTLCreateSystemDefaultDevice(),
                  let renderer = MetalRenderer(
                    device: device,
                    frames: engine.frameSlot,
                    renderState: engine.renderStateSlot
                  )
            else {
                fatalError("Metal is required for live view")
            }
            self.metalDevice = device
            self.renderer = renderer
        }
    }
}

final class LiveMTKView: MTKView {
    var onScroll: ((CGFloat) -> Void)?
    var onMagnify: ((CGFloat) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event.scrollingDeltaY)
    }

    override func magnify(with event: NSEvent) {
        onMagnify?(1 + event.magnification)
    }
}

struct OverlayView: View {
    let overlay: OverlayModel
    let zoom: Double

    var body: some View {
        Canvas { context, size in
            let layout = ImageLayout(
                imageWidth: max(overlay.imageWidth, 1),
                imageHeight: max(overlay.imageHeight, 1),
                viewWidth: size.width,
                viewHeight: size.height,
                zoom: zoom,
                lockNormalized: overlay.stabilizeLock,
                stabilizeCentroid: overlay.stabilizeCentroid
            )
            let rect = layout.imageRect
            let imageRect = CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)

            let cx = layout.viewPoint(image: SIMD2(Double(overlay.imageWidth) / 2, Double(overlay.imageHeight) / 2))
            drawCrosshair(context: &context, at: CGPoint(x: cx.x, y: cx.y), color: .white.opacity(0.55))

            if let centroid = overlay.centroid {
                let p = layout.viewPoint(image: centroid)
                drawCrosshair(context: &context, at: CGPoint(x: p.x, y: p.y), color: Color(red: 0.3, green: 0.9, blue: 0.4), size: 14)
            }
            if let outer = overlay.outer {
                strokeCircle(context: &context, layout: layout, circle: outer, color: Color(red: 0.4, green: 0.75, blue: 1))
            }
            if let inner = overlay.inner {
                strokeCircle(context: &context, layout: layout, circle: inner, color: Color(red: 1, green: 0.75, blue: 0.25))
            }
            if let outer = overlay.outer, let vector = overlay.comaVector {
                let start = layout.viewPoint(image: outer.center)
                let scale = 8.0
                let end = layout.viewPoint(image: outer.center + vector * scale)
                var path = Path()
                path.move(to: CGPoint(x: start.x, y: start.y))
                path.addLine(to: CGPoint(x: end.x, y: end.y))
                context.stroke(path, with: .color(Color(red: 1, green: 0.35, blue: 0.3)), lineWidth: 2)
            }

            _ = imageRect
        }
        .allowsHitTesting(false)
    }

    private func drawCrosshair(context: inout GraphicsContext, at point: CGPoint, color: Color, size: CGFloat = 18) {
        var path = Path()
        path.move(to: CGPoint(x: point.x - size, y: point.y))
        path.addLine(to: CGPoint(x: point.x + size, y: point.y))
        path.move(to: CGPoint(x: point.x, y: point.y - size))
        path.addLine(to: CGPoint(x: point.x, y: point.y + size))
        context.stroke(path, with: .color(color), lineWidth: 1)
        let r: CGFloat = 3
        context.fill(
            Path(ellipseIn: CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2)),
            with: .color(color)
        )
    }

    private func strokeCircle(context: inout GraphicsContext, layout: ImageLayout, circle: FittedCircle, color: Color) {
        let c = layout.viewPoint(image: circle.center)
        let r = circle.radius * layout.zoom
        let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        context.stroke(Path(ellipseIn: rect), with: .color(color), lineWidth: 1.2)
    }
}
