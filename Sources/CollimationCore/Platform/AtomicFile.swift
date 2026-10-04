import Foundation
#if os(Windows)
import WinSDK
#elseif canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Commit a completed sibling temporary file without removing the old destination first.
enum AtomicFile {
    static func commit(_ temporary: URL, to destination: URL) throws {
#if os(Windows)
        let source = Array(temporary.path.utf16) + [0]
        let target = Array(destination.path.utf16) + [0]
        let succeeded = source.withUnsafeBufferPointer { sourceBuffer in
            target.withUnsafeBufferPointer { targetBuffer in
                // MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH, on the same volume.
                MoveFileExW(sourceBuffer.baseAddress, targetBuffer.baseAddress, DWORD(0x0000_0009))
            }
        }
        guard succeeded else {
            throw NSError(domain: "NSWin32ErrorDomain", code: Int(GetLastError()),
                userInfo: [NSLocalizedDescriptionKey: "Could not commit the completed focus constellation TIFF."])
        }
#else
        let result = temporary.path.withCString { source in
            destination.path.withCString { target in rename(source, target) }
        }
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
#endif
    }
}
