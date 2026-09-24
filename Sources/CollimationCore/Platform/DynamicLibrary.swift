#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#if os(Windows)
import WinSDK
#endif
import Foundation

/// A vendor SDK opened at run time. The app links no vendor binary, so a
/// missing camera or filter-wheel library is a status message, not a
/// launch failure.
///
/// `candidates` are tried in order, then the bare file name, which lets the
/// platform loader search its own directories.
public struct DynamicLibrary: @unchecked Sendable {
#if os(Windows)
    private let module: HMODULE
#else
    private let module: UnsafeMutableRawPointer
#endif

    public init?(candidates: [String], bareName: String) {
        var attempts: [String] = []
#if os(Windows)
        var opened: HMODULE?
#else
        var opened: UnsafeMutableRawPointer?
#endif
        for path in candidates {
            if let handle = Self.load(path) {
                opened = handle
                break
            }
            attempts.append("\(path) — \(Self.lastError())")
        }
        if opened == nil {
            if let handle = Self.load(bareName) {
                opened = handle
            } else {
                attempts.append("\(bareName) — \(Self.lastError())")
            }
        }
        guard let module = opened else {
            Log.info("Could not load \(bareName):")
            for attempt in attempts {
                Log.info("  \(attempt)")
            }
            return nil
        }
        self.module = module
    }

    /// Resolves `name` and reinterprets it as `T`, which must be a
    /// `@convention(c)` function type matching the SDK declaration.
    public func symbol<T>(_ name: String) -> T? {
#if os(Windows)
        guard let address = GetProcAddress(module, name) else { return nil }
        return unsafeBitCast(address, to: T.self)
#else
        guard let address = dlsym(module, name) else { return nil }
        return unsafeBitCast(address, to: T.self)
#endif
    }

    /// Directories searched for a vendor library, in order: next to the
    /// executable, the macOS bundle's Frameworks folder, `Vendor/<vendorFolder>`
    /// under the working directory, the working directory, then the platform
    /// defaults.
    public static func candidatePaths(fileName: String, vendorFolder: String) -> [String] {
        var paths: [String] = []
        if let executable = Bundle.main.executablePath {
            let directory = URL(fileURLWithPath: executable).deletingLastPathComponent()
            paths.append(directory.appendingPathComponent(fileName).path)
            paths.append(
                directory
                    .deletingLastPathComponent()
                    .appendingPathComponent("Frameworks")
                    .appendingPathComponent(fileName).path
            )
        }
#if os(macOS)
        if let frameworks = Bundle.main.privateFrameworksPath {
            paths.append(frameworks + "/" + fileName)
        }
#endif
        let cwd = FileManager.default.currentDirectoryPath
        let cwdURL = URL(fileURLWithPath: cwd, isDirectory: true)
        paths.append(
            cwdURL
                .appendingPathComponent("Vendor")
                .appendingPathComponent(vendorFolder)
                .appendingPathComponent(fileName).path
        )
        paths.append(cwdURL.appendingPathComponent(fileName).path)
#if os(macOS)
        paths.append("/usr/local/lib/" + fileName)
        paths.append(
            URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library")
                .appendingPathComponent(vendorFolder)
                .appendingPathComponent(fileName).path
        )
#endif
        var seen = Set<String>()
        return paths
            .map(normalizeSeparators)
            .filter { seen.insert($0).inserted }
    }

    /// `URL.path` yields forward slashes even on Windows. Win32 accepts them,
    /// but native separators keep the loader diagnostics readable and avoid
    /// any path-parsing corner case.
    private static func normalizeSeparators(_ path: String) -> String {
#if os(Windows)
        return path.replacingOccurrences(of: "/", with: "\\")
#else
        return path
#endif
    }

#if os(Windows)
    private static func load(_ path: String) -> HMODULE? {
        // LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR (0x100) lets a vendor DLL find its
        // own dependencies next to it; LOAD_LIBRARY_SEARCH_DEFAULT_DIRS
        // (0x1000) keeps the application and system directories in the search.
        // Both require a fully qualified path — passing them with a bare file
        // name fails with ERROR_INVALID_PARAMETER instead of searching — so a
        // bare name goes through the standard search order, which is the whole
        // point of that fallback.
        let flags: DWORD = isAbsolute(path) ? 0x0000_0100 | 0x0000_1000 : 0
        return path.withCString(encodedAs: UTF16.self) { wide in
            LoadLibraryExW(wide, nil, flags)
        }
    }

    /// `C:\...`, `\\server\share\...`, or `\\?\...`.
    private static func isAbsolute(_ path: String) -> Bool {
        let scalars = Array(path.unicodeScalars)
        if scalars.count >= 2, scalars[0] == "\\", scalars[1] == "\\" { return true }
        guard scalars.count >= 3, scalars[1] == ":" else { return false }
        return scalars[2] == "\\" || scalars[2] == "/"
    }

    private static func lastError() -> String {
        "Windows error \(GetLastError())"
    }
#else
    private static func load(_ path: String) -> UnsafeMutableRawPointer? {
        dlopen(path, RTLD_NOW | RTLD_LOCAL)
    }

    private static func lastError() -> String {
        guard let message = dlerror() else { return "not found" }
        return String(cString: message)
    }
#endif
}

/// Platform file names for the vendor libraries loaded at run time.
public enum VendorLibrary {
#if os(Windows)
    public static let playerOneCamera = "PlayerOneCamera.dll"
    public static let playerOneFilterWheel = "PlayerOnePW.dll"
    public static let zwoCamera = "ASICamera2.dll"
#elseif os(macOS)
    public static let playerOneCamera = "libPlayerOneCamera.dylib"
    public static let playerOneFilterWheel = "libPlayerOnePW.dylib"
    public static let zwoCamera = "libASICamera2.dylib"
#else
    public static let playerOneCamera = "libPlayerOneCamera.so"
    public static let playerOneFilterWheel = "libPlayerOnePW.so"
    public static let zwoCamera = "libASICamera2.so"
#endif

    public static let playerOneFolder = "PlayerOne"
    public static let zwoFolder = "ZWO"
}
