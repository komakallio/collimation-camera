import Foundation

/// sRGB with straight alpha, 0…1 per component.
///
/// Every colour both UIs draw is spelled out here. The macOS app used named
/// SwiftUI system colours, which have no equivalent in ImGui, so those are
/// resolved to their Apple sRGB values and both renderers draw the constant.
public struct HUDColor: Equatable, Sendable {
    public var r: Float
    public var g: Float
    public var b: Float
    public var a: Float

    public init(_ r: Float, _ g: Float, _ b: Float, _ a: Float = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    /// 0…255 components, the form the vendor and Apple palettes are published in.
    public init(red: Int, green: Int, blue: Int, alpha: Double = 1) {
        self.init(Float(red) / 255, Float(green) / 255, Float(blue) / 255, Float(alpha))
    }

    public func opacity(_ value: Double) -> HUDColor {
        HUDColor(r, g, b, Float(value))
    }

    /// `amount` 0 keeps this colour; 1 is `other`.
    public func mixed(with other: HUDColor, amount: Double) -> HUDColor {
        let t = Float(max(0, min(1, amount)))
        return HUDColor(
            r + (other.r - r) * t,
            g + (other.g - g) * t,
            b + (other.b - b) * t,
            a + (other.a - a) * t
        )
    }

    public static let clear = HUDColor(0, 0, 0, 0)
    public static let white = HUDColor(1, 1, 1)
    public static let black = HUDColor(0, 0, 0)

    /// Apple system colours, resolved so ImGui can draw the same pixels.
    public static let systemOrange = HUDColor(red: 255, green: 149, blue: 0)
    public static let systemRed = HUDColor(red: 255, green: 59, blue: 48)
    public static let systemBlue = HUDColor(red: 0, green: 122, blue: 255)
    public static let systemYellow = HUDColor(red: 255, green: 204, blue: 0)
    public static let systemGray = HUDColor(red: 142, green: 142, blue: 147)

    /// Packed 0xAABBGGRR, the layout ImGui's draw list wants.
    public var packedABGR: UInt32 {
        func channel(_ value: Float) -> UInt32 {
            UInt32(max(0, min(1, value)) * 255 + 0.5)
        }
        return channel(r) | (channel(g) << 8) | (channel(b) << 16) | (channel(a) << 24)
    }
}

/// Where a text primitive sits relative to its anchor point.
public enum HUDAnchor: Sendable {
    case topLeading
    case top
    case topTrailing
    case leading
    case center
    case trailing
    case bottomLeading
    case bottom
    case bottomTrailing
}

public enum HUDWeight: Sendable {
    case regular
    case medium
    case semibold
    case bold
}
