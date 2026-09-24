import CollimationCore
import CollimationUI
import Foundation

private func lines(_ primitives: [HUDPrimitive]) -> [(SIMD2<Double>, SIMD2<Double>, HUDColor)] {
    primitives.compactMap { primitive in
        if case .line(let from, let to, let color, _) = primitive { return (from, to, color) }
        return nil
    }
}

private func circles(_ primitives: [HUDPrimitive]) -> [(SIMD2<Double>, Double, HUDColor)] {
    primitives.compactMap { primitive in
        if case .circle(let center, let radius, let color, _) = primitive { return (center, radius, color) }
        return nil
    }
}

private func texts(_ primitives: [HUDPrimitive]) -> [(String, SIMD2<Double>)] {
    primitives.compactMap { primitive in
        if case .text(let value, let at, _, _, _, _, _) = primitive { return (value, at) }
        return nil
    }
}

private func fillRects(_ primitives: [HUDPrimitive]) -> [(SIMD2<Double>, SIMD2<Double>, HUDColor)] {
    primitives.compactMap { primitive in
        if case .fillRect(let origin, let size, let color, _) = primitive { return (origin, size, color) }
        return nil
    }
}

/// The sensor-center crosshair lands where the layout says the sensor center is.
func testOverlaySceneSensorCenter() throws {
    let roi = ROI(x: 1000, y: 500, width: 512, height: 512)
    let overlay = OverlayModel(
        imageWidth: 512,
        imageHeight: 512,
        sensorWidth: 2048,
        sensorHeight: 1024,
        roi: roi
    )
    guard let sensorCenter = overlay.sensorCenterInImage else {
        throw UIModelExpectation(description: "sensor center should be inside this ROI")
    }
    let viewSize = SIMD2(800.0, 700.0)
    let primitives = OverlayScene.primitives(overlay: overlay, zoom: 1, viewSize: viewSize)

    let layout = ImageLayout(
        imageWidth: 512,
        imageHeight: 512,
        viewWidth: viewSize.x,
        viewHeight: viewSize.y,
        zoom: 1
    )
    let expected = layout.viewPoint(image: sensorCenter)
    let horizontal = lines(primitives).filter { abs($0.0.y - expected.y) < 1e-6 && abs($0.1.y - expected.y) < 1e-6 }
    try expectUI(horizontal.count == 24, "twelve fading pieces on each horizontal arm, got \(horizontal.count)")
    let nearest = horizontal.min { abs(($0.0.x + $0.1.x) / 2 - expected.x) < abs(($1.0.x + $1.1.x) / 2 - expected.x) }
    let farthest = horizontal.max { abs(($0.0.x + $0.1.x) / 2 - expected.x) < abs(($1.0.x + $1.1.x) / 2 - expected.x) }
    try expectUI((nearest?.2.a ?? 0) > (farthest?.2.a ?? 1), "the cross is brighter at the center than at the edge")
    try expectUI(
        horizontal.contains { min($0.0.x, $0.1.x) <= 1e-6 } && horizontal.contains { max($0.0.x, $0.1.x) >= viewSize.x - 1e-6 },
        "the cross reaches both view edges"
    )

    // Off-frame sensor centers are not drawn.
    let far = OverlayModel(
        imageWidth: 512,
        imageHeight: 512,
        sensorWidth: 6252,
        sensorHeight: 4176,
        roi: ROI(x: 0, y: 0, width: 512, height: 512)
    )
    let farPrimitives = OverlayScene.primitives(overlay: far, zoom: 1, viewSize: viewSize)
    try expectUI(
        lines(farPrimitives).filter { $0.2 == OverlayChrome.frameCenter }.isEmpty
            && circles(farPrimitives).filter { $0.2 == OverlayChrome.frameCenter }.isEmpty,
        "sensor center outside the frame is not drawn"
    )
}

