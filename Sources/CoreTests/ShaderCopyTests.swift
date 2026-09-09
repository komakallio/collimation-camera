import CollimationCore
import Foundation

// The stretch maths exists in FOUR places, not the three every document used
// to claim:
//
//   1. StretchParams.apply         the CPU reference
//   2. MetalRenderer.shaderSource  MSL, and what the macOS release renders
//   3. ShaderSource.metal          MSL, and what the portable app renders
//   4. ShaderSource.hlslFragment   HLSL, Windows
//
// 2 and 3 are separate strings that happen to be identical from the fragment
// stage down. Follow the pull request checklist, edit ShaderSource.swift, and
// the macOS release goes on rendering the old curve — silently, because
// `stretch shader math` re-implements the maths in Swift and never reads
// either string.
//
// The right end state is one shared MSL fragment source, which is a change to
// a renderer nobody here can watch the output of. Until then this reads both
// files and fails the moment they drift, which is the part that matters.

/// The body of a Swift multi-line string literal that starts at `marker`.
private func stringLiteral(after marker: String, in text: String) throws -> [String] {
    guard let start = text.range(of: marker) else {
        throw UIModelExpectation(description: "no \(marker) — did the shader move or get renamed?")
    }
    let rest = text[start.upperBound...]
    guard let end = rest.range(of: "\n    \"\"\"") else {
        throw UIModelExpectation(description: "unterminated string literal after \(marker)")
    }
    return rest[..<end.lowerBound]
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { line in String(line.hasPrefix("    ") ? line.dropFirst(4) : line) }
}

/// The fragment stage, which is where every line of the stretch maths lives.
/// The vertex stage above it differs on purpose — Metal reads a vertex buffer,
/// SDL derives the quad from `vertex_id` — so only this part can be compared.
private func fragmentStage(_ lines: [String]) throws -> [String] {
    guard let start = lines.firstIndex(where: { $0.contains("fragment float4 stretchFragment") }) else {
        throw UIModelExpectation(description: "no stretchFragment in this shader")
    }
    return Array(lines[start...])
}

func testStretchShaderCopies() throws {
    let root = repositoryRoot()
    let appPath = root.appendingPathComponent("Sources/CollimationApp/MetalRenderer.swift")
    let portablePath = root.appendingPathComponent("Sources/CollimationPortableApp/ShaderSource.swift")

    // One file is CRLF in the working tree and the other LF, so line endings
    // are normalised first. Note this cannot be done by filtering out a
    // carriage return: Swift treats CRLF as a single Character, so a
    // comparison against a bare CR never matches it.
    func normalized(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "\r\n", with: "\n")
    }
    let appText = try normalized(appPath)
    let portableText = try normalized(portablePath)

    let appMSL = try stringLiteral(after: "shaderSource = \"\"\"\n", in: appText)
    let portableMSL = try stringLiteral(after: "static let metal = \"\"\"\n", in: portableText)

    let appFragment = try fragmentStage(appMSL)
    let portableFragment = try fragmentStage(portableMSL)

    if appFragment != portableFragment {
        let appOnly = appFragment.filter { !portableFragment.contains($0) }
        let portableOnly = portableFragment.filter { !appFragment.contains($0) }
        throw UIModelExpectation(description: """
            The two MSL fragment shaders have diverged. The macOS release renders \
            MetalRenderer.shaderSource; the portable app renders ShaderSource.metal. \
            A change to one has to be made to both, to the HLSL copy, and to \
            StretchParams.apply.
            Only in MetalRenderer.swift: \(appOnly.prefix(4).joined(separator: " | "))
            Only in ShaderSource.swift: \(portableOnly.prefix(4).joined(separator: " | "))
            """)
    }

    // The HLSL copy is a different language, so it cannot be compared line for
    // line. What can be pinned is the handful of expressions that are supposed
    // to be identical across all three, and that a partial edit would break.
    let hlsl = try stringLiteral(after: "static let hlslFragment = \"\"\"\n", in: portableText)
    let joinedHLSL = hlsl.joined(separator: "\n")
    let joinedMSL = portableFragment.joined(separator: "\n")

    for shared in [
        "float t = saturate((raw - ",
        "t = saturate(((m - 1.0) * t) / ((2.0 * m - 1.0) * t - m));",
        "return float4(t, t, t, 1);",
    ] {
        try expectUI(joinedMSL.contains(shared), "the MSL shaders lost: \(shared)")
        try expectUI(joinedHLSL.contains(shared), "the HLSL shader lost: \(shared)")
    }

    // The clip colour is written out in all three. A change to one of them is a
    // change to what a clipped pixel looks like on one platform only.
    let clipColour = "float4(1.0, 0.18, 0.14, 1.0)"
    try expectUI(appMSL.joined().contains(clipColour), "MetalRenderer clip colour changed alone")
    try expectUI(portableMSL.joined().contains(clipColour), "portable MSL clip colour changed alone")
    try expectUI(joinedHLSL.contains(clipColour), "HLSL clip colour changed alone")
}
