import AppKit
import SwiftUI
import msgblastCore

@MainActor
final class CrashReviewSession: ObservableObject {
    let reports: [CrashReport]
    let store: CrashReportStore?
    @Published var selection = 0 {
        didSet { if selection != oldValue { note = ""; message = nil } }
    }
    @Published var note = ""
    @Published var message: String?
    @Published var sending = false
    private var task: Task<Void, Never>?
    var report: CrashReport? { reports.indices.contains(selection) ? reports[selection] : nil }
    var pending: CrashAttempt? { report.flatMap { store?.attempt($0) } }
    var sent: Bool { report.map { store?.isSubmitted($0) == true } ?? false }
    var sendTitle: String {
        if sent { return "Crash report sent" }
        if sending { return "Sending…" }
        return pending == nil ? "Send crash report" : "Retry same report"
    }
    var preview: String { (pending?.report ?? report)?.preview ?? "No supported msgblast crash report was found in the last 30 days." }
    init(reports: [CrashReport], store: CrashReportStore?, error: String? = nil) {
        self.reports = reports; self.store = store; self.message = error
    }
    func send() {
        guard !sending, !sent, let report, let store else { return }
        do {
            let previous = store.attempt(report)
            let context = previous?.note ?? note
            guard context.count <= DiagnosticReport.maximumNoteLength else { message = "Shorten your context to 8,000 characters."; return }
            var request = DiagnosticRequest(kind: .crash, note: context.isEmpty ? "Crash report (no additional context)." : context, facts: .empty())
            request.crash = previous?.report ?? report
            do { _ = try FeedbackSubmission.encodeRequest(request, id: previous?.id ?? UUID()) }
            catch { message = error.localizedDescription; return }
            let attempt = try store.prepare(report, note: context)
            let fixture = Bundle.main.object(forInfoDictionaryKey: "msgblastDemo") as? Bool == true || ProcessInfo.processInfo.arguments.contains("--demo")
            let endpoint = fixture
                ? (Bundle.main.object(forInfoDictionaryKey: "msgblastFeedbackEndpoint") as? String).flatMap(URL.init(string:)) ?? FeedbackSubmission.productionEndpoint
                : FeedbackSubmission.productionEndpoint
            if fixture && endpoint == FeedbackSubmission.productionEndpoint && ProcessInfo.processInfo.arguments.contains("--crash-report-preview") {
                message = "Demo fixture: configure a local feedback endpoint to submit this synthetic report."
                return
            }
            sending = true
            message = "Sending the reviewed crash summary…"
            task = Task { @MainActor in
                defer { sending = false; task = nil }
                do {
                    let receipt = try await FeedbackSubmission.send(request, id: attempt.id, endpoint: endpoint, isLocalFixture: fixture)
                    try store.confirm(report)
                    message = "Sent privately to msgblast. Report ID: \(receipt.id.uuidString.lowercased())"
                } catch {
                    message = "Submission is unconfirmed. Retry sends the same report and context with the same ID."
                }
            }
        } catch { message = "The crash report journal could not be saved. Nothing was sent." }
    }
    func dismiss() {
        guard let report, let store else { return }
        do { try store.dismiss(report); message = "Dismissed. You can review this report later from Help." }
        catch { message = "Could not remember dismissal. Nothing was sent." }
    }
    func cleanup() { task?.cancel() }
}

@MainActor
final class CrashReportWindowController: NSObject, NSWindowDelegate {
    static var current: CrashReportWindowController?
    private let session: CrashReviewSession
    private var hostedWindow: NSWindow?
    static func show(reports: [CrashReport], store: CrashReportStore?, error: String? = nil) {
        guard !focusIfOpen() else { return }
        let controller = CrashReportWindowController(session: CrashReviewSession(reports: reports, store: store, error: error))
        current = controller
        controller.hostedWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    static func focusIfOpen() -> Bool {
        guard let window = current?.hostedWindow else { return false }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        return true
    }
    private init(session: CrashReviewSession) {
        self.session = session
        super.init()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 650), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Review Crash Report"
        window.contentView = NSHostingView(rootView: CrashReportView(session: session))
        window.minSize = NSSize(width: 500, height: 500)
        window.center(); window.isReleasedWhenClosed = false; window.delegate = self
        hostedWindow = window
    }
    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            self.session.dismiss(); self.session.cleanup()
            self.hostedWindow?.delegate = nil; self.hostedWindow = nil
            if Self.current === self { Self.current = nil }
        }
    }
}

private struct CrashReportView: View {
    @ObservedObject var session: CrashReviewSession
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Help us understand an earlier crash").font(.title2.bold())
            if Bundle.main.object(forInfoDictionaryKey: "msgblastDemo") as? Bool == true {
                Text("msgblast Demo · fixture workflow").font(.caption).foregroundStyle(.secondary)
            }
            Text("Review this summary before sending it privately to the msgblast team. Nothing is uploaded until you choose Send crash report.")
            Text("Only app/build details, exception categories, and binary identifiers with stack offsets are collected. Raw crash files, paths, registers, messages, contacts, and chat content are excluded.").foregroundStyle(.secondary)
            if !session.reports.isEmpty {
                Picker("Crash", selection: $session.selection) {
                    ForEach(Array(session.reports.enumerated()), id: \.offset) { index, report in
                        Text("\(report.day) · \(report.process) · \(report.version) (\(report.build))").tag(index)
                    }
                }.disabled(session.sending)
            }
            ScrollView {
                Text(session.preview).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.padding(10).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier("Crash summary preview")
            Text("What were you doing? (optional)").font(.headline)
            Text("Leave out private conversations, contact details, and credentials.").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: Binding(get: { session.pending?.note ?? session.note }, set: { session.note = $0 })).frame(height: 72).disabled(session.sending || session.pending != nil || session.sent)
                .accessibilityLabel("Crash context")
            if session.pending != nil {
                Text("Unconfirmed submission: the original context above is locked for an identical retry.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message = session.message { Text(message).font(.callout).accessibilityIdentifier("Crash submission status") }
            HStack {
                Button("Dismiss") { session.dismiss() }.disabled(session.sending || session.report == nil)
                Spacer()
                Button(session.sendTitle) { session.send() }
                    .disabled(session.sending || session.sent || session.report == nil || session.store == nil)
            }
        }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
