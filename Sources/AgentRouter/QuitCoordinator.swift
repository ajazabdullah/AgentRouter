import AppKit
import SwiftUI
import UniformTypeIdentifiers
import RouterCore

@MainActor
final class QuitCoordinator: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var exporting = false
    @Published private(set) var exportStatus = ""
    @Published private(set) var stopping = false
    @Published private(set) var pendingStopTargets: [QuitStopTarget] = []
    private var window: NSPanel?
    private let model: RouterModel
    private let approve: () -> Void

    init(model: RouterModel, approve: @escaping () -> Void) {
        self.model = model; self.approve = approve
    }

    func present() {
        if let window { window.makeKeyAndOrderFront(nil); return }
        model.quitReviewActive = true
        exportStatus = ""
        pendingStopTargets = []
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 580),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Before quitting AgentRouter"
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: QuitReviewView(model: model, coordinator: self))
        window = panel
        panel.center(); panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func cancel() {
        guard !exporting, !stopping else { return }
        model.quitReviewActive = false
        window?.orderOut(nil); window = nil
        // The widget was never hidden or revealed by this review.
    }

    func quit() {
        guard !model.busy, !exporting, !stopping else { return }
        approve()
    }

    func stopAndQuit(force: Bool = false) {
        guard !model.busy, !exporting, !stopping, let window else { return }
        stopping = true
        Task { @MainActor in
            do {
                let targets: [QuitStopTarget]
                if force {
                    let live = try await model.prepareQuitShutdown()
                    targets = live.filter { current in pendingStopTargets.contains { $0.id == current.id && $0.runID == current.runID && $0.paneID == current.paneID } }
                    guard !targets.isEmpty else {
                        stopping = false; pendingStopTargets = []
                        exportStatus = "No previously confirmed CLI runs remain eligible for force stop. Use Stop Agents & Quit to review current runs."
                        return
                    }
                }
                else { targets = try await model.prepareQuitShutdown() }
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = force ? "Force-stop agents and quit?" : "Stop agents and quit?"
                let names = targets.map(\.name).joined(separator: "\n")
                alert.informativeText = (force
                    ? "Force-stop the previously confirmed CLI runs that remain alive? Unsaved work may be lost. Restarted or unverified agents will not be targeted."
                    : "Request graceful shutdown of all verified AgentRouter CLI runs below? This may interrupt active work and does not automatically save files or write a handoff. Export a checkpoint first if needed.")
                    + "\n\n" + (names.isEmpty ? "No live managed CLI runs detected." : names)
                    + "\n\nAgentRouter quits only after every configured CLI is verified stopped. Unsent drafts will be discarded. Terminal windows stay open."
                alert.addButton(withTitle: "Cancel")
                alert.addButton(withTitle: force ? "Force Stop & Quit" : "Stop Agents & Quit")
                alert.beginSheetModal(for: window) { [weak self] response in
                    Task { @MainActor in
                        guard let self else { return }
                        guard response == .alertSecondButtonReturn else { self.stopping = false; return }
                        self.exportStatus = force ? "Force-stop requested; waiting for verified exit…" : "Graceful shutdown requested; waiting for verified exit…"
                        let result = await self.model.stopAgentsForQuit(targets, force: force)
                        self.stopping = false
                        if result.stopped { self.approve() }
                        else { self.pendingStopTargets = result.remaining; self.exportStatus = result.message }
                    }
                }
            } catch {
                stopping = false
                exportStatus = "No shutdown was started: \(error.localizedDescription)\nAgentRouter remains open."
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { cancel(); return false }

    func exportCheckpoint() {
        guard !model.busy, !exporting, !stopping, let window else { return }
        exporting = true
        let save = NSSavePanel()
        save.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        save.nameFieldStringValue = "AgentRouter-checkpoint-" + Date().ISO8601Format().replacingOccurrences(of: ":", with: "-") + ".md"
        save.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        save.message = "Export completed replies and CLI identities. Review replies for sensitive content before sharing. Drafts are excluded."
        save.beginSheetModal(for: window) { [weak self] response in
            Task { @MainActor in
                guard let self else { return }
                defer { self.exporting = false }
                guard response == .OK, let url = save.url else { return }
                do {
                    let capturedAt = Date()
                    let entries = try await self.model.checkpointEntries()
                    try await Task.detached {
                        try CheckpointExport.write(CheckpointExport.markdown(entries: entries, capturedAt: capturedAt), to: url)
                    }.value
                    let missing = entries.filter { $0.reply == nil }.count
                    self.exportStatus = "Saved: \(url.path)\n\(entries.count) CLIs; \(missing) replies unavailable. AgentRouter is still running."
                } catch { self.exportStatus = "Export failed: \(error.localizedDescription)\nAgentRouter remains open." }
            }
        }
    }
}

private struct QuitReviewView: View {
    @ObservedObject var model: RouterModel
    @ObservedObject var coordinator: QuitCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Quit AgentRouter").font(.system(size: 24, weight: .bold))
            Text("Keep CLI sessions running, or stop them before quitting. Monitoring and notifications stop when AgentRouter exits. Terminal windows stay open.")
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.projects) { project in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(project.name + " · " + project.cli.title).bold()
                            Text("Process: \(model.health[project.id]?.state.rawValue ?? "unverified") · Activity: \(model.activities[project.id]?.kind.rawValue ?? "UNKNOWN")").font(.system(size: 15))
                        }
                    }
                    ForEach(model.quitWarnings, id: \.self) { warning in Text(warning).foregroundStyle(.orange) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("A running process does not prove the agent is working. A checkpoint contains available completed replies, not an agent-written handoff or guaranteed saved work.").font(.system(size: 15))
            Text("Session survival is not guaranteed during macOS logout, shutdown, or force quit.").font(.system(size: 15))
            if !coordinator.exportStatus.isEmpty {
                Text(coordinator.exportStatus).font(.system(size: 15)).textSelection(.enabled)
            }
            HStack {
                Button("Cancel") { coordinator.cancel() }.keyboardShortcut(.defaultAction).disabled(coordinator.exporting || coordinator.stopping)
                Spacer()
                Button(coordinator.exporting ? "Exporting…" : "Export Checkpoint…") { coordinator.exportCheckpoint() }
                    .disabled(model.busy || coordinator.exporting || coordinator.stopping)
            }
            if !coordinator.pendingStopTargets.isEmpty {
                Button("Force Stop Remaining…") { coordinator.stopAndQuit(force: true) }
                    .foregroundStyle(.red).disabled(model.busy || coordinator.exporting || coordinator.stopping)
            }
            HStack {
                Button("Keep Running & Quit") { coordinator.quit() }
                Spacer()
                Button(coordinator.stopping ? "Stopping…" : "Stop Agents & Quit…") { coordinator.stopAndQuit() }
            }.disabled(model.busy || coordinator.exporting || coordinator.stopping)
        }.padding(20).font(.system(size: 16)).frame(width: 600, height: 540)
    }
}
