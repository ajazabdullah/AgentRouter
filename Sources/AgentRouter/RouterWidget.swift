import SwiftUI
import AppKit
import RouterCore

struct RouterWidget: View {
    @ObservedObject var model: RouterModel
    @State private var confirmation: Action?
    enum Action: String, Identifiable { case stop, restart, force, remove, startAndSend; var id: String { rawValue } }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("AgentRouter").font(.headline)
                Spacer()
                Button("Hide") { model.hideWidget() }.help("Hide widget; agents keep running")
                Button("History") { model.showHistory.toggle() }
                Button("Quit") { NSApp.terminate(nil) }
            }.padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Picker("Destination", selection: Binding<UUID?>(
                            get: { model.selectedID },
                            set: { id in
                                if let id { Task { await model.selectProjectAndOpenCLI(id) } }
                            }
                        )) {
                            if model.projects.isEmpty { Text("Add a project").tag(Optional<UUID>.none) }
                            ForEach(model.projects) { Text($0.name).tag(Optional($0.id)) }
                        }.disabled(model.busy)
                        Button { model.editing = Project() } label: { Image(systemName: "plus") }.help("Add project")
                        Button("Settings") { model.editing = model.current }.disabled(model.current == nil)
                    }
                    VStack(spacing: 4) {
                        ForEach(Array(model.projects.enumerated()), id: \.element.id) { index, project in
                            Button { Task { await model.selectProjectAndOpenCLI(project.id) } } label: {
                                HStack {
                                    Circle().fill(color(index)).frame(width: 8, height: 8)
                                    Text(project.name).fontWeight(model.selectedID == project.id ? .semibold : .regular).lineLimit(1)
                                    Text(project.cli.title).font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Circle().fill(stateColor(model.health[project.id]?.state)).frame(width: 7, height: 7)
                                    Text(model.health[project.id]?.state.rawValue.capitalized ?? "Checking").font(.caption)
                                    if let kind = model.activities[project.id]?.kind { Text(kind.rawValue).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary) }
                                }
                                .padding(8).background(color(index).opacity(model.selectedID == project.id ? 0.14 : 0.035), in: RoundedRectangle(cornerRadius: 7))
                            }
                            .buttonStyle(.plain).disabled(model.busy)
                            .keyboardShortcut(model.shortcuts && index < 9 ? KeyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.command, .option]) : nil)
                            .accessibilityLabel(project.name + ", " + project.cli.title)
                        }
                    }
                    DisclosureGroup("Window behavior") {
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle("Show widget automatically when copying", isOn: $model.showWidgetOnCopy)
                            Toggle("Hide widget after sending", isOn: $model.hideWidgetAfterSending)
                            Text("Reopen from any application with ⌥⌘R, or AR → Show AgentRouter.").font(.caption2)
                            Text("When automatic opening is off, a temporary dot appears beside AR. Monitoring stays active while hidden.").font(.caption2).foregroundStyle(.secondary)
                        }.font(.caption).padding(.top, 5)
                    }.font(.caption)
                    Toggle("Project shortcuts: ⌥⌘1–9 while widget is active", isOn: $model.shortcuts).font(.caption)
                    Toggle("Global CLI shortcuts: F7 / F8 / F9 for the first three projects", isOn: $model.cliFunctionKeysEnabled).font(.caption)
                    Text("If your keyboard uses media keys by default, hold Fn with F7/F8/F9, or enable standard function keys in macOS Keyboard settings. Shortcuts require AgentRouter to be running.")
                        .font(.caption2).foregroundStyle(.secondary)
                    if let project = model.current {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Destination: \(project.name)").font(.subheadline.bold())
                            Text(project.directory.isEmpty ? "Choose a working directory in Settings" : project.directory).lineLimit(2)
                            Text("\(project.cli.title) · session \(project.session) · pane \(model.currentHealth?.paneID ?? "not started")")
                        }.font(.caption).textSelection(.enabled).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                        Button("Send Clipboard & Open Terminal") { Task { await model.sendAndOpenCLI() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.busy || model.fatal)
                            .help("Read the latest clipboard, submit only to a verified ready agent, then open its exact Terminal session")
                        Text(model.status).font(.caption).foregroundStyle(model.fatal ? .red : .secondary).textSelection(.enabled)
                        if let fallback = model.fallbackProject {
                            Button("Open Terminal — \(fallback.name) for manual interaction") {
                                Task { await model.openProject(fallback.id) }
                            }.disabled(model.busy)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                        Text("Project management").font(.headline)
                        if model.busy {
                            HStack { ProgressView().controlSize(.small); Text("Working…").font(.caption) }
                        }
                        HStack {
                            Button(model.currentHealth?.state == .running ? "Agent Running" : "Start Agent") { Task { await model.start() } }
                                .disabled([.running, .starting, .stopping].contains(model.currentHealth?.state ?? .stopped))
                                .help(model.currentHealth?.state == .running ? "This agent is already running. Use Open Terminal to show its session." : "Start the selected agent and open its Terminal session")
                            Button("Open Terminal") { Task { await model.open() } }.disabled(model.currentHealth?.paneID == nil)
                            Button("Stop") { confirmation = .stop }.disabled(model.currentHealth?.agentHealthy != true)
                            Button("Restart") { confirmation = .restart }.disabled(model.currentHealth?.paneID == nil)
                            Menu("More") {
                                Button("Force Stop…", role: .destructive) { confirmation = .force }
                                Button("Remove Project…", role: .destructive) { confirmation = .remove }
                            }
                            Spacer()
                            Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        }.disabled(model.busy || model.fatal)
                        Text(model.status).font(.caption).foregroundStyle(model.fatal ? .red : .primary).textSelection(.enabled)
                        Picker("Start / restart", selection: $model.launchMode) {
                            ForEach(LaunchMode.allCases, id: \.self) { Text($0.title).tag($0) }
                        }.font(.caption).disabled(model.busy)
                        Text(model.currentHealth?.message ?? "Checking health…").font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            Text("tmux: \(model.currentHealth?.tmuxHealthy == true ? "verified" : "unverified")")
                            Text("CLI: \(model.currentHealth?.agentHealthy == true ? "alive" : "unverified")")
                        }.font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    if let activity = model.activity {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(activity.kind.rawValue).font(.caption.bold())
                            Text(activity.detail).font(.caption).textSelection(.enabled)
                            Text(activity.evidence).font(.caption2).foregroundStyle(.secondary)
                            Text(activity.canSubmit(now: Date()) ? "Text submission readiness: verified idle lease; expires shortly" : "Text submission readiness: unverified — use Paste Only or Open Terminal")
                                .font(.caption2).foregroundStyle(activity.canSubmit(now: Date()) ? .green : .secondary)
                            if let question = activity.question {
                                Text(question).font(.caption).textSelection(.enabled)
                                TextEditor(text: $model.reply).font(.system(.body, design: .monospaced)).frame(height: 65).border(.quaternary)
                                HStack {
                                    Button("Paste Reply Only") { Task { await model.send(submit: false, isReply: true) } }.disabled(!model.canPaste || model.reply.isEmpty || activity.modal)
                                    Button("Send Reply & Submit") { Task { await model.send(submit: true, isReply: true) } }.disabled(!model.canSubmit || model.reply.isEmpty)
                                }
                                if activity.modal { Text("Structured question: use Open Terminal to answer in the CLI. Pasting or Enter here could select the wrong option.").font(.caption).foregroundStyle(.orange) }
                            }
                        }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                    }
                    Divider()
                    HStack {
                        Text(model.source).font(.caption).lineLimit(2)
                        Spacer()
                        Button("Clear") { model.text = "" }
                    }
                    TextEditor(text: $model.text).font(.system(.body, design: .monospaced)).frame(height: 130).border(.quaternary)
                    Text("\(model.text.utf8.count) / 65,536 bytes · Clipboard never changes the selected project").font(.caption2).foregroundStyle(.secondary)
                    Toggle("I checked the displayed destination and its input is ready", isOn: $model.ready).font(.caption).disabled(model.busy)
                    HStack {
                        Button("Paste Only") { Task { await model.send(submit: false) } }.disabled(!model.canPaste || model.text.isEmpty)
                        Button("Send & Submit") { Task { await model.send(submit: true) } }.disabled(!model.canSubmit || model.text.isEmpty)
                        Spacer()
                    }
                    Text("Submit needs a fresh verified idle signal. Stop events alone never authorize Enter. Approvals must be handled in the CLI.").font(.caption2).foregroundStyle(.secondary)
                    if model.showHistory {
                        Divider()
                        HStack { Text("Notification history").font(.headline); Spacer(); Button("Clear history") { Task { await model.clearHistory() } } }
                        ForEach(model.history.reversed()) { entry in
                            Button { model.selectedID = entry.projectID } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(entry.projectName) · \(entry.kind.rawValue)").font(.caption.bold())
                                    Text(entry.timestamp.formatted(date: .abbreviated, time: .standard) + " · " + entry.evidence).font(.caption2).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain)
                        }
                        if model.history.isEmpty { Text("No events yet.").font(.caption).foregroundStyle(.secondary) }
                    }
                    Divider()
                    HStack {
                        Text("CLI output").font(.headline)
                        Spacer()
                        Button("Refresh Output") { Task { await model.refreshOutput() } }.disabled(model.busy)
                        Button("Copy Output") { model.copyOutput() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!model.hasDisplayedOutput)
                    }
                    Picker("Output project", selection: $model.outputProjectID) {
                        Text("Follow selected destination").tag(Optional<UUID>.none)
                        ForEach(model.projects) { Text($0.name).tag(Optional($0.id)) }
                    }
                    ScrollView([.vertical, .horizontal]) {
                        Text(model.styledOutput)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }.frame(height: 210).background(Color.black).border(.quaternary)
                    if !model.outputError.isEmpty {
                        Text(model.outputError).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("All text retained by tmux for this pane; full-screen CLIs may replace earlier output. Copy Output copies this display verbatim, with no trimming or length limit. Paste into ChatGPT or Claude yourself.")
                        .font(.caption2).foregroundStyle(.secondary)
                }.padding(16)
            }
        }
        .frame(width: 560)
        .onChange(of: model.startOffer?.id) { _, id in
            if id != nil { confirmation = .startAndSend }
        }
        .onChange(of: model.outputProjectID) { _, _ in Task { await model.refreshOutput() } }
        .onChange(of: model.selectedID) { _, _ in Task { await model.refreshOutput() } }
        .sheet(item: $model.editing) { project in ProjectEditor(model: model, project: project) }
        .alert(item: $confirmation) { action in
            let project = model.current?.name ?? "project"
            let message: String
            switch action {
            case .stop: message = "Request shutdown of \(project)? This sends SIGTERM to its verified controller group and may interrupt active work. No force stop follows automatically."
            case .restart: message = "Restart \(project) with \(model.launchMode.title.lowercased())? Shutdown may interrupt active work. Restart proceeds only after the previous CLI exits."
            case .force: message = "Force-stop \(project)? This sends SIGKILL to its verified controller group. Active work may be lost."
            case .remove: message = "Remove \(project) and its settings? Live agents must be stopped first. Repository files remain unchanged."
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
        VStack(alignment: .leading, spacing: 12) {
            Text("Project settings").font(.headline)
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
            Toggle("Notifications for this project", isOn: $project.notifications.enabled)
            HStack {
                Toggle("Turn / task events", isOn: $project.notifications.turnFinished)
                Toggle("Attention", isOn: $project.notifications.needsAttention)
                Toggle("Unexpected exit", isOn: $project.notifications.unexpectedExit)
            }.font(.caption)
            HStack {
                Button("Allow macOS Notifications…") { Task { await model.enableNotifications() } }
                Button("Test Notification") { Task { await model.testNotification(for: project) } }
            }
            Text("Save to apply notification preferences, including to running sessions. macOS permission applies to all projects. The test checks delivery only; it does not attach agent hooks.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Hook settings apply only to AgentRouter launches. Existing CLI configuration is not overwritten. Codex may require hook trust review through Open Terminal → /hooks.").font(.caption).foregroundStyle(.secondary)
            Text(model.status).font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { model.editing = nil }
                Button("Save") { Task { await model.save(project) } }.disabled(model.busy)
            }
        }.padding(20).frame(width: 540)
    }
}