/// With stabilization on, the rings follow the live centroid.
func testOverlaySceneRingShift() throws {
    let overlay = OverlayModel(
        imageWidth: 512,
        imageHeight: 512,
        centroid: SIMD2(256, 256),
        outer: FittedCircle(center: SIMD2(256, 256), radius: 40),
        inner: FittedCircle(center: SIMD2(258, 254), radius: 14),
        comaVector: SIMD2(1, 0),
        trackingState: .tracking,
        sensorWidth: 512,
        sensorHeight: 512,
        roi: ROI(x: 0, y: 0, width: 512, height: 512)
    )
    let viewSize = SIMD2(600.0, 600.0)
    let still = OverlayScene.primitives(overlay: overlay, zoom: 1, viewSize: viewSize)
    let moved = OverlayScene.primitives(
        overlay: overlay,
        zoom: 1,
        liveCentroid: SIMD2(276, 246),
        displayedWidth: 512,
        displayedHeight: 512,
        viewSize: viewSize
    )

    let stillOuter = circles(still).first { $0.2 == OverlayChrome.outerRing }
    let movedOuter = circles(moved).first { $0.2 == OverlayChrome.outerRing }
    guard let stillOuter, let movedOuter else {
        throw UIModelExpectation(description: "both scenes draw the outer ring")
    }
    try expectUI(
        abs(movedOuter.0.x - stillOuter.0.x - 20) < 1e-9,
        "outer ring follows the live centroid in x, moved by \(movedOuter.0.x - stillOuter.0.x)"
    )
    try expectUI(
        abs(movedOuter.0.y - stillOuter.0.y + 10) < 1e-9,
        "outer ring follows the live centroid in y, moved by \(movedOuter.0.y - stillOuter.0.y)"
    )
    try expectUI(abs(movedOuter.1 - stillOuter.1) < 1e-9, "radius unchanged by the shift")

    // A live pose from a differently sized frame must be ignored.
    let mismatched = OverlayScene.primitives(
        overlay: overlay,
        zoom: 1,
        liveCentroid: SIMD2(276, 246),
        displayedWidth: 2048,
        displayedHeight: 2048,
        viewSize: viewSize
    )
    let mismatchedOuter = circles(mismatched).first { $0.2 == OverlayChrome.outerRing }
    try expectUI(
        mismatchedOuter.map { abs($0.0.x - stillOuter.0.x) < 1e-9 } ?? false,
        "a pose from another frame size is dropped"
    )

    // The coma vector is drawn eight times its measured length.
    let comaLine = lines(still).first { $0.2 == OverlayChrome.coma }
    guard let comaLine else { throw UIModelExpectation(description: "coma line missing") }
    try expectUI(
        abs((comaLine.1.x - comaLine.0.x) - 8) < 1e-9,
        "coma vector scaled by 8, got \(comaLine.1.x - comaLine.0.x)"
    )
}

