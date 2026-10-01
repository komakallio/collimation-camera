import CollimationCore
import Foundation

/// Tooltips that belong to a control rather than to a command.
///
/// Command tooltips live on `Command.help`; these are the ones on sliders,
/// pickers, sections, and HUD widgets. Both apps show them: `.help` on macOS,
/// `igSetItemTooltip` after the item in ImGui.
public enum HelpText {
    public static let focuser = "ESATTO USB focuser. In decreases the position; Out increases it. Moves use the device's calibrated travel range."
    public static let focuserStepSize = "Distance in motor steps for each In or Out move."
    public static let focuserTarget = "Absolute position in motor steps. Enter a target, then press Go to."
    public static let autofocus = "Scan nine positions around the current focus using the tracked star's half-flux radius. Requires a real camera, an unsaturated star and room within calibrated travel. Stop cancels the run."
    public static let autofocusStep = "Spacing in motor steps between autofocus samples. The scan covers four steps either side, plus one inward step for the approach. Choose a step larger than backlash. A flat curve needs a larger step."
    public static let stackCount = "Number of 256×256 frames to capture and average"

    public static let stackedSave =
        "Capture 256×256 crops at full camera readout, register them on the star centroid, average, and save a 32-bit float TIFF"

    public static func filterPicker(slotCount: Int) -> String {
        "Stored aliases come from the wheel. Positions are 1–\(slotCount)."
    }

    public static let roiSection: String = {
        let window = CaptureLayout.trackingHardwareSize
        let crop = CaptureLayout.displayCropSize
        return "Keep the \(window)×\(window) camera window on the star. "
            + "The live view is a \(crop)×\(crop) software crop."
    }()

    public static let arcsinh = "asinh(αx) / asinh(α). Larger α lifts the faint background more."

    public static let fwhm = "Full width at half maximum. 1600 mm focal length, 3.76 µm pixels."

    public static let legend =
        "White cross is the physical sensor center, 200 sensor pixels each way, fading out to the tracking grid by halfway. While a star is tracked, faint lines sit every 200 sensor pixels. The star marker is green when exposure is good, yellow when faint, and red when clipped. Cyan is the outer donut, gold the secondary shadow, red the coma."

    public static let roiMap =
        "Full sensor with the current camera ROI. White plus is the physical sensor center. Grid lines are sensor quarters."

    public static let starProfile =
        "Average of four cuts through the star (horizontal, vertical, both diagonals). Vertical scale is logarithmic, 0.15% to 16-bit full well."
}
