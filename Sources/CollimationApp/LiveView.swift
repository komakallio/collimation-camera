import AppKit
import CollimationCore
import CollimationUI
import MetalKit
import SwiftUI

struct LiveView: NSViewRepresentable {
    let engine: CollimationEngine

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
                engine.zoom = engine.clampedZoom(engine.zoom * factor)
            }
        }
        view.onMagnify = { magnification in
            Task { @MainActor in
                engine.zoom = engine.clampedZoom(engine.zoom * Double(magnification))
            }
        }
        view.onResize = { size in
            Task { @MainActor in
                engine.viewWidth = size.width
                engine.viewHeight = size.height
                engine.updateStabilization()
            }
        }
        return view
    }

    func updateNSView(_ nsView: LiveMTKView, context: Context) {}

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
    /// Live-view size in points. `updateNSView` used to feed this, but it only
    /// ran because `@ObservedObject` re-invoked it on every published change;
    /// under Observation this view reads no tracked property.
    var onResize: ((CGSize) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onResize?(bounds.size)
    }

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event.scrollingDeltaY)
    }

    override func magnify(with event: NSEvent) {
        onMagnify?(1 + event.magnification)
    }
}

struct OverlayLegendView: View {
    var collimation = true
    var sensorMarks = true

    var body: some View {
        let rows = LegendScene.rows(collimation: collimation, sensorMarks: sensorMarks)
        VStack(alignment: .leading, spacing: LegendScene.rowSpacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: LegendScene.markSpacing) {
                    Canvas { context, size in
                        HUDCanvas.draw(
                            LegendScene.markPrimitives(row.mark, size: SIMD2(size.width, size.height)),
                            in: &context
                        )
                    }
                    .frame(width: LegendScene.markSize.x, height: LegendScene.markSize.y)
                    Text(row.label)
                }
            }
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
        .help(HelpText.legend)
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
    var showCollimation = true
    var showSensorMarks = true

    var body: some View {
        Canvas { context, size in
            HUDCanvas.draw(
                OverlayScene.primitives(
                    overlay: overlay,
                    zoom: zoom,
                    lockNormalized: lockNormalized,
                    liveCentroid: liveCentroid,
                    displayedWidth: displayedWidth,
                    displayedHeight: displayedHeight,
                    viewSize: SIMD2(size.width, size.height),
                    showCollimation: showCollimation,
                    showSensorMarks: showSensorMarks
                ),
                in: &context
            )
        }
        .allowsHitTesting(false)
    }
}

struct ROIMapView: View {
    let sensorWidth: Int
    let sensorHeight: Int
    let roi: ROI
    var centroidInFrame: SIMD2<Double>?

    var body: some View {
        let size = ROIMapScene.size(sensorWidth: sensorWidth, sensorHeight: sensorHeight)
        Canvas { context, canvas in
            HUDCanvas.draw(
                ROIMapScene.primitives(
                    sensorWidth: sensorWidth,
                    sensorHeight: sensorHeight,
                    roi: roi,
                    centroidInFrame: centroidInFrame,
                    size: SIMD2(canvas.width, canvas.height)
                ),
                in: &context
            )
        }
        .frame(width: size.x, height: size.y)
        .background(
            HUDCanvas.swiftUIColor(ROIMapScene.background),
            in: RoundedRectangle(cornerRadius: ROIMapScene.cornerRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ROIMapScene.cornerRadius, style: .continuous)
                .strokeBorder(HUDCanvas.swiftUIColor(ROIMapScene.border), lineWidth: 1)
        )
        .help(HelpText.roiMap)
    }
}

struct StarProfileView: View {
    let profile: StarIntensityProfile?
    var width: CGFloat = StarProfileScene.size.x
    var height: CGFloat = StarProfileScene.size.y

    var body: some View {
        Canvas { context, canvas in
            HUDCanvas.draw(
                StarProfileScene.primitives(
                    profile: profile,
                    size: SIMD2(canvas.width, canvas.height)
                ),
                in: &context
            )
        }
        .frame(width: width, height: height)
        .background(
            HUDCanvas.swiftUIColor(StarProfileScene.background),
            in: RoundedRectangle(cornerRadius: StarProfileScene.cornerRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: StarProfileScene.cornerRadius, style: .continuous)
                .strokeBorder(HUDCanvas.swiftUIColor(StarProfileScene.border), lineWidth: 1)
        )
        .help(HelpText.starProfile)
    }
}
