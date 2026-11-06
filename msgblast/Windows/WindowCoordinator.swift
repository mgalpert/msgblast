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
    var workspaceWindow: NSWindow?
    var workspaceComparisonID: UUID?
    private var confirming: Set<ObjectIdentifier> = []

    @discardableResult
    func reopenWorkspace() -> Bool {
        guard let workspaceWindow else { return false }
        if workspaceWindow.isMiniaturized { workspaceWindow.deminiaturize(nil) }
        workspaceWindow.makeKeyAndOrderFront(nil)
        return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !closingAll, let value = sender.identifier?.rawValue,
              !value.hasSuffix(":report"), let id = UUID(uuidString: String(value.prefix(36))) else { return true }
        return confirmClose(sender, comparisonID: id)
    }

    func confirmClose(_ window: NSWindow, comparisonID: UUID) -> Bool {
        guard let comparison = model.comparison(comparisonID), comparison.endedAt == nil else { return true }
        let key = ObjectIdentifier(window)
        guard confirming.insert(key).inserted else { return false }
        let alert = NSAlert()
        alert.messageText = "End this conversation?"
        alert.informativeText = "Keep the history and stop adding future replies to this conversation."
        alert.addButton(withTitle: "End and Close")
        alert.addButton(withTitle: "Keep Active and Close")
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = "\u{1b}"
        alert.beginSheetModal(for: window) { [weak self, weak window] response in
            guard let self, let window else { return }
            self.confirming.remove(key)
            switch response {
            case .alertFirstButtonReturn:
                if self.model.endConversation(comparisonID) { self.dismissConversationWindow(window) }
                else {
                    let failure = NSAlert()
                    failure.messageText = "Could not end this conversation"
                    failure.informativeText = self.model.error ?? "The conversation remains active. Try again after its history loads."
                    self.model.error = nil
                    failure.addButton(withTitle: "OK")
                    failure.beginSheetModal(for: window)
                }
            case .alertSecondButtonReturn: self.dismissConversationWindow(window)
            default: break
            }
        }
        return false
    }

    func dismissConversationWindow(_ window: NSWindow) {
        // Closing a SwiftUI scene tears down its hosting graph. Retain the main
        // workspace while dismissing its window so reopening remains interactive.
        if window === workspaceWindow { window.orderOut(nil) }
        else { window.close() }
    }

    func updateMembershipWindow(_ id: UUID) {
        let prefix = id.uuidString + ":"
        guard windows[prefix + "connected"] == nil else { return }
        let candidates = windows.values.filter {
            $0.identifier?.rawValue.hasPrefix(prefix) == true &&
            $0.identifier?.rawValue.hasSuffix(":report") != true &&
            $0.identifier?.rawValue.hasSuffix(":all") != true
        }
        guard let window = candidates.first(where: { $0.isKeyWindow }) ?? candidates.first else { return }
        // Reuse the originating separate pane as the joined conversation window.
        let obsolete = windows.filter { $0.key.hasPrefix(prefix) && !$0.key.hasSuffix(":report") }
        for (key, existing) in obsolete {
            windows.removeValue(forKey: key)
            if existing !== window { existing.close() }
        }
        window.identifier = NSUserInterfaceItemIdentifier(prefix + "connected")
        windows[prefix + "connected"] = window
        window.contentView = NSHostingView(rootView: ComparisonWorkspace(model: model, comparisonID: id))
    }

    // Membership changes must never tear down or replace a conversation window.
    func prepareJoiningWebAgent(_ id: UUID) {
        updateMembershipWindow(id)
        let dedicated = windows[id.uuidString + ":connected"]
        let draft = model.comparison(id)?.allDraft ?? ""
        let wasSelected = model.webAgents.comparisonID == id
        let recipients = wasSelected ? model.state.selection : Set(model.comparison(id).map {
            ($0.recipientSelection ?? ConversationRecipients()).recipientIDs(in: $0.members)
        } ?? [])
        let webRecipients = Set(model.webAgents.selected.map(\.id))
        model.openWebComparison(id, present: dedicated == nil && workspaceComparisonID != id)
        model.state.selection = recipients
        if wasSelected {
            for agent in model.comparison(id)?.resolvedWebAgentIDs ?? [] {
                if let session = model.webAgents.session(for: agent) {
                    model.webAgents.select(session, selected: webRecipients.contains(agent))
                }
            }
        }
        if let window = dedicated {
            model.setSharedDraft(draft)
            window.contentView = NSHostingView(rootView: AgentsWorkspaceView(model: model, web: model.webAgents, showingComparison: .constant(true), preservesWindowFrame: true, windowComparisonID: id))
        }
    }

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
        [.flexibleSpace, NSToolbarItem.Identifier("details"), NSToolbarItem.Identifier("captureChat"), NSToolbarItem.Identifier("summarize")]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if identifier.rawValue == "details",
           let id = UUID(uuidString: String(toolbar.identifier.dropFirst("summarize:".count))) {
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = "Details"
            let view = NSHostingView(rootView: ComparisonDetailsButton(model: model, comparisonID: id).frame(width: 36, height: 28))
            view.frame.size = NSSize(width: 36, height: 28)
            item.view = view
            return item
        }
        if identifier.rawValue == "captureChat",
           let id = UUID(uuidString: String(toolbar.identifier.dropFirst("summarize:".count))) {
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = "Capture chat"
            let view = NSHostingView(rootView: ChatShareButton(title: model.comparison(id)?.title ?? "Chat").frame(width: 36, height: 28))
            view.frame.size = NSSize(width: 36, height: 28)
            item.view = view
            return item
        }
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
        if let window = windows[id.uuidString + ":connected"] {
            if model.comparison(id)?.resolvedWebAgentIDs.isEmpty == false { model.openWebComparison(id, present: false) }
            window.makeKeyAndOrderFront(nil)
            return
        }
        if workspaceComparisonID == id, let workspaceWindow {
            workspaceWindow.makeKeyAndOrderFront(nil)
            return
        }
        if model.comparison(id)?.webProviders?.isEmpty == false {
            model.openWebComparison(id)
            workspaceWindow?.makeKeyAndOrderFront(nil)
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
                window.contentView = NSHostingView(rootView: ConversationView(model: model, comparisonID: id, memberID: member.id,
                    removeFromView: { [weak window] in window?.close() }))
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

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let key = window.identifier?.rawValue, key.hasSuffix(":connected"),
              let id = UUID(uuidString: String(key.prefix(36))),
              model.comparison(id)?.resolvedWebAgentIDs.isEmpty == false,
              model.webAgents.comparisonID != id else { return }
        model.openWebComparison(id, present: false)
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
