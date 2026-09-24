import ASICameraC
import CollimationCore
import Foundation

/// The three ZWO codes the engine reacts to differently, pinned so a refactor
/// of the loader cannot quietly turn a disconnect into a generic SDK error:
/// a timeout is retried, a disconnect opens the error dialog and stops
/// capture, and an invalid ROI means the alignment rules were wrong.
func testASIErrorMapping() throws {
    try expectUI(ASIErrorMapping.cameraError(for: ASI_SUCCESS) == nil, "success maps to no error")

    func mapped(_ code: ASI_ERROR_CODE) throws -> CameraError {
        guard let error = ASIErrorMapping.cameraError(for: code) else {
            throw UIModelExpectation(description: "\(code.rawValue) mapped to no error")
        }
        return error
    }

    guard case .timeout = try mapped(ASI_ERROR_TIMEOUT) else {
        throw UIModelExpectation(description: "ASI_ERROR_TIMEOUT should map to .timeout")
    }
    for code in [ASI_ERROR_CAMERA_REMOVED, ASI_ERROR_CAMERA_CLOSED] {
        guard case .disconnected = try mapped(code) else {
            throw UIModelExpectation(description: "\(code.rawValue) should map to .disconnected")
        }
    }
    for code in [ASI_ERROR_INVALID_SIZE, ASI_ERROR_OUTOF_BOUNDARY] {
        guard case .invalidROI = try mapped(code) else {
            throw UIModelExpectation(description: "\(code.rawValue) should map to .invalidROI")
        }
    }

    // Everything else keeps its code and its message rather than being
    // flattened, so the error dialog can say what the SDK actually returned.
    for code in [
        ASI_ERROR_INVALID_INDEX,
        ASI_ERROR_INVALID_ID,
        ASI_ERROR_INVALID_CONTROL_TYPE,
        ASI_ERROR_INVALID_IMGTYPE,
        ASI_ERROR_INVALID_SEQUENCE,
        ASI_ERROR_BUFFER_TOO_SMALL,
        ASI_ERROR_VIDEO_MODE_ACTIVE,
        ASI_ERROR_EXPOSURE_IN_PROGRESS,
        ASI_ERROR_GENERAL_ERROR,
        ASI_ERROR_INVALID_MODE,
    ] {
        guard case .sdk(let vendor, let reported, let message) = try mapped(code) else {
            throw UIModelExpectation(description: "\(code.rawValue) should map to .sdk")
        }
        try expectUI(vendor == .zwo, "\(code.rawValue) reports the ZWO vendor")
        try expectUI(reported == Int32(code.rawValue), "\(code.rawValue) keeps its code, got \(reported)")
        try expectUI(!message.isEmpty, "\(code.rawValue) has a message")
        try expectUI(
            !message.hasPrefix("ZWO SDK error "),
            "\(code.rawValue) falls through to the generic message: \(message)"
        )
    }

    // An unknown code still produces something a user can report.
    let unknown = ASI_ERROR_CODE(rawValue: 9_999)
    guard case .sdk(_, let code, let message) = try mapped(unknown) else {
        throw UIModelExpectation(description: "an unknown code should still map to .sdk")
    }
    try expectUI(code == 9_999, "unknown code preserved")
    try expectUI(message.contains("9999"), "unknown code named in the message: \(message)")
}
