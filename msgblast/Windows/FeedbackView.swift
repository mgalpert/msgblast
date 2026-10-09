import AppKit
import SwiftUI
import UniformTypeIdentifiers
import msgblastCore

@MainActor
final class FeedbackSession: ObservableObject {
    @Published var note = ""
    @Published var contact = ""
    @Published var includeDiagnostics = true
    @Published var message: String?
    let facts: DiagnosticFacts
    @Published private(set) var isSending = false
    @Published private var sentRequest: DiagnosticRequest?
    private var lastAttempt: (request: DiagnosticRequest, id: UUID)?
    private var sendTask: Task<Void, Never>?

    private var request: DiagnosticRequest {
        DiagnosticRequest(kind: .feedback, note: note, contact: contact, includeDiagnostics: includeDiagnostics, facts: facts)
    }

    var canSend: Bool { canExport && !isSending && sentRequest != request }
    var sendTitle: String { isSending ? "Sending…" : sentRequest == request ? "Feedback sent" : "Send feedback" }

    init(facts: DiagnosticFacts) { self.facts = facts }

    var canExport: Bool {
        !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && contactIsAcceptable
    }

    var contactIsAcceptable: Bool {
        let trimmed = contact.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || DiagnosticReport.isValidContact(trimmed)
    }

    var saveTitle: String { includeDiagnostics ? "Save Report with Diagnostics…" : "Save Report…" }
    var diagnosticsPreview: String { DiagnosticReport.diagnosticsJSON(facts) }

    func save() {
        guard let package = makePackage() else { return }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = package.suggestedFilename
        panel.title = saveTitle
        panel.message = package.includeDiagnostics
            ? "The ZIP includes the note you wrote and the diagnostic report shown in this window."
            : "The ZIP includes the note you wrote. A diagnostic report is not included."
        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }
        do {
            try DiagnosticArchive.write(package.archive, to: url)
            message = "Saved \(url.lastPathComponent). msgblast did not upload it."
        } catch {
            message = error.localizedDescription
        }
    }

    func send() {
        guard canSend, makePackage() != nil else { return }
        let snapshot = request
        let id = lastAttempt?.request == snapshot ? lastAttempt!.id : UUID()
        lastAttempt = (snapshot, id)
        isSending = true
        message = "Sending your feedback to msgblast…"
        let fixture = Bundle.main.object(forInfoDictionaryKey: "msgblastDemo") as? Bool == true
        let endpoint = fixture
            ? (Bundle.main.object(forInfoDictionaryKey: "msgblastFeedbackEndpoint") as? String).flatMap(URL.init(string:)) ?? FeedbackSubmission.productionEndpoint
            : FeedbackSubmission.productionEndpoint
        sendTask = Task { @MainActor in
            defer { isSending = false; sendTask = nil }
            do {
                let receipt = try await FeedbackSubmission.send(snapshot, id: id, endpoint: endpoint, isLocalFixture: fixture)
                sentRequest = snapshot
                message = "Sent to msgblast. Report ID: \(receipt.id.uuidString.lowercased())"
            } catch {
                message = "\(error.localizedDescription) Your note is still here."
            }
        }
    }

    func cleanup() { sendTask?.cancel() }

    private func makePackage() -> DiagnosticPackage? {
        do {
            let package = try DiagnosticReport.make(request)
            message = nil
            return package
        } catch {
            message = error.localizedDescription
            return nil
        }
    }
}

@MainActor
final class FeedbackWindowController: NSObject, NSWindowDelegate {
    static var current: FeedbackWindowController?
    let session: FeedbackSession
    private var hostedWindow: NSWindow?

    static func show(model: AppModel?, updater: AppUpdater) {
        if let current, let window = current.hostedWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = FeedbackWindowController(model: model, updater: updater)
        current = controller
        controller.hostedWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    init(model: AppModel?, updater: AppUpdater) {
        session = FeedbackSession(facts: FeedbackFacts.capture(model: model, updater: updater))
        super.init()
        let host = NSHostingView(rootView: FeedbackView(session: session))
        host.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.contentView = host
        window.title = "Send Feedback"
        window.setContentSize(NSSize(width: 560, height: 600))
        window.minSize = NSSize(width: 480, height: 420)
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        hostedWindow = window
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            self.session.cleanup()
            self.hostedWindow?.delegate = nil
            self.hostedWindow = nil
            if FeedbackWindowController.current === self { FeedbackWindowController.current = nil }
        }
    }
}

struct FeedbackView: View {
    @ObservedObject var session: FeedbackSession

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                form
                    .padding(20)
                    .disabled(session.isSending)
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                if let message = session.message {
                    Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Feedback status")
                        .accessibilityValue(message)
                }
                exportButtons
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Send feedback to msgblast")
                .font(.headline)
            Text("Send your note directly to the msgblast team. A diagnostic report is included to help us investigate; you can uncheck it below.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Only your note, optional reply email, and the diagnostics you choose are sent. Reports are stored privately. Leave out message transcripts, phone numbers, and files.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Feedback note").font(.headline)
            Text("Describe what happened, what you expected, and the steps to reproduce it.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $session.note)
                .font(.body)
                .frame(height: 120)
                .accessibilityLabel("Feedback note")
            TextField("Reply email, optional", text: $session.contact)
                .accessibilityLabel("Reply email, optional")
            if !session.contactIsAcceptable {
                Text("Leave the reply address blank or enter an email address.")
                    .font(.caption).foregroundStyle(.orange)
            }
            Toggle("Include a diagnostic report", isOn: $session.includeDiagnostics)
            Text("Diagnostics never include:").font(.caption).foregroundStyle(.secondary)
            Text(DiagnosticReport.excludedTopics.map { "• \($0)" }.joined(separator: "\n"))
                .font(.caption).foregroundStyle(.secondary)
            if session.includeDiagnostics {
                Text("This is the entire diagnostic file.")
                    .font(.headline)
                ScrollView {
                    Text(session.diagnosticsPreview)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("Diagnostic preview")
                        .accessibilityLabel("Diagnostic preview")
                        .accessibilityValue(session.diagnosticsPreview)
                }
                .frame(height: 160)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            } else {
                Text("A diagnostic report is not included.")
                    .font(.callout)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var exportButtons: some View {
        HStack {
            Spacer()
            Button(session.saveTitle) { session.save() }
                .disabled(!session.canExport || session.isSending)
            Button(session.sendTitle) { session.send() }
                .keyboardShortcut(.defaultAction)
                .disabled(!session.canSend)
        }
    }
}
