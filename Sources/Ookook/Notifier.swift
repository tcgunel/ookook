import AppKit
import UserNotifications

/// Tells you when an agent finishes or gets stuck, so you can look away from
/// the window without missing the moment you are needed.
@MainActor
final class Notifier {
    static let shared = Notifier()

    /// Users who want silence get it; a tool that pings constantly gets muted
    /// entirely, which is worse than not pinging at all.
    var soundEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "notifySound") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "notifySound") }
    }

    var bannersEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "notifyBanners") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "notifyBanners") }
    }

    private var authorized = false

    func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
                Task { @MainActor in self?.authorized = granted }
            }
    }

    /// An agent stopped working and is now waiting on the user.
    func agentNeedsAttention(process: String, project: String) {
        post(title: "\(process) needs you",
             body: "\(project) - the agent is waiting for a reply.",
             sound: "Funk")
        // Bounce the Dock icon until the app is focused; this is the one case
        // worth interrupting for.
        NSApp.requestUserAttention(.informationalRequest)
    }

    /// An agent finished a turn and went quiet.
    func agentFinished(process: String, project: String) {
        post(title: "\(process) finished",
             body: "\(project) - the agent stopped working.",
             sound: "Glass")
    }

    func processCrashed(process: String, project: String, code: Int32) {
        post(title: "\(process) crashed",
             body: "\(project) - exited with code \(code).",
             sound: "Basso")
    }

    /// Number of agents waiting, shown on the Dock icon.
    func updateBadge(waiting: Int) {
        NSApp.dockTile.badgeLabel = waiting > 0 ? String(waiting) : nil
    }

    private func post(title: String, body: String, sound: String) {
        if soundEnabled {
            NSSound(named: sound)?.play()
        }
        guard bannersEnabled, authorized else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body

        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
