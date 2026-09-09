import CImGui
import CollimationUI
import Foundation

/// Draws a `[HUDPrimitive]` scene onto an ImGui draw list.
///
/// The portable half of §8.4, opposite `HUDCanvas` on macOS. Scene coordinates
/// are view points with the widget's own origin, so every coordinate is scaled
/// by `pointScale` and offset by where the widget sits (§9.6).
enum HUDDrawList {
    static func draw(
        _ primitives: [HUDPrimitive],
        on list: UnsafeMutablePointer<ImDrawList>?,
        origin: SIMD2<Double>,
        pointScale: Double
    ) {
        guard let list else { return }
        for primitive in primitives {
            draw(primitive, on: list, origin: origin, pointScale: pointScale)
        }
    }

    private static func draw(
        _ primitive: HUDPrimitive,
        on list: UnsafeMutablePointer<ImDrawList>,
        origin: SIMD2<Double>,
        pointScale: Double
    ) {
        func point(_ value: SIMD2<Double>) -> ImVec2 {
            ImVec2(
                x: Float(origin.x + value.x * pointScale),
                y: Float(origin.y + value.y * pointScale)
            )
        }
        func scaled(_ value: Double) -> Float { Float(value * pointScale) }
        // ImGui strokes thinner than a pixel disappear; the macOS canvas
        // antialiases them instead, so a floor keeps the two comparable.
        func stroke(_ width: Double) -> Float { max(Float(width * pointScale), 1) }

        switch primitive {
        case .line(let from, let to, let color, let width):
            ImDrawList_AddLine(list, point(from), point(to), color.packedABGR, stroke(width))

        case .polyline(let points, let color, let width):
            guard points.count >= 2 else { return }
            var converted = points.map(point)
            converted.withUnsafeMutableBufferPointer { buffer in
                ImDrawList_AddPolyline(
                    list,
                    buffer.baseAddress,
                    Int32(buffer.count),
                    color.packedABGR,
                    stroke(width),
                    0
                )
            }

        case .circle(let center, let radius, let color, let width):
            ImDrawList_AddCircle(list, point(center), scaled(radius), color.packedABGR, 0, stroke(width))

        case .disc(let center, let radius, let color):
            ImDrawList_AddCircleFilled(list, point(center), scaled(radius), color.packedABGR, 0)

        case .rect(let rectOrigin, let size, let color, let width, let cornerRadius):
            ImDrawList_AddRect(
                list,
                point(rectOrigin),
                point(rectOrigin + size),
                color.packedABGR,
                scaled(cornerRadius),
                stroke(width),
                0
            )

        case .fillRect(let rectOrigin, let size, let color, let cornerRadius):
            ImDrawList_AddRectFilled(
                list,
                point(rectOrigin),
                point(rectOrigin + size),
                color.packedABGR,
                scaled(cornerRadius),
                0
            )

        case .fillPolygon(let points, let color):
            guard points.count >= 3 else { return }
            var converted = points.map(point)
            converted.withUnsafeMutableBufferPointer { buffer in
                ImDrawList_AddConvexPolyFilled(
                    list,
                    buffer.baseAddress,
                    Int32(buffer.count),
                    color.packedABGR
                )
            }

        case .text(let value, let at, let anchor, let color, let size, let monospaced, let weight):
            let font = Fonts.font(monospaced: monospaced, weight: weight)
            // AddText takes the final rendered size, so it scales like the
            // coordinates do.
            let renderedSize = Float(size * pointScale)
            let measured = measure(value, font: font, size: renderedSize)
            var position = point(at)
            position.x -= measured.x * anchorFraction(anchor).x
            position.y -= measured.y * anchorFraction(anchor).y
            value.withCString { text in
                ImDrawList_AddText_FontPtr(
                    list,
                    font,
                    renderedSize,
                    position,
                    color.packedABGR,
                    text,
                    nil,
                    0,
                    nil
                )
            }

        case .clipped(let clipOrigin, let size, _, let inner):
            // ImGui clips to a rectangle; the scenes use a 1 pt corner radius
            // whose difference is below a pixel.
            ImDrawList_PushClipRect(list, point(clipOrigin), point(clipOrigin + size), true)
            for child in inner {
                draw(child, on: list, origin: origin, pointScale: pointScale)
            }
            ImDrawList_PopClipRect(list)
        }
    }

    /// cimgui returns the vector by value here, not through an out parameter.
    static func measure(_ text: String, font: UnsafeMutablePointer<ImFont>?, size: Float) -> ImVec2 {
        text.withCString { pointer in
            if let font {
                return ImFont_CalcTextSizeA(font, size, .greatestFiniteMagnitude, 0, pointer, nil, nil)
            }
            return igCalcTextSize(pointer, nil, false, -1)
        }
    }

    static func anchorFraction(_ anchor: HUDAnchor) -> ImVec2 {
        switch anchor {
        case .topLeading: return ImVec2(x: 0, y: 0)
        case .top: return ImVec2(x: 0.5, y: 0)
        case .topTrailing: return ImVec2(x: 1, y: 0)
        case .leading: return ImVec2(x: 0, y: 0.5)
        case .center: return ImVec2(x: 0.5, y: 0.5)
        case .trailing: return ImVec2(x: 1, y: 0.5)
        case .bottomLeading: return ImVec2(x: 0, y: 1)
        case .bottom: return ImVec2(x: 0.5, y: 1)
        case .bottomTrailing: return ImVec2(x: 1, y: 1)
        }
    }
}

/// Swift cannot import a variadic C function, so none of ImGui's text helpers
/// — `igText`, `igTextDisabled`, `igTextWrapped`, `igSetItemTooltip` — are
/// available (§14a). Each is rebuilt here from its non-variadic parts.
enum ImGuiText {
    static func plain(_ value: String) {
        value.withCString { igTextUnformatted($0, nil) }
    }

    /// `igTextDisabled` is the disabled colour plus `igText`.
    static func disabled(_ value: String) {
        if let color = igGetStyleColorVec4(Int32(ImGuiCol_TextDisabled.rawValue)) {
            igPushStyleColor_Vec4(Int32(ImGuiCol_Text.rawValue), color.pointee)
            plain(value)
            igPopStyleColor(1)
        } else {
            plain(value)
        }
    }

    /// `igTextWrapped` is a wrap position plus `igText`.
    static func wrapped(_ value: String) {
        igPushTextWrapPos(0)
        plain(value)
        igPopTextWrapPos()
    }

    /// Tooltip for the item just submitted. `igBeginItemTooltip` handles the
    /// hover delay and returns false when nothing should be shown.
    static func tooltip(_ value: String?) {
        guard let value, !value.isEmpty else { return }
        guard igBeginItemTooltip() else { return }
        plain(value)
        igEndTooltip()
    }
}
