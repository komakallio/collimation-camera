import CollimationCore
import Foundation

/// Every string both UIs display, formatted once.
///
/// A view never spells a format specifier of its own. The em dash placeholder
/// is the same one the pre-port sidebar used for a missing measurement.
public enum MetricText {
    public static let placeholder = "—"

    // MARK: - Collimation metrics

    public static func coma(_ coma: ComaResult?) -> String {
        guard let coma else { return placeholder }
        return String(format: "%.3f  (%.1f px)", coma.magnitudeNormalized, coma.magnitudePixels)
    }

    public static func direction(_ coma: ComaResult?) -> String {
        guard let coma else { return placeholder }
        return String(format: "%.0f°", coma.directionDegrees)
    }

    public static func asymmetry(_ coma: ComaResult?) -> String {
        guard let coma else { return placeholder }
        return String(format: "%.2f", coma.sectorAsymmetry)
    }

    /// Blank while the star is lost or a search is running, so a stale number
    /// is never shown next to a missing star.
    public static func fwhm(_ fwhm: FWHMResult?, trackingState: TrackingState) -> String {
        if trackingState == .lost || trackingState == .searching { return placeholder }
        guard let fwhm else { return placeholder }
        return String(format: "%.2f″  (%.1f px)", fwhm.arcseconds, fwhm.sensorPixels)
    }

    public static func snr(_ detection: StarDetection?, trackingState: TrackingState) -> String {
        if trackingState == .lost || trackingState == .searching { return "star lost" }
        guard let snr = detection?.snr else { return placeholder }
        return String(format: "%.0f", snr)
    }

    /// The sentence under the metrics that says what to do next.
    public static func quality(
        trackingState: TrackingState,
        starPeak: UInt16?,
        coma: ComaResult?
    ) -> String {
        switch trackingState {
        case .searching:
            return "Searching the full frame for the artificial star."
        case .lost:
            return "Star dropped out of the ROI. Search starts after a few frames."
        case .tracking:
            switch starPeak.map(StarQuality.from) {
            case .saturated:
                return "Star is saturating. Lower exposure or gain. Clipped pixels are red."
            case .faint:
                return "Star peak is under 10% of full well. Increase exposure."
            case .good, .none:
                break
            }
            if let quality = coma?.quality, quality >= 0.6 {
                if coma?.isDonut == false {
                    return "In-focus star. Reduce the normalized coma toward zero."
                }
                return "Donut locked. Reduce the normalized coma toward zero."
            }
            if coma?.isDonut == false {
                return "In-focus star locked. Coma is the offset of the bright core from the geometric center."
            }
            return "Star found. Defocus until the secondary shadow is clear."
        case .idle:
            return "Connect a camera or the simulator to begin."
        }
    }

    // MARK: - Controls

    /// Exposure gains a decimal as it gets shorter, so sub-millisecond values
    /// stay readable.
    public static func exposureLabel(microseconds: Double) -> String {
        let ms = microseconds / 1000
        if ms < 1 { return String(format: "%.2f ms", ms) }
        if ms < 10 { return String(format: "%.1f ms", ms) }
        return String(format: "%.0f ms", ms)
    }

    public static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }

    public static func gain(_ value: Double) -> String {
        String(format: "%.0f", value)
    }

    public static func midtones(_ value: Double) -> String {
        String(format: "%.4f", value)
    }

    public static func arcsinhFactor(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    public static func zoomPercent(_ zoom: Double) -> String {
        String(format: "%.0f%%", zoom * 100)
    }

    public static func zoomAndFPS(zoom: Double, fps: Double) -> String {
        String(format: "%.0f%%  ·  %.1f fps", zoom * 100, fps)
    }

    public static func stackCount(_ count: Int) -> String {
        "\(count)"
    }

    // MARK: - Devices

    /// `/dev/cu.usbserial-1` shows as `cu.usbserial-1`; `COM3` is already short.
    public static func serialPortName(_ path: String) -> String {
        guard path.contains("/") else { return path }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    public static func filterWheelPlaceholder(sdkPresent: Bool) -> String {
        sdkPresent ? "No Phoenix wheel" : "SDK not found"
    }

    public static let serialPortPlaceholder = "No serial ports"

    /// The calibration lines under the mount status: when it was measured, and
    /// the backlash line only when either axis exceeds half a pixel.
    public static func calibrationSummary(_ calibration: GuideCalibration) -> [String] {
        var lines = [calibration.calibratedAt.formatted(date: .abbreviated, time: .shortened)]
        if calibration.raBacklashPixels > 0.5 || calibration.decBacklashPixels > 0.5 {
            lines.append(String(
                format: "Backlash  RA %.0f px  ·  Dec %.0f px",
                calibration.raBacklashPixels,
                calibration.decBacklashPixels
            ))
        }
        return lines
    }
}

/// The exposure and arcsinh sliders move in log space so the low end is usable.
public enum LogSlider {
    public static func range(_ bounds: ClosedRange<Double>) -> ClosedRange<Double> {
        log10(bounds.lowerBound)...log10(bounds.upperBound)
    }

    public static func position(_ value: Double, in bounds: ClosedRange<Double>) -> Double {
        log10(min(max(value, bounds.lowerBound), bounds.upperBound))
    }

    public static func value(_ position: Double) -> Double {
        pow(10, position)
    }
}
