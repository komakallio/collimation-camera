import CSDL3
import CollimationCore

/// Window decoration that is not part of a frame: the icon (§9.6).
enum AppWindow {
    /// Sets the title bar, taskbar, and Alt-Tab icon from
    /// `Resources/AppIcon-256.png`. On macOS SDL's Cocoa backend forwards this
    /// to `NSApp.applicationIconImage`, so an unbundled `swift run` gets the
    /// Dock icon too. The icon Explorer and Start show comes from the PE
    /// resource in a packaged Windows build, not from here.
    ///
    /// A missing or unreadable icon is not fatal: the app runs with the
    /// default one and says so in the log.
    static func applyIcon(to window: OpaquePointer) {
        guard let url = AppPaths.resource("AppIcon-256.png") else {
            Log.info("No AppIcon-256.png found; using the default window icon.")
            return
        }
        guard let surface = url.path.withCString({ SDL_LoadPNG($0) }) else {
            Log.info("Could not load \(url.path): \(Diagnostics.sdlError())")
            return
        }
        // SDL_SetWindowIcon converts to the format it needs and keeps its own
        // copy, so the surface is released right away.
        if !SDL_SetWindowIcon(window, surface) {
            Log.info("SDL_SetWindowIcon failed: \(Diagnostics.sdlError())")
        }
        SDL_DestroySurface(surface)
    }
}
