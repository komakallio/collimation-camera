#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(CRT)
import CRT
#endif

/// Flushing lives here so `Log` stays free of platform imports (§12.1).
enum StandardOutput {
    static func flush() {
        fflush(stdout)
    }
}
