#if os(Windows)
import CollimationCore
import Foundation
import WinSDK
import WinSDK.DirectX

/// Compiles the stretch shaders to DXBC at run time.
///
/// SDL's D3D12 backend checks only the DXBC fourcc and hands the blob to the
/// pipeline, so `D3DCompile` from `d3dcompiler_47.dll` — which ships with
/// Windows 10 and 11 — is enough; no offline step and no shader toolchain.
///
/// Targets must be SM 5.1, not 5.0: without register spaces the root signature
/// does not match what SDL builds.
enum HLSLCompiler {
    /// The last compiler diagnostic, so a shader that fails to build reaches
    /// the startup message box and not only the log.
    nonisolated(unsafe) static var lastError: String?

    static func compile(source: String, entryPoint: String, target: String) -> Data? {
        var codeBlob: UnsafeMutablePointer<ID3DBlob>?
        var errorBlob: UnsafeMutablePointer<ID3DBlob>?

        let hr = source.withCString { sourcePointer -> HRESULT in
            entryPoint.withCString { entryPointer in
                target.withCString { targetPointer in
                    D3DCompile(
                        sourcePointer,
                        SIZE_T(strlen(sourcePointer)),
                        nil,        // source name, for error messages
                        nil,        // defines
                        nil,        // include handler
                        entryPointer,
                        targetPointer,
                        0,          // flags1
                        0,          // flags2
                        &codeBlob,
                        &errorBlob
                    )
                }
            }
        }

        defer {
            if let errorBlob { _ = errorBlob.pointee.lpVtbl.pointee.Release(errorBlob) }
        }

        if hr < 0 {
            var message = "D3DCompile failed, HRESULT 0x\(String(UInt32(bitPattern: hr), radix: 16))"
            if let errorBlob,
               let text = errorBlob.pointee.lpVtbl.pointee.GetBufferPointer(errorBlob) {
                let size = errorBlob.pointee.lpVtbl.pointee.GetBufferSize(errorBlob)
                let data = Data(bytes: text, count: Int(size))
                if let compilerText = String(data: data, encoding: .utf8) {
                    message += "\n\(compilerText)"
                }
            }
            Log.info(message)
            // Kept so the startup failure box can show what the compiler said,
            // not just "the pipeline could not be created" (§9.5).
            lastError = message
            return nil
        }

        guard let codeBlob else { return nil }
        defer { _ = codeBlob.pointee.lpVtbl.pointee.Release(codeBlob) }
        guard let pointer = codeBlob.pointee.lpVtbl.pointee.GetBufferPointer(codeBlob) else {
            return nil
        }
        let size = codeBlob.pointee.lpVtbl.pointee.GetBufferSize(codeBlob)
        return Data(bytes: pointer, count: Int(size))
    }
}
#endif
