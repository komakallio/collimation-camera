import CollimationCore
import Foundation

public enum TiltText {
    public static func progress(_ progress: TiltProgress) -> String {
        let phase: String
        switch progress.phase {
        case .idle: return "Tilt measurement ready"
        case .moving: phase = "moving star"
        case .focusing: phase = "autofocusing"
        case .restoringFocus: phase = "restoring centre focus"
        case .stacking: phase = "stacking \(progress.collected)/\(progress.target)"
        case .checkingDrift: phase = "checking centre drift"
        case .saving: phase = "saving"
        case .complete: phase = "finished"
        case .cancelled: phase = "cancelled"
        case .failed: phase = "failed"
        }
        return "Tilt \(progress.index)/9 \(progress.label): \(phase)"
    }

    public static func point(_ point: TiltPointResult, reference: Int?) -> String {
        guard let focus = point.focus, let reference else { return "\(point.label): focus unavailable" }
        let text = String(format: "%@: %d (%+d steps)", point.label, focus.position, focus.position - reference)
        return text + (focus.diagnostics?.fit.map { String(format: "; fit uncertainty ~%.0f steps", $0.uncertaintySteps) } ?? "")
    }

    public static func summary(_ report: TiltMeasurementReport) -> [String] {
        var lines = ["Tilt \(report.status.rawValue): \(report.validOuterCount)/8 outer measurements"]
        if let common = report.commonFocus { lines.append("Images at centre focus: \(common) steps") }
        if let fit = report.fit {
            lines.append(String(format: "Tilt spread: %.1f steps%@", fit.spread, report.validOuterCount < 8 ? " (partial)" : ""))
            if let direction = fit.directionDegrees {
                lines.append(String(format: "Increasing focus: %.1f° clockwise from right", direction))
            }
            lines.append(String(format: "Radial offset: %+.1f steps; RMS %.1f", fit.radialOffset, fit.residualRMS))
        } else { lines.append("Tilt fit unavailable: need centre and six outer measurements with valid geometry.") }
        lines.append(report.drift.map { "Centre drift: \($0 >= 0 ? "+" : "")\($0) steps (uncorrected)" } ?? "Centre drift unavailable")
        for point in report.points {
            lines.append(self.point(point, reference: report.commonFocus))
            if let error = point.focusError { lines.append("\(point.label): \(error)") }
            if let error = point.imageError { lines.append("\(point.label) image: \(error)") }
        }
        if let warning = report.warning { lines.append(warning) }
        return lines
    }
}
