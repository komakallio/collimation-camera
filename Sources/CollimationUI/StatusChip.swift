import CollimationCore
import Foundation

/// The capsule over the live view that says what the app is doing.
///
/// Stack work outranks mount work, which outranks auto exposure, which
/// outranks the tracking state — the same order the pre-port view used, so a
/// long operation is never hidden behind a tracking label.
public enum StatusChip {
    public struct Model: Equatable, Sendable {
        public var label: String
        public var color: HUDColor

        public init(label: String, color: HUDColor) {
            self.label = label
            self.color = color
        }
    }

    public static let busyColor = HUDColor(0.55, 0.85, 0.95)
    public static let attentionColor = HUDColor(0.95, 0.72, 0.22)
    public static let centeringColor = HUDColor(0.45, 0.75, 1)
    public static let trackingColor = HUDColor(0.35, 0.85, 0.45)

    /// The capsule background is drawn at 85% opacity with black text.
    public static let backgroundOpacity = 0.85

    @MainActor
    public static func model(_ engine: CollimationEngine) -> Model {
        model(
            stackWork: engine.stackWork,
            mountWork: engine.mountWork,
            isAutoExposing: engine.isAutoExposing,
            trackingState: engine.tracking.state
        )
    }

    public static func model(
        stackWork: StackWork?,
        mountWork: MountWork?,
        isAutoExposing: Bool,
        trackingState: TrackingState
    ) -> Model {
        if let stackWork {
            switch stackWork {
            case .capturing(let collected, let target):
                return Model(label: "STACKING \(collected)/\(target)", color: busyColor)
            case .combining, .constellationCombining:
                return Model(label: "COMBINING", color: busyColor)
            case .constellationMoving(let step, let steps):
                return Model(label: "CONSTELLATION \(step)/\(steps)", color: busyColor)
            case .constellationCapturing(let step, let steps, let collected, let target):
                return Model(
                    label: "CONST \(step)/\(steps)  \(collected)/\(target)",
                    color: busyColor
                )
            }
        }
        if let mountWork {
            switch mountWork {
            case .calibrating:
                return Model(label: "CALIBRATING", color: attentionColor)
            case .centering:
                return Model(label: "CENTERING", color: centeringColor)
            }
        }
        if isAutoExposing {
            return Model(label: "AUTO-EXPOSURE", color: attentionColor)
        }
        switch trackingState {
        case .tracking: return Model(label: "TRACKING", color: trackingColor)
        case .searching: return Model(label: "SEARCHING", color: .systemOrange)
        case .lost: return Model(label: "LOST", color: .systemRed)
        case .idle: return Model(label: "IDLE", color: .systemGray)
        }
    }
}
