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
    private var indicator: Task<Void, Never>?
    private var activeProjectItem: NSStatusItem?
    private var activeProjectSubscription: AnyCancellable?
    private var globalShortcuts: GlobalShortcuts?
    private var functionKeysSubscription: AnyCancellable?
    private var functionKeyProjects: [String: String] = UserDefaults.standard.dictionary(forKey: "cliFunctionKeyProjects") as? [String: String] ?? [:]
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        model = RouterModel()
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
        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 760), styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
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
            guard self.model.projects.contains(where: { $0.id == id }) else {
                self.model.status = "This notification belongs to a removed project."; self.show(); return
            }
            self.model.selectedID = id; self.model.showHistory = false; self.show()
        }
        revealForLaunch()
    }
    private func updateActiveProjectItem(_ projects: [Project], health: [UUID: ProjectHealth], busy: Bool, selectedID: UUID?) {
        item.isVisible = true
        if functionKeyProjects.isEmpty && !projects.isEmpty {
            for (index, project) in projects.prefix(3).enumerated() {
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
        button.title = compactProjectTitle(project.name)
        button.font = .systemFont(ofSize: 12, weight: .bold)
        button.target = self
        button.action = #selector(openProjectFromMenuBar(_:))
        button.identifier = NSUserInterfaceItemIdentifier(project.id.uuidString)
        button.isEnabled = !busy && !model.fatal
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
        menu.addItem(showItem)
        let hideItem = NSMenuItem(title: "Hide AgentRouter", action: #selector(hideFromMenu), keyEquivalent: "")
        hideItem.target = self
        hideItem.isEnabled = panel.isVisible
        menu.addItem(hideItem)
        menu.addItem(.separator())
        for project in model.projects {
            guard model.health[project.id]?.state == .running else { continue }
            let projectItem = NSMenuItem(title: project.name, action: #selector(openProjectFromMenu(_:)), keyEquivalent: "")
            projectItem.representedObject = project.id.uuidString
            projectItem.state = project.id == model.selectedID ? .on : .off
            projectItem.target = self
            projectItem.isEnabled = !model.busy && !model.fatal
            menu.addItem(projectItem)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit AgentRouter", action: #selector(quitFromMenu), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
    }
    private func handleGlobalShortcut(_ id: UInt32) {
        if id == 0 { revealForLaunch(); return }
        guard let value = functionKeyProjects[String(id)], let projectID = UUID(uuidString: value),
              model.projects.contains(where: { $0.id == projectID }) else {
            model.status = "No project is assigned to F\(id + 6)."
            revealForLaunch()
            return
        }
        openProject(projectID)
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
    private func openProject(_ id: UUID) {
        Task { [weak self] in
            guard let self else { return }
            let opened = await self.model.selectProjectAndOpenCLI(id)
            // A stopped agent or Terminal permission error should be visible, not silent.
            if !opened { self.show() }
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if panel != nil { revealForLaunch() }; return true
    }
    private func revealForLaunch() { panel.center(); show() }
    private func hide() {
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
        if !panel.isVisible { panel.center() }
        indicator?.cancel()
        item.button?.title = "AR"
        panel.orderFrontRegardless()
        model.widgetWasVisible = true
    }
    @objc private func toggle() { if panel.isVisible { hide() } else { show() } }
}
