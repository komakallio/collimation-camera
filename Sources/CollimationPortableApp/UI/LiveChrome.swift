import CImGui
import CollimationCore
import CollimationUI
import Foundation

/// Everything drawn over the live image: overlay, status chip, zoom and fps,
/// legend, star profile, and ROI map.
///
/// All of it goes on the background draw list, so it sits above the stretch
/// pass (ImGui renders last) and below any ImGui window. Layout matches
/// `ContentView.chrome`.
@MainActor
enum LiveChrome {
    static let padding = 10.0
    static let widgetSpacing = 8.0
    static let widgetGap = 6.0

    static func draw(
        engine: CollimationEngine,
        liveRect: (origin: SIMD2<Double>, size: SIMD2<Double>),
        pointScale: Double
    ) {
        guard let list = igGetBackgroundDrawList(nil) else { return }
        let origin = liveRect.origin * pointScale
        let pose = engine.stabilize ? engine.renderStateSlot.peek() : nil

        if engine.showOverlay {
            HUDDrawList.draw(
                OverlayScene.primitives(
                    overlay: engine.overlay,
                    zoom: engine.zoom,
                    lockNormalized: pose?.stabilizeLock,
                    liveCentroid: pose?.stabilizeCentroid,
                    displayedWidth: pose?.imageWidth,
                    displayedHeight: pose?.imageHeight,
                    viewSize: liveRect.size
                ),
                on: list,
                origin: origin,
                pointScale: pointScale
            )
        }

        drawStatusChip(engine: engine, list: list, origin: origin, pointScale: pointScale)
        drawZoomLabel(
            engine: engine,
            list: list,
            origin: origin,
            liveSize: liveRect.size,
            pointScale: pointScale
        )
        drawCorner(engine: engine, list: list, origin: origin, liveSize: liveRect.size, pointScale: pointScale)
    }

    private static func drawStatusChip(
        engine: CollimationEngine,
        list: UnsafeMutablePointer<ImDrawList>,
        origin: SIMD2<Double>,
        pointScale: Double
    ) {
        let model = StatusChip.model(engine)
        capsule(
            text: model.label,
            background: model.color.opacity(StatusChip.backgroundOpacity),
            foreground: .black,
            at: SIMD2(padding, padding),
            list: list,
            origin: origin,
            pointScale: pointScale,
            alignRight: nil
        )
    }

    private static func drawZoomLabel(
        engine: CollimationEngine,
        list: UnsafeMutablePointer<ImDrawList>,
        origin: SIMD2<Double>,
        liveSize: SIMD2<Double>,
        pointScale: Double
    ) {
        capsule(
            text: MetricText.zoomAndFPS(zoom: engine.zoom, fps: engine.fps),
            background: HUDColor.black.opacity(0.45),
            foreground: .white,
            at: SIMD2(0, padding),
            list: list,
            origin: origin,
            pointScale: pointScale,
            alignRight: liveSize.x - padding
        )
    }

