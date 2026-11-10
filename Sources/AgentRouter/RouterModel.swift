import AppKit
import SwiftUI
import RouterCore

@MainActor
final class RouterModel: ObservableObject {
    struct StartOffer: Identifiable {
        let id = UUID()
        let projectID: UUID
        let projectName: String
        let prompt: String
        let mode: LaunchMode
    }
    struct OutputSnapshot {
        let projectID: UUID
        let text: String
        let styledText: AttributedString
        let view: OutputView
    }
    enum OutputView: String, CaseIterable { case latestReply = "Latest reply", terminal = "Terminal screen" }
    @Published var projects: [Project] = []
    @Published var projectGroups: [Project] = []
    @Published var cliInstances: [AgentInstance] = []
    private var lastCLIByProject = UserDefaults.standard.dictionary(forKey: "lastCLIByProject") as? [String: String] ?? [:]
    @Published var selectedID: UUID? {
        didSet {
            ready = false
            if let selectedID {
                UserDefaults.standard.set(selectedID.uuidString, forKey: "selectedProjectID")
                if let group = groupID(for: selectedID) {
                    lastCLIByProject[group.uuidString] = selectedID.uuidString
                    UserDefaults.standard.set(lastCLIByProject, forKey: "lastCLIByProject")
                }
            }
        }
    }
    @Published var health: [UUID: ProjectHealth] = [:]
    @Published var activities: [UUID: AgentActivity] = [:]
    @Published var history: [HistoryEntry] = []
    @Published var text = "" { didSet { ready = false } }
    @Published var reply = "" { didSet { ready = false } }
    @Published var ready = false
    @Published var busy = false
    @Published var quitReviewActive = false
    @Published var status = "Loading projects…"
    @Published var source = "No captured text"
    @Published var editing: Project?
    @Published var showHistory = false
    @Published var startOffer: StartOffer?
    @Published var openFallbackProjectID: UUID?
    @Published var outputProjectID: UUID?
    @Published var splitProjectID: UUID?
    @Published var outputView: OutputView = .latestReply
    @Published private(set) var outputSnapshot: OutputSnapshot?
    @Published private(set) var outputError = "Start a project to view its terminal output."
    private var readingOutput = false
    @Published var shortcuts = UserDefaults.standard.bool(forKey: "projectShortcuts") {
        didSet { UserDefaults.standard.set(shortcuts, forKey: "projectShortcuts") }
    }
    @Published var cliFunctionKeysEnabled = UserDefaults.standard.object(forKey: "cliFunctionKeysEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(cliFunctionKeysEnabled, forKey: "cliFunctionKeysEnabled") }
    }
    @Published var launchMode: LaunchMode = .fresh
    @Published var showWidgetOnCopy = UserDefaults.standard.bool(forKey: "showWidgetOnCopy") {
        didSet { UserDefaults.standard.set(showWidgetOnCopy, forKey: "showWidgetOnCopy") }
    }
    @Published var hideWidgetAfterSending = UserDefaults.standard.object(forKey: "hideWidgetAfterSending") as? Bool ?? true {
        didSet { UserDefaults.standard.set(hideWidgetAfterSending, forKey: "hideWidgetAfterSending") }
    }
    @Published var fatal = false
    let notifications = NotificationBridge()
    private var manager: LifecycleManager?
    private var server: HookServer?
    private var timer: Timer?
    private var healthTimer: Timer?
    private var refreshing = false
    private var changeCount = NSPasteboard.general.changeCount
    var onCapture: (() -> Void)?
    var onHide: (() -> Void)?
    var widgetWasVisible: Bool {
        get { UserDefaults.standard.bool(forKey: "widgetVisible") }
        set { UserDefaults.standard.set(newValue, forKey: "widgetVisible") }
    }
    func hideWidget() { onHide?() }
    var current: Project? { projects.first { $0.id == selectedID } }
    var currentProject: Project? {
        guard let id = selectedID, let group = groupID(for: id) else { return nil }
        return projectGroups.first { $0.id == group }
    }
    var isAdditionalCLI: Bool { cliInstances.contains { $0.id == selectedID } }
    func groupID(for id: UUID) -> UUID? {
        if projectGroups.contains(where: { $0.id == id }) { return id }
        return cliInstances.first { $0.id == id }?.projectID
    }
    func controllers(in projectID: UUID) -> [Project] {
        let children = Set(cliInstances.filter { $0.projectID == projectID }.map(\.id))
        return projects.filter { $0.id == projectID || children.contains($0.id) }
    }
    func cliTitle(_ id: UUID) -> String {
        cliInstances.first { $0.id == id }?.name ?? "Main · \(projects.first { $0.id == id }?.cli.title ?? "CLI")"
    }
    func projectState(_ id: UUID) -> LifecycleState? {
        let states = controllers(in: id).compactMap { health[$0.id]?.state }
        return [.running, .starting, .stopping, .failed, .disconnected, .stopped].first { states.contains($0) }
    }
    var currentHealth: ProjectHealth? { selectedID.flatMap { health[$0] } }
    var activity: AgentActivity? { selectedID.flatMap { activities[$0] } }
    var canPaste: Bool { !quitReviewActive && !fatal && !busy && ready && currentHealth?.agentHealthy == true && currentHealth?.bracketedPaste == true && activity?.modal != true && activity?.kind != .approvalRequired }
    var canSubmit: Bool { canPaste && activity?.canSubmit(now: Date()) == true }
    var outputDestinationID: UUID? { outputProjectID ?? selectedID }
    var displayedOutput: String {
        guard outputSnapshot?.projectID == outputDestinationID, outputSnapshot?.view == outputView else { return "" }
        return outputSnapshot?.text ?? ""
    }
    var hasDisplayedOutput: Bool { outputSnapshot != nil && outputSnapshot?.projectID == outputDestinationID && outputSnapshot?.view == outputView }
    var styledOutput: AttributedString {
        guard outputSnapshot?.projectID == outputDestinationID, outputSnapshot?.view == outputView else { return AttributedString() }
        return outputSnapshot?.styledText ?? AttributedString()
    }
    var fallbackProject: Project? { projects.first { $0.id == openFallbackProjectID } }

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AgentRouter")
        let defaults: [Project]
        if let data = UserDefaults.standard.data(forKey: "destinations"), let old = try? JSONDecoder().decode([Destination].self, from: data), !old.isEmpty {
            defaults = old.map { Project(name: $0.name, session: $0.session) }
        } else { defaults = Project.defaults }
        let tmux = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"].first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/opt/homebrew/bin/tmux"
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/AgentRouterHook").path
        do {
            let store = ProjectStore(url: directory.appendingPathComponent("projects.json"))
            // Saved projects must remain visible even if IPC or health checks fail.
            let saved = try store.load(defaults: defaults)
            projectGroups = saved.projects; cliInstances = saved.instances; projects = saved.controllers
            history = saved.history
            selectedID = UserDefaults.standard.string(forKey: "selectedProjectID").flatMap(UUID.init(uuidString:))
            if current == nil { selectedID = projects.first?.id }
            let m = try LifecycleManager(store: store, defaults: defaults, tmux: tmux, hookHelper: helper, ipcPath: directory.appendingPathComponent("events.sock").path)
            manager = m
            server = try HookServer(path: directory.appendingPathComponent("events.sock").path) { data, pid in await m.ingest(data, peerPID: pid) }
            Task { await refresh(initial: true) }
        } catch { fatal = true; status = "Startup failed: \(error.localizedDescription)" }
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in Task { @MainActor in self?.pollClipboard() } }
        healthTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in await self?.refresh() } }
    }
    func refresh(initial: Bool = false) async {
        guard let manager, !busy, !refreshing, !fatal else { return }
        refreshing = true; defer { refreshing = false }
        do {
            let snapshot = await manager.snapshot()
            guard !busy else { return }
            projectGroups = snapshot.projects; cliInstances = snapshot.instances; projects = snapshot.controllers; history = snapshot.history
            if current == nil { selectedID = projects.first?.id }
            let nextHealth = try await manager.health()
            let refreshedSnapshot = await manager.snapshot()
            let nextActivities = await manager.activities()
            guard !busy else { return }
            health = nextHealth; projectGroups = refreshedSnapshot.projects; cliInstances = refreshedSnapshot.instances
            projects = refreshedSnapshot.controllers; history = refreshedSnapshot.history
            activities = nextActivities
            if current == nil { selectedID = projects.first?.id }
            if initial {
                try await manager.saveInitialSettings()
                if currentHealth?.state == .running {
                    status = "\(current?.name ?? "The selected project") already has a running agent. Use Open Terminal to show it."
                } else {
                    status = "Choose a project, configure its directory, and press Start Agent."
                }
            }
            for entry in await manager.drainNotifications() {
                do { try await notifications.post(entry) } catch { status = "Notification failed: \(error.localizedDescription)" }
            }
            await refreshOutput()
        } catch { status = error.localizedDescription; health = [:]; ready = false }
    }
    @discardableResult
    func perform(_ operation: @escaping (LifecycleManager) async throws -> Void, success: String) async -> Bool {
        guard let manager, !busy, !fatal, !quitReviewActive else { return false }
        busy = true; ready = false
        while refreshing { try? await Task.sleep(for: .milliseconds(20)) }
        let succeeded: Bool
        do { try await operation(manager); status = success; succeeded = true }
        catch { status = error.localizedDescription; succeeded = false }
        busy = false; await refresh()
        return succeeded
    }
    func start() async {
        guard let id = current?.id else { return }
        guard !busy, !fatal else { return }
        let mode = launchMode
        status = "Starting agent and opening Terminal…"
        await perform({ manager in
            try await manager.start(id, mode: mode)
            try await self.verifyStartupAndOpenTerminal(id, manager: manager)
        }, success: "Agent session started with \(mode.title.lowercased()) and opened in Terminal. Complete any login, trust, or startup dialogs there.")
    }
    func stop(force: Bool = false) async {
        guard let id = current?.id else { return }
        await perform({ manager in
            if force { try await manager.forceStop(id, confirmed: true) }
            else { try await manager.stop(id, confirmedInterrupt: true) }
        }, success: force ? "Force-stop approved and sent to the owned controller." : "Graceful shutdown requested. No force stop will happen automatically.")
    }
    func restart() async {
        guard let id = current?.id else { return }
        let mode = launchMode
        await perform({ manager in
            var health = try await manager.health()[id]
            if health?.paneDead != true {
                try await manager.stop(id, confirmedInterrupt: true)
                for _ in 0..<50 {
                    health = try await manager.health()[id]
                    if health?.paneDead == true { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard health?.paneDead == true else { throw RouterError.message("The agent is still stopping. Restart did not force-stop it; wait and try again.") }
            }
            try await manager.restart(id, mode: mode)
            try await self.verifyStartupAndOpenTerminal(id, manager: manager)
        }, success: "Restarted with \(mode.title.lowercased()) and opened the new session in Terminal.")
    }
    private func verifyStartupAndOpenTerminal(_ id: UUID, manager: LifecycleManager) async throws {
        // Do not mistake a short-lived shebang interpreter for a surviving CLI.
        try await Task.sleep(for: .seconds(2))
        let health = try await manager.health()[id]
        guard health?.agentHealthy == true else {
            let captured = health?.paneDead == true ? (try? await manager.captureOutput(id)) : nil
            let detail = captured?.split(whereSeparator: \.isNewline).prefix(3).joined(separator: " ") ?? "Open Terminal to inspect authentication or startup."
            throw RouterError.message("Agent startup was not verified. \(health?.message ?? "No health status.") \(String(detail.prefix(1000)))")
        }
        do {
            try await TerminalLauncher.open(target: manager.terminalTarget(id))
        } catch {
            throw RouterError.message("The agent is running, but Terminal could not open: \(error.localizedDescription) Use Open Terminal; do not start a second agent.")
        }
    }
    func open() async {
        guard let id = current?.id else { return }
        await openProject(id)
    }
    @discardableResult
    func selectProjectAndOpenCLI(_ id: UUID) async -> Bool {
        var target = id
        if projectGroups.contains(where: { $0.id == id }), let remembered = lastCLIByProject[id.uuidString].flatMap(UUID.init(uuidString:)) {
            guard controllers(in: id).contains(where: { $0.id == remembered }) else {
                status = "The remembered CLI no longer exists. Choose a CLI explicitly from AR → project. No other CLI was opened."
                return false
            }
            target = remembered
        }
        return await selectCLIAndOpen(target)
    }
    /// Open project controls without launching or focusing any Terminal window.
    func selectProjectForManagement(_ id: UUID) -> Bool {
        guard !busy, !fatal, !quitReviewActive, projectGroups.contains(where: { $0.id == id }) else { return false }
        if currentProject?.id == id { return true }
        let target = lastCLIByProject[id.uuidString].flatMap(UUID.init(uuidString:)) ?? id
        guard controllers(in: id).contains(where: { $0.id == target }) else {
            status = "The remembered CLI no longer exists. Select a CLI explicitly from the AR menu."
            return false
        }
        selectedID = target
        return true
    }
    @discardableResult
    func selectCLIAndOpen(_ id: UUID) async -> Bool {
        guard !busy, !fatal, !quitReviewActive, projects.contains(where: { $0.id == id }) else { return false }
        selectedID = id
        guard health[id]?.agentHealthy == true else {
            status = "\(current?.name ?? "The selected CLI") is not running. Use Start Agent for this CLI."
            return false
        }
        return await openProject(id)
    }
    @discardableResult
    func newCLI(_ cli: CLIKind, projectID: UUID? = nil) async -> Bool {
        let requestedProject = projectID == nil ? currentProject : projectGroups.first { $0.id == projectID }
        guard let root = requestedProject else {
            status = "Select a project first."; return false
        }
        let succeeded = await perform({ manager in
            let id = try await manager.addCLI(projectID: root.id, cli: cli)
            let snapshot = await manager.snapshot()
            self.projectGroups = snapshot.projects; self.cliInstances = snapshot.instances; self.projects = snapshot.controllers
            self.selectedID = id
            try await manager.start(id)
            try await self.verifyStartupAndOpenTerminal(id, manager: manager)
        }, success: "Started a new independent \(cli.title) CLI in \(root.name). Select it in the CLI menu.")
        if let id = selectedID, groupID(for: id) == root.id {
            lastCLIByProject[root.id.uuidString] = id.uuidString
            UserDefaults.standard.set(lastCLIByProject, forKey: "lastCLIByProject")
        }
        return succeeded
    }
    @discardableResult
    func openProject(_ id: UUID) async -> Bool {
        return await perform({ manager in try await TerminalLauncher.open(target: manager.terminalTarget(id)) }, success: "Opened the project's Terminal tab, reusing its existing session when attached.")
    }
    func openSplitView(balance: Bool = false) async {
        guard let first = current?.id, let second = splitProjectID, first != second else {
            status = "Choose a different second project for Split View."; return
        }
        await perform({ manager in
            let target = try await manager.splitViewTarget(first: first, second: second, balance: balance)
            try await TerminalLauncher.open(target: target)
        }, success: "Opened Split View. Drag its divider to resize; click a pane to work there. AgentRouter sends still use the displayed Destination.")
    }
    func closeSplitView() async {
        guard let first = current?.id, let second = splitProjectID, first != second else { return }
        await perform({ try await $0.closeSplitView(first: first, second: second) }, success: "Closed only the split display. Both project agents remain running; Open Terminal still works separately.")
    }
    /// Normal workflow always snapshots the latest pasteboard on the button click.
    /// A pending start offer is memory-only and bound to the explicitly selected project.
    func sendAndOpenCLI() async {
        guard !busy, !fatal, !quitReviewActive, let project = current else { return }
        guard let prompt = NSPasteboard.general.string(forType: .string) else {
            status = "The clipboard has no plain text. Copy a prompt, then click Send Clipboard & Open Terminal."; return
        }
        do { try Tmux.validateText(prompt) }
        catch { status = error.localizedDescription; return }
        changeCount = NSPasteboard.general.changeCount
        text = prompt; source = "Latest clipboard — Send Clipboard & Open Terminal"
        openFallbackProjectID = nil
        let offer = StartOffer(projectID: project.id, projectName: project.name, prompt: prompt, mode: launchMode)
        let delivered = await perform({ manager in
            let state = try await manager.health()[project.id]?.state
            if state == .stopped || state == .failed || state == .disconnected {
                self.startOffer = offer
                return
            }
            try await self.submitAndOpen(manager: manager, offer: offer)
        }, success: "Prompt submitted; Terminal opened for \(project.name).")
        if startOffer != nil { status = "Confirm startup for \(project.name). Nothing has been sent." }
        else if delivered { if hideWidgetAfterSending { hideWidget() } }
        else {
            openFallbackProjectID = project.id
            status += " Inspect the CLI before retrying if delivery may have begun."
        }
    }
    func startAndSendPendingPrompt() async {
        guard let offer = startOffer, !busy, !quitReviewActive else { return }
        startOffer = nil
        let delivered = await perform({ manager in
            try await manager.start(offer.projectID, mode: offer.mode)
            let deadline = Date().addingTimeInterval(10)
            var blocker = "CLI startup readiness is unverified."
            while Date() < deadline {
                if let issue = await manager.submissionBlocker(offer.projectID) { blocker = issue }
                else {
                    try await self.submitAndOpen(manager: manager, offer: offer)
                    return
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            throw RouterError.message("\(offer.projectName) started, but no prompt was sent: \(blocker) Use Open Terminal for manual interaction. No background send remains queued.")
        }, success: "Prompt submitted; Terminal opened for \(offer.projectName).")
        if delivered { if hideWidgetAfterSending { hideWidget() } }
        else {
            openFallbackProjectID = offer.projectID
            status += " Inspect the CLI before retrying if delivery may have begun."
        }
    }
    private func submitAndOpen(manager: LifecycleManager, offer: StartOffer) async throws {
        if let issue = await manager.submissionBlocker(offer.projectID) {
            throw RouterError.message("\(offer.projectName): nothing sent. \(issue) Use Open Terminal for manual interaction or the confirmed Paste Only fallback.")
        }
        let target = try await manager.terminalTarget(offer.projectID)
        try await manager.paste(offer.prompt, projectID: offer.projectID, confirmedReady: true, submit: true)
        text = ""; source = "Clipboard prompt submitted to \(offer.projectName)"
        do { try await TerminalLauncher.open(target: target) }
        catch {
            throw RouterError.message("The prompt was submitted to \(offer.projectName), but Terminal could not open. Do not resend the prompt. Use Open Terminal. \(error.localizedDescription)")
        }
    }
    func refreshOutput() async {
        guard let manager, let id = outputDestinationID, !readingOutput, !busy else { return }
        let view = outputView
        readingOutput = true; defer { readingOutput = false }
        do {
            let captured: String
            if view == .latestReply { captured = try await manager.latestReply(id) }
            else { captured = try await manager.captureOutput(id, includeColors: true) }
            guard id == outputDestinationID, view == outputView, !busy else { return }
            var rendered = view == .terminal ? TerminalOutputStyle.render(captured) : AttributedString(captured)
            if view == .latestReply { rendered.foregroundColor = .white }
            outputSnapshot = OutputSnapshot(projectID: id, text: view == .latestReply ? captured : String(rendered.characters), styledText: rendered, view: view); outputError = ""
        } catch {
            guard id == outputDestinationID, view == outputView else { return }
            outputSnapshot = nil; outputError = error.localizedDescription
        }
    }
    func copyOutput() async {
        guard !readingOutput, !busy else { status = "Output is refreshing. Try Copy Output again when it finishes."; return }
        await refreshOutput()
        guard let snapshot = outputSnapshot, snapshot.projectID == outputDestinationID, snapshot.view == outputView else {
            status = "Refresh output for the selected output project first."; return
        }
        let board = NSPasteboard.general
        board.clearContents()
        guard board.setString(snapshot.text, forType: .string) else { status = "Could not copy output to the clipboard."; return }
        changeCount = board.changeCount // Do not recapture our own output as an incoming prompt.
        status = snapshot.view == .latestReply ? "Copied the complete latest recorded reply. Paste it into your desktop conversation manually." : "Copied the retained terminal screen. Hidden CLI scrollback may not be included."
    }
    func save(_ p: Project) async {
        await perform({ try await $0.saveProject(p) }, success: p.cli == .codex ? "Project settings saved. Codex permissions apply at the next Start or Restart." : "Project settings saved.")
        if projectGroups.contains(p) {
            editing = nil
            if selectedID.flatMap({ groupID(for: $0) }) != p.id { selectedID = p.id }
        }
    }
    func remove() async {
        guard let id = current?.id else { return }
        let additional = isAdditionalCLI, parent = groupID(for: id)
        await perform({ manager in
            try await manager.removeProject(id)
            self.selectedID = additional ? parent : nil
        }, success: additional ? "CLI removed. The project's Main CLI is selected; other agents were not stopped." : "Project removed; no repository files were changed.")
    }
    func send(submit: Bool, isReply: Bool = false) async {
        guard canPaste, let id = current?.id else { return }
        let draft = isReply ? reply : text, questionID = isReply ? activity?.questionID : nil
        let delivered = await perform({ try await $0.paste(draft, projectID: id, confirmedReady: true, submit: submit, replyingTo: questionID) }, success: submit ? "Sent and submitted to the displayed destination." : "Pasted only. Review and submit in the agent terminal.")
        if delivered {
            if isReply { reply = "" } else { text = ""; source = "Preview cleared after delivery" }
            if hideWidgetAfterSending { hideWidget() }
        } else { status += " Inspect the CLI before retrying if delivery may have begun." }
    }
    func enableNotifications() async {
        do { status = try await notifications.authorize() ? "Notifications authorized. Enable them per project in Settings." : "Notifications are disabled by macOS. History remains available in AgentRouter." }
        catch { status = error.localizedDescription }
    }
    func testNotification(for project: Project) async {
        do { status = try await notifications.verify(project: project) }
        catch { status = "Notification test: \(error.localizedDescription)" }
    }
    func clearHistory() async { await perform({ try await $0.clearHistory() }, success: "Notification history cleared.") }
    private func pollClipboard() {
        guard !quitReviewActive else { return }
        let board = NSPasteboard.general
        guard board.changeCount != changeCount else { return }
        changeCount = board.changeCount
        text = ""; source = "Clipboard changed; destination stays manually selected."
        let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard id == "com.openai.chat" || id == "com.anthropic.claudefordesktop" else { return }
        capture(source: "Desktop clipboard (frontmost-app heuristic)", automatic: true)
    }
    func capture(source: String = "Manual clipboard capture", automatic: Bool = false) {
        guard !quitReviewActive else { return }
        changeCount = NSPasteboard.general.changeCount
        guard let value = NSPasteboard.general.string(forType: .string) else { text = ""; status = "Clipboard has no plain text."; return }
        do { try Tmux.validateText(value) } catch { text = ""; status = error.localizedDescription; return }
        text = value; self.source = source
        if automatic { onCapture?() }
    }

    var needsQuitReview: Bool {
        busy || editing != nil || startOffer != nil || !text.isEmpty || !reply.isEmpty ||
        projects.contains { health[$0.id]?.state != .stopped }
    }

    var quitWarnings: [String] {
        var result: [String] = []
        if busy { result.append("An operation is finishing. Wait before quitting or exporting.") }
        if !text.isEmpty || !reply.isEmpty || startOffer != nil { result.append("Unsent prompt/reply drafts will be discarded. They are not included in the checkpoint.") }
        if editing != nil { result.append("Project settings are open. Unsaved edits will be discarded.") }
        return result
    }

    func checkpointEntries() async throws -> [CheckpointEntry] {
        guard quitReviewActive, !busy, let manager else { throw RouterError.message("Wait for the current operation, or cancel and resolve the startup error before exporting.") }
        let snapshot = await manager.snapshot()
        let states = try? await manager.health()
        let signals = await manager.activities()
        var entries: [CheckpointEntry] = []
        for root in snapshot.projects {
            for project in snapshot.controllers where project.id == root.id || snapshot.instances.contains(where: { $0.id == project.id && $0.projectID == root.id }) {
                let binding = snapshot.bindings[project.id.uuidString]
                let state = states?[project.id]
                let reply = try? await manager.latestReply(project.id)
                entries.append(CheckpointEntry(project: root.name, cli: project.name + " · " + project.cli.title,
                    directory: project.directory, session: project.session + (binding.map { " (recorded ID: \($0.sessionID), server: \($0.server))" } ?? ""), pane: binding?.paneID,
                    health: state.map { "\($0.state.rawValue); tmux verified: \($0.tmuxHealthy); agent process verified: \($0.agentHealthy)" } ?? "unverified",
                    activity: signals[project.id]?.kind.rawValue ?? "UNKNOWN", reply: reply))
            }
        }
        return entries
    }

    func prepareQuitShutdown() async throws -> [QuitStopTarget] {
        guard quitReviewActive, !busy, let manager else { throw RouterError.message("Wait for the current operation before stopping agents.") }
        busy = true
        defer { busy = false }
        while refreshing { try await Task.sleep(for: .milliseconds(20)) }
        return try await manager.quitStopTargets()
    }

    func stopAgentsForQuit(_ targets: [QuitStopTarget], force: Bool) async -> (stopped: Bool, message: String, remaining: [QuitStopTarget]) {
        guard quitReviewActive, !busy, let manager else { return (false, "AgentRouter is busy or the lifecycle manager is unavailable.", []) }
        busy = true
        while refreshing { try? await Task.sleep(for: .milliseconds(20)) }
        var errors: [String] = []
        for target in targets {
            do { try await manager.requestQuitStop(target, force: force) }
            catch { errors.append(target.name + ": " + error.localizedDescription) }
        }
        let deadline = Date().addingTimeInterval(10)
        var remaining: [QuitStopTarget] = []
        var verificationError: String?
        repeat {
            do {
                remaining = try await manager.quitStopTargets()
                if remaining.isEmpty {
                    busy = false
                    return (true, "All configured CLI processes are verified stopped.", [])
                }
                verificationError = nil
            } catch {
                // tmux may not have published pane_dead yet after the root process exits.
                // Retry within the same bounded wait; never treat an identity error as stopped.
                verificationError = error.localizedDescription
                remaining = []
            }
            try? await Task.sleep(for: .milliseconds(250))
        } while Date() < deadline
        busy = false; await refresh()
        if let verificationError {
            return (false, "Shutdown could not be verified. AgentRouter remains open.\n" + verificationError + "\n" + errors.joined(separator: "\n"), [])
        }
        let names = remaining.map(\.name).joined(separator: ", ")
        let eligible = remaining.filter { live in targets.contains { $0.id == live.id && $0.runID == live.runID && $0.paneID == live.paneID } }
        return (false, "Still running: \(names). AgentRouter remains open. No automatic force stop was performed.\n" + errors.joined(separator: "\n"), eligible)
    }
}
