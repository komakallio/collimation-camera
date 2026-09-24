#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(CRT)
import CRT
#endif

/// Flushing lives here so `Log` stays free of platform imports (§12.1).
enum StandardOutput {
    /// `fflush(nil)` is C's "flush every output stream". Naming `stdout` would
    /// not compile under Swift 6: on Darwin and Glibc it is an imported
    /// `extern FILE *` global, which strict concurrency rejects as shared
    /// mutable state. Only the Windows overlay declares it
    /// `nonisolated(unsafe)`.
    static func flush() {
        fflush(nil)
    }
}