func testROIMapScene() throws {
    let sensorWidth = 2048
    let sensorHeight = 1024
    let box = ROIMapScene.size(sensorWidth: sensorWidth, sensorHeight: sensorHeight)
    // 140/2048 vs 94/1024 — width is the binding constraint.
    try expectUI(abs(box.x - (140 + 8)) < 1e-9, "map box width \(box.x)")
    try expectUI(abs(box.y - (70 + 8)) < 1e-9, "map box height \(box.y)")

    let roi = ROI(x: 512, y: 256, width: 512, height: 256)
    let primitives = ROIMapScene.primitives(
        sensorWidth: sensorWidth,
        sensorHeight: sensorHeight,
        roi: roi
    )
    let scale = 140.0 / 2048.0
    let roiRect = fillRects(primitives).first { $0.2 == ROIMapScene.roiFill }
    guard let roiRect else { throw UIModelExpectation(description: "no ROI rectangle") }
    try expectUI(abs(roiRect.0.x - (4 + 512 * scale)) < 1e-9, "roi x \(roiRect.0.x)")
    try expectUI(abs(roiRect.0.y - (4 + 256 * scale)) < 1e-9, "roi y \(roiRect.0.y)")
    try expectUI(abs(roiRect.1.x - 512 * scale) < 1e-9, "roi width \(roiRect.1.x)")

    // A one-pixel ROI still renders at the visibility floor.
    let tiny = ROIMapScene.primitives(
        sensorWidth: sensorWidth,
        sensorHeight: sensorHeight,
        roi: ROI(x: 0, y: 0, width: 1, height: 1)
    )
    let tinyRect = fillRects(tiny).first { $0.2 == ROIMapScene.roiFill }
    try expectUI(tinyRect.map { $0.1.x >= 1.5 && $0.1.y >= 1.5 } ?? false, "tiny ROI stays visible")

    // Centering clears the stabilizer centroid and leaves the previous crop.
    // The full-frame star must be mapped through the full-frame ROI, or the
    // marker lands down and to the right of the sensor centre.
    let crop = ROI(x: 744, y: 494, width: 512, height: 512)
    let full = ROI(x: 0, y: 0, width: sensorWidth, height: sensorHeight)
    let starOnSensor = SIMD2(1200.0, 700.0)
    let fullCentroid = full.framePixel(fromSensorPoint: starOnSensor)
    let duringCenter = ROIMapScene.displayedStar(
        poseROI: crop,
        poseCentroid: nil,
        overlayROI: full,
        overlayCentroid: fullCentroid
    )
    try expectUI(duringCenter.roi == full, "centering map uses the full-frame ROI")
    let plotted = duringCenter.roi.sensorPoint(fromFramePixel: duringCenter.centroid ?? .zero)
    try expectUI(
        hypot(plotted.x - starOnSensor.x, plotted.y - starOnSensor.y) < 1,
        "star stays on the sensor point, plotted \(plotted)"
    )
    let cropCentroid = crop.framePixel(fromSensorPoint: starOnSensor)
    let whileTracking = ROIMapScene.displayedStar(
        poseROI: crop,
        poseCentroid: cropCentroid,
        overlayROI: full,
        overlayCentroid: fullCentroid
    )
    try expectUI(whileTracking.roi == crop, "a matched stabilize pose keeps its crop")
}

func testHistogramScene() throws {
    var histogram = Histogram()
    histogram.bins = [UInt32](repeating: 0, count: Histogram.binCount)
    histogram.bins[0] = 100
    histogram.bins[Histogram.binCount - 1] = 50
    var stretch = StretchParams.default
    stretch.black = 0.25
    stretch.white = 0.75
    let size = SIMD2(256.0, 64.0)
    let primitives = HistogramScene.primitives(histogram: histogram, stretch: stretch, size: size)

    let bars = fillRects(primitives).filter { $0.2 == HistogramScene.barColor }
    try expectUI(bars.count == Histogram.binCount, "one bar per bin, got \(bars.count)")
    try expectUI(abs(bars[0].1.y - 64) < 1e-9, "tallest bin fills the height")
    try expectUI(abs(bars[0].0.y) < 1e-9, "tallest bar starts at the top")
    try expectUI(abs(bars[Histogram.binCount - 1].1.y - 32) < 1e-9, "half-height bin")

    let markers = lines(primitives)
    let black = markers.first { $0.2 == HistogramScene.blackMarker }
    let white = markers.first { $0.2 == HistogramScene.whiteMarker }
    try expectUI(black.map { abs($0.0.x - 64) < 1e-9 } ?? false, "black marker at 25%")
    try expectUI(white.map { abs($0.0.x - 192) < 1e-9 } ?? false, "white marker at 75%")
}

