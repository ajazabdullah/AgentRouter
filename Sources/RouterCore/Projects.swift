import Foundation

public enum CLIKind: String, Codable, CaseIterable, Sendable {
    case codex, claude
    public var title: String { self == .codex ? "Codex" : "Claude Code" }
    public var detectedPath: String {
        let candidates = ["/opt/homebrew/bin/", "/usr/local/bin/", NSHomeDirectory() + "/.local/bin/"]
        return candidates.map { $0 + rawValue }.first { FileManager.default.isExecutableFile(atPath: $0) } ?? ""
    }
    public func arguments(mode: LaunchMode) -> [String] {
        switch (self, mode) {
        case (.codex, .fresh): return ["--no-daemon"]
        case (.claude, .fresh): return []
        case (.codex, .resumePicker): return ["--no-daemon", "resume"]
        case (.claude, .resumePicker): return ["--resume"]
        }
    }
}
public enum LaunchMode: String, Codable, CaseIterable, Sendable {
    case fresh, resumePicker
    public var title: String { self == .fresh ? "Fresh conversation" : "Choose conversation to resume" }
}
public struct TerminalTarget: Sendable {
    public let command: String
    public let attachedTTYs: [String]
    public init(command: String, attachedTTYs: [String]) {
        self.command = command; self.attachedTTYs = attachedTTYs
    }
}
public struct NotificationPreferences: Codable, Equatable, Sendable {
    public var enabled = false
    public var turnFinished = true
    public var needsAttention = true
    public var unexpectedExit = true
    public init() {}
}
public enum CodexApprovalPolicy: String, Codable, CaseIterable, Sendable {
    case inherit, onRequest = "on-request", never
    public var title: String {
        switch self {
        case .inherit: return "Use existing config"
        case .onRequest: return "Ask when needed (on-request)"
        case .never: return "Never ask (never)"
        }
    }
}
public enum CodexSandboxMode: String, Codable, CaseIterable, Sendable {
    case inherit, readOnly = "read-only", workspaceWrite = "workspace-write", fullAccess = "danger-full-access"
    public var title: String {
        switch self {
        case .inherit: return "Use existing config"
        case .readOnly: return "Read only (read-only)"
        case .workspaceWrite: return "Write in workspace (workspace-write)"
        case .fullAccess: return "Unrestricted access (danger-full-access)"
        }
    }
}
public struct CodexSettings: Codable, Equatable, Sendable {
    public var approvalPolicy: CodexApprovalPolicy = .inherit
    public var sandboxMode: CodexSandboxMode = .inherit
    public init() {}
    public var arguments: [String] {
        var result: [String] = []
        if approvalPolicy != .inherit { result += ["-c", "approval_policy=\"\(approvalPolicy.rawValue)\""] }
        if sandboxMode != .inherit { result += ["-c", "sandbox_mode=\"\(sandboxMode.rawValue)\""] }
        return result
    }
    public var toml: String {
        var lines: [String] = []
        if approvalPolicy != .inherit { lines.append("approval_policy = \"\(approvalPolicy.rawValue)\"") }
        if sandboxMode != .inherit { lines.append("sandbox_mode = \"\(sandboxMode.rawValue)\"") }
        return lines.joined(separator: "\n")
    }
}
public struct Project: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var directory: String
    public var cli: CLIKind
    public var executable: String
    public var session: String
    public var notifications: NotificationPreferences
    public var codexSettings: CodexSettings?
    public init(id: UUID = UUID(), name: String = "New project", directory: String = "", cli: CLIKind = .codex, executable: String? = nil, session: String? = nil) {
        self.id = id; self.name = name; self.directory = directory; self.cli = cli
        self.executable = executable ?? cli.detectedPath
        self.session = session ?? "ar-" + id.uuidString.prefix(8).lowercased()
        self.notifications = NotificationPreferences()
    }
    public static var defaults: [Project] { Destination.defaults.map { Project(name: $0.name, session: $0.session) } }
    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RouterError.message("Project name is required.") }
        guard session.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$", options: .regularExpression) != nil else { throw RouterError.message("Session must contain 1–64 letters, digits, underscores or hyphens, beginning with a letter or digit.") }
        var isDirectory: ObjCBool = false
        guard directory.hasPrefix("/"), !directory.contains("\0"), FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue, FileManager.default.isReadableFile(atPath: directory) else { throw RouterError.message("Choose an existing, readable absolute project directory.") }
        guard URL(fileURLWithPath: executable).lastPathComponent == cli.rawValue, executable.hasPrefix("/"), !executable.contains("\0"), FileManager.default.isExecutableFile(atPath: executable) else { throw RouterError.message("Choose an installed executable named \(cli.rawValue) for \(cli.title); shells are not accepted.") }
    }
}
public struct Binding: Codable, Equatable, Sendable {
    public var projectID: UUID
    public var runID: String
    public var credential: String
    public var server: String
    public var sessionID: String
    public var paneID: String
    public var pid: Int32
    public var processStart: String
    public var launchedAt: Date
    public var mode: LaunchMode
    public var configuration: Project
    public var stopRequested = false
    public var nativeSessionID: String?
    public var transcriptPath: String?
}
public enum LifecycleState: String, Codable, Sendable {
    case stopped, starting, running, stopping, failed, disconnected
}
public struct ProjectHealth: Sendable {
    public var state: LifecycleState
    public var tmuxHealthy: Bool
    public var agentHealthy: Bool
    public var message: String
    public var paneID: String?
    public var bracketedPaste: Bool
    public var paneDead: Bool
    public init(state: LifecycleState, tmuxHealthy: Bool = false, agentHealthy: Bool = false, message: String, paneID: String? = nil, bracketedPaste: Bool = false, paneDead: Bool = false) {
        self.state = state; self.tmuxHealthy = tmuxHealthy; self.agentHealthy = agentHealthy; self.message = message; self.paneID = paneID; self.bracketedPaste = bracketedPaste
        self.paneDead = paneDead
    }
}
public struct AgentInstance: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var projectID: UUID
    public var name: String
    public var cli: CLIKind
    public var executable: String
    public var session: String
    public init(projectID: UUID, name: String, cli: CLIKind, executable: String) {
        id = UUID(); self.projectID = projectID; self.name = name; self.cli = cli; self.executable = executable
        session = "ar-cli-" + id.uuidString.lowercased()
    }
}
public struct Workspace: Codable, Sendable {
    public var version = 3
    public var projects: [Project]
    public var bindings: [String: Binding] = [:]
    public var history: [HistoryEntry] = []
    public var instances: [AgentInstance] = []
    public init(projects: [Project]) { self.projects = projects }
    private enum CodingKeys: String, CodingKey { case version, projects, bindings, history, instances }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        projects = try values.decode([Project].self, forKey: .projects)
        bindings = try values.decode([String: Binding].self, forKey: .bindings)
        history = try values.decode([HistoryEntry].self, forKey: .history)
        instances = try values.decodeIfPresent([AgentInstance].self, forKey: .instances) ?? []
    }
    /// Existing project IDs remain the IDs of their original Main controller.
    public var controllers: [Project] {
        projects + instances.compactMap { instance in
            guard let root = projects.first(where: { $0.id == instance.projectID }) else { return nil }
            var target = Project(id: instance.id, name: root.name + " · " + instance.name, directory: root.directory,
                                 cli: instance.cli, executable: instance.executable, session: instance.session)
            target.notifications = root.notifications
            target.codexSettings = root.codexSettings
            return target
        }
    }
}
public struct ProjectStore: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load(defaults: [Project]) throws -> Workspace {
        guard FileManager.default.fileExists(atPath: url.path) else { return Workspace(projects: defaults) }
        let workspace = try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: url))
        let ids = workspace.projects.map(\.id) + workspace.instances.map(\.id)
        guard [2, 3].contains(workspace.version), Set(ids).count == ids.count,
              workspace.instances.allSatisfy({ instance in workspace.projects.contains { $0.id == instance.projectID } }),
              Set(workspace.controllers.map(\.session)).count == workspace.controllers.count else { throw RouterError.message("Invalid settings file; it was not overwritten.") }
        return workspace
    }
    public func save(_ workspace: Workspace) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(workspace)
        try data.write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
