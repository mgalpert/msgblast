import AppKit
import SwiftUI
import msgblastCore

final class ComposerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class WindowCoordinator: NSObject, NSWindowDelegate, NSToolbarDelegate {
    unowned let model: AppModel
    private var windows: [String: NSWindow] = [:]
    private var placing = false
    private var closingAll = false

    init(model: AppModel) { self.model = model }

    func closeAll(keepingReports: Bool = false) {
        guard !windows.isEmpty else { return }
        closingAll = true
        Array(windows.values).filter { !keepingReports || $0.identifier?.rawValue.hasSuffix(":report") != true }.forEach { $0.close() }
        closingAll = false
        model.persist()
    }

    func reopenComparisons() {
        let previousKeyWindow = NSApp.keyWindow
        let openIDs = model.state.comparisons.filter { comparison in
            windows.keys.contains { $0.hasPrefix(comparison.id.uuidString + ":") && !$0.hasSuffix(":report") }
        }.map(\.id)
        closeAll(keepingReports: true)
        for id in openIDs { open(id) }
        if previousKeyWindow?.isVisible == true { previousKeyWindow?.makeKeyAndOrderFront(nil) }
    }

    private func key(_ comparison: UUID, _ member: UUID) -> String {
        comparison.uuidString + ":" + member.uuidString
    }

