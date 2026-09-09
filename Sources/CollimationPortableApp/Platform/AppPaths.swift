import CollimationCore
import Foundation

/// Where the app finds its resources and writes its log.
///
/// `swift run` starts an unbundled executable, a packaged build has the files
/// beside it or in a bundle, and a developer may run from the repository root.
/// All three are searched, in that order.
enum AppPaths {
    static var executableDirectory: URL? {
        guard let path = Bundle.main.executablePath else { return nil }
        return URL(fileURLWithPath: path).deletingLastPathComponent()
    }

    /// Directories that may hold `Resources/`, most specific first.
    static var resourceRoots: [URL] {
        var roots: [URL] = []
        if let executableDirectory {
            roots.append(executableDirectory)
            // macOS bundle: Contents/MacOS/<exe> → Contents/Resources
            roots.append(executableDirectory.deletingLastPathComponent())
        }
        roots.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
        return roots
    }

    /// Looks for `Resources/<relative>` and `<relative>` under each root.
    static func resource(_ relative: String) -> URL? {
        for root in resourceRoots {
            for candidate in [
                root.appendingPathComponent("Resources").appendingPathComponent(relative),
                root.appendingPathComponent(relative),
            ] {
                if FileManager.default.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        return nil
    }

    static func font(_ fileName: String) -> URL? {
        resource("Fonts/\(fileName)")
    }

    /// `%LOCALAPPDATA%\Collimation Camera` on Windows,
    /// `~/Library/Logs/Collimation Camera` on macOS. The Windows directory is
    /// the same one `GuideCalibrationStore` uses.
    static var logDirectory: URL {
#if os(macOS)
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return base.appendingPathComponent("Logs").appendingPathComponent("Collimation Camera")
#else
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return base.appendingPathComponent("Collimation Camera")
#endif
    }

    static var logFile: URL {
        logDirectory.appendingPathComponent("collimation.log")
    }
}
