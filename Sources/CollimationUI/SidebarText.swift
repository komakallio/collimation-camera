import Foundation

/// Sidebar section titles, control labels, and metric names.
///
/// These are the strings that are not attached to a command — a command's text
/// comes from `CommandCatalog`, a value's from `MetricText`, a tooltip's from
/// `HelpText`. Everything left over used to be written out by hand in both
/// sidebars, which is how the "Camera 2048×2048" caption came to be stated
/// three times, and how the coma metrics came to be written "Coma" on macOS and
/// "COMA" in the portable app — agreeing only because the SwiftUI view happened
/// to call `.uppercased()`.
///
/// Metric names are stored in the case they are read in. Both apps render them
/// upper case; that is presentation, and it belongs in the view.
public enum SidebarText {
    // MARK: - Sections

    public static let cameraSection = "Camera"
    public static let filterWheelSection = "Filter wheel"
    public static let mountSection = "Mount"
    public static let roiSection = "ROI & zoom"
    public static let stabilizationSection = "Image stabilization"
    public static let stretchSection = "Stretch"
    public static let collimationSection = "Collimation"

    /// In the order both sidebars lay them out, so a test can check that.
    public static let sections = [
        cameraSection,
        filterWheelSection,
        mountSection,
        roiSection,
        stabilizationSection,
        stretchSection,
        collimationSection,
    ]

    // MARK: - Controls

    public static let exposure = "Exposure"
    public static let gain = "Gain"
    public static let zoom = "Zoom"
    public static let black = "Black"
    public static let white = "White"
    public static let midtones = "Midtones"
    public static let arcsinhFactor = "Factor"

    // MARK: - Metrics

    public static let coma = "Coma"
    public static let direction = "Direction"
    public static let asymmetry = "Asymmetry"
    public static let fwhm = "FWHM"
    public static let snr = "SNR"

    public static let metrics = [coma, direction, asymmetry, fwhm, snr]
}