func testCompassDialScene() throws {
    let size = CompassDialScene.size
    let radius = min(size.x, size.y) / 2 - CompassDialScene.inset
    let center = SIMD2(size.x / 2, size.y / 2)

    // 90° points down: +y in image coordinates.
    let down = CompassDialScene.primitives(degrees: 90, magnitude: 1)
    let arrow = lines(down).first { $0.2 == CompassDialScene.arrow }
    guard let arrow else { throw UIModelExpectation(description: "no arrow") }
    try expectUI(abs(arrow.0.x - center.x) < 1e-9, "arrow starts at the centre")
    try expectUI(abs(arrow.1.x - center.x) < 1e-9, "90° has no horizontal component")
    try expectUI(arrow.1.y > center.y, "90° points down, got \(arrow.1.y) vs \(center.y)")
    try expectUI(abs((arrow.1.y - center.y) - radius) < 1e-9, "large magnitude saturates at the rim")

    // 0° points right.
    let right = CompassDialScene.primitives(degrees: 0, magnitude: 0)
    let rightArrow = lines(right).first { $0.2 == CompassDialScene.arrow }
    try expectUI(rightArrow.map { $0.1.x > center.x && abs($0.1.y - center.y) < 1e-9 } ?? false, "0° points right")
    try expectUI(
        rightArrow.map { abs(($0.1.x - center.x) - radius * 0.25) < 1e-9 } ?? false,
        "zero magnitude still draws a quarter-length arrow"
    )

    // No coma, no arrow — but the rim and labels stay.
    let empty = CompassDialScene.primitives(degrees: nil, magnitude: 0)
    try expectUI(lines(empty).filter { $0.2 == CompassDialScene.arrow }.isEmpty, "no arrow without a direction")
    try expectUI(texts(empty).map(\.0) == ["R", "D", "L", "U"], "dial labels")
    try expectUI(circles(empty).count == 1, "dial rim")
}

func testStarProfileScene() throws {
    let origin = SIMD2(StarProfileScene.padding, StarProfileScene.padding)
    let plot = SIMD2(
        StarProfileScene.size.x - StarProfileScene.padding * 2,
        StarProfileScene.size.y - StarProfileScene.padding * 2
    )
    // Full well sits at the top, the floor at the bottom.
    try expectUI(
        abs(StarProfileScene.yPosition(1, origin: origin, size: plot) - origin.y) < 1e-9,
        "100% at the top"
    )
    try expectUI(
        abs(StarProfileScene.yPosition(StarProfileScene.logFloor, origin: origin, size: plot) - (origin.y + plot.y)) < 1e-9,
        "the floor is the baseline"
    )
    try expectUI(
        StarProfileScene.yPosition(0.001, origin: origin, size: plot)
            == StarProfileScene.yPosition(StarProfileScene.logFloor, origin: origin, size: plot),
        "values under the floor clamp"
    )

    let empty = StarProfileScene.primitives(profile: nil)
    try expectUI(texts(empty).map(\.0) == ["100%", "1%", "0.15%"], "axis labels always drawn")

    let profile = StarIntensityProfile(samples: [1.0, 0.5, 0.1, 0.01], radiusPixels: 32, sectionCount: 4)
    let drawn = StarProfileScene.primitives(profile: profile)
    let polylines = drawn.flatMap { primitive -> [[SIMD2<Double>]] in
        if case .clipped(_, _, _, let inner) = primitive {
            return inner.compactMap { if case .polyline(let points, _, _) = $0 { return points } else { return nil } }
        }
        return []
    }
    try expectUI(polylines.count == 1, "one profile curve")
    try expectUI(polylines[0].count == 4, "one point per sample")
    try expectUI(abs(polylines[0][0].x - origin.x) < 1e-9, "curve starts at the left edge")
    try expectUI(abs(polylines[0][3].x - (origin.x + plot.x)) < 1e-9, "curve ends at the right edge")
}

