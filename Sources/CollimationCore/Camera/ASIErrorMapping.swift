import ASICameraC
import Foundation

/// ZWO error code to `CameraError`.
///
/// Free-standing and public so the mapping can be pinned by a test without a
/// camera, without the SDK, and without an `ASINative` instance — `ASINative`
/// cannot be built at all unless `ASICamera2` loads. The three special cases
/// are the ones the engine reacts to: a timeout is retried, a disconnect opens
/// the error dialog and stops capture, and an invalid ROI means the alignment
/// rules were wrong. Everything else is reported verbatim.
public enum ASIErrorMapping {
    /// Nil for `ASI_SUCCESS`; otherwise the error to throw.
    public static func cameraError(for error: ASI_ERROR_CODE) -> CameraError? {
        if error == ASI_SUCCESS { return nil }
        if error == ASI_ERROR_TIMEOUT { return .timeout }
        if error == ASI_ERROR_CAMERA_REMOVED || error == ASI_ERROR_CAMERA_CLOSED {
            return .disconnected
        }
        if error == ASI_ERROR_INVALID_SIZE || error == ASI_ERROR_OUTOF_BOUNDARY {
            return .invalidROI
        }
        return .sdk(
            vendor: .zwo,
            code: Int32(error.rawValue),
            message: ASINative.message(for: error)
        )
    }
}
