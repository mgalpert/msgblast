import AppKit
import SwiftUI
import msgblastCore

@MainActor
final class GPTLiveWindowController: NSObject, NSWindowDelegate {
    private static var current: GPTLiveWindowController?
    private var hostedWindow: NSWindow?
    private let controller: GPTLiveController

    static func show(model: AppModel, comparisonID: UUID? = nil) {
        if let current, let window = current.hostedWindow {
            if let comparisonID { current.controller.selectedComparisonID = comparisonID }
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return
        }
        let owner = GPTLiveWindowController(model: model, comparisonID: comparisonID)
        current = owner
        owner.hostedWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    static func shutdown() async { await current?.controller.disconnect() }

    init(model: AppModel, comparisonID: UUID?) {
        controller = GPTLiveController(model: model, comparisonID: comparisonID)
        super.init()
        let host = NSHostingView(rootView: GPTLiveView(controller: controller))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "GPT-Live · msgblast"
        window.contentView = host
        window.minSize = NSSize(width: 620, height: 620)
        if let screen = NSScreen.main { window.setContentSize(NSSize(width: min(900, screen.visibleFrame.width), height: min(820, screen.visibleFrame.height - 40))) }
        window.center(); window.isReleasedWhenClosed = false; window.delegate = self
        hostedWindow = window
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !controller.sending else { NSSound.beep(); return false }
        Task { await controller.disconnect() }
        // Retain this controller while shutdown finishes; a reopened panel cannot start a second session.
        return true
    }
}

struct GPTLiveView: View {
    @ObservedObject var controller: GPTLiveController
    @ObservedObject private var session: GPTLiveSession
    @ObservedObject private var model: AppModel
    @State private var showKey = false
    @State private var showContext = false
    @State private var showDebug = false
    @State private var contextPreview = ""

