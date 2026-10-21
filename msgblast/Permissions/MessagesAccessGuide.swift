import SwiftUI
import AppKit
import msgblastCore

// The app-bundle drag and adjacent-guide interaction are adapted from
// riko2chen/AskForPermission (MIT). The full notice is bundled in ThirdPartyNotices.txt.
@MainActor
final class MessagesAccessGuide: ObservableObject {
    @Published private(set) var flow = HistoryAccessHandoff()
    @Published private(set) var message: String?
    weak var sourceView: NSView?
    var checkHistory: (() -> Bool)?
    private var panel: NSPanel?
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private var dragInProgress = false
    private var returning = false
    private let defaults: UserDefaults
    private let requestKey: String
    private var appURL = Bundle.main.bundleURL
    private var appName = "msgblast"
    private var permissionName = "Full Disk Access"
    private var checkAccess: (() async -> Bool)?
    static let pendingKey = "messagesAccessHandoffPending"
    private let settingsBundleID = "com.apple.systempreferences"

    init(defaults: UserDefaults = .standard, pendingKey: String = MessagesAccessGuide.pendingKey) {
        self.defaults = defaults
        requestKey = pendingKey
    }

    func observeHistory(available: Bool) {
        guard flow.isActive || flow.stage == .verified || defaults.bool(forKey: requestKey) else { return }
        var next = flow
        next.observeHistory(available: available)
        guard next != flow else { return }
        flow = next
        if available {
            stopOperation()
            if !dragInProgress { hidePanel() }
            message = nil
        }
    }

