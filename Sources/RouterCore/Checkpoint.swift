import Foundation
import Darwin

/// An explicit export DTO. Never serialize Workspace or Binding (which contain IPC credentials).
public struct CheckpointEntry: Sendable {
    public let project: String
    public let cli: String
    public let directory: String
    public let session: String
    public let pane: String?
    public let health: String
    public let activity: String
    public let reply: String?
    public init(project: String, cli: String, directory: String, session: String, pane: String?, health: String, activity: String, reply: String?) {
        self.project = project; self.cli = cli; self.directory = directory; self.session = session
        self.pane = pane; self.health = health; self.activity = activity; self.reply = reply
    }
}

public enum CheckpointExport {
    public static func markdown(entries: [CheckpointEntry], capturedAt: Date) -> String {
        func literal(_ value: String) -> String {
            let fence = String(repeating: "`", count: max(3, (value.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0) + 1))
            return "\(fence)text\n\(value)\n\(fence)"
        }
        var sections = ["# AgentRouter local checkpoint\n\nCaptured: \(capturedAt.ISO8601Format())\n\nThis is a local checkpoint, not an agent-authored handoff or proof of task completion. Status and replies are sampled sequentially and may change. Running CLI processes may continue after AgentRouter quits; monitoring and AgentRouter notifications stop. Unsent drafts and clipboard contents are excluded. Agent replies may themselves contain sensitive information; review before sharing."]
        for (index, entry) in entries.enumerated() {
            let metadata = "Project: \(entry.project)\nCLI: \(entry.cli)\nDirectory: \(entry.directory)\nTmux session: \(entry.session)\nRecorded bound pane: \(entry.pane ?? "Unavailable")\nHealth: \(entry.health)\nActivity: \(entry.activity)"
            sections.append("## CLI \(index + 1)\n\n" + literal(metadata) + "\n\n### Latest verified completed reply\n\n" + (entry.reply.map(literal) ?? "Unavailable: no verified completed reply could be read. No terminal-screen fallback was used."))
        }
        return sections.joined(separator: "\n\n") + "\n"
    }

    /// Write a private temporary file on the same volume, then atomically replace the chosen file.
    public static func write(_ text: String, to url: URL) throws {
        var template = Array(url.deletingLastPathComponent().appendingPathComponent(".agentrouter-checkpoint-XXXXXX").path.utf8CString)
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let path = String(cString: template)
        defer { unlink(path) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        guard fchmod(descriptor, 0o600) == 0 else { throw POSIXError(.EACCES) }
        try handle.write(contentsOf: Data(text.utf8))
        try handle.synchronize()
        guard rename(path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
