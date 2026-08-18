import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let app = AppModel()
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = "Ookook"
        window.setFrameAutosaveName("OokookMainWindow")
        window.contentView = NSHostingView(rootView: ContentView(app: app))
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window

        NSApp.activate(ignoringOtherApps: true)

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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Never leave supervised children orphaned when the app goes away.
    func applicationWillTerminate(_ notification: Notification) {
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

    @objc private func toggleSound(_ sender: NSMenuItem) {
        Notifier.shared.soundEnabled.toggle()
        sender.state = Notifier.shared.soundEnabled ? .on : .off
    }

    @objc private func toggleBanners(_ sender: NSMenuItem) {
        Notifier.shared.bannersEnabled.toggle()
        sender.state = Notifier.shared.bannersEnabled ? .on : .off
    }

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
        appMenu.addItem(withTitle: "Hide Ookook", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Ookook", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let projectItem = NSMenuItem()
        let projectMenu = NSMenu(title: "Project")
        projectMenu.addItem(withTitle: "Open Project…", action: #selector(openProject(_:)), keyEquivalent: "o")
        projectMenu.addItem(withTitle: "Close Project", action: #selector(closeProject(_:)), keyEquivalent: "w")
        projectMenu.addItem(withTitle: "Reload Configs", action: #selector(reloadConfig(_:)), keyEquivalent: "r")
        projectMenu.addItem(.separator())
        projectMenu.addItem(withTitle: "Start All", action: #selector(startAll(_:)), keyEquivalent: "")
        projectMenu.addItem(withTitle: "Stop All", action: #selector(stopAll(_:)), keyEquivalent: "")
        for item in projectMenu.items where item.action != nil { item.target = self }
        projectItem.submenu = projectMenu
        mainMenu.addItem(projectItem)

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