func testImageLayoutNDCRect() throws {
    // A 100x100 image at zoom 1 in a 200x200 view sits in the middle.
    let layout = ImageLayout(
        imageWidth: 100,
        imageHeight: 100,
        viewWidth: 200,
        viewHeight: 200,
        zoom: 1
    )
    let ndc = layout.ndcRect()
    try expectUI(abs(ndc.x0 + 0.5) < 1e-12, "x0 \(ndc.x0)")
    try expectUI(abs(ndc.x1 - 0.5) < 1e-12, "x1 \(ndc.x1)")
    try expectUI(abs(ndc.y0 + 0.5) < 1e-12, "y0 \(ndc.y0)")
    try expectUI(abs(ndc.y1 - 0.5) < 1e-12, "y1 \(ndc.y1)")

    // Filling the view maps to the full NDC cube.
    let full = ImageLayout(imageWidth: 200, imageHeight: 200, viewWidth: 200, viewHeight: 200, zoom: 1)
    let fullNDC = full.ndcRect()
    try expectUI(abs(fullNDC.x0 + 1) < 1e-12 && abs(fullNDC.x1 - 1) < 1e-12, "full width")
    try expectUI(abs(fullNDC.y0 + 1) < 1e-12 && abs(fullNDC.y1 - 1) < 1e-12, "full height")

    // The vertical axis flips: a rect in the top half of the view has positive y.
    let top = ImageLayout(imageWidth: 200, imageHeight: 100, viewWidth: 200, viewHeight: 400, zoom: 1)
    let topNDC = top.ndcRect()
    try expectUI(topNDC.y1 > topNDC.y0, "y1 is the top edge")
    // imageRect y = (400-100)/2 = 150, so top = 1 - 2*150/400 = 0.25.
    try expectUI(abs(topNDC.y1 - 0.25) < 1e-12, "flipped top edge \(topNDC.y1)")
    try expectUI(abs(topNDC.y0 + 0.25) < 1e-12, "flipped bottom edge \(topNDC.y0)")
}

func testQuarterViewTiles() throws {
    let rect = (x: 0.0, y: 0.0, width: 512.0, height: 512.0)
    let tiles = QuarterView.quads(
        imageWidth: 512,
        imageHeight: 512,
        star: SIMD2(256, 256),
        imageRect: rect
    )
    try expectUI(tiles.count == 4, "four tiles, got \(tiles.count)")
    try expectUI(tiles.allSatisfy { abs($0.width - 256) < 1e-9 && abs($0.height - 256) < 1e-9 }, "a centred star fills every tile")
    // Top-left stays the original top-left quadrant, star at its inner corner.
    let topLeft = tiles.first { abs($0.x) < 1e-9 && abs($0.y) < 1e-9 }
    try expectUI(topLeft != nil, "a tile fills the top-left")
    try expectUI(abs((topLeft?.u0 ?? 1) - 0) < 1e-9 && abs((topLeft?.v0 ?? 1) - 0) < 1e-9, "top-left is not mirrored")
    try expectUI(abs((topLeft?.u1 ?? 0) - 0.5) < 1e-9 && abs((topLeft?.v1 ?? 0) - 0.5) < 1e-9, "its inner corner is the star")
    // Bottom-left shows the original top-right, so the horizontal seam joins
    // the two upper quadrants and an up-down mismatch is visible there too.
    let bottomLeft = tiles.first { abs($0.x) < 1e-9 && abs($0.y - 256) < 1e-9 }
    try expectUI(bottomLeft != nil, "a tile fills the bottom-left")
    try expectUI(abs((bottomLeft?.u0 ?? 0) - 1) < 1e-9 && abs((bottomLeft?.v1 ?? 1) - 0) < 1e-9, "bottom-left is the top-right quadrant, mirrored")
    try expectUI(abs((bottomLeft?.u1 ?? 0) - 0.5) < 1e-9 && abs((bottomLeft?.v0 ?? 0) - 0.5) < 1e-9, "its inner corner is the star")
    let topRight = tiles.first { abs($0.x - 256) < 1e-9 && abs($0.y) < 1e-9 }
    try expectUI(topRight != nil, "a tile fills the top-right")
    try expectUI(abs((topRight?.v0 ?? 0) - 1) < 1e-9, "top-right is the bottom quadrant, mirrored")
    try expectUI(abs((topRight?.v1 ?? 1) - 0.5) < 1e-9, "its inner edge is the star")
    try expectUI(tiles.allSatisfy { quad in
        let onStarX = abs(quad.x - 256) < 1e-6 || abs(quad.x + quad.width - 256) < 1e-6
        let onStarY = abs(quad.y - 256) < 1e-6 || abs(quad.y + quad.height - 256) < 1e-6
        return onStarX && onStarY
    }, "every tile meets the star")

    let off = QuarterView.quads(
        imageWidth: 512,
        imageHeight: 512,
        star: SIMD2(256, 100),
        imageRect: rect
    )
    let swappedUp = off.first { abs($0.x - 256) < 1e-6 && abs($0.y) < 1e-6 }
    try expectUI(abs((swappedUp?.height ?? 0) - 100) < 1e-6, "a tall quadrant is clipped to the space opposite the star")
}