    /// The legend, star profile, and ROI map, stacked in the bottom-right
    /// corner the way the macOS chrome stacks them.
    private static func drawCorner(
        engine: CollimationEngine,
        list: UnsafeMutablePointer<ImDrawList>,
        origin: SIMD2<Double>,
        liveSize: SIMD2<Double>,
        pointScale: Double
    ) {
        var bottom = liveSize.y - padding

        if engine.overlay.sensorWidth > 0, engine.overlay.sensorHeight > 0 {
            let pose = engine.stabilize ? engine.renderStateSlot.peek() : nil
            let mapSize = ROIMapScene.size(
                sensorWidth: engine.overlay.sensorWidth,
                sensorHeight: engine.overlay.sensorHeight
            )
            let profileSize = StarProfileScene.size
            let rowHeight = max(mapSize.y, profileSize.y)
            let rowTop = bottom - rowHeight

            let mapOrigin = SIMD2(liveSize.x - padding - mapSize.x, bottom - mapSize.y)
            panel(size: mapSize, at: mapOrigin, cornerRadius: ROIMapScene.cornerRadius,
                  background: ROIMapScene.background, border: ROIMapScene.border,
                  list: list, origin: origin, pointScale: pointScale)
            HUDDrawList.draw(
                ROIMapScene.primitives(
                    sensorWidth: engine.overlay.sensorWidth,
                    sensorHeight: engine.overlay.sensorHeight,
                    roi: pose?.roi ?? engine.overlay.roi,
                    centroidInFrame: pose?.stabilizeCentroid ?? engine.overlay.centroid,
                    size: mapSize
                ),
                on: list,
                origin: origin + mapOrigin * pointScale,
                pointScale: pointScale
            )

            let profileOrigin = SIMD2(
                mapOrigin.x - widgetGap - profileSize.x,
                bottom - profileSize.y
            )
            panel(size: profileSize, at: profileOrigin, cornerRadius: StarProfileScene.cornerRadius,
                  background: StarProfileScene.background, border: StarProfileScene.border,
                  list: list, origin: origin, pointScale: pointScale)
            HUDDrawList.draw(
                StarProfileScene.primitives(profile: engine.starProfile, size: profileSize),
                on: list,
                origin: origin + profileOrigin * pointScale,
                pointScale: pointScale
            )

            bottom = rowTop - widgetSpacing
        }

        guard engine.showOverlay else { return }
        let rows = LegendScene.rows
        let rowHeight = LegendScene.markSize.y
        let textSize = 10.0
        var widest = 0.0
        for row in rows {
            let measured = HUDDrawList.measure(
                row.label,
                font: Fonts.proportional,
                size: Float(textSize * pointScale)
            )
            widest = max(widest, Double(measured.x) / pointScale)
        }
        let legendSize = SIMD2(
            LegendScene.markSize.x + LegendScene.markSpacing + widest + 16,
            Double(rows.count) * rowHeight + Double(rows.count - 1) * LegendScene.rowSpacing + 14
        )
        let legendOrigin = SIMD2(liveSize.x - padding - legendSize.x, bottom - legendSize.y)
        panel(size: legendSize, at: legendOrigin, cornerRadius: 4,
              background: HUDColor.black.opacity(0.5), border: HUDColor.white.opacity(0.2),
              list: list, origin: origin, pointScale: pointScale)

        var y = legendOrigin.y + 7
        for row in rows {
            let markOrigin = SIMD2(legendOrigin.x + 8, y)
            HUDDrawList.draw(
                LegendScene.markPrimitives(row.mark),
                on: list,
                origin: origin + markOrigin * pointScale,
                pointScale: pointScale
            )
            HUDDrawList.draw(
                [.text(
                    row.label,
                    at: SIMD2(LegendScene.markSize.x + LegendScene.markSpacing, rowHeight / 2),
                    anchor: .leading,
                    color: HUDColor.white.opacity(0.92),
                    size: textSize,
                    monospaced: false,
                    weight: .regular
                )],
                on: list,
                origin: origin + markOrigin * pointScale,
                pointScale: pointScale
            )
            y += rowHeight + LegendScene.rowSpacing
        }
    }

    private static func panel(
        size: SIMD2<Double>,
        at position: SIMD2<Double>,
        cornerRadius: Double,
        background: HUDColor,
        border: HUDColor,
        list: UnsafeMutablePointer<ImDrawList>,
        origin: SIMD2<Double>,
        pointScale: Double
    ) {
        HUDDrawList.draw(
            [
                .fillRect(origin: position, size: size, color: background, cornerRadius: cornerRadius),
                .rect(origin: position, size: size, color: border, width: 1, cornerRadius: cornerRadius),
            ],
            on: list,
            origin: origin,
            pointScale: pointScale
        )
    }

    /// The rounded label used for the status chip and the zoom readout.
    private static func capsule(
        text: String,
        background: HUDColor,
        foreground: HUDColor,
        at position: SIMD2<Double>,
        list: UnsafeMutablePointer<ImDrawList>,
        origin: SIMD2<Double>,
        pointScale: Double,
        alignRight: Double?
    ) {
        let size = 10.0
        let measured = HUDDrawList.measure(text, font: Fonts.monoBold, size: Float(size * pointScale))
        let textSize = SIMD2(Double(measured.x) / pointScale, Double(measured.y) / pointScale)
        let box = SIMD2(textSize.x + 16, textSize.y + 8)
        var placed = position
        if let alignRight {
            placed.x = alignRight - box.x
        }
        HUDDrawList.draw(
            [
                .fillRect(origin: placed, size: box, color: background, cornerRadius: box.y / 2),
                .text(
                    text,
                    at: SIMD2(placed.x + box.x / 2, placed.y + box.y / 2),
                    anchor: .center,
                    color: foreground,
                    size: size,
                    monospaced: true,
                    weight: .bold
                ),
            ],
            on: list,
            origin: origin,
            pointScale: pointScale
        )
    }
}
