import Foundation

public enum MountError: Error, LocalizedError, Sendable {
    case notConnected
    case noPortSelected
    case openFailed(String)
    case timeout
    case unrecognized
    case noStar
    case notCalibrated
    case calibrationTooSmall(String)
    case cancelled
    case protocolFailure(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "The mount is not connected."
        case .noPortSelected:
            return "Select a serial port for the EQ6."
        case .openFailed(let path):
            return "Could not open serial port \(path)."
        case .timeout:
            return "Timed out waiting for the mount to respond."
        case .unrecognized:
            return "No EQ6 protocol on this port. Use a SynScan handset or EQDIR adapter at 9600 8N1."
        case .noStar:
            return "No tracked star. Keep the artificial star in the frame."
        case .notCalibrated:
            return "Calibrate the mount before centering."
        case .calibrationTooSmall(let axis):
            return "The \(axis) pulse barely moved the star. Check the cable, tracking, and that the mount can pulse-guide."
        case .cancelled:
            return "Mount move cancelled."
        case .protocolFailure(let detail):
            return "Mount command failed: \(detail)"
        }
    }
}
