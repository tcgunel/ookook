import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let workspace = Workspace()
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = "Ookook"
        window.setFrameAutosaveName("OokookMainWindow")
        window.contentView = NSHostingView(rootView: ContentView(workspace: workspace))
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        workspace.load(configURL: Self.resolveConfigURL())
        window.title = workspace.projectName
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Never leave supervised children orphaned when the app goes away.
    func applicationWillTerminate(_ notification: Notification) {
        workspace.stopAll()
    }

    // MARK: - Config discovery

    /// An explicit path argument wins; otherwise search upward from the working
    /// directory the way git looks for `.git`.
    nonisolated private static func resolveConfigURL() -> URL {
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        if let first = args.first {
            let url = URL(fileURLWithPath: (first as NSString).expandingTildeInPath)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    return Workspace.findConfig(startingAt: url)
                        ?? url.appendingPathComponent("ookook.yml")
                }
                return url
            }
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return Workspace.findConfig(startingAt: cwd) ?? cwd.appendingPathComponent("ookook.yml")
    }

    // MARK: - Actions

    @objc private func openProject(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a project folder or an ookook.yml file."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        let configURL = isDirectory.boolValue
            ? (Workspace.findConfig(startingAt: url) ?? url.appendingPathComponent("ookook.yml"))
            : url
        workspace.load(configURL: configURL)
        window?.title = workspace.projectName
    }

    @objc private func reloadConfig(_ sender: Any?) {
        workspace.reload()
    }

    @objc private func startAll(_ sender: Any?) {
        workspace.startAll()
    }

    @objc private func stopAll(_ sender: Any?) {
        workspace.stopAll()
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
        projectMenu.addItem(withTitle: "Reload Config", action: #selector(reloadConfig(_:)), keyEquivalent: "r")
        projectMenu.addItem(.separator())
        projectMenu.addItem(withTitle: "Start All", action: #selector(startAll(_:)), keyEquivalent: "")
        projectMenu.addItem(withTitle: "Stop All", action: #selector(stopAll(_:)), keyEquivalent: "")
        for item in projectMenu.items where item.action != nil { item.target = self }
        projectItem.submenu = projectMenu
        mainMenu.addItem(projectItem)

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