    func start(appURL: URL = Bundle.main.bundleURL, appName: String = "msgblast",
               pane: String = "Privacy_AllFiles", permissionName: String = "Full Disk Access",
               checkAccess: (() async -> Bool)? = nil) {
        guard !flow.isActive else { return }
        self.appURL = appURL
        self.appName = appName
        self.permissionName = permissionName
        self.checkAccess = checkAccess
        message = nil
        defaults.set(true, forKey: requestKey)
        flow.begin()
        if checkHistory?() == true { observeHistory(available: true); return }
        guard AppBundleDragPayload.writer(for: appURL) != nil else {
            fail("Open the installed \(appName) app, then try again.")
            return
        }
        let source = sourceFrame()
        let snapshot = sourceSnapshot()
        guard let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(pane)"), NSWorkspace.shared.open(url) else {
            fail("Open System Settings → Privacy & Security → \(permissionName).")
            return
        }
        generation = UUID()
        let token = generation
        operation = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.operation = nil } }
            do {
                let settings = try await self.waitForSettings()
                try Task.checkCancellation()
                guard self.generation == token else { return }
                let target = self.guideFrame(settings)
                let guide = self.makePanel(frame: source ?? target)
                self.panel = guide
                if let snapshot { guide.contentView = NSImageView(image: snapshot) }
                else { guide.contentView = NSHostingView(rootView: self.guideContent()) }
                guide.orderFrontRegardless()
                // The source stays visible until its flight copy is on screen.
                self.flow.showGuide()
                try await self.fly(guide, from: guide.frame, to: target)
                guard self.generation == token else { return }
                guide.contentView = NSHostingView(rootView: self.guideContent())
                var tick = 0
                while !Task.isCancelled, self.generation == token, self.flow.isActive {
                    if !self.dragInProgress, self.flow.stage == .guiding {
                        guard let frame = self.settingsFrame() else {
                            self.cancel(abandonRequest: false)
                            return
                        }
                        let docked = self.guideFrame(frame)
                        if guide.frame != docked { guide.setFrame(docked, display: true) }
                    }
                    if tick % 6 == 0, !self.dragInProgress {
                        let available: Bool
                        if let checkAccess = self.checkAccess { available = await checkAccess() }
                        else { available = self.checkHistory?() == true }
                        guard self.generation == token else { return }
                        if available { self.observeHistory(available: true); return }
                    }
                    tick += 1
                    try await Task.sleep(for: .milliseconds(150))
                }
            } catch is CancellationError { }
            catch {
                guard self.generation == token else { return }
                self.fail("In \(self.permissionName), use + to add \(self.appName), then enable its switch.")
            }
        }
    }

    func cancel(abandonRequest: Bool = true) {
        guard !returning else { return }
        if abandonRequest { defaults.removeObject(forKey: requestKey) }
        stopOperation()
        let token = generation
        guard let panel, let destination = sourceFrame(), !dragInProgress else {
            hidePanel(); flow.cancel(); return
        }
        returning = true
        operation = Task { [weak self] in
            guard let self else { return }
            do { try await self.fly(panel, from: panel.frame, to: destination) }
            catch { return }
            guard !Task.isCancelled, self.generation == token else { return }
            self.hidePanel()
            self.flow.cancel(); self.returning = false; self.operation = nil
            self.sourceView?.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func dismissCompletion() {
        defaults.removeObject(forKey: requestKey)
        flow.cancel()
    }

    private func stopOperation() {
        generation = UUID()
        operation?.cancel()
        operation = nil
        returning = false
    }

    private func fail(_ message: String) {
        stopOperation()
        hidePanel()
        flow.cancel(); self.message = message
    }

    private func hidePanel() {
        guard let panel else { return }
        NSApp.removeWindowsItem(panel)
        panel.orderOut(nil)
        self.panel = nil
    }

    private func makePanel(frame: CGRect) -> NSPanel {
        let panel = MessagesAccessPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true; panel.level = .floating
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.title = "\(permissionName) guide"
        panel.isExcludedFromWindowsMenu = false
        panel.setAccessibilityLabel(panel.title)
        panel.setAccessibilityElement(true)
        NSApp.addWindowsItem(panel, title: panel.title, filename: false)
        return panel
    }

    private func guideContent() -> some View {
        MessagesAccessGuideContent(appURL: appURL, appName: appName, permissionName: permissionName, cancel: { [weak self] in self?.cancel() }, dragStarted: { [weak self] in self?.dragInProgress = true }, dragEnded: { [weak self] dropped in
            guard let self else { return }
            self.dragInProgress = false
            self.flow.finishDrag(dropped: dropped)
            if dropped || self.flow.stage == .verified { self.hidePanel() }
        })
    }

    private func sourceFrame() -> CGRect? {
        guard let view = sourceView, let window = view.window, view.bounds.width > 0 else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }

    private func sourceSnapshot() -> NSImage? {
        guard let view = sourceView, let content = view.window?.contentView else { return nil }
        let rect = view.convert(view.bounds, to: content)
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        content.cacheDisplay(in: rect, to: bitmap)
        let image = NSImage(size: rect.size); image.addRepresentation(bitmap)
        return image
    }

    private func settingsFrame() -> CGRect? {
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: settingsBundleID).map { $0.processIdentifier })
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        return windows.compactMap { window -> CGRect? in
            guard let pid = window[kCGWindowOwnerPID as String] as? Int32, pids.contains(pid),
                  window[kCGWindowLayer as String] as? Int == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary), frame.width > 300, frame.height > 300 else { return nil }
            return PermissionGuideGeometry.appKitFrame(frame, primaryHeight: primaryHeight)
        }.max { $0.width * $0.height < $1.width * $1.height }
    }

    private func waitForSettings() async throws -> CGRect {
        let clock = ContinuousClock(), deadline = ContinuousClock().now + .seconds(8)
        var previous: CGRect?
        while clock.now < deadline {
            try Task.checkCancellation()
            if let frame = settingsFrame() {
                if previous?.integral == frame.integral { return frame }
                previous = frame
            }
            try await Task.sleep(for: .milliseconds(150))
        }
        throw AppFailure.blocked("Settings window not found")
    }

    private func guideFrame(_ settings: CGRect) -> CGRect {
        let screen = NSScreen.screens.max { a, b in
            let x = a.frame.intersection(settings), y = b.frame.intersection(settings)
            return (x.isNull ? 0 : x.width * x.height) < (y.isNull ? 0 : y.width * y.height)
        }
        return PermissionGuideGeometry.dockedFrame(settings: settings, visibleFrame: screen?.visibleFrame ?? settings)
    }

    private func fly(_ panel: NSPanel, from: CGRect, to: CGRect) async throws {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { panel.setFrame(to, display: true); return }
        let clock = ContinuousClock(), start = ContinuousClock().now
        while true {
            try Task.checkCancellation()
            let elapsed = start.duration(to: clock.now).components
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            let raw = min(1, seconds / 0.5)
            let t = CGFloat(raw * raw * (3 - 2 * raw))
            let arc = 4 * t * (1 - t) * 100
            panel.setFrame(CGRect(x: from.minX + (to.minX - from.minX) * t,
                                  y: from.minY + (to.minY - from.minY) * t + arc,
                                  width: from.width + (to.width - from.width) * t,
                                  height: from.height + (to.height - from.height) * t), display: true)
            if raw == 1 { break }
            try await Task.sleep(for: .milliseconds(16))
        }
        // Small damped arrival bounce, without moving the final dock position.
        let settle = clock.now
        while settle.duration(to: clock.now) < .milliseconds(300) {
            try Task.checkCancellation()
            let components = settle.duration(to: clock.now).components
            let s = Double(components.seconds) + Double(components.attoseconds) / 1e18
            let offset = CGFloat(sin(s * 28) * exp(-s * 14) * 5)
            panel.setFrameOrigin(CGPoint(x: to.minX, y: to.minY + offset))
            try await Task.sleep(for: .milliseconds(16))
        }
        panel.setFrame(to, display: true)
    }
}

private final class MessagesAccessPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct PermissionSourceAnchor: NSViewRepresentable {
    let guide: MessagesAccessGuide
    func makeNSView(context: Context) -> NSView { let view = NSView(); guide.sourceView = view; return view }
    func updateNSView(_ nsView: NSView, context: Context) { guide.sourceView = nsView }
}

