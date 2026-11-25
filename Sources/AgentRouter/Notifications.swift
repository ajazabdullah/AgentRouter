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
        return "Authorization: \(state). Test request \(entry.id.uuidString) accepted without errors. In delivered list: \(delivered ? "yes" : "not yet"). Click the notification to open the CLI for \(project.name)."
    }
    func post(_ entry: HistoryEntry) async throws {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            throw RouterError.message("macOS notification authorization is not enabled. Event remains in History.")
        }
        let content = UNMutableNotificationContent()
        content.title = entry.projectName + " · " + entry.kind.rawValue
        content.body = "Click to open this project's CLI in Terminal. " + entry.evidence
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
    static func open(target: TerminalTarget, fillScreen: Bool = false) async throws {
        let bounds = await MainActor.run { () -> [String] in
            guard let screen = NSApp.keyWindow?.screen ?? NSScreen.main, let primary = NSScreen.screens.first else { return [] }
            let rect = screen.visibleFrame
            return [rect.minX, primary.frame.maxY - rect.maxY, rect.maxX, primary.frame.maxY - rect.minY].map { String(Int($0)) }
        }
        if fillScreen && bounds.isEmpty { throw RouterError.message("Cannot identify a display for the CLI window. Open CLI manually.") }
        try await Task.detached {
            // Match Terminal's actual TTY against clients of the verified tmux session.
            // Focusing an existing tab sends no command or keystroke to it.
            // All variable data is argv; none is interpolated into AppleScript source.
            let source = """
            on run argv
                set attachCommand to item 1 of argv
                set shouldFill to item 2 of argv is "1"
                set screenBounds to {item 3 of argv as integer, item 4 of argv as integer, item 5 of argv as integer, item 6 of argv as integer}
                set attachedTTYs to {}
                if (count of argv) > 6 then set attachedTTYs to items 7 thru -1 of argv
                tell application "Terminal"
                    repeat with terminalWindow in windows
                        repeat with terminalTab in tabs of terminalWindow
                            if attachedTTYs contains (tty of terminalTab as text) then
                                set selected tab of terminalWindow to terminalTab
                                set miniaturized of terminalWindow to false
                                set visible of terminalWindow to true
                                set index of terminalWindow to 1
                                if shouldFill then set bounds of terminalWindow to screenBounds
                                activate
                                return "reused"
                            end if
                        end repeat
                    end repeat
                    activate
                    set attachedTab to do script attachCommand
                    if shouldFill then
                        repeat 50 times
                            set newTTY to ""
                            try
                                set newTTY to tty of attachedTab as text
                            end try
                            if newTTY starts with "/dev/" then
                                repeat with terminalWindow in windows
                                    repeat with terminalTab in tabs of terminalWindow
                                        if (tty of terminalTab as text) is newTTY then
                                            set bounds of terminalWindow to screenBounds
                                            return "attached"
                                        end if
                                    end repeat
                                end repeat
                            end if
                            delay 0.05
                            end repeat
                        error "Cannot identify the newly attached Terminal window for resizing."
                    end if
                    return "attached"
                end tell
            end run
            """
            let geometry = bounds.isEmpty ? ["0", "0", "0", "0"] : bounds
            let result = try ProcessRunner.run("/usr/bin/osascript", ["-e", source, target.command, fillScreen ? "1" : "0"] + geometry + target.attachedTTYs, timeout: 60)
            guard result.status == 0 else { throw RouterError.message("Terminal could not open. Allow AgentRouter to control Terminal in System Settings → Privacy & Security → Automation. \(result.error)") }
        }.value
    }
}