    init(controller: GPTLiveController) {
        self.controller = controller; session = controller.session; model = controller.model
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(22)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    setup
                    if let error = controller.error ?? session.error {
                        Label(error, systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(.orange).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("GPTLive error")
                    }
                    transcript
                    if controller.pendingDraft != nil { draft }
                    if controller.pendingEndConversationID != nil { endConversationReview }
                }.padding(22)
            }
            Divider()
            composer.padding(18)
        }
        .frame(minWidth: 600, minHeight: 580)
        .sheet(isPresented: $showDebug) { GPTLiveDebugView(activity: controller.activity) }
        .onChange(of: controller.selectedComparisonID) { controller.selectedRecipientID = "all" }
        .onChange(of: showContext) { _, expanded in if expanded { refreshContextPreview() } }
        .onChange(of: controller.selectedComparisonID) { if showContext { refreshContextPreview() } }
        .onChange(of: controller.selectedRecipientID) { if showContext { refreshContextPreview() } }
        .onChange(of: controller.speaker) { if !controller.speaker { controller.audio.stopPlayback() } }
    }
    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "waveform.circle.fill").font(.system(size: 42)).foregroundStyle(.teal)
            VStack(alignment: .leading, spacing: 4) {
                Text("GPT-Live").font(.title.bold())
                Text("Your assistant across the whole app.").foregroundStyle(.secondary)
            }
            Spacer()
            Button("Debug activity") { showDebug = true }.accessibilityIdentifier("GPTLive debug")
            if controller.active {
                Button("End session") { Task { await controller.disconnect() } }
                    .disabled(session.state == .closing).accessibilityIdentifier("GPTLive end")
            }
        }
    }
    private var setup: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle().fill(controller.connected ? Color.green : Color.secondary.opacity(0.4)).frame(width: 8, height: 8)
                Text(controller.fixtureConnected ? "Demo session" : session.state.rawValue.capitalized).font(.headline)
                Spacer()
                Text("GPT-Live 1 · GPT-6 Luna").font(.caption).foregroundStyle(.secondary)
            }
            Label("App-wide access", systemImage: "square.grid.2x2")
                .font(.headline)
            Text("Find and open conversations, review replies, select agents, manage drafts, and prepare messages to multiple recipients.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("\(model.state.comparisons.count) conversations · \(controller.appDestinations.count) configured agents")
                .font(.caption).foregroundStyle(.secondary)
            if model.demo {
                HStack {
                    Toggle("Simulate GPT-Live", isOn: $controller.simulate).disabled(controller.active)
                    Spacer()
                    Button("Create sample conversation") { Task { await controller.createSampleConversation() } }
                        .disabled(controller.active || model.busy).accessibilityIdentifier("GPTLive create sample")
                }
                Text(controller.simulate ? "Demo uses sample answers and simulated sends. No OpenAI request." : "OpenAI requests are live and billed to your key. Messages in this Demo app remain simulated.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !controller.active {
                DisclosureGroup("OpenAI API key", isExpanded: $showKey) {
                    VStack(alignment: .leading, spacing: 10) {
                        SecureField("sk-…", text: $controller.apiKey).textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("GPTLive API key")
                        HStack {
                            Toggle("Remember in Keychain", isOn: $controller.rememberKey)
                            Spacer()
                            Button("Save key") { controller.saveKey() }.disabled(controller.apiKey.isEmpty)
                            Button("Forget key") { controller.forgetKey() }
                        }
                        Text(controller.keyStatus.isEmpty ? "Your key is used directly with OpenAI on this Mac." : controller.keyStatus)
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.top, 8)
                }
            }
            DisclosureGroup("Preview app state", isExpanded: $showContext) {
                Button("Refresh preview") { refreshContextPreview() }
                Text(contextPreview)
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
            }
            if !controller.active {
                Text("Connecting lets GPT-Live inspect app state and requested conversation history through tools. Sending messages and ending conversations require your review here. Attachment contents are excluded. Microphone starts off.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(controller.simulate ? "Start demo session" : "Connect GPT-Live") { Task { await controller.connect() } }
                    .buttonStyle(.borderedProminent).tint(.teal)
                    .disabled(!controller.simulate && controller.apiKey.isEmpty)
                    .accessibilityIdentifier("GPTLive connect")
            }
        }.padding(16).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
    }
    private var transcript: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Session").font(.headline)
                Spacer()
                if session.backendBusy { ProgressView().controlSize(.small); Text("Working…").font(.caption) }
            }
            if session.transcript.isEmpty && controller.fixtureTranscript.isEmpty {
                Text("Try “Show my agents”, “Compare my recent conversations”, or “Start a new message to Cedar”. Tool activity is available in Debug activity.")
                    .foregroundStyle(.secondary).padding(.vertical, 14)
            }
            ForEach(session.transcript) { entry in
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.role == "user" ? "You" : entry.role == "assistant" ? "GPT-Live" : entry.role.capitalized)
                        .font(.caption.bold()).foregroundStyle(.secondary)
                    Text(entry.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    .background(entry.role == "user" ? Color.teal.opacity(0.08) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            }
            ForEach(Array(controller.fixtureTranscript.enumerated()), id: \.offset) { _, text in
                Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            }
        }.accessibilityIdentifier("GPTLive transcript")
    }
    private var draft: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Review message", systemImage: "square.and.pencil").font(.headline)
            Text("Conversation: " + controller.draftConversationTitle).font(.subheadline)
            Text("To: " + controller.draftRecipientName).font(.subheadline.bold())
            TextEditor(text: Binding(get: { controller.pendingDraft?.text ?? "" }, set: { controller.editDraft($0) }))
                .font(.body).frame(minHeight: 100, maxHeight: 180).scrollContentBackground(.hidden)
                .padding(8).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .disabled(controller.sending).accessibilityIdentifier("GPTLive reviewed draft")
            HStack {
                Text("Nothing is sent until you click Send.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Discard") { controller.discardDraft() }.disabled(controller.sending)
                Button(model.demo ? "Send (simulated)" : "Send to " + controller.draftRecipientName) {
                    Task { await controller.sendDraft() }
                }.buttonStyle(.borderedProminent).disabled(!controller.canSendDraft)
                    .accessibilityIdentifier("GPTLive send draft")
            }
        }.padding(16).background(Color.teal.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
    }
    private var endConversationReview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("End conversation?", systemImage: "archivebox").font(.headline)
            Text(controller.pendingEndConversationID.flatMap { model.comparison($0)?.title } ?? "Unavailable conversation")
            Text("History will be retained. This conversation will stop accepting new messages.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") {
                    controller.pendingEndConversationID = nil
                    controller.activity.record(category: "action", summary: "User cancelled conversation closure")
                }
                Button("End conversation") { controller.confirmEndConversation() }
                    .disabled(controller.sending || model.busy || model.webBroadcastBusy)
            }
        }.padding(16).background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("App overview") { Task { await controller.ask("Inspect the app state and tell me which agents and recent conversations are available.") } }
                    .disabled(session.backendBusy)
                Button("Review conversations") { Task { await controller.ask("List my recent conversations and help me choose which to review.") } }
                    .disabled(session.backendBusy)
                Spacer()
            }.disabled(!controller.connected)
            HStack {
                Spacer()
                Toggle("Speaker", isOn: $controller.speaker).toggleStyle(.button)
                Button(controller.microphone ? "Mute microphone" : "Use microphone") {
                    Task { await controller.setMicrophone(!controller.microphone) }
                }.disabled(controller.simulate).accessibilityIdentifier("GPTLive microphone")
            }.disabled(!controller.connected)
            HStack(alignment: .bottom) {
                TextField("Ask GPT-Live to do something in the app…", text: $controller.input, axis: .vertical)
                    .lineLimit(2...5).textFieldStyle(.roundedBorder).accessibilityIdentifier("GPTLive request")
                Button("Ask") { Task { await controller.ask() } }.buttonStyle(.borderedProminent)
                    .disabled(!controller.connected || session.backendBusy || controller.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || controller.input.count > 8000)
                    .accessibilityIdentifier("GPTLive ask")
            }
            HStack {
                Text(controller.status).lineLimit(3).accessibilityIdentifier("GPTLive status")
                Spacer()
                Text(session.usageSummary)
            }.font(.caption).foregroundStyle(.secondary)
        }
    }
    private func refreshContextPreview() {
        contextPreview = controller.appStateJSON()
    }
}
