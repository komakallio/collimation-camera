import CollimationUI
import SwiftUI

/// Draws a `[HUDPrimitive]` scene with SwiftUI's `GraphicsContext`.
///
/// The macOS half of §8.4. Every HUD widget is now a scene from CollimationUI
/// plus this one rasterizer, so the portable app can draw the same geometry
/// through an ImGui draw list.
struct HUDCanvas: View {
    let primitives: [HUDPrimitive]

    var body: some View {
        Canvas { context, _ in
            HUDCanvas.draw(primitives, in: &context)
        }
    }

    static func draw(_ primitives: [HUDPrimitive], in context: inout GraphicsContext) {
        for primitive in primitives {
            draw(primitive, in: &context)
        }
    }

    private static func draw(_ primitive: HUDPrimitive, in context: inout GraphicsContext) {
        switch primitive {
        case .line(let from, let to, let color, let width):
            var path = Path()
            path.move(to: point(from))
            path.addLine(to: point(to))
            context.stroke(path, with: .color(swiftUIColor(color)), lineWidth: width)

        case .polyline(let points, let color, let width):
            guard points.count >= 2 else { return }
            var path = Path()
            path.move(to: point(points[0]))
            for value in points.dropFirst() {
                path.addLine(to: point(value))
            }
            context.stroke(path, with: .color(swiftUIColor(color)), lineWidth: width)

        case .circle(let center, let radius, let color, let width):
            context.stroke(
                Path(ellipseIn: square(center: center, radius: radius)),
                with: .color(swiftUIColor(color)),
                lineWidth: width
            )

        case .disc(let center, let radius, let color):
            context.fill(
                Path(ellipseIn: square(center: center, radius: radius)),
                with: .color(swiftUIColor(color))
            )

        case .rect(let origin, let size, let color, let width, let cornerRadius):
            context.stroke(
                path(origin: origin, size: size, cornerRadius: cornerRadius),
                with: .color(swiftUIColor(color)),
                lineWidth: width
            )

        case .fillRect(let origin, let size, let color, let cornerRadius):
            context.fill(
                path(origin: origin, size: size, cornerRadius: cornerRadius),
                with: .color(swiftUIColor(color))
            )

        case .fillPolygon(let points, let color):
            guard points.count >= 3 else { return }
            var path = Path()
            path.move(to: point(points[0]))
            for value in points.dropFirst() {
                path.addLine(to: point(value))
            }
            path.closeSubpath()
            context.fill(path, with: .color(swiftUIColor(color)))

        case .text(let value, let at, let anchor, let color, let size, let monospaced, let weight):
            context.draw(
                Text(value)
                    .font(.system(
                        size: size,
                        weight: fontWeight(weight),
                        design: monospaced ? .monospaced : .default
                    ))
                    .foregroundColor(swiftUIColor(color)),
                at: point(at),
                anchor: unitPoint(anchor)
            )

        case .clipped(let origin, let size, let cornerRadius, let inner):
            context.drawLayer { layer in
                layer.clip(to: path(origin: origin, size: size, cornerRadius: cornerRadius))
                draw(inner, in: &layer)
            }
        }
    }

    // MARK: - Conversions

    private static func point(_ value: SIMD2<Double>) -> CGPoint {
        CGPoint(x: value.x, y: value.y)
    }

    private static func square(center: SIMD2<Double>, radius: Double) -> CGRect {
        CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }

    private static func path(origin: SIMD2<Double>, size: SIMD2<Double>, cornerRadius: Double) -> Path {
        let rect = CGRect(x: origin.x, y: origin.y, width: size.x, height: size.y)
        if cornerRadius <= 0 { return Path(rect) }
        return Path(roundedRect: rect, cornerRadius: cornerRadius)
    }

    static func swiftUIColor(_ color: HUDColor) -> Color {
        Color(
            .sRGB,
            red: Double(color.r),
            green: Double(color.g),
            blue: Double(color.b),
            opacity: Double(color.a)
        )
    }

    private static func fontWeight(_ weight: HUDWeight) -> Font.Weight {
        switch weight {
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        }
    }

    private static func unitPoint(_ anchor: HUDAnchor) -> UnitPoint {
        switch anchor {
        case .topLeading: return .topLeading
        case .top: return .top
        case .topTrailing: return .topTrailing
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        case .bottomLeading: return .bottomLeading
        case .bottom: return .bottom
        case .bottomTrailing: return .bottomTrailing
        }
    }
}
