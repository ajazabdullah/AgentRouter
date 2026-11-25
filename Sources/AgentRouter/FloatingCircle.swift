import AppKit

@MainActor
private final class CirclePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class FloatingCircleController {
    private let panel: CirclePanel
    init(onToggle: @escaping () -> Void) {
        panel = CirclePanel(contentRect: NSRect(x: 0, y: 0, width: 56, height: 56),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let view = CircleView(frame: NSRect(x: 0, y: 0, width: 56, height: 56))
        view.onToggle = onToggle
        panel.contentView = view
        restorePosition()
    }
    func setVisible(_ visible: Bool) {
        if visible { clampPosition(); panel.orderFrontRegardless() }
        else { panel.orderOut(nil) }
    }
    private func restorePosition() {
        let defaults = UserDefaults.standard
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let point: NSPoint
        if defaults.object(forKey: "floatingCircleX") != nil && defaults.object(forKey: "floatingCircleY") != nil {
            point = NSPoint(x: defaults.double(forKey: "floatingCircleX"), y: defaults.double(forKey: "floatingCircleY"))
        } else { point = NSPoint(x: screen.maxX - 80, y: screen.minY + 80) }
        panel.setFrameOrigin(point)
        clampPosition()
    }
    private func clampPosition() {
        let current = panel.frame
        guard let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(NSPoint(x: current.midX, y: current.midY)) }) ?? NSScreen.main else { return }
        panel.setFrameOrigin(CircleView.clamp(current.origin, size: current.size, to: screen.visibleFrame))
    }
}

@MainActor
private final class CircleView: NSView {
    var onToggle: (() -> Void)?
    private var mouseStart = NSPoint.zero
    private var windowStart = NSPoint.zero
    private var dragged = false
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Show or hide AgentRouter")
        toolTip = "Click to show/hide AgentRouter. Drag to move."
    }
    required init?(coder: NSCoder) { fatalError("Not implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityPerformPress() -> Bool { onToggle?(); return true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 3, dy: 3)).fill()
        let text = NSAttributedString(string: "AR", attributes: [.font: NSFont.systemFont(ofSize: 17, weight: .semibold), .foregroundColor: NSColor.white])
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
    override func mouseDown(with event: NSEvent) {
        mouseStart = NSEvent.mouseLocation
        windowStart = window?.frame.origin ?? .zero
        dragged = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let now = NSEvent.mouseLocation
        let delta = NSPoint(x: now.x - mouseStart.x, y: now.y - mouseStart.y)
        guard dragged || hypot(delta.x, delta.y) > 4 else { return }
        dragged = true
        let point = NSPoint(x: windowStart.x + delta.x, y: windowStart.y + delta.y)
        let screen = NSScreen.screens.first { $0.frame.contains(now) } ?? window.screen ?? NSScreen.main
        window.setFrameOrigin(screen.map { Self.clamp(point, size: window.frame.size, to: $0.visibleFrame) } ?? point)
    }
    override func mouseUp(with event: NSEvent) {
        if dragged, let origin = window?.frame.origin {
            UserDefaults.standard.set(origin.x, forKey: "floatingCircleX")
            UserDefaults.standard.set(origin.y, forKey: "floatingCircleY")
        } else { onToggle?() }
    }
    static func clamp(_ point: NSPoint, size: NSSize, to frame: NSRect) -> NSPoint {
        NSPoint(x: min(max(point.x, frame.minX), frame.maxX - size.width),
                y: min(max(point.y, frame.minY), frame.maxY - size.height))
    }
}
