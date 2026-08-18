import AppKit
import SwiftUI

/// Hosts `SettingsView` in its own window.
///
/// The app builds its windows by hand rather than through a SwiftUI `App`, so
/// the settings panel needs the same treatment: one window, reused, brought back
/// to the front on a second invocation instead of stacking up copies.
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private let store = ClaudeConfigStore()

    private init() {}

    /// - Parameter projectRoot: the project whose `.claude` folder is shown next
    ///   to the user's own. Pass the selected project's `rootURL`; nil hides the
    ///   project tabs rather than guessing.
    func show(projectRoot: URL?) {
        store.setProjectRoot(projectRoot)
        store.reload()

        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "Settings"
        window.setFrameAutosaveName("OokookSettingsWindow")
        window.contentView = NSHostingView(rootView: SettingsView(store: store))
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }
}