struct MessagesAccessRow: View {
    @ObservedObject var guide: MessagesAccessGuide
    let check: () -> Void
    var isOnboarding = false
    var body: some View {
        let handedOff = guide.flow.stage == .guiding || guide.flow.stage == .waitingForAccess
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: guide.flow.stage == .verified ? "checkmark.circle.fill" : "lock.fill")
                    .font(.title2).foregroundStyle(guide.flow.stage == .verified ? .green : .secondary)
                if handedOff {
                    Text("Complete in System Settings").foregroundStyle(.secondary)
                    Spacer()
                    Button("Check again", action: check)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(isOnboarding ? "Chat with the agents you text on Messages" : "Connect Messages").font(.headline)
                        if isOnboarding {
                            Text("Your messages are yours. You choose what to share.")
                                .font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("Full Disk Access lets msgblast read your local Messages history to find and compare the agents you text. Web model chats work without it.")
                                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer()
                    if guide.flow.stage == .verified {
                        Label("Done", systemImage: "checkmark").foregroundStyle(.green)
                        Button("Continue") { guide.dismissCompletion() }
                    } else {
                        Button("Open Settings") { guide.start() }.buttonStyle(.borderedProminent).disabled(guide.flow.isActive)
                    }
                }
            }.padding(14).frame(minHeight: 72)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                .overlay { if handedOff { RoundedRectangle(cornerRadius: 12).stroke(.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [5, 4])) } }
                .background(PermissionSourceAnchor(guide: guide))
            if let message = guide.message {
                Text(message).font(.callout).foregroundStyle(.secondary)
                HStack {
                    AppBundleDragRow(dragStarted: {}, dragEnded: { _ in }).frame(height: 44)
                    Button("Check again", action: check)
                }
            }
        }
    }
}

private struct MessagesAccessGuideContent: View {
    let appURL: URL
    let appName: String
    let permissionName: String
    let cancel: () -> Void
    let dragStarted: () -> Void
    let dragEnded: (Bool) -> Void
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up").font(.title3.weight(.semibold)).foregroundStyle(.blue)
                Text("Drag \(appName) to the list, then enable it").font(.callout)
            }
            HStack(spacing: 8) {
                Button(action: cancel) { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                    .accessibilityLabel("Back to msgblast")
                AppBundleDragRow(appURL: appURL, appName: appName, permissionName: permissionName, dragStarted: dragStarted, dragEnded: dragEnded).frame(height: 44)
            }
        }.padding(14).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}

private struct AppBundleDragRow: NSViewRepresentable {
    var appURL = Bundle.main.bundleURL
    var appName = "msgblast"
    var permissionName = "Full Disk Access"
    let dragStarted: () -> Void
    let dragEnded: (Bool) -> Void
    func makeNSView(context: Context) -> AppBundleDragView { AppBundleDragView(appURL: appURL, appName: appName, permissionName: permissionName, dragStarted: dragStarted, dragEnded: dragEnded) }
    func updateNSView(_ nsView: AppBundleDragView, context: Context) { nsView.onStart = dragStarted; nsView.onEnd = dragEnded }
}

private final class AppBundleDragView: NSView, NSDraggingSource {
    var onStart: () -> Void
    var onEnd: (Bool) -> Void
    private let appURL: URL
    private var down: NSEvent?
    private var dragging = false
    init(appURL: URL, appName: String, permissionName: String, dragStarted: @escaping () -> Void, dragEnded: @escaping (Bool) -> Void) {
        self.appURL = appURL
        onStart = dragStarted; onEnd = dragEnded
        super.init(frame: CGRect(x: 0, y: 0, width: 280, height: 44))
        wantsLayer = true; layer?.cornerRadius = 9
        layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.3).cgColor
        let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: appURL.path))
        let name = NSTextField(labelWithString: appName)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        icon.translatesAutoresizingMaskIntoConstraints = false; name.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon); addSubview(name)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10), icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 28), icon.heightAnchor.constraint(equalToConstant: 28),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10), name.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10)
        ])
        setAccessibilityElement(true); setAccessibilityRole(.button)
        setAccessibilityEnabled(true)
        setAccessibilityLabel("Drag \(appName) into \(permissionName)")
        setAccessibilityHelp("Drag this app into the \(permissionName) list in System Settings, then enable its switch.")
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) { down = event; dragging = false }
    override func mouseUp(with event: NSEvent) { down = nil; dragging = false }
    override func mouseDragged(with event: NSEvent) {
        guard let down, !dragging, hypot(event.locationInWindow.x - down.locationInWindow.x, event.locationInWindow.y - down.locationInWindow.y) >= 3,
              let writer = AppBundleDragPayload.writer(for: appURL) else { return }
        dragging = true; onStart()
        let item = NSDraggingItem(pasteboardWriter: writer)
        let preview = NSImage(size: bounds.size)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) { cacheDisplay(in: bounds, to: rep); preview.addRepresentation(rep) }
        item.setDraggingFrame(bounds, contents: preview)
        let session = beginDraggingSession(with: [item], event: down, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { dragging = false; down = nil; onEnd(!operation.isEmpty) }
}
