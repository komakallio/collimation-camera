import CollimationCore
import Foundation

/// Tooltips that belong to a control rather than to a command.
///
/// Command tooltips live on `Command.help`; these are the ones on sliders,
/// pickers, sections, and HUD widgets. Both apps show them: `.help` on macOS,
/// `igSetItemTooltip` after the item in ImGui.
public enum HelpText {
    public static let constellationFocusSweep = "Centre the star and autofocus, then record every constellation star across the configured sweep range and step size. Move the mount once per star and sweep focus upwards after backlash take-up. Uses the selected stacking count at every focus position. Requires a connected focuser and calibrated mount."
    public static let constellationFocusSweepRange = "Distance in motor steps on each side of centre best focus. Default ±4000. Must be positive and a multiple of the sweep step size. The full range and autofocus take-up must fit focuser travel."
    public static let constellationFocusSweepStep = "Spacing in motor steps between recorded focus positions. Default 250. Must be positive and divide the sweep range exactly, including centre best focus and both endpoints. At most \(FocusConstellationSettings.maximumCount) positions per star."
    public static let focuser = "ESATTO USB focuser. In decreases the position; Out increases it. Moves use the device's calibrated travel range."
    public static let focuserStepSize = "Distance in motor steps for each In or Out move."
    public static let focuserTarget = "Absolute position in motor steps. Enter a target, then press Go to."
    public static let autofocus = "Choose exposure, then fit nine five-frame median HFR measurements on both focus flanks. Settle for one second and discard three fresh frames after each approach. Accept focus from curve support, residuals and position sensitivity. Final HFR from three separated blocks is diagnostic only; it cannot reject or change the fitted position. Report approximate position uncertainty and leave-one-out sensitivity. Saturation during the scan restarts the entire curve. Stop cancels every phase."
    public static let autofocusStep = "Spacing in motor steps between nine curve samples, four either side. Choose enough spacing to measure both flanks. A flat curve needs a larger step. Take-up is set separately."
    public static let autofocusTakeUp = "Outward approach distance in motor steps, independent of scan spacing. Each reversed approach moves this far below its target first. Default 4000; the entire approach must fit calibrated travel. This does not change controller backlash compensation."
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
