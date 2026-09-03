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
                    renderState: engine.renderStateSlot,
                    stabilization: engine.stabilization
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

enum OverlayChrome {
    static let frameCenter = Color.white.opacity(0.55)
    static let outerRing = Color(red: 0.4, green: 0.75, blue: 1)
    static let innerRing = Color(red: 1, green: 0.75, blue: 0.25)
    static let coma = Color(red: 1, green: 0.35, blue: 0.3)
    static let starGood = Color(red: 0.3, green: 0.9, blue: 0.4)
    static let starFaint = Color(red: 1, green: 0.85, blue: 0.15)
    static let starSaturated = Color(red: 1, green: 0.22, blue: 0.18)

    static func starMarker(peak: UInt16?) -> Color {
        switch peak.map(StarQuality.from) {
        case .saturated: return starSaturated
        case .faint: return starFaint
        case .good, .none: return starGood
        }
    }
}

struct OverlayLegendView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            row("Sensor center") { OverlayLegendMark.crosshair(OverlayChrome.frameCenter) }
            row("Star") { OverlayLegendMark.starPeaks() }
            row("Outer ring") { OverlayLegendMark.ring(OverlayChrome.outerRing) }
            row("Inner ring") { OverlayLegendMark.ring(OverlayChrome.innerRing) }
            row("Coma") { OverlayLegendMark.line(OverlayChrome.coma) }
        }
        .font(.caption2)
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(.white.opacity(0.2), lineWidth: 1)
        )
        .help("White plus is the physical sensor center. The star marker is green when exposure is good, yellow when faint, and red when clipped. Cyan is the outer donut, gold the secondary shadow, red the coma.")
    }

    private func row(_ label: String, @ViewBuilder mark: () -> some View) -> some View {
        HStack(spacing: 6) {
            mark()
                .frame(width: 28, height: 12)
            Text(label)
        }
    }
}

private enum OverlayLegendMark {
    static func crosshair(_ color: Color, size: CGFloat = 8) -> some View {
        Canvas { context, canvas in
            strokeCrosshair(
                context: &context,
                at: CGPoint(x: canvas.width / 2, y: canvas.height / 2),
                color: color,
                size: size
            )
        }
        .frame(width: 16, height: 12)
    }

    static func ring(_ color: Color) -> some View {
        Canvas { context, canvas in
            let p = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
            let r: CGFloat = 5
            context.stroke(
                Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                with: .color(color),
                lineWidth: 1.2
            )
        }
        .frame(width: 16, height: 12)
    }

    static func starPeaks() -> some View {
        Canvas { context, canvas in
            let colors = [OverlayChrome.starGood, OverlayChrome.starFaint, OverlayChrome.starSaturated]
            let step = canvas.width / 4
            for (index, color) in colors.enumerated() {
                strokeCrosshair(
                    context: &context,
                    at: CGPoint(x: step * CGFloat(index + 1), y: canvas.height / 2),
                    color: color,
                    size: 4
                )
            }
        }
        .frame(width: 28, height: 12)
    }

    static func line(_ color: Color) -> some View {
        Canvas { context, canvas in
            let y = canvas.height / 2
            var path = Path()
            path.move(to: CGPoint(x: 1, y: y))
            path.addLine(to: CGPoint(x: canvas.width - 1, y: y))
            context.stroke(path, with: .color(color), lineWidth: 2)
        }
        .frame(width: 16, height: 12)
    }

    private static func strokeCrosshair(
        context: inout GraphicsContext,
        at point: CGPoint,
        color: Color,
        size: CGFloat
    ) {
        var path = Path()
        path.move(to: CGPoint(x: point.x - size, y: point.y))
        path.addLine(to: CGPoint(x: point.x + size, y: point.y))
        path.move(to: CGPoint(x: point.x, y: point.y - size))
        path.addLine(to: CGPoint(x: point.x, y: point.y + size))
        context.stroke(path, with: .color(color), lineWidth: 1)
        let r = max(size * 0.22, 1.2)
        context.fill(
            Path(ellipseIn: CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2)),
            with: .color(color)
        )
    }
}

struct OverlayView: View {
    let overlay: OverlayModel
    let zoom: Double
    var lockNormalized: SIMD2<Double>? = nil
    var liveCentroid: SIMD2<Double>? = nil
    /// When set, live pose is applied only if it matches this overlay frame size.
    var displayedWidth: Int? = nil
    var displayedHeight: Int? = nil

