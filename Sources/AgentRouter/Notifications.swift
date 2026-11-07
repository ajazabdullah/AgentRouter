import Foundation
import AppKit
import UserNotifications
import RouterCore

@MainActor
final class NotificationBridge: NSObject, UNUserNotificationCenterDelegate {
    var onSelect: ((UUID) -> Void)?
    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }
    func authorize() async throws -> Bool {
        // Permission UI is requested only by an explicit button click, never on clipboard capture.
        NSApp.activate(ignoringOtherApps: true)
        return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }
    func verify(project: Project) async throws -> String {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        let state: String
        switch settings.authorizationStatus {
        case .authorized: state = "authorized"
        case .provisional: state = "provisional"
        case .denied: state = "denied"
        case .notDetermined: state = "not determined"
        case .ephemeral: state = "ephemeral"
        @unknown default: state = "unknown"
        }
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            throw RouterError.message("Authorization is \(state); no test request sent.")
        }
        let entry = HistoryEntry(projectID: project.id, projectName: project.name, kind: .unknown, evidence: "AgentRouter test notification — no agent action")
        try await post(entry)
        try await Task.sleep(for: .seconds(1))
        let delivered = await center.deliveredNotifications().contains { $0.request.identifier == entry.id.uuidString }
        return "Authorization: \(state). Test request \(entry.id.uuidString) accepted without errors. In delivered list: \(delivered ? "yes" : "not yet"). Click the notification to select \(project.name)."
    }
    func post(_ entry: HistoryEntry) async throws {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            throw RouterError.message("macOS notification authorization is not enabled. Event remains in History.")
        }
        let content = UNMutableNotificationContent()
        content.title = entry.projectName + " · " + entry.kind.rawValue
        content.body = "Open AgentRouter to review this event. " + entry.evidence
        content.sound = .default
        content.userInfo = ["projectID": entry.projectID.uuidString]
        try await center.add(UNNotificationRequest(identifier: entry.id.uuidString, content: content, trigger: nil))
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = (response.notification.request.content.userInfo["projectID"] as? String).flatMap(UUID.init(uuidString:))
        Task { @MainActor [weak self] in if let id { self?.onSelect?(id) } }
        completionHandler()
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
}

enum TerminalLauncher {
    static func open(target: TerminalTarget) async throws {
        try await Task.detached {
            // Match Terminal's actual TTY against clients of the verified tmux session.
            // Focusing an existing tab sends no command or keystroke to it.
            // All variable data is argv; none is interpolated into AppleScript source.
            let source = """
            on run argv
                set attachCommand to item 1 of argv
                set attachedTTYs to rest of argv
                tell application "Terminal"
                    repeat with terminalWindow in windows
                        repeat with terminalTab in tabs of terminalWindow
                            if attachedTTYs contains (tty of terminalTab as text) then
                                set selected tab of terminalWindow to terminalTab
                                set miniaturized of terminalWindow to false
                                set visible of terminalWindow to true
                                set index of terminalWindow to 1
                                activate
                                return "reused"
                            end if
                        end repeat
                    end repeat
                    activate
                    do script attachCommand
                    return "attached"
                end tell
            end run
            """
            let result = try ProcessRunner.run("/usr/bin/osascript", ["-e", source, target.command] + target.attachedTTYs, timeout: 60)
            guard result.status == 0 else { throw RouterError.message("Terminal could not open. Allow AgentRouter to control Terminal in System Settings → Privacy & Security → Automation. \(result.error)") }
        }.value
    }
}
