import CollimationCore
import Foundation

/// Tooltips that belong to a control rather than to a command.
///
/// Command tooltips live on `Command.help`; these are the ones on sliders,
/// pickers, sections, and HUD widgets. Both apps show them: `.help` on macOS,
/// `igSetItemTooltip` after the item in ImGui.
public enum HelpText {
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
        "White plus is the physical sensor center. The star marker is green when exposure is good, yellow when faint, and red when clipped. Cyan is the outer donut, gold the secondary shadow, red the coma."

    public static let roiMap =
        "Full sensor with the current camera ROI. White plus is the physical sensor center. Grid lines are sensor quarters."

    public static let starProfile =
        "Average of four cuts through the star (horizontal, vertical, both diagonals). Vertical scale is logarithmic, 0.15% to 16-bit full well."
}
