import AppKit

final class SelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class SelectionView: NSView {
    let screen: NSScreen
    var completed: ((NSScreen, CGRect?) -> Void)?
    private var anchor: NSPoint?
    private var selection = CGRect.zero
    override var acceptsFirstResponder: Bool { true }
    init(screen: NSScreen) {
        self.screen = screen
        super.init(frame: CGRect(origin: .zero, size: screen.frame.size))
    }
    required init?(coder: NSCoder) { fatalError() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func mouseDown(with event: NSEvent) {
        anchor = convert(event.locationInWindow, from: nil)
        selection = .zero
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let anchor else { return }
        let p = convert(event.locationInWindow, from: nil)
        selection = CGRect(x: min(anchor.x, p.x), y: min(anchor.y, p.y), width: abs(p.x - anchor.x), height: abs(p.y - anchor.y)).intersection(bounds)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        guard selection.width >= 8, selection.height >= 8 else { anchor = nil; needsDisplay = true; return }
        completed?(screen, selection)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { completed?(screen, nil) }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.28).setFill()
        let dim = NSBezierPath(rect: bounds)
        if !selection.isEmpty { dim.appendRect(selection); dim.windingRule = .evenOdd }
        dim.fill()
        if !selection.isEmpty {
            NSColor.systemBlue.setStroke()
            let border = NSBezierPath(rect: selection); border.lineWidth = 2; border.stroke()
        }
        let text = selection.isEmpty ? "Przeciągnij, aby wybrać fragment · Escape anuluje" : "\(Int(selection.width)) × \(Int(selection.height)) pkt · Puść, aby nagrywać · Escape anuluje"
        let style = NSMutableParagraphStyle(); style.alignment = .center
        text.draw(in: CGRect(x: 20, y: bounds.height - 90, width: bounds.width - 40, height: 50), withAttributes: [
            .font: NSFont.systemFont(ofSize: 20, weight: .semibold), .foregroundColor: NSColor.white, .paragraphStyle: style])
    }
}

final class RegionSelector {
    private var panels: [NSPanel] = []
    private var eventMonitor: Any?
    private var completion: ((NSScreen, CGRect?) -> Void)?
    func begin(completion: @escaping (NSScreen, CGRect?) -> Void) {
        self.completion = completion
        NSApp.activate(ignoringOtherApps: true)
        for screen in NSScreen.screens {
            let panel = SelectionPanel(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            panel.isOpaque = false; panel.backgroundColor = .clear
            panel.level = .screenSaver; panel.hasShadow = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = SelectionView(screen: screen)
            view.completed = { [weak self] screen, rect in self?.finish(screen: screen, rect: rect) }
            panel.contentView = view
            panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(view)
            panels.append(panel)
        }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53, let screen = NSScreen.main {
                self?.finish(screen: screen, rect: nil); return nil
            }
            return event
        }
    }
    func cancel() { if let screen = NSScreen.main { finish(screen: screen, rect: nil) } }
    private func finish(screen: NSScreen, rect: CGRect?) {
        let callback = completion; completion = nil
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }; eventMonitor = nil
        for panel in panels { panel.orderOut(nil) }; panels.removeAll()
        callback?(screen, rect)
    }
}
