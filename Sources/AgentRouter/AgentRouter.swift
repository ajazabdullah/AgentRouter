import AppKit
import SwiftUI
import RouterCore
import Combine

@main
struct AgentRouterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene { Settings { EmptyView() } }
}
@MainActor
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
@MainActor
final class WidgetHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private var panel: FloatingPanel!
    private var model: RouterModel!
    private var quitCoordinator: QuitCoordinator?
    private var quitApproved = false
    private var indicator: Task<Void, Never>?
    private var activeProjectItem: NSStatusItem?
    private var activeProjectSubscription: AnyCancellable?
    private var globalShortcuts: GlobalShortcuts?
    private var functionKeysSubscription: AnyCancellable?
    private var functionKeyProjects: [String: String] = UserDefaults.standard.dictionary(forKey: "cliFunctionKeyProjects") as? [String: String] ?? [:]
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        model = RouterModel()
        quitCoordinator = QuitCoordinator(model: model) { [weak self] in
            self?.quitApproved = true
            NSApp.terminate(nil)
        }
        item = NSStatusBar.system.statusItem(withLength: 36)
        // A fresh stable identity avoids restoring the old item's hidden/overflow placement.
        item.autosaveName = "AgentRouter.MainUtility"
        item.behavior = []
        item.isVisible = true
        item.button?.title = "AR"
        item.button?.font = .systemFont(ofSize: 12, weight: .semibold)
        item.button?.toolTip = "AgentRouter — Show/Hide widget; ⌥⌘R opens it from any application"
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 760), styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "AgentRouter"
        panel.delegate = self
        panel.isFloatingPanel = true; panel.level = .floating
        panel.hidesOnDeactivate = false; panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = WidgetHostingView(rootView: RouterWidget(model: model))
        model.onCapture = { [weak self] in
            guard let self else { return }
            if self.model.showWidgetOnCopy { self.show() }
            else { self.showClipboardIndicator() }
        }
        model.onHide = { [weak self] in self?.hide() }
        do {
            globalShortcuts = try GlobalShortcuts { [weak self] id in self?.handleGlobalShortcut(id) }
            functionKeysSubscription = model.$cliFunctionKeysEnabled
                .receive(on: RunLoop.main)
                .sink { [weak self] enabled in
                    do { try self?.globalShortcuts?.setCLIKeysEnabled(enabled) }
                    catch { self?.model.status = error.localizedDescription }
                }
        } catch { model.status = error.localizedDescription }
        activeProjectSubscription = model.$projects
            .combineLatest(model.$health, model.$busy, model.$selectedID)
            .receive(on: RunLoop.main)
            .sink { [weak self] projects, health, busy, selectedID in
                self?.updateActiveProjectItem(projects, health: health, busy: busy, selectedID: selectedID)
            }
        model.notifications.onSelect = { [weak self] id in
            guard let self else { return }
            if self.model.quitReviewActive { self.quitCoordinator?.present(); return }
            guard self.model.projects.contains(where: { $0.id == id }) else {
                self.model.status = "This notification belongs to a removed project."; self.show(); return
            }
            self.model.selectedID = id
            self.model.showHistory = false
            guard !self.model.busy else {
                self.model.status = "AgentRouter is busy. Wait for the current operation, then use Open Terminal for the selected project."
                self.show(); return
            }
            Task { [weak self] in
                guard let self else { return }
                let opened = await self.model.openProject(id)
                if opened { self.hide() }
                else { self.show() }
            }
        }
        revealForLaunch()
    }
    private func updateActiveProjectItem(_ projects: [Project], health: [UUID: ProjectHealth], busy: Bool, selectedID: UUID?) {
        item.isVisible = true
        if functionKeyProjects.isEmpty && !projects.isEmpty {
            for (index, project) in model.projectGroups.prefix(3).enumerated() {
                functionKeyProjects[String(index + 1)] = project.id.uuidString
            }
            UserDefaults.standard.set(functionKeyProjects, forKey: "cliFunctionKeyProjects")
        }
        guard let project = projects.first(where: { $0.id == selectedID }),
              let state = health[project.id], state.state == .running,
              state.agentHealthy, state.tmuxHealthy else {
            // Never leave the previous project's name visible after selecting a stopped one.
            if let existing = activeProjectItem { NSStatusBar.system.removeStatusItem(existing) }
            activeProjectItem = nil
            return
        }
        let statusItem: NSStatusItem
        if let existing = activeProjectItem { statusItem = existing }
        else {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItem.autosaveName = "AgentRouter.ActiveProject"
            activeProjectItem = statusItem
        }
        statusItem.isVisible = true
        guard let button = statusItem.button else { return }
        let group = model.projectGroups.first { $0.id == model.groupID(for: project.id) }
        let suffix = model.cliInstances.first { $0.id == project.id }?.name.split(separator: " ").last.map { " ·" + $0 } ?? ""
        button.title = compactProjectTitle(group?.name ?? project.name) + suffix
        button.font = .systemFont(ofSize: 12, weight: .bold)
        button.target = self
        button.action = #selector(openProjectFromMenuBar(_:))
        button.identifier = NSUserInterfaceItemIdentifier(project.id.uuidString)
        button.isEnabled = !busy && !model.fatal && !model.quitReviewActive
        button.toolTip = "Active: \(project.name) · \(project.cli.title) — open existing CLI tab"
        button.setAccessibilityLabel("Active project \(project.name); open CLI")
    }
    private func compactProjectTitle(_ name: String) -> String {
        name.count > 10 ? String(name.prefix(10)) + "…" : name
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let showItem = NSMenuItem(title: "Show AgentRouter", action: #selector(showFromMenu), keyEquivalent: "r")
        showItem.keyEquivalentModifierMask = [.command, .option]
        showItem.target = self
        showItem.isEnabled = !model.quitReviewActive
        menu.addItem(showItem)
        let hideItem = NSMenuItem(title: "Hide AgentRouter", action: #selector(hideFromMenu), keyEquivalent: "")
        hideItem.target = self
        hideItem.isEnabled = panel.isVisible && !model.quitReviewActive
        menu.addItem(hideItem)
        menu.addItem(.separator())
        for project in model.projectGroups {
            let groupItem = NSMenuItem(title: project.name, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: project.name)
            submenu.autoenablesItems = false
            for cli in model.controllers(in: project.id) {
                let state = model.health[cli.id]?.state.rawValue.capitalized ?? "Checking"
                let entry = NSMenuItem(title: model.cliTitle(cli.id) + " — " + state, action: #selector(openProjectFromMenu(_:)), keyEquivalent: "")
                entry.representedObject = cli.id.uuidString; entry.target = self
                entry.state = cli.id == model.selectedID ? .on : .off
                entry.isEnabled = !model.busy && !model.fatal && !model.quitReviewActive
                submenu.addItem(entry)
            }
            submenu.addItem(.separator())
            for cli in CLIKind.allCases {
                let entry = NSMenuItem(title: "Start new \(cli.title) CLI", action: #selector(startNewCLIFromMenu(_:)), keyEquivalent: "")
                entry.representedObject = project.id.uuidString + "|" + cli.rawValue
                entry.target = self; entry.isEnabled = !model.busy && !model.fatal && !model.quitReviewActive
                submenu.addItem(entry)
            }
            groupItem.submenu = submenu
            menu.addItem(groupItem)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit AgentRouter", action: #selector(quitFromMenu), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
    }
    private func handleGlobalShortcut(_ id: UInt32) {
        if model.quitReviewActive { quitCoordinator?.present(); return }
        if id == 0 { revealForLaunch(); return }
        guard let value = functionKeyProjects[String(id)], let projectID = UUID(uuidString: value),
              model.projectGroups.contains(where: { $0.id == projectID }) else {
            model.status = "No project is assigned to F\(id + 6)."
            revealForLaunch()
            return
        }
        openProject(projectID, rememberProject: true)
    }
    @objc private func startNewCLIFromMenu(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        let fields = value.split(separator: "|")
        guard fields.count == 2, let project = UUID(uuidString: String(fields[0])), let cli = CLIKind(rawValue: String(fields[1])) else { return }
        Task { [weak self] in
            guard let self else { return }
            if !(await self.model.newCLI(cli, projectID: project)) { self.show() }
        }
    }
    @objc private func showFromMenu() { revealForLaunch() }
    @objc private func hideFromMenu() { hide() }
    @objc private func quitFromMenu() { NSApp.terminate(nil) }
    @objc private func openProjectFromMenu(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let id = UUID(uuidString: value) else { return }
        openProject(id)
    }
    @objc private func openProjectFromMenuBar(_ sender: NSButton) {
        guard let value = sender.identifier?.rawValue, let id = UUID(uuidString: value) else { return }
        openProject(id)
    }
    private func openProject(_ id: UUID, rememberProject: Bool = false) {
        guard !model.quitReviewActive else { quitCoordinator?.present(); return }
        Task { [weak self] in
            guard let self else { return }
            let opened: Bool
            if rememberProject { opened = await self.model.selectProjectAndOpenCLI(id) }
            else { opened = await self.model.selectCLIAndOpen(id) }
            // A stopped agent or Terminal permission error should be visible, not silent.
            if !opened { self.show() }
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if model?.quitReviewActive == true { quitCoordinator?.present(); return true }
        if panel != nil { revealForLaunch() }; return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitApproved || model == nil { return .terminateNow }
        if model.quitReviewActive || model.needsQuitReview {
            quitCoordinator?.present()
            return .terminateCancel
        }
        return .terminateNow
    }
    private func revealForLaunch() { panel.center(); show() }
    private func hide() {
        guard !model.quitReviewActive else { return }
        item.isVisible = true
        panel.orderOut(nil)
        model.widgetWasVisible = false
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { hide(); return false }
    private func showClipboardIndicator() {
        guard !panel.isVisible else { return }
        indicator?.cancel()
        item.button?.title = "AR •"
        item.button?.toolTip = "AgentRouter — clipboard captured; Show AgentRouter or press ⌥⌘R to review"
        indicator = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            self?.item.button?.title = "AR"
            self?.item.button?.toolTip = "AgentRouter — Show/Hide widget; ⌥⌘R opens it from any application"
        }
    }
    private func show() {
        guard !model.quitReviewActive else { quitCoordinator?.present(); return }
        if !panel.isVisible { panel.center() }
        indicator?.cancel()
        item.button?.title = "AR"
        panel.orderFrontRegardless()
        model.widgetWasVisible = true
    }
    @objc private func toggle() { if panel.isVisible { hide() } else { show() } }
}