    private func configureChrome(_ window: NSWindow) {
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.delegate = self
        for button: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = false
        }
    }

    private func restore(_ window: NSWindow, frame: SavedFrame, screen: NSRect) {
        // Persisted frames are outer window frames, not content rectangles.
        window.setFrame(NSRect(x: screen.minX + frame.x, y: screen.minY + frame.y, width: frame.width, height: frame.height), display: false)
    }

    private func addSummaryToolbar(to window: NSWindow, comparisonID: UUID) {
        let toolbar = NSToolbar(identifier: "summarize:" + comparisonID.uuidString)
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, NSToolbarItem.Identifier("summarize")]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard identifier.rawValue == "summarize" else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "Summarize"
        let button = NSButton(title: "Summarize", target: self, action: #selector(summarizeFromToolbar(_:)))
        button.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.bezelStyle = .texturedRounded
        button.identifier = NSUserInterfaceItemIdentifier(String(toolbar.identifier.dropFirst("summarize:".count)))
        button.toolTip = "Generate a comparison report and best next action with your personal agent"
        button.setAccessibilityLabel("Summarize")
        item.view = button
        return item
    }

    @objc private func summarizeFromToolbar(_ button: NSButton) {
        guard let value = button.identifier?.rawValue, let id = UUID(uuidString: value) else { return }
        openReport(id)
        Task { await model.personalAgent.requestReport(id, model: model) }
    }

    private func openReport(_ id: UUID) {
        guard let comparison = model.comparison(id) else { return }
        let windowKey = id.uuidString + ":report"
        if windows[windowKey] == nil {
            placing = true
            defer { placing = false }
            let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Comparison report · \(comparison.title)" + (model.demo ? " [Demo]" : "")
            window.identifier = NSUserInterfaceItemIdentifier(windowKey)
            window.contentView = NSHostingView(rootView: ComparisonReportView(model: model, agent: model.personalAgent, comparisonID: id))
            configureChrome(window)
            window.tabbingMode = .disallowed
            window.minSize = NSSize(width: 660, height: 620)
            let width = min(820, screen.width - 40), height = min(820, screen.height - 60)
            restore(window, frame: model.state.frames[windowKey] ?? SavedFrame(x: (screen.width - width) / 2, y: (screen.height - height) / 2, width: width, height: height), screen: screen)
            windows[windowKey] = window
        }
        windows[windowKey]?.makeKeyAndOrderFront(nil)
    }

    func open(_ id: UUID) {
        if model.comparison(id)?.webProviders?.isEmpty == false {
            model.openWebComparison(id)
            NSApp.activate()
            return
        }
        guard let comparison = model.comparison(id) else { return }
        if model.state.effectiveWindowStyle == .connected {
            openConnected(comparison)
            return
        }
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frames = WindowLayout.columns(count: comparison.members.count, screenWidth: screen.width, screenHeight: screen.height)
        placing = true
        for (offset, member) in comparison.members.enumerated() {
            let windowKey = key(id, member.id)
            if windows[windowKey] == nil {
                let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
                window.title = "\(member.name) · \(comparison.title)"
                window.identifier = NSUserInterfaceItemIdentifier(windowKey)
                window.contentView = NSHostingView(rootView: ConversationView(model: model, comparisonID: id, memberID: member.id))
                configureChrome(window)
                addSummaryToolbar(to: window, comparisonID: id)
                window.titleVisibility = .hidden
                window.minSize = NSSize(width: 320, height: 400)
                restore(window, frame: model.state.frames[windowKey] ?? frames[offset], screen: screen)
                windows[windowKey] = window
            }
            if let window = windows[windowKey], offset == 0 || window.frame.maxX <= screen.maxX { window.orderFront(nil) }
        }
        let composerKey = id.uuidString + ":all"
        if windows[composerKey] == nil {
            let panel = ComposerPanel(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            panel.title = comparison.title + (model.demo ? " [Demo]" : "")
            panel.identifier = NSUserInterfaceItemIdentifier(composerKey)
            panel.contentView = NSHostingView(rootView: FloatingComposer(model: model, comparisonID: id))
            configureChrome(panel)
            addSummaryToolbar(to: panel, comparisonID: id)
            panel.minSize = NSSize(width: 470, height: 170)
            panel.level = .floating
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            restore(panel, frame: model.state.frames[composerKey] ?? SavedFrame(x: 40, y: 30, width: 520, height: 190), screen: screen)
            windows[composerKey] = panel
        }
        placing = false
        windows[composerKey]?.makeKeyAndOrderFront(nil)
    }

    private func openConnected(_ comparison: Comparison) {
        let windowKey = comparison.id.uuidString + ":connected"
        if windows[windowKey] == nil {
            placing = true
            defer { placing = false }
            let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = comparison.title + (model.demo ? " [Demo]" : "")
            window.identifier = NSUserInterfaceItemIdentifier(windowKey)
            window.contentView = NSHostingView(rootView: ComparisonWorkspace(model: model, comparisonID: comparison.id))
            configureChrome(window)
            addSummaryToolbar(to: window, comparisonID: comparison.id)
            window.minSize = NSSize(width: 640, height: 500)
            let width = min(screen.width - 40, max(800, Double(comparison.members.count) * 390))
            let height = min(screen.height - 60, 760)
            restore(window, frame: model.state.frames[windowKey] ?? SavedFrame(x: (screen.width - width) / 2, y: (screen.height - height) / 2, width: width, height: height), screen: screen)
            windows[windowKey] = window
        }
        windows[windowKey]?.makeKeyAndOrderFront(nil)
    }

    func tile(_ id: UUID) {
        guard let comparison = model.comparison(id) else { return }
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let frames = WindowLayout.columns(count: comparison.members.count, screenWidth: screen.width, screenHeight: screen.height)
        placing = true
        for (offset, member) in comparison.members.enumerated() {
            guard let window = windows[key(id, member.id)] else { continue }
            let frame = frames[offset]
            restore(window, frame: frame, screen: screen)
            if frame.x + frame.width <= screen.width { window.orderFront(nil) } else { window.orderOut(nil) }
            record(window)
        }
        placing = false
        model.persist()
    }
    func fitComposer(_ id: UUID, hasAttachments: Bool) {
        guard let panel = windows[id.uuidString + ":all"] else { return }
        let height: CGFloat = hasAttachments ? 280 : 170
        panel.minSize = NSSize(width: 470, height: height)
        if panel.frame.height < height {
            var frame = panel.frame
            frame.size.height = height
            panel.setFrame(frame, display: true)
        }
    }

    func focus(_ id: UUID, memberID: UUID) {
        if windows[key(id, memberID)] == nil { open(id) }
        guard let window = windows[key(id, memberID)] else { return }
        let screen = NSScreen.main?.visibleFrame ?? .zero
        if !screen.contains(window.frame) {
            window.setFrameOrigin(NSPoint(x: screen.maxX - window.frame.width - 20, y: screen.minY + 320))
        }
        window.makeKeyAndOrderFront(nil)
    }

    func windowDidMove(_ notification: Notification) { recordChange(notification) }
    func windowDidResize(_ notification: Notification) { recordChange(notification) }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let id = window.identifier?.rawValue else { return }
        record(window)
        windows.removeValue(forKey: id)
        if !closingAll { model.persist() }
    }
    private func recordChange(_ notification: Notification) {
        if !placing, let window = notification.object as? NSWindow { record(window); model.persist() }
    }
    private func record(_ window: NSWindow) {
        guard let id = window.identifier?.rawValue else { return }
        let screen = NSScreen.main?.visibleFrame ?? .zero
        model.state.frames[id] = SavedFrame(x: window.frame.minX - screen.minX, y: window.frame.minY - screen.minY, width: window.frame.width, height: window.frame.height)
    }
}