/// Every stroke the scenes emit, including the ones inside a clip.
private func strokeWidths(_ primitives: [HUDPrimitive]) -> [Double] {
    var widths: [Double] = []
    for primitive in primitives {
        switch primitive {
        case .line(_, _, _, let width): widths.append(width)
        case .polyline(_, _, let width): widths.append(width)
        case .circle(_, _, _, let width): widths.append(width)
        case .rect(_, _, _, let width, _): widths.append(width)
        case .clipped(_, _, _, let inner): widths.append(contentsOf: strokeWidths(inner))
        case .disc, .fillRect, .fillPolygon, .text: continue
        }
    }
    return widths
}

/// The two apps stroke the same geometry through different canvases: SwiftUI
/// takes a width in points and antialiases it, ImGui takes one in pixels and
/// cannot go under one. `HUDDrawList` draws a sub-pixel stroke at a pixel wide
/// with the alpha scaled down, which is what antialiasing does — but only
/// convincingly down to about half a pixel. Below that the two apps would
/// start drawing visibly different pictures on a 100% display, so the scenes
/// stay above it.
func testHUDStrokeWidths() throws {
    let roi = ROI(x: 512, y: 256, width: 512, height: 512)
    let overlay = OverlayModel(
        imageWidth: 512,
        imageHeight: 512,
        sensorWidth: 2048,
        sensorHeight: 1024,
        roi: roi
    )
    let viewSize = SIMD2(800.0, 700.0)

    var scenes: [(String, [HUDPrimitive])] = [
        ("overlay", OverlayScene.primitives(overlay: overlay, zoom: 1, viewSize: viewSize)),
        ("roi map", ROIMapScene.primitives(sensorWidth: 2048, sensorHeight: 1024, roi: roi)),
        ("compass dial", CompassDialScene.primitives(degrees: 30, magnitude: 0.4)),
        ("compass dial, no coma", CompassDialScene.primitives(degrees: nil, magnitude: 0)),
    ]

    let histogram = Histogram(
        bins: (0..<Histogram.binCount).map { UInt32($0 % 97) },
        sampleCount: 4_096,
        maxADU: 54_000
    )
    scenes.append((
        "histogram",
        HistogramScene.primitives(histogram: histogram, stretch: .default, size: SIMD2(276.0, 56.0))
    ))

    let profile = StarIntensityProfile(
        samples: (0..<64).map { 1 - Double($0) / 64 },
        radiusPixels: 32,
        sectionCount: 4
    )
    scenes.append(("star profile", StarProfileScene.primitives(profile: profile)))
    scenes.append(("star profile, empty", StarProfileScene.primitives(profile: nil)))

    var thinnest = Double.greatestFiniteMagnitude
    for (name, primitives) in scenes {
        for width in strokeWidths(primitives) {
            try expectUI(width >= 0.5, "\(name) strokes \(width) points, too thin to fake with alpha")
            try expectUI(width <= 4, "\(name) strokes \(width) points, which is not a HUD line")
            thinnest = min(thinnest, width)
        }
    }
    // If this ever stops finding a sub-pixel stroke, HUDDrawList's alpha
    // compensation has become dead code and can go.
    try expectUI(thinnest < 1, "no scene strokes under a point any more (thinnest \(thinnest))")
}
