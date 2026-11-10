import SwiftUI
import AppKit
import RouterCore

struct RouterWidget: View {
    @ObservedObject var model: RouterModel
    @State private var confirmation: Action?
    @State private var showAppSettings = false
    @State private var managingProjectID: UUID?
    enum Action: String, Identifiable { case stop, restart, force, remove, startAndSend; var id: String { rawValue } }
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if model.showHistory { historyPage }
                    else if showAppSettings { settingsPage }
                    else if managingProjectID != nil { projectsPage }
                    else { workspace }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack(spacing: 8) {
                if model.busy { ProgressView().controlSize(.small) }
                Image(systemName: "lock.shield").foregroundStyle(.secondary)
                Text("Agents keep running while hidden").font(.system(size: 15)).foregroundStyle(.secondary)
                Spacer()
                Text("⌥⌘R to reopen").font(.system(size: 15)).foregroundStyle(.secondary)
            }.padding(.horizontal, 20).padding(.vertical, 12)
        }
        .font(.system(size: 16))
        .controlSize(.large)
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(width: 640)
        .disabled(model.quitReviewActive)
        .onChange(of: model.startOffer?.id) { _, id in
            if id != nil { confirmation = .startAndSend }
        }
        .onChange(of: model.outputProjectID) { _, _ in Task { await model.refreshOutput() } }
        .onChange(of: model.outputView) { _, _ in Task { await model.refreshOutput() } }
        .onChange(of: model.selectedID) { _, _ in
            model.outputProjectID = nil
            if let managingProjectID, model.currentProject?.id != managingProjectID { self.managingProjectID = nil }
            Task { await model.refreshOutput() }
        }
        .onAppear { model.outputProjectID = nil }
        .sheet(item: $model.editing) { project in ProjectEditor(model: model, project: project).disabled(model.quitReviewActive) }
        .alert(item: $confirmation) { action in
            let project = model.current?.name ?? "project"
            let message: String
            switch action {
            case .stop: message = "Request shutdown of \(project)? This sends SIGTERM to its verified controller group and may interrupt active work. No force stop follows automatically."
            case .restart: message = "Restart \(project) with \(model.launchMode.title.lowercased())? Shutdown may interrupt active work. Restart proceeds only after the previous CLI exits."
            case .force: message = "Force-stop \(project)? This sends SIGKILL to its verified controller group. Active work may be lost."
            case .remove: message = model.isAdditionalCLI ? "Remove only \(project)? Its agent must be stopped first. Other CLIs and project settings remain." : "Remove \(project) and all of its configured CLIs? All agents in this project must be stopped first. Repository files remain unchanged."
            case .startAndSend:
                let offer = model.startOffer
                message = "Start \(offer?.projectName ?? project) with \(offer?.mode.title.lowercased() ?? "the selected launch mode") and send the clipboard prompt captured when you clicked? Submission occurs only if readiness is verified within 10 seconds. Otherwise, nothing is sent and Open Terminal is offered."
            }
            let performAction: () -> Void = {
                Task {
                    switch action {
                    case .stop: await model.stop()
                    case .restart: await model.restart()
                    case .force: await model.stop(force: true)
                    case .remove: await model.remove()
                    case .startAndSend: await model.startAndSendPendingPrompt()
                    }
                }
            }
            let primary: Alert.Button = action == .startAndSend
                ? .default(Text("Start & Send"), action: performAction)
                : .destructive(Text(action == .force ? "Force Stop and Discard Work" : "Confirm"), action: performAction)
            return Alert(title: Text(action == .startAndSend ? "Start agent before sending?" : "Confirm \(action.rawValue)"), message: Text(message), primaryButton: primary, secondaryButton: .cancel {
                if action == .startAndSend { model.startOffer = nil }
            })
        }
    }
    private var header: some View {
        HStack(spacing: 12) {
            if model.showHistory || showAppSettings || managingProjectID != nil {
                Button {
                    model.showHistory = false; showAppSettings = false; managingProjectID = nil
                } label: { Image(systemName: "chevron.left") }.accessibilityLabel("Back to projects")
            }
            Image(systemName: "arrow.triangle.branch").font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.tint).frame(width: 44, height: 44)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text("AgentRouter").font(.system(size: 24, weight: .bold))
                Text("Your projects. Your agents.").font(.system(size: 15)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.showHistory = true; showAppSettings = false; managingProjectID = nil } label: { Image(systemName: "bell") }
                .accessibilityLabel("Notification history")
            Button { model.showHistory = false; showAppSettings = true; managingProjectID = nil } label: { Image(systemName: "slider.horizontal.3") }
                .accessibilityLabel("App settings")
            Menu {
                ForEach(Array(model.projectGroups.enumerated()), id: \.element.id) { index, project in
                    Button("Open " + project.name) { Task { await model.selectProjectAndOpenCLI(project.id) } }
                        .disabled(model.busy || model.fatal)
                        .keyboardShortcut(model.shortcuts && index < 9 ? KeyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.command, .option]) : nil)
                }
                Divider()
                Button("Quit AgentRouter…") { NSApp.terminate(nil) }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("App actions")
            Button { model.hideWidget() } label: { Image(systemName: "minus") }
                .help("Hide AgentRouter; agents keep running").accessibilityLabel("Hide AgentRouter")
        }.padding(20)
    }

    private func card<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: icon).font(.system(size: 17, weight: .semibold))
            content()
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.07)))
    }

    private var workspace: some View {
        Group {
            card("Projects", icon: "folder") {
                HStack {
                    Text("Select a project to work with its CLI.").foregroundStyle(.secondary)
                    Spacer()
                    Button { model.editing = Project() } label: { Label("Add", systemImage: "plus") }
                        .disabled(model.busy || model.fatal)
                }
                projectRows
                statusMessage
            }
            if let activity = model.activity, activity.question != nil || [.approvalRequired, .blocked, .needsInput].contains(activity.kind) {
                card("Agent activity", icon: "waveform.path") {
                    Text(activity.kind.rawValue.replacingOccurrences(of: "_", with: " ")).font(.system(size: 16, weight: .semibold))
                    Text(activity.detail).textSelection(.enabled)
                    if let question = activity.question {
                        Text(question).textSelection(.enabled)
                        TextEditor(text: $model.reply).font(.system(size: 16, design: .monospaced)).frame(height: 85).border(.quaternary)
                        HStack {
                            Button("Paste Reply Only") { Task { await model.send(submit: false, isReply: true) } }.disabled(!model.canPaste || model.reply.isEmpty || activity.modal)
                            Button("Send Reply & Submit") { Task { await model.send(submit: true, isReply: true) } }.disabled(!model.canSubmit || model.reply.isEmpty)
                        }
                        if activity.modal { Text("Answer structured questions in Open CLI. Approvals must be handled there.").foregroundStyle(.orange) }
                    }
                    DisclosureGroup("Readiness details") {
                        Text(activity.evidence).textSelection(.enabled)
                        Text(activity.canSubmit(now: Date()) ? "Verified idle lease; expires shortly." : "Readiness unverified. Use Paste Only or Open CLI.")
                    }.font(.system(size: 15)).foregroundStyle(.secondary)
                }
            }
            card("Prompt preview & manual routing", icon: "doc.on.clipboard") {
                if let project = model.current {
                    Text(project.name + " → " + model.cliTitle(project.id)).fontWeight(.semibold).foregroundStyle(.tint)
                }
                Text(model.source).font(.system(size: 15)).foregroundStyle(.secondary)
                TextEditor(text: $model.text).font(.system(size: 16, design: .monospaced)).frame(height: 120).border(.quaternary)
                HStack {
                    Text("\(model.text.utf8.count) / 65,536 bytes").font(.system(size: 15)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear") { model.text = "" }
                }
                Button { Task { await model.sendAndOpenCLI() } } label: {
                    Label("Send & Open CLI", systemImage: "paperplane.fill").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).disabled(model.busy || model.fatal || model.current == nil)
                Text("Reads the latest clipboard. Submits only to the selected CLI when readiness is verified.").font(.system(size: 15)).foregroundStyle(.secondary)
                Button("Open CLI") { Task { await model.open() } }.disabled(model.busy || model.currentHealth?.paneID == nil)
                if let fallback = model.fallbackProject {
                    Button("Open \(fallback.name) for manual interaction") { Task { await model.openProject(fallback.id) } }.disabled(model.busy)
                }
                DisclosureGroup("Manual paste & submit") {
                Toggle("I checked the destination and its input is ready", isOn: $model.ready).disabled(model.busy)
                HStack {
                    Button("Paste Only") { Task { await model.send(submit: false) } }.disabled(!model.canPaste || model.text.isEmpty)
                    Button("Send & Submit") { Task { await model.send(submit: true) } }.disabled(!model.canSubmit || model.text.isEmpty)
                }
                Text("Submit requires a fresh verified idle signal. Approvals stay in the CLI.").font(.system(size: 15)).foregroundStyle(.secondary)
                }
            }
            outputCard
        }
    }

    private var statusMessage: some View {
        Text(model.status).font(.system(size: 15)).foregroundStyle(model.fatal ? .red : .secondary)
            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }

    private var outputCard: some View {
        card("CLI output", icon: "text.alignleft") {
            HStack {
                Button { Task { await model.refreshOutput() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }.disabled(model.busy)
                Spacer()
                Button { Task { await model.copyOutput() } } label: {
                    Label(model.outputView == .latestReply ? "Copy Output" : "Copy Screen", systemImage: "doc.on.doc")
                }.buttonStyle(.borderedProminent).disabled(model.busy || !model.hasDisplayedOutput)
            }
            Picker("View", selection: $model.outputView) {
                ForEach(RouterModel.OutputView.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            ScrollView([.vertical, .horizontal]) {
                Text(model.styledOutput).font(.system(size: 16, design: .monospaced))
                    .textSelection(.enabled).fixedSize(horizontal: true, vertical: true)
                    .padding(12).frame(maxWidth: .infinity, alignment: .topLeading)
            }.frame(height: 230).background(Color.black, in: RoundedRectangle(cornerRadius: 10))
            if !model.outputError.isEmpty { Text(model.outputError).font(.system(size: 15)).foregroundStyle(.secondary) }
            Text(model.outputView == .latestReply ? "Complete latest recorded reply. Copy preserves the text exactly." : "Retained terminal screen; use Latest reply for complete reply copying.")
                .font(.system(size: 15)).foregroundStyle(.secondary)
        }
    }

    private var projectsPage: some View {
        Group {
            card("Project settings", icon: "gearshape") {
                if let project = model.currentProject {
                    Text(project.name).font(.system(size: 18, weight: .semibold))
                    cliSelector(allowCreation: true)
                    Button("Edit Configuration…") { model.editing = model.currentProject }
                } else {
                    Text("Add or select a project above.").foregroundStyle(.secondary)
                }
                if model.current != nil {
                    HStack {
                        Button(model.currentHealth?.state == .running ? "Agent Running" : "Start Agent") { Task { await model.start() } }
                            .disabled([.running, .starting, .stopping].contains(model.currentHealth?.state ?? .stopped))
                        Button("Open CLI") { Task { await model.open() } }.disabled(model.currentHealth?.paneID == nil)
                    }.disabled(model.busy || model.fatal)
                    HStack {
                        Button("Stop") { confirmation = .stop }.disabled(model.currentHealth?.agentHealthy != true)
                        Button("Restart") { confirmation = .restart }.disabled(model.currentHealth?.paneID == nil)
                        Menu("More") {
                            Button("Force Stop…", role: .destructive) { confirmation = .force }
                            Button(model.isAdditionalCLI ? "Remove This CLI…" : "Remove Project…", role: .destructive) { confirmation = .remove }
                        }
                    }.disabled(model.busy || model.fatal)
                    Picker("Start / restart", selection: $model.launchMode) {
                        ForEach(LaunchMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.disabled(model.busy)
                    Text(model.currentHealth?.message ?? "Checking health…").font(.system(size: 15)).foregroundStyle(.secondary)
                    Text("tmux: \(model.currentHealth?.tmuxHealthy == true ? "verified" : "unverified") · CLI process: \(model.currentHealth?.agentHealthy == true ? "alive" : "unverified")")
                        .font(.system(size: 15)).foregroundStyle(.secondary)
                    DisclosureGroup("Session identity") {
                        Text("Session: \(model.current?.session ?? "—") · Pane: \(model.currentHealth?.paneID ?? "not started")").textSelection(.enabled)
                    }.font(.system(size: 15))
                }
                statusMessage
                Button("Refresh status") { Task { await model.refresh() } }.disabled(model.busy)
            }
            splitCard
        }
    }

    private var splitCard: some View {
        card("Work side by side", icon: "rectangle.split.2x1") {
            Picker("Second CLI", selection: $model.splitProjectID) {
                Text("Choose another CLI").tag(Optional<UUID>.none)
                ForEach(model.projects.filter { $0.id != model.selectedID }) { Text($0.name).tag(Optional($0.id)) }
            }
            HStack {
                Button("Open Split View") { Task { await model.openSplitView() } }
                Button("Balance 50/50") { Task { await model.openSplitView(balance: true) } }
                Button("Close Split View") { Task { await model.closeSplitView() } }
            }.disabled(model.busy || model.fatal || model.splitProjectID == nil || model.splitProjectID == model.selectedID)
            if let second = model.projects.first(where: { $0.id == model.splitProjectID }), second.id != model.selectedID {
                Button("Open \(second.name) Separately") { Task { await model.openProject(second.id) } }.disabled(model.busy || model.fatal)
            }
            Text("Both CLIs must be running. Drag the divider in Terminal to resize. The routing destination stays manually selected.")
                .font(.system(size: 15)).foregroundStyle(.secondary)
        }
    }

    private var historyPage: some View {
        card("Notification history", icon: "bell.badge") {
            HStack { Text("\(model.history.count) events").foregroundStyle(.secondary); Spacer(); Button("Clear history") { Task { await model.clearHistory() } }.disabled(model.busy) }
            if model.history.isEmpty {
                Label("No events yet", systemImage: "bell").foregroundStyle(.secondary).padding(.vertical, 24)
            }
            ForEach(model.history.reversed()) { entry in
                Button { model.selectedID = entry.projectID; showAppSettings = false; managingProjectID = nil; model.showHistory = false } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.projectName).font(.system(size: 16, weight: .semibold))
                        Text(entry.kind.rawValue.replacingOccurrences(of: "_", with: " "))
                        Text(entry.timestamp.formatted(date: .abbreviated, time: .standard) + " · " + entry.evidence)
                            .font(.system(size: 15)).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                }.buttonStyle(.plain)
                Divider()
            }
        }
    }

    private var settingsPage: some View {
        Group {
            card("Window behavior", icon: "macwindow") {
                Toggle("Show widget automatically when copying", isOn: $model.showWidgetOnCopy)
                Toggle("Hide widget after sending", isOn: $model.hideWidgetAfterSending)
                Text("When hidden, monitoring stays active. A temporary dot beside AR indicates a captured clipboard.").foregroundStyle(.secondary)
            }
            card("Keyboard shortcuts", icon: "keyboard") {
                Toggle("Project shortcuts: ⌥⌘1–9", isOn: $model.shortcuts)
                Toggle("Global CLI shortcuts: F7 / F8 / F9", isOn: $model.cliFunctionKeysEnabled)
                Text("Project shortcuts work while the widget is active. F7–F9 use your existing project assignments. Hold Fn if your keyboard uses media controls.").foregroundStyle(.secondary)
                Text("⌥⌘R reopens AgentRouter from any application.").fontWeight(.medium)
            }
        }
    }

    @ViewBuilder
    private func cliSelector(allowCreation: Bool) -> some View {
        if let root = model.currentProject {
                HStack {
                    Picker("CLI", selection: Binding<UUID?>(
                        get: { model.selectedID },
                        set: { id in if let id { Task { await model.selectCLIAndOpen(id) } } }
                    )) {
                        ForEach(model.controllers(in: root.id)) { target in
                            Text(model.cliTitle(target.id) + " · " + (model.health[target.id]?.state.rawValue ?? "checking")).tag(Optional(target.id))
                        }
                    }
                    if allowCreation {
                    Menu("New CLI") {
                        Button("Start new Codex") { Task { await model.newCLI(.codex, projectID: root.id) } }
                        Button("Start new Claude Code") { Task { await model.newCLI(.claude, projectID: root.id) } }
                    }
                    }
                }.disabled(model.busy || model.fatal)
            }
    }
    private var projectRows: some View {
        VStack(spacing: 4) {
            ForEach(Array(model.projectGroups.enumerated()), id: \.element.id) { index, project in
                VStack(alignment: .leading, spacing: 10) {
                HStack {
                Button { Task { await model.selectProjectAndOpenCLI(project.id) } } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "folder.fill").foregroundStyle(color(index)).frame(width: 32, height: 36)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(project.name).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                            Text(projectSummary(project.id)).font(.system(size: 15)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Circle().fill(stateColor(model.projectState(project.id))).frame(width: 8, height: 8)
                        Text(model.projectState(project.id)?.rawValue.capitalized ?? "Checking").font(.system(size: 15))
                        if model.currentProject?.id == project.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(color(index)) }
                    }
                    .padding(12).background(color(index).opacity(model.currentProject?.id == project.id ? 0.12 : 0.04), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain).disabled(model.busy)
                .accessibilityLabel(project.name + ", \(model.controllers(in: project.id).count) CLIs")
                Button {
                    if model.selectProjectForManagement(project.id) {
                        managingProjectID = project.id; model.showHistory = false; showAppSettings = false
                    }
                } label: { Image(systemName: "gearshape") }
                    .disabled(model.busy || model.fatal).accessibilityLabel("Settings for " + project.name)
                }
                if model.currentProject?.id == project.id {
                    ViewThatFits(in: .horizontal) {
                        HStack { cliChips(project.id) }
                        VStack(alignment: .leading) { cliChips(project.id) }
                    }.padding(.horizontal, 12)
                }
                }
            }
        }
    }
    @ViewBuilder
    private func cliChips(_ projectID: UUID) -> some View {
        ForEach(model.controllers(in: projectID)) { cli in
            Button { Task { await model.selectCLIAndOpen(cli.id) } } label: {
                HStack {
                    if model.selectedID == cli.id { Image(systemName: "checkmark.circle.fill") }
                    Text(model.cliTitle(cli.id))
                }.font(.system(size: 15))
            }.tint(model.selectedID == cli.id ? .accentColor : .secondary).disabled(model.busy || model.fatal)
        }
    }
    private func projectSummary(_ id: UUID) -> String {
        let controllers = model.controllers(in: id)
        let running = controllers.filter { model.health[$0.id]?.agentHealthy == true }.count
        return "\(running) running · \(controllers.count) configured"
    }
    private func color(_ index: Int) -> Color { [.blue, .green, .orange, .purple, .teal, .pink][index % 6] }
    private func stateColor(_ state: LifecycleState?) -> Color {
        switch state {
        case .running: return .green
        case .starting, .stopping: return .orange
        case .failed, .disconnected: return .red
        default: return .gray
        }
    }
}

struct ProjectEditor: View {
    @ObservedObject var model: RouterModel
    @State var project: Project
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
            Text("Project settings").font(.system(size: 22, weight: .bold))
            Text("CLI type, executable and session below configure Main and defaults for new CLIs. Additional CLIs keep their own type and session. Directory, notification preferences and Codex permissions are shared by this project's CLIs.")
                .font(.system(size: 15)).foregroundStyle(.secondary)
            TextField("Name", text: $project.name)
            HStack {
                TextField("Absolute working directory", text: $project.directory)
                Button("Choose…") {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url { project.directory = url.path }
                }
            }
            Picker("CLI", selection: $project.cli) { ForEach(CLIKind.allCases, id: \.self) { Text($0.title).tag($0) } }
                .onChange(of: project.cli) { _, cli in project.executable = cli.detectedPath }
            TextField("Absolute CLI executable", text: $project.executable)
            TextField("Unique tmux session identifier", text: $project.session)
            if project.cli == .codex || model.controllers(in: project.id).contains(where: { $0.cli == .codex }) {
                Text("Codex permissions").font(.system(size: 18, weight: .semibold))
                Picker("Approval policy", selection: Binding(
                    get: { project.codexSettings?.approvalPolicy ?? .inherit },
                    set: { value in
                        var settings = project.codexSettings ?? CodexSettings()
                        settings.approvalPolicy = value; project.codexSettings = settings
                    }
                )) {
                    ForEach(CodexApprovalPolicy.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Sandbox mode", selection: Binding(
                    get: { project.codexSettings?.sandboxMode ?? .inherit },
                    set: { value in
                        var settings = project.codexSettings ?? CodexSettings()
                        settings.sandboxMode = value; project.codexSettings = settings
                    }
                )) {
                    ForEach(CodexSandboxMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text("Saved choices apply at the next Start or Restart. Never ask does not bypass sandbox limits, sign-in or hook trust. Unrestricted access removes filesystem and network sandbox restrictions.")
                    .font(.system(size: 15)).foregroundStyle(.secondary)
                if let settings = project.codexSettings, !settings.toml.isEmpty {
                    Text(settings.toml).font(.system(size: 15, design: .monospaced)).textSelection(.enabled)
                }
            }
            Toggle("Notifications for this project", isOn: $project.notifications.enabled)
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Turn / task events", isOn: $project.notifications.turnFinished)
                Toggle("Attention", isOn: $project.notifications.needsAttention)
                Toggle("Unexpected exit", isOn: $project.notifications.unexpectedExit)
            }.font(.system(size: 15))
            HStack {
                Button("Allow macOS Notifications…") { Task { await model.enableNotifications() } }
                Button("Test Notification") { Task { await model.testNotification(for: project) } }
            }
            Text("Save to apply notification preferences, including to running sessions. macOS permission applies to all projects. The test checks delivery only; it does not attach agent hooks.")
                .font(.system(size: 15)).foregroundStyle(.secondary)
            Text("Hook settings apply only to AgentRouter launches. Existing CLI configuration is not overwritten. Codex may require hook trust review through Open Terminal → /hooks.").font(.system(size: 15)).foregroundStyle(.secondary)
            Text(model.status).font(.system(size: 15)).foregroundStyle(.secondary)
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { model.editing = nil }
                Button("Save") { Task { await model.save(project) } }.disabled(model.busy)
            }.padding(20)
        }.font(.system(size: 16)).controlSize(.large).frame(width: 600, height: 700)
    }
}
