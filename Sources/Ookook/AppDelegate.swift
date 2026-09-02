import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let app = AppModel()
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()

        showMainWindow()

        // A path on the command line opens that project; otherwise pick up
        // wherever we were last, then fall back to the working directory.
        if let launchPath = Self.launchPath() {
            app.open(path: launchPath)
        } else {
            app.restoreOpenProjects()
            if app.projects.isEmpty {
                let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                if let config = Project.findConfig(startingAt: cwd) {
                    app.open(configURL: config)
                }
            }
        }

        // Agents connect to the app itself; no helper binary to install.
        Notifier.shared.requestAuthorization()
        app.startServices()
    }

    /// Closing the window does not quit.
    ///
    /// The agents and dev servers keep running, which is the point of a
    /// supervisor - losing a Claude session mid-task because the window was in
    /// the way would be indefensible. The Dock icon (or ⌘0) brings it back, and
    /// ⌘Q still quits properly, stopping everything.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { showMainWindow() }
        return true
    }

    /// Builds the window on first use, and re-shows it after it was closed.
    @objc func showMainWindow() {
        if let window {
            Self.moveOnScreenIfNeeded(window)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = "Ookook"
        window.setFrameAutosaveName("OokookMainWindow")
        window.contentView = NSHostingView(rootView: ContentView(app: app))
        // Without this the window is deallocated on close and `window` above
        // becomes a dangling reference - the app would sit there running with
        // no window and no way to get one back.
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        Self.moveOnScreenIfNeeded(window)
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Asks before closing while work is running.
    ///
    /// Closing does not stop anything, but it does take a wall of live agents
    /// off the screen, and the red button sits a few pixels from the sidebar -
    /// it is far too easy to hit by accident for something you cannot undo by
    /// pressing it again.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === window else { return true }
        let running = app.projects.flatMap(\.controllers).filter(\.status.isRunning).count
        guard running > 0, !UserDefaults.standard.bool(forKey: "suppressCloseConfirmation") else {
            return true
        }

        let alert = NSAlert()
        alert.messageText = "Close the Ookook window?"
        alert.informativeText = running == 1
            ? "1 process keeps running in the background. Reopen the window from the Dock icon or with ⌘0."
            : "\(running) processes keep running in the background. Reopen the window from the Dock icon or with ⌘0."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close Window")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"

        let close = alert.runModal() == .alertFirstButtonReturn
        if close, alert.suppressionButton?.state == .on {
            UserDefaults.standard.set(true, forKey: "suppressCloseConfirmation")
        }
        return close
    }

    /// Rescues a window left on a display that is no longer attached.
    ///
    /// `setFrameAutosaveName` restores wherever the window was last, and if that
    /// was a monitor you have since unplugged, the window is restored into empty
    /// space: the app runs, the Dock icon is there, and nothing is visible. This
    /// is why ⌘0 exists as well - so a window stranded while the app is already
    /// running can be pulled back.
    private static func moveOnScreenIfNeeded(_ window: NSWindow) {
        let frame = window.frame
        let visible = NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
        guard !visible, let main = NSScreen.main else { return }
        var recovered = frame
        recovered.size.width = min(frame.width, main.visibleFrame.width)
        recovered.size.height = min(frame.height, main.visibleFrame.height)
        window.setFrame(recovered, display: false)
        window.center()
    }

    /// Never leave supervised children orphaned when the app goes away.
    func applicationWillTerminate(_ notification: Notification) {
        app.persistScrollback()
        app.stopServices()
        app.stopAll()
    }

    private nonisolated static func launchPath() -> URL? {
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        guard let first = args.first else { return nil }
        let url = URL(fileURLWithPath: (first as NSString).expandingTildeInPath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Actions

    @objc private func openProject(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose a project folder or an ookook.yml file."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            app.open(path: url)
        }
    }

    @objc private func openSettings(_ sender: Any?) {
        // The selected project's .claude folder is shown beside the user's own;
        // with nothing selected the project tabs are simply absent.
        let root = (app.selection?.project).flatMap { app.project(id: $0)?.rootURL }
        SettingsWindowController.shared.show(
            projectRoot: root,
            ssh: app.ssh,
            projects: app.projects.map { (id: $0.id, name: $0.name) })
    }

    @objc private func toggleSound(_ sender: NSMenuItem) {
        Notifier.shared.soundEnabled.toggle()
        sender.state = Notifier.shared.soundEnabled ? .on : .off
    }

    @objc private func toggleBanners(_ sender: NSMenuItem) {
        Notifier.shared.bannersEnabled.toggle()
        sender.state = Notifier.shared.bannersEnabled ? .on : .off
    }

    @objc private func selectPreviousTerminal(_ sender: Any?) { app.selectAdjacent(by: -1) }
    @objc private func selectNextTerminal(_ sender: Any?) { app.selectAdjacent(by: 1) }
    @objc private func selectTerminalAbove(_ sender: Any?) { app.selectVertically(-1) }
    @objc private func selectTerminalBelow(_ sender: Any?) { app.selectVertically(1) }

    @objc private func reloadConfig(_ sender: Any?) { app.reloadAll() }
    @objc private func startAll(_ sender: Any?) { app.startAll() }
    @objc private func stopAll(_ sender: Any?) { app.stopAll() }

    @objc private func closeProject(_ sender: Any?) {
        guard let id = app.selection?.project, let project = app.project(id: id) else { return }
        app.close(project)
    }

    // MARK: - Menu

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Ookook", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Ookook", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Ookook", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let projectItem = NSMenuItem()
        let projectMenu = NSMenu(title: "Project")
        projectMenu.addItem(withTitle: "Ookook Window", action: #selector(showMainWindow), keyEquivalent: "0")
        projectMenu.addItem(.separator())
        projectMenu.addItem(withTitle: "Open Project…", action: #selector(openProject(_:)), keyEquivalent: "o")
        projectMenu.addItem(withTitle: "Close Project", action: #selector(closeProject(_:)), keyEquivalent: "w")
        projectMenu.addItem(withTitle: "Reload Configs", action: #selector(reloadConfig(_:)), keyEquivalent: "r")
        projectMenu.addItem(.separator())
        projectMenu.addItem(withTitle: "Start All", action: #selector(startAll(_:)), keyEquivalent: "")
        projectMenu.addItem(withTitle: "Stop All", action: #selector(stopAll(_:)), keyEquivalent: "")
        for item in projectMenu.items where item.action != nil { item.target = self }
        projectItem.submenu = projectMenu
        mainMenu.addItem(projectItem)

        // Moving between terminals from the keyboard.
        //
        // ⌘ plus an arrow rather than a modifier nobody presses by accident:
        // travelling the wall of agents is a thing you do constantly, and it
        // has to cost one hand. The trade is that ⌘← and ⌘→ no longer jump to
        // the ends of a line inside text fields, which in an app that is
        // almost entirely terminals is a fair price.
        let goItem = NSMenuItem()
        let goMenu = NSMenu(title: "Go")
        let directions: [(String, Selector, Int)] = [
            ("Previous Terminal", #selector(selectPreviousTerminal(_:)), NSLeftArrowFunctionKey),
            ("Next Terminal", #selector(selectNextTerminal(_:)), NSRightArrowFunctionKey),
            ("Terminal Above", #selector(selectTerminalAbove(_:)), NSUpArrowFunctionKey),
            ("Terminal Below", #selector(selectTerminalBelow(_:)), NSDownArrowFunctionKey),
        ]
        for (title, action, key) in directions {
            guard let scalar = UnicodeScalar(key) else { continue }
            let item = NSMenuItem(title: title, action: action, keyEquivalent: String(scalar))
            item.keyEquivalentModifierMask = [.command]
            item.target = self
            goMenu.addItem(item)
        }
        goItem.submenu = goMenu
        mainMenu.addItem(goItem)

        let alertsItem = NSMenuItem()
        let alertsMenu = NSMenu(title: "Alerts")
        let sound = NSMenuItem(title: "Play Sounds", action: #selector(toggleSound(_:)), keyEquivalent: "")
        sound.state = Notifier.shared.soundEnabled ? .on : .off
        sound.target = self
        alertsMenu.addItem(sound)
        let banners = NSMenuItem(title: "Show Notifications", action: #selector(toggleBanners(_:)), keyEquivalent: "")
        banners.state = Notifier.shared.bannersEnabled ? .on : .off
        banners.target = self
        alertsMenu.addItem(banners)
        alertsItem.submenu = alertsMenu
        mainMenu.addItem(alertsItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }
}
