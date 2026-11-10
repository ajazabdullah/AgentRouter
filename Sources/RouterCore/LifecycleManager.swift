import Foundation
import Darwin

struct ManagedPane: Sendable {
    let session: String, sessionID: String, paneID: String, server: String
    let project: String, run: String, paneRun: String
    let pid: Int32
    let dead: Bool, bracketed: Bool, inMode: Bool, inputOff: Bool
    let exitStatus: String
    let outputGeneration: String
}

/// Captured before quit confirmation; a restarted/rebound CLI must never inherit consent.
public struct QuitStopTarget: Sendable {
    public let id: UUID
    public let name: String
    public let runID: String
    public let paneID: String
}

public actor LifecycleManager {
    public static let defaultSocket = "agentrouter-managed-v2"
    private let tmux: String
    public let socket: String
    private let store: ProjectStore
    private var workspace: Workspace
    private let hookHelper: String?
    private let ipcPath: String?
    private var live: [UUID: AgentActivity] = [:]
    private var seenEvents: Set<String> = []
    private var exitReported: Set<String> = []
    private var disconnectReported: Set<String> = []
    private var pendingNotifications: [HistoryEntry] = []
    private var replyCache: [UUID: (run: String, session: String, stamp: LatestReply.Stamp, text: String)] = [:]
    // Printable separators survive tmux sanitization in Finder/Spotlight non-UTF-8 locales.
    private static let format = "#{session_name}|#{session_id}|#{pane_id}|#{pid}:#{start_time}|#{@ar_project}|#{@ar_run}|#{@ar_pane_run}|#{pane_pid}|#{pane_dead}|#{bracket_paste_flag}|#{pane_in_mode}|#{pane_input_off}|#{pane_dead_status}|#{pane_output_generation}"

    public init(store: ProjectStore, defaults: [Project] = Project.defaults,
                tmux: String = "/opt/homebrew/bin/tmux", socket: String = LifecycleManager.defaultSocket,
                hookHelper: String? = nil, ipcPath: String? = nil) throws {
        self.store = store; self.tmux = tmux; self.socket = socket
        self.workspace = try store.load(defaults: defaults)
        self.hookHelper = hookHelper; self.ipcPath = ipcPath
    }
    public func snapshot() -> Workspace { workspace }
    public func saveInitialSettings() throws { try persist() }
    private func persist() throws { try store.save(workspace) }
    private func project(_ id: UUID) throws -> Project {
        guard let p = workspace.controllers.first(where: { $0.id == id }) else { throw RouterError.message("Project or CLI no longer exists.") }; return p
    }
    private func run(_ args: [String], input: Data? = nil) throws -> String {
        let r = try ProcessRunner.run(tmux, ["-L", socket, "-f", "/dev/null"] + args, input: input)
        guard r.status == 0 else { throw RouterError.message(r.error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "tmux command failed or timed out." : r.error.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return r.output
    }
    private func panes() throws -> [ManagedPane] {
        let r = try ProcessRunner.run(tmux, ["-L", socket, "-f", "/dev/null", "list-panes", "-a", "-F", Self.format])
        if r.status != 0 {
            if r.error.contains("no server running") || r.error.contains("No such file or directory") || r.error.contains("Connection refused") { return [] }
            throw RouterError.message("Cannot inspect tmux: \(r.error)")
        }
        return try Self.parsePanes(r.output)
    }
    static func parsePanes(_ output: String) throws -> [ManagedPane] {
        // Split Unicode scalars rather than Characters: CRLF is one Swift Character.
        return try output.components(separatedBy: "\n").filter { !$0.isEmpty }.map { rawLine in
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 14 else {
                // Only the bounded identity response is shown, never pane contents or credentials.
                let diagnostic = String(reflecting: String(line.prefix(180)))
                throw RouterError.message("Unrecognized tmux identity response: expected 14 fields, received \(f.count). Response: \(diagnostic)")
            }
            guard let pid = Int32(f[7]) ?? (f[8] == "1" ? 0 : nil) else { throw RouterError.message("Unrecognized tmux identity response: invalid controller PID (\(f[7].utf8.count) bytes; dead=\(f[8] == "1")). No agent action was performed.") }
            return ManagedPane(session: f[0], sessionID: f[1], paneID: f[2], server: f[3], project: f[4], run: f[5], paneRun: f[6], pid: pid, dead: f[8] == "1", bracketed: f[9] == "1", inMode: f[10] != "0", inputOff: f[11] != "0", exitStatus: f[12], outputGeneration: f[13])
        }
    }
    private func ownedPane(_ p: Project, _ b: Binding, from all: [ManagedPane]) throws -> ManagedPane {
        let session = all.filter { $0.session == p.session }
        guard session.count == 1, let pane = session.first,
              b.projectID == p.id, b.configuration.directory == p.directory, b.configuration.executable == p.executable,
              b.configuration.cli == p.cli, b.configuration.session == p.session,
              pane.project == p.id.uuidString, pane.run == b.runID, pane.paneRun == b.runID,
              pane.server == b.server, pane.sessionID == b.sessionID, pane.paneID == b.paneID,
              (pane.dead || pane.pid == b.pid) else { throw RouterError.message("Stale or ambiguous session ownership. No input or stop command was sent.") }
        if !pane.dead {
            guard try ProcessTable.startTime(b.pid) == b.processStart else { throw RouterError.message("Agent process identity changed. Refusing this target.") }
        }
        return pane
    }
    private func binding(_ id: UUID) throws -> Binding {
        guard let b = workspace.bindings[id.uuidString] else { throw RouterError.message("This project has no managed agent. Start it first.") }; return b
    }
    private func agentExists(_ p: Project, pane: ManagedPane, processes: [ProcessInfoEntry]) -> Bool {
        let resolved = URL(fileURLWithPath: p.executable).resolvingSymlinksInPath().path
        return ProcessTable.descendants(of: pane.pid, in: processes).contains {
            $0.executable == resolved || $0.executable == p.executable || URL(fileURLWithPath: $0.executable).lastPathComponent == p.cli.rawValue
        }
    }
    public func saveProject(_ p: Project) throws {
        try p.validate()
        var retiredChildren: [UUID] = []
        guard !workspace.instances.contains(where: { $0.id == p.id }) else { throw RouterError.message("Edit the parent project's settings; each additional CLI keeps its own executable and session.") }
        guard !workspace.controllers.contains(where: { $0.id != p.id && $0.session == p.session }) else { throw RouterError.message("Another CLI already uses this session identifier.") }
        if let before = workspace.projects.first(where: { $0.id == p.id }), before.directory != p.directory {
            let all = try panes()
            for instance in workspace.instances where instance.projectID == p.id {
                if let binding = workspace.bindings[instance.id.uuidString], all.contains(where: { $0.session == instance.session }) {
                    guard try ownedPane(project(instance.id), binding, from: all).dead else {
                        throw RouterError.message("Stop every CLI in this project before changing its directory.")
                    }
                }
            }
            retiredChildren = workspace.instances.filter { $0.projectID == p.id }.map(\.id)
        }
        if let b = workspace.bindings[p.id.uuidString] {
            let before = try project(p.id)
            let all = try panes()
            if all.contains(where: { $0.session == before.session }) {
                let pane = try ownedPane(before, b, from: all)
                guard pane.dead || (p.directory == before.directory && p.cli == before.cli && p.executable == before.executable && p.session == before.session) else { throw RouterError.message("Stop the agent before changing its directory, CLI or session.") }
                if pane.dead && (p.directory != before.directory || p.cli != before.cli || p.executable != before.executable || p.session != before.session) { try release(p.id) }
            } else { workspace.bindings.removeValue(forKey: p.id.uuidString) }
        }
        for child in retiredChildren where workspace.bindings[child.uuidString] != nil { try release(child) }
        if let index = workspace.projects.firstIndex(where: { $0.id == p.id }) { workspace.projects[index] = p }
        else { workspace.projects.append(p) }
        try persist()
    }
    public func removeProject(_ id: UUID) throws {
        _ = try project(id)
        let targets = [id] + workspace.instances.filter { $0.projectID == id }.map(\.id)
        let all = try panes()
        for target in targets {
            let p = try project(target)
            if let b = workspace.bindings[target.uuidString], all.contains(where: { $0.session == p.session }) {
                guard try ownedPane(p, b, from: all).dead else { throw RouterError.message("Stop all affected CLIs before removing this project or CLI.") }
            }
        }
        for target in targets {
            if workspace.bindings[target.uuidString] != nil { try release(target) }
            live[target] = nil; replyCache[target] = nil
        }
        workspace.projects.removeAll { $0.id == id }
        workspace.instances.removeAll { $0.id == id || $0.projectID == id }
        try persist()
    }
    public func addCLI(projectID: UUID, cli: CLIKind) throws -> UUID {
        guard let root = workspace.projects.first(where: { $0.id == projectID }) else { throw RouterError.message("Select a project before creating another CLI.") }
        let names = Set(workspace.instances.filter { $0.projectID == projectID }.map(\.name))
        var ordinal = root.cli == cli ? 2 : 1
        while names.contains("\(cli.title) \(ordinal)") { ordinal += 1 }
        let instance = AgentInstance(projectID: projectID, name: "\(cli.title) \(ordinal)", cli: cli,
                                     executable: root.cli == cli ? root.executable : cli.detectedPath)
        var target = Project(id: instance.id, name: instance.name, directory: root.directory, cli: cli,
                             executable: instance.executable, session: instance.session)
        target.codexSettings = root.codexSettings
        try target.validate()
        guard !workspace.controllers.contains(where: { $0.session == instance.session }) else { throw RouterError.message("New CLI session collision; nothing was started.") }
        let previousVersion = workspace.version
        workspace.version = 3
        workspace.instances.append(instance)
        do { try persist() }
        catch { workspace.instances.removeAll { $0.id == instance.id }; workspace.version = previousVersion; throw error }
        return instance.id
    }
    /// Cleanup is permitted only for the exact dead controller pane, never a live or extra pane.
    private func release(_ id: UUID) throws {
        let p = try project(id), b = try binding(id), all = try panes()
        if all.contains(where: { $0.session == p.session }) {
            let pane = try ownedPane(p, b, from: all)
            guard pane.dead else { throw RouterError.message("Stop this agent before removing the project or replacing its session.") }
            _ = try run(["kill-session", "-t", b.sessionID])
        }
        workspace.bindings.removeValue(forKey: id.uuidString); live[id] = nil
        try persist()
    }
    public func start(_ id: UUID, mode: LaunchMode = .fresh) throws {
        let p = try project(id); try p.validate()
        var all = try panes()
        if let b = workspace.bindings[id.uuidString], all.contains(where: { $0.session == p.session }) {
            let pane = try ownedPane(p, b, from: all)
            guard pane.dead else { throw RouterError.message("An agent is already running for this project.") }
            try release(id)
            all = try panes()
        }
        guard !all.contains(where: { $0.session == p.session || $0.project == id.uuidString }) else { throw RouterError.message("Session collision: an existing controller will not be adopted or replaced.") }
        let runID = UUID().uuidString, credential = UUID().uuidString + UUID().uuidString
        // The only forcibly replaced process is this newly created inert placeholder.
        // Two argv elements make tmux use direct exec rather than a shell.
        let created = try run(["new-session", "-d", "-P", "-F", "#{session_id}|#{pane_id}", "-s", p.session, "-c", p.directory, "-x", "120", "-y", "36", "/bin/sleep", "86400"])
        let ids = created.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|").map(String.init)
        guard ids.count == 2 else { throw RouterError.message("tmux did not return the new session identity.") }
        _ = try run(["set-option", "-t", ids[0], "@ar_project", id.uuidString])
        _ = try run(["set-option", "-t", ids[0], "@ar_run", runID])
        _ = try run(["set-option", "-p", "-t", ids[1], "@ar_pane_run", runID])
        _ = try run(["set-option", "-p", "-t", ids[1], "remain-on-exit", "on"])
        let placeholder = try panes().first { $0.sessionID == ids[0] && $0.paneID == ids[1] }
        guard let placeholder, placeholder.project == id.uuidString, placeholder.run == runID else { throw RouterError.message("New session ownership could not be established.") }
        var args = p.cli.arguments(mode: mode)
        if p.cli == .codex { args += (p.codexSettings ?? CodexSettings()).arguments }
        if let hookHelper, let ipcPath {
            args += try HookConfiguration.arguments(for: p.cli, helper: hookHelper, directory: store.url.deletingLastPathComponent())
            _ = ipcPath
        }
        let path = AgentEnvironment.path(for: p.executable)
        var spawn = ["respawn-pane", "-k", "-t", ids[1], "-c", p.directory,
                     "-e", "AR_PROJECT=" + id.uuidString, "-e", "AR_RUN=" + runID, "-e", "AR_TOKEN=" + credential]
        if let ipcPath { spawn += ["-e", "AR_SOCKET=" + ipcPath] }
        // A tmux server started from a coding tool may inherit NO_COLOR=1.
        // Remove it only for this new interactive agent, preserving the server and other panes.
        // tmux can overwrite -e PATH with its command client's (Finder) PATH.
        // Set it in the final child invocation, after tmux has built the environment.
        spawn += ["/usr/bin/env", "-u", "NO_COLOR", "PATH=" + path, p.executable] + args
        // Persist placeholder identity first: a crash never silently adopts a future session.
        var b = Binding(projectID: id, runID: runID, credential: credential, server: placeholder.server,
                        sessionID: ids[0], paneID: ids[1], pid: placeholder.pid, processStart: try ProcessTable.startTime(placeholder.pid),
                        launchedAt: Date(), mode: mode, configuration: p)
        workspace.bindings[id.uuidString] = b; try persist()
        _ = try run(spawn)
        guard let spawned = try panes().first(where: { $0.sessionID == b.sessionID && $0.paneID == b.paneID && $0.run == runID }) else { throw RouterError.message("Agent startup did not preserve the created pane.") }
        b.pid = spawned.pid
        b.processStart = (try? ProcessTable.startTime(spawned.pid)) ?? "exited"
        workspace.bindings[id.uuidString] = b
        live[id] = AgentActivity(runID: runID)
        try persist()
    }
    public func health() throws -> [UUID: ProjectHealth] {
        let all = try panes(), processes = try ProcessTable.entries()
        var result: [UUID: ProjectHealth] = [:]
        for p in workspace.controllers {
            guard let b = workspace.bindings[p.id.uuidString] else {
                let conflict = all.contains { $0.session == p.session }
                result[p.id] = ProjectHealth(state: conflict ? .disconnected : .stopped, message: conflict ? "Unowned session name collision; start refused." : "Stopped. Configure a directory and press Start.")
                continue
            }
            do {
                let pane = try ownedPane(p, b, from: all)
                if pane.dead {
                    let state: LifecycleState = b.stopRequested || pane.exitStatus == "0" ? .stopped : .failed
                    result[p.id] = ProjectHealth(state: state, tmuxHealthy: true, message: "CLI exited (status \(pane.exitStatus.isEmpty ? "signal/unknown" : pane.exitStatus)).", paneID: pane.paneID, paneDead: true)
                    if !b.stopRequested, exitReported.insert(b.runID).inserted { try recordExit(p, b) }
                } else {
                    let exists = agentExists(p, pane: pane, processes: processes)
                    let state: LifecycleState = b.stopRequested ? .stopping : (exists ? .running : (Date().timeIntervalSince(b.launchedAt) < 12 ? .starting : .failed))
                    result[p.id] = ProjectHealth(state: state, tmuxHealthy: true, agentHealthy: exists,
                        message: exists ? "Agent process alive. Authentication and startup may need Open." : "tmux is alive, but the selected CLI process is not verified.", paneID: pane.paneID, bracketedPaste: pane.bracketed && !pane.inMode && !pane.inputOff)
                }
            } catch {
                result[p.id] = ProjectHealth(state: .disconnected, message: error.localizedDescription)
                live[p.id]?.revoke()
                if disconnectReported.insert(b.runID).inserted {
                    try record(p, kind: .unknown, evidence: "controller identity or tmux connection lost; agent exit unverified")
                }
            }
        }
        return result
    }
    public func stop(_ id: UUID, confirmedInterrupt: Bool) throws {
        guard confirmedInterrupt else { throw RouterError.message("Stopping may interrupt active work and requires confirmation.") }
        let p = try project(id); var b = try binding(id)
        let pane = try ownedPane(p, b, from: panes())
        if pane.dead { return }
        let group = try ProcessRunner.run("/bin/ps", ["-p", String(b.pid), "-o", "pgid="])
        guard group.status == 0, Int32(group.output.trimmingCharacters(in: .whitespacesAndNewlines)) == b.pid else { throw RouterError.message("Cannot verify the controller process group. No signal sent.") }
        _ = try ownedPane(p, b, from: panes())
        let previousStopRequested = b.stopRequested
        b.stopRequested = true; workspace.bindings[id.uuidString] = b; live[id]?.revoke(); try persist()
        guard kill(-b.pid, SIGTERM) == 0 else {
            let reason = String(cString: strerror(errno))
            b.stopRequested = previousStopRequested; workspace.bindings[id.uuidString] = b; try? persist()
            throw RouterError.message("The graceful shutdown request failed: \(reason)")
        }
    }
    public func quitStopTargets() throws -> [QuitStopTarget] {
        let all = try panes()
        let processes = try ProcessTable.entries()
        var targets: [QuitStopTarget] = []
        for project in workspace.controllers {
            guard let binding = workspace.bindings[project.id.uuidString] else {
                guard !all.contains(where: { $0.session == project.session }) else {
                    throw RouterError.message("\(project.name): unowned session collision. Nothing may be stopped by guessing its identity.")
                }
                continue
            }
            if !all.contains(where: { $0.session == project.session }) {
                // A missing tmux session alone does not prove its controller exited.
                if processes.contains(where: { $0.pid == binding.pid }),
                   try ProcessTable.startTime(binding.pid) == binding.processStart {
                    throw RouterError.message("\(project.name): the controller process is still alive but its pane is missing. Shutdown cannot be safely verified.")
                }
                continue
            }
            let pane = try ownedPane(project, binding, from: all)
            if !pane.dead {
                targets.append(QuitStopTarget(id: project.id, name: project.name, runID: binding.runID, paneID: binding.paneID))
            }
        }
        return targets
    }

    public func requestQuitStop(_ target: QuitStopTarget, force: Bool) throws {
        let current = try binding(target.id)
        guard current.runID == target.runID, current.paneID == target.paneID else {
            throw RouterError.message("\(target.name): the CLI run changed after confirmation. No stop signal was sent to the new run.")
        }
        if force { try forceStop(target.id, confirmed: true) }
        else { try stop(target.id, confirmedInterrupt: true) }
    }
    public func forceStop(_ id: UUID, confirmed: Bool) throws {
        guard confirmed else { throw RouterError.message("Force stop requires explicit approval to discard active work.") }
        let p = try project(id); var b = try binding(id)
        let pane = try ownedPane(p, b, from: panes())
        if !pane.dead {
            let group = try ProcessRunner.run("/bin/ps", ["-p", String(b.pid), "-o", "pgid="])
            guard group.status == 0, Int32(group.output.trimmingCharacters(in: .whitespacesAndNewlines)) == b.pid else { throw RouterError.message("Cannot verify the owned process group.") }
            _ = try ownedPane(p, b, from: panes())
            let previousStopRequested = b.stopRequested
            b.stopRequested = true; workspace.bindings[id.uuidString] = b; try persist()
            guard kill(-b.pid, SIGKILL) == 0 else {
                b.stopRequested = previousStopRequested; workspace.bindings[id.uuidString] = b; try? persist()
                throw RouterError.message("Force stop signal failed.")
            }
        }
        live[id]?.revoke()
    }
    /// Never forces shutdown. The caller waits for stopped health before invoking this again.
    public func restart(_ id: UUID, mode: LaunchMode) throws {
        let p = try project(id), b = try binding(id)
        let pane = try ownedPane(p, b, from: panes())
        guard pane.dead else { throw RouterError.message("Agent has not exited. Restart will not force-stop it.") }
        try start(id, mode: mode)
    }
    public func terminalCommand(_ id: UUID) throws -> String {
        let p = try project(id), b = try binding(id)
        _ = try ownedPane(p, b, from: panes())
        // Only validated immutable IDs and executable/socket paths enter a shell command.
        return [tmux, "-L", socket, "attach-session", "-t", b.sessionID].map(Self.shellQuote).joined(separator: " ")
    }
    /// Resolve live client TTYs rather than remembering a window title or a stale tab index.
    /// This also finds tabs opened before AgentRouter was restarted.
    public func terminalTarget(_ id: UUID) throws -> TerminalTarget {
        let p = try project(id), b = try binding(id)
        let command = try terminalCommand(id)
        let clients = try run(["list-clients", "-F", "#{session_id}|#{client_tty}"])
        let ttys = clients.split(separator: "\n").compactMap { line -> String? in
            let fields = line.split(separator: "|", omittingEmptySubsequences: false)
            guard fields.count == 2, String(fields[0]) == b.sessionID,
                  fields[1].hasPrefix("/dev/") else { return nil }
            return String(fields[1])
        }
        _ = try ownedPane(p, b, from: panes())
        return TerminalTarget(command: command, attachedTTYs: ttys)
    }
    public func splitViewTarget(first: UUID, second: UUID, balance: Bool = false) throws -> TerminalTarget {
        guard first != second else { throw RouterError.message("Choose two different projects for Split View.") }
        let left = try project(first), right = try project(second)
        let leftBinding = try binding(first), rightBinding = try binding(second)
        let all = try panes(), processes = try ProcessTable.entries()
        for (project, binding) in [(left, leftBinding), (right, rightBinding)] {
            let pane = try ownedPane(project, binding, from: all)
            guard !pane.dead, !binding.stopRequested, agentExists(project, pane: pane, processes: processes) else {
                throw RouterError.message("Start \(project.name) before opening Split View. No agent was started or replaced.")
            }
        }
        let target = try SplitWorkspace.target(tmux: tmux, controllerSocket: socket, first: left, second: right,
                                               firstBinding: leftBinding, secondBinding: rightBinding, balance: balance)
        let checked = try panes()
        _ = try ownedPane(left, leftBinding, from: checked)
        _ = try ownedPane(right, rightBinding, from: checked)
        return target
    }
    public func closeSplitView(first: UUID, second: UUID) throws {
        guard first != second else { throw RouterError.message("Choose the two projects whose split view should close.") }
        try SplitWorkspace.close(tmux: tmux, first: first, second: second)
    }
    /// Read-only snapshot of every line tmux still retains, including the current screen.
    /// This is terminal output, not a reconstructed conversation transcript.
    public func captureOutput(_ id: UUID, includeColors: Bool = false) throws -> String {
        let p = try project(id), b = try binding(id)
        _ = try ownedPane(p, b, from: panes())
        let output = try run(["capture-pane", "-p"] + (includeColors ? ["-e"] : []) + ["-S", "-", "-E", "-", "-t", b.paneID])
        _ = try ownedPane(p, b, from: panes())
        return output // No trimming, character limit, or message extraction.
    }
    public func latestReply(_ id: UUID) async throws -> String {
        let p = try project(id), b = try binding(id)
        _ = try ownedPane(p, b, from: panes())
        guard let session = b.nativeSessionID, let path = b.transcriptPath else {
            throw RouterError.message("No verified transcript is bound yet. Complete an agent turn with AgentRouter running and hooks enabled, then refresh. Terminal screen view remains available.")
        }
        let stamp = try LatestReply.stamp(path: path, cli: p.cli)
        if let cached = replyCache[id], cached.run == b.runID, cached.session == session, cached.stamp == stamp {
            return cached.text
        }
        let text = try await Task.detached {
            try LatestReply.read(stamp, cli: p.cli, sessionID: session, directory: p.directory)
        }.value
        let current = try binding(id)
        guard current.runID == b.runID, current.nativeSessionID == session, current.transcriptPath == path else {
            throw RouterError.message("The agent conversation changed while reading. Refresh before copying.")
        }
        _ = try ownedPane(try project(id), current, from: panes())
        if try LatestReply.stamp(path: path, cli: p.cli) == stamp {
            replyCache[id] = (b.runID, session, stamp, text)
        }
        return text
    }
    /// Advisory preflight for the UI's bounded startup wait; paste rechecks everything.
    public func submissionBlocker(_ id: UUID) -> String? {
        do {
            let p = try project(id), b = try binding(id)
            let pane = try ownedPane(p, b, from: panes())
            guard !pane.dead, !b.stopRequested,
                  agentExists(p, pane: pane, processes: try ProcessTable.entries()) else {
                return "The configured CLI process is not running or verified."
            }
            guard pane.bracketed, !pane.inMode, !pane.inputOff else {
                return "The CLI has not established a verified text-input editor."
            }
            guard let activity = live[id], activity.canSubmit(now: Date()),
                  activity.outputGeneration == pane.outputGeneration else {
                return "No fresh, verified idle signal is available. The agent may be busy, awaiting authentication, or showing a question/approval dialog."
            }
            return nil
        } catch { return error.localizedDescription }
    }
    public static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    public func paste(_ text: String, projectID id: UUID, confirmedReady: Bool, submit: Bool = false, replyingTo: String? = nil) throws {
        guard confirmedReady else { throw RouterError.message("Confirm that the agent input is ready.") }
        try Tmux.validateText(text)
        let p = try project(id), b = try binding(id)
        let pane = try ownedPane(p, b, from: panes())
        guard !pane.dead, pane.bracketed, !pane.inMode, !pane.inputOff,
              agentExists(p, pane: pane, processes: try ProcessTable.entries()), !b.stopRequested else { throw RouterError.message("Agent editor health is unverified (dead=\(pane.dead), bracketed=\(pane.bracketed), mode=\(pane.inMode), inputOff=\(pane.inputOff)). Open its terminal to resolve startup or authentication.") }
        if let activity = live[id], activity.modal || activity.kind == .approvalRequired {
            throw RouterError.message("This is a structured question or approval dialog. Use Open; terminal input is blocked here.")
        }
        if submit {
            guard let activity = live[id], activity.canSubmit(now: Date()), activity.outputGeneration == pane.outputGeneration,
                  replyingTo == nil || activity.questionID == replyingTo else { throw RouterError.message("No current, verified text-input readiness signal. Use Paste Only or Open; Enter was not sent.") }
        }
        let buffer = "ar-" + UUID().uuidString
        defer { _ = try? run(["delete-buffer", "-b", buffer]) }
        _ = try run(["load-buffer", "-b", buffer, "-"], input: Data(text.utf8))
        let checked = try ownedPane(p, b, from: panes())
        guard checked.bracketed, !checked.dead, !checked.inMode, !checked.inputOff else { throw RouterError.message("Pane readiness changed before paste.") }
        // Consume readiness BEFORE sending so double clicks and delayed events cannot reuse it.
        if submit {
            guard let activity = live[id], activity.canSubmit(now: Date()), activity.outputGeneration == checked.outputGeneration else {
                throw RouterError.message("Agent output changed or readiness expired; no input was sent.")
            }
        }
        live[id]?.revoke()
        _ = try run(["paste-buffer", "-p", "-r", "-d", "-b", buffer, "-t", b.paneID])
        if submit {
            // Revalidate identity once more; never guess a fallback pane.
            _ = try ownedPane(p, b, from: panes())
            _ = try run(["send-keys", "-t", b.paneID, "Enter"])
        }
    }
}


extension LifecycleManager {
    public func activities() -> [UUID: AgentActivity] { live }
    public func drainNotifications() -> [HistoryEntry] {
        let values = pendingNotifications; pendingNotifications.removeAll(); return values
    }
    private func record(_ p: Project, kind: AgentEventKind, evidence: String) throws {
        let entry = HistoryEntry(projectID: p.id, projectName: p.name, kind: kind, evidence: evidence)
        workspace.history.append(entry)
        workspace.history = Array(workspace.history.suffix(500))
        try persist()
        let prefs = p.notifications
        if prefs.enabled && ((kind == .turnFinished || kind == .completed) && prefs.turnFinished
            || kind == .exited && prefs.unexpectedExit
            || [.needsInput, .approvalRequired, .blocked, .unknown].contains(kind) && prefs.needsAttention) {
            pendingNotifications.append(entry)
        }
    }
    func recordExit(_ p: Project, _ b: Binding) throws {
        live[p.id]?.revoke()
        if live[p.id] == nil { live[p.id] = AgentActivity(runID: b.runID) }
        live[p.id]?.kind = .exited
        live[p.id]?.detail = "Agent exited outside an AgentRouter stop request."
        try record(p, kind: .exited, evidence: "verified owned tmux pane exited; completion unknown")
    }
    public func clearHistory() throws { workspace.history.removeAll(); try persist() }
    /// Called only after the Unix listener checks peer uid and obtains the kernel peer PID.
    public func ingest(_ data: Data, peerPID: Int32) -> Bool {
        do {
            guard data.count <= LocalIPC.maximumBytes else { return false }
            let e = try JSONDecoder().decode(HookEnvelope.self, from: data)
            guard e.version == 1, abs(e.timestamp.timeIntervalSinceNow) < 5, !seenEvents.contains(e.id) else { return false }
            let p = try project(e.projectID)
            var b = try binding(p.id)
            guard b.runID == e.runID, b.credential == e.credential, b.paneID == e.paneID, !b.stopRequested else { return false }
            let pane = try ownedPane(p, b, from: panes())
            guard !pane.dead, ProcessTable.descendants(of: b.pid, in: try ProcessTable.entries()).contains(where: { $0.pid == peerPID }) else { return false }
            if let type = e.payload["agent_type"]?.string, !type.isEmpty, type != "main", type != "default" { return false }
            var activity = live[p.id] ?? AgentActivity(runID: b.runID)
            if let last = activity.lastEventAt, e.timestamp <= last { return false }
            guard let sessionID = e.payload["session_id"]?.string, !sessionID.isEmpty else { return false }
            if let current = activity.nativeSessionID ?? b.nativeSessionID, current != sessionID {
                guard e.payload["hook_event_name"]?.string == "SessionStart" else { return false }
                activity = AgentActivity(runID: b.runID)
            }
            let previousSession = b.nativeSessionID, previousPath = b.transcriptPath
            if b.nativeSessionID != sessionID { b.nativeSessionID = sessionID; b.transcriptPath = nil }
            if let path = e.payload["transcript_path"]?.string, path.hasPrefix("/"), path.utf8.count <= 4096 {
                b.transcriptPath = path
            }
            if previousSession != b.nativeSessionID || previousPath != b.transcriptPath {
                workspace.bindings[p.id.uuidString] = b
                replyCache[p.id] = nil
                try persist() // Session metadata only; reply bodies stay in native CLI history/memory.
            }
            activity.nativeSessionID = sessionID; activity.lastEventAt = e.timestamp
            let interpreted = HookAdapter.interpret(e.payload, cli: p.cli)
            activity.revoke()
            // Preserve a textual question across the idle notification, which carries no question body.
            let modalLatched = activity.modal && interpreted.kind != .working && interpreted.kind != .exited
            if !modalLatched && !(interpreted.idleTextEditor && activity.question != nil) {
                activity.kind = interpreted.kind; activity.detail = interpreted.detail
                activity.question = interpreted.question; activity.questionID = interpreted.question == nil ? nil : e.id
                activity.modal = interpreted.modal; activity.evidence = interpreted.evidence
            }
            if interpreted.idleTextEditor, !activity.modal, pane.bracketed, !pane.inMode, !pane.inputOff, !pane.outputGeneration.isEmpty {
                activity.readinessUntil = Date().addingTimeInterval(15)
                activity.outputGeneration = pane.outputGeneration
            }
            live[p.id] = activity
            seenEvents.insert(e.id)
            if seenEvents.count > 2000 { seenEvents = [e.id] }
            if interpreted.kind != .working && e.payload["hook_event_name"]?.string != "SessionStart" {
                try record(p, kind: activity.kind, evidence: activity.evidence)
            }
            return true
        } catch { return false }
    }
}