    var body: some View {
        Canvas { context, size in
            let poseMatchesDisplayed = displayedWidth == nil
                || displayedHeight == nil
                || (displayedWidth == overlay.imageWidth && displayedHeight == overlay.imageHeight)
            let live = poseMatchesDisplayed ? liveCentroid : nil
            let layout = ImageLayout(
                imageWidth: max(overlay.imageWidth, 1),
                imageHeight: max(overlay.imageHeight, 1),
                viewWidth: size.width,
                viewHeight: size.height,
                zoom: zoom,
                lockNormalized: poseMatchesDisplayed ? lockNormalized : nil,
                stabilizeCentroid: live ?? overlay.centroid
            )
            let rect = layout.imageRect
            let imageRect = CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
            let ringShift = overlay.shift(toLiveCentroid: live)

            if let sensorCenter = overlay.sensorCenterInImage,
               sensorCenter.x >= -2, sensorCenter.y >= -2,
               sensorCenter.x <= Double(overlay.imageWidth) + 2,
               sensorCenter.y <= Double(overlay.imageHeight) + 2 {
                let cx = layout.viewPoint(image: sensorCenter)
                drawCrosshair(context: &context, at: CGPoint(x: cx.x, y: cx.y), color: OverlayChrome.frameCenter)
            }

            if let centroid = live ?? overlay.centroid {
                let p = layout.viewPoint(image: centroid)
                drawCrosshair(context: &context, at: CGPoint(x: p.x, y: p.y), color: OverlayChrome.starMarker(peak: overlay.starPeak), size: 14)
            }
            if let outer = overlay.outer {
                strokeCircle(
                    context: &context,
                    layout: layout,
                    circle: outer.translated(by: ringShift),
                    color: OverlayChrome.outerRing
                )
            }
            if let inner = overlay.inner {
                strokeCircle(
                    context: &context,
                    layout: layout,
                    circle: inner.translated(by: ringShift),
                    color: OverlayChrome.innerRing
                )
            }
            if let outer = overlay.outer, let vector = overlay.comaVector {
                let origin = outer.center + ringShift
                let start = layout.viewPoint(image: origin)
                let scale = 8.0
                let end = layout.viewPoint(image: origin + vector * scale)
                var path = Path()
                path.move(to: CGPoint(x: start.x, y: start.y))
                path.addLine(to: CGPoint(x: end.x, y: end.y))
                context.stroke(path, with: .color(OverlayChrome.coma), lineWidth: 2)
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

struct ROIMapView: View {
    let sensorWidth: Int
    let sensorHeight: Int
    let roi: ROI
    var centroidInFrame: SIMD2<Double>?

    private let maxWidth: CGFloat = 140
    private let maxHeight: CGFloat = 94

    var body: some View {
        let size = mapSize
        Canvas { context, canvas in
            let pad: CGFloat = 4
            let sw = CGFloat(max(sensorWidth, 1))
            let sh = CGFloat(max(sensorHeight, 1))
            let scale = min((canvas.width - pad * 2) / sw, (canvas.height - pad * 2) / sh)
            let frameW = sw * scale
            let frameH = sh * scale
            let origin = CGPoint(
                x: (canvas.width - frameW) / 2,
                y: (canvas.height - frameH) / 2
            )
            let frameRect = CGRect(x: origin.x, y: origin.y, width: frameW, height: frameH)
            context.fill(Path(roundedRect: frameRect, cornerRadius: 1), with: .color(Color.white.opacity(0.08)))
            context.drawLayer { ctx in
                ctx.clip(to: Path(roundedRect: frameRect, cornerRadius: 1))
                drawGrid(context: &ctx, in: frameRect, divisions: 4)
            }
            context.stroke(Path(roundedRect: frameRect, cornerRadius: 1), with: .color(.white.opacity(0.75)), lineWidth: 1)

            let sensorCenter = MountGuide.frameCenter(width: sensorWidth, height: sensorHeight)
            drawPlus(
                context: &context,
                at: CGPoint(
                    x: origin.x + sensorCenter.x * scale,
                    y: origin.y + sensorCenter.y * scale
                ),
                color: OverlayChrome.frameCenter
            )

            let roiRect = CGRect(
                x: origin.x + CGFloat(roi.x) * scale,
                y: origin.y + CGFloat(roi.y) * scale,
                width: max(CGFloat(roi.sensorWidth) * scale, 1.5),
                height: max(CGFloat(roi.sensorHeight) * scale, 1.5)
            )
            context.fill(Path(roiRect), with: .color(Color.red.opacity(0.28)))
            context.stroke(Path(roiRect), with: .color(.red), lineWidth: 1.2)

            if let centroidInFrame {
                let sensor = roi.sensorPoint(fromFramePixel: centroidInFrame)
                let point = CGPoint(
                    x: origin.x + sensor.x * scale,
                    y: origin.y + sensor.y * scale
                )
                drawPlus(context: &context, at: point, color: .yellow)
            }
        }
        .frame(width: size.width, height: size.height)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(.white.opacity(0.2), lineWidth: 1)
        )
        .help("Full sensor with the current camera ROI. White plus is the physical sensor center. Grid lines are sensor quarters.")
    }

    private func drawGrid(context: inout GraphicsContext, in rect: CGRect, divisions: Int) {
        let n = max(2, divisions)
        var minor = Path()
        var major = Path()
        for i in 1..<n {
            let x = rect.minX + rect.width * CGFloat(i) / CGFloat(n)
            let y = rect.minY + rect.height * CGFloat(i) / CGFloat(n)
            var path = Path()
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
            if i * 2 == n {
                major.addPath(path)
            } else {
                minor.addPath(path)
            }
        }
        context.stroke(minor, with: .color(.white.opacity(0.14)), lineWidth: 0.5)
        context.stroke(major, with: .color(.white.opacity(0.32)), lineWidth: 0.6)
    }

    private func drawPlus(context: inout GraphicsContext, at point: CGPoint, color: Color) {
        let arm: CGFloat = 4
        var path = Path()
        path.move(to: CGPoint(x: point.x - arm, y: point.y))
        path.addLine(to: CGPoint(x: point.x + arm, y: point.y))
        path.move(to: CGPoint(x: point.x, y: point.y - arm))
        path.addLine(to: CGPoint(x: point.x, y: point.y + arm))
        context.stroke(path, with: .color(color), lineWidth: 1.25)
    }

    private var mapSize: CGSize {
        let sw = CGFloat(max(sensorWidth, 1))
        let sh = CGFloat(max(sensorHeight, 1))
        let scale = min(maxWidth / sw, maxHeight / sh)
        return CGSize(width: sw * scale + 8, height: sh * scale + 8)
    }
}

struct StarProfileView: View {
    let profile: StarIntensityProfile?
    var width: CGFloat = 148
    var height: CGFloat = 102

    /// 0.15% of 16-bit full well; log(0) is undefined.
    private static let logFloor = 0.0015
    private static let logMin = log10(logFloor)

    var body: some View {
        Canvas { context, canvas in
            let pad: CGFloat = 4
            let plot = CGRect(
                x: pad,
                y: pad,
                width: canvas.width - pad * 2,
                height: canvas.height - pad * 2
            )
            context.fill(Path(roundedRect: plot, cornerRadius: 1), with: .color(Color.white.opacity(0.08)))
            context.drawLayer { ctx in
                ctx.clip(to: Path(roundedRect: plot, cornerRadius: 1))
                drawGrid(context: &ctx, in: plot)
                if let profile, profile.samples.count >= 2 {
                    drawProfile(context: &ctx, in: plot, samples: profile.samples)
                }
            }
            context.stroke(Path(roundedRect: plot, cornerRadius: 1), with: .color(.white.opacity(0.75)), lineWidth: 1)
            drawLogLabels(context: &context, in: plot)
        }
        .frame(width: width, height: height)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(.white.opacity(0.2), lineWidth: 1)
        )
        .help("Average of four cuts through the star (horizontal, vertical, both diagonals). Vertical scale is logarithmic, 0.15% to 16-bit full well.")
    }

    private func drawGrid(context: inout GraphicsContext, in rect: CGRect) {
        var minor = Path()
        var major = Path()
        let n = 4
        for i in 1..<n {
            let x = rect.minX + rect.width * CGFloat(i) / CGFloat(n)
            var path = Path()
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
            if i * 2 == n {
                major.addPath(path)
            } else {
                minor.addPath(path)
            }
        }
        for decade in [1e-2, 1e-1] {
            let y = yPosition(decade, in: rect)
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
            if decade == 1e-1 {
                major.addPath(path)
            } else {
                minor.addPath(path)
            }
        }
        context.stroke(minor, with: .color(.white.opacity(0.14)), lineWidth: 0.5)
        context.stroke(major, with: .color(.white.opacity(0.32)), lineWidth: 0.6)
    }

    private func drawLogLabels(context: inout GraphicsContext, in rect: CGRect) {
        let font = Font.system(size: 8, weight: .medium, design: .monospaced)
        let color = Color.white.opacity(0.7)
        let x = rect.minX + 3
        context.draw(
            Text("100%").font(font).foregroundColor(color),
            at: CGPoint(x: x, y: rect.minY + 2),
            anchor: .topLeading
        )
        context.draw(
            Text("1%").font(font).foregroundColor(color),
            at: CGPoint(x: x, y: yPosition(0.01, in: rect)),
            anchor: .leading
        )
        context.draw(
            Text("0.15%").font(font).foregroundColor(color),
            at: CGPoint(x: x, y: rect.maxY - 2),
            anchor: .bottomLeading
        )
    }

    private func drawProfile(context: inout GraphicsContext, in rect: CGRect, samples: [Double]) {
        let last = samples.count - 1
        var line = Path()
        var fill = Path()
        for (i, value) in samples.enumerated() {
            let x = rect.minX + rect.width * CGFloat(i) / CGFloat(last)
            let p = CGPoint(x: x, y: yPosition(value, in: rect))
            if i == 0 {
                fill.move(to: CGPoint(x: x, y: rect.maxY))
                fill.addLine(to: p)
                line.move(to: p)
            } else {
                fill.addLine(to: p)
                line.addLine(to: p)
            }
        }
        fill.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        fill.closeSubpath()
        context.fill(fill, with: .color(OverlayChrome.starGood.opacity(0.22)))
        context.stroke(line, with: .color(OverlayChrome.starGood), lineWidth: 1.2)
    }

    private func yPosition(_ value: Double, in rect: CGRect) -> CGFloat {
        let v = min(max(value, Self.logFloor), 1)
        let t = (log10(v) - Self.logMin) / -Self.logMin
        return rect.maxY - CGFloat(t) * rect.height
    }
}
