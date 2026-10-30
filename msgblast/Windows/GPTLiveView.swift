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
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            current.controller.beginVoice()
            return
        }
        let owner = GPTLiveWindowController(model: model, comparisonID: comparisonID)
        current = owner
        owner.hostedWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        owner.controller.beginVoice()
    }
    static func shutdown() async { await current?.controller.disconnect() }
    static func close() { current?.hostedWindow?.performClose(nil) }

    init(model: AppModel, comparisonID: UUID?) {
        controller = GPTLiveController(model: model, comparisonID: comparisonID)
        super.init()
        let host = NSHostingView(rootView: GPTLiveView(controller: controller))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "GPT-Live"
        window.contentView = host
        window.minSize = NSSize(width: 480, height: 560)
        if let screen = NSScreen.main {
            window.setContentSize(NSSize(width: min(560, screen.visibleFrame.width), height: min(680, screen.visibleFrame.height - 40)))
        }
        window.center(); window.isReleasedWhenClosed = false; window.delegate = self
        hostedWindow = window
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !controller.sending else { NSSound.beep(); return false }
        Task { await controller.disconnect() }
        return true
    }
}

struct GPTLiveView: View {
    @ObservedObject var controller: GPTLiveController
    @ObservedObject private var session: GPTLiveSession
    @ObservedObject private var audio: GPTLiveAudio
    @ObservedObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showTranscript = false
    @State private var showText = false
    @State private var showDebug = false
    @State private var showContext = false
    @State private var contextPreview = ""
    @FocusState private var textFocused: Bool

    init(controller: GPTLiveController) {
        self.controller = controller
        session = controller.session; audio = controller.audio; model = controller.model
    }
    private var hasReview: Bool { controller.pendingDraft != nil || controller.pendingEndConversationID != nil }
    private var failure: String? { controller.error ?? session.error }
    private var preparing: Bool { controller.startingVoice || controller.microphoneStarting || session.state == .connecting }
    private var speaking: Bool { controller.connected && controller.speaker && audio.outputLevel > 0.08 }
    private var voiceTitle: String {
        if session.state == .closing { return "Ending voice…" }
        if controller.microphoneStarting { return "Starting your microphone…" }
        if preparing { return "Connecting…" }
        if failure != nil { return "Let’s get you connected" }
        if hasReview { return "Ready for your review" }
        if controller.simulate && controller.connected { return "Demo conversation" }
        if speaking { return "Speaking" }
        if session.backendBusy { return "Working on it…" }
        if controller.microphone { return "Listening" }
        if controller.connected { return "Microphone muted" }
        return "Ready when you are"
    }
    private var voiceHint: String {
        if controller.microphoneStarting { return "Allow microphone access if macOS asks." }
        if preparing { return "Getting voice ready." }
        if hasReview { return "Check the message below before sending." }
        if controller.simulate { return "Sample replies and simulated sends. No microphone or API use." }
        if controller.microphone { return "Talk naturally. You can interrupt at any time." }
        if controller.connected { return "Turn on your mic to keep talking, or type a message." }
        if controller.voiceNeedsKey { return "Add your OpenAI key in settings to get started." }
        return "Your voice, across msgblast."
    }
    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 24) {
                        voiceStage
                        if let failure { errorCard(failure) }
                        if controller.pendingDraft != nil { draft.id("review") }
                        if controller.pendingEndConversationID != nil { endConversationReview.id("end-review") }
                        if showTranscript { transcript }
                        if !controller.status.isEmpty && !controller.status.hasPrefix("Connected") && !controller.status.hasPrefix("Demo session") && controller.status != "Session ended" {
                            Text(controller.status).font(.callout).foregroundStyle(.secondary)
                                .textSelection(.enabled).accessibilityIdentifier("GPTLive status")
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }.padding(.horizontal, 28).padding(.bottom, 12)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: controller.pendingDraft?.id) { _, id in
                    if id != nil { withAnimation(reduceMotion ? nil : .easeInOut) { proxy.scrollTo("review", anchor: .top) } }
                }
                .onChange(of: controller.pendingEndConversationID) { _, id in
                    if id != nil { proxy.scrollTo("end-review", anchor: .top) }
                }
                .onChange(of: session.transcript.last?.text) { if showTranscript { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
            if showText { textComposer.padding(.horizontal, 24).padding(.bottom, 16) }
            voiceControls.padding(.horizontal, 24).padding(.bottom, 24).padding(.top, 12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 460, minHeight: 520)
        .sheet(isPresented: $controller.showSettings) { settings }
        .sheet(isPresented: $showDebug) { GPTLiveDebugView(activity: controller.activity) }
        .onChange(of: controller.selectedComparisonID) { controller.selectedRecipientID = "all" }
        .onChange(of: showContext) { _, expanded in if expanded { contextPreview = controller.appStateJSON() } }
        .onChange(of: controller.speaker) { if !controller.speaker { audio.stopPlayback() } }
    }
    private var header: some View {
        HStack {
            Label("GPT-Live", systemImage: "waveform").font(.headline)
            Spacer()
            Menu {
                Button("Voice settings…", systemImage: "slider.horizontal.3") { controller.showSettings = true }
                Toggle("Show transcript", isOn: $showTranscript)
                Divider()
                Button("Activity…", systemImage: "list.bullet.rectangle") { showDebug = true }
                    .accessibilityIdentifier("GPTLive debug")
            } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Voice options").accessibilityLabel("Voice options").accessibilityIdentifier("GPTLive options")
        }.padding(.horizontal, 24).padding(.vertical, 16)
    }
    private var voiceStage: some View {
        VStack(spacing: 24) {
            Spacer(minLength: hasReview || showTranscript ? 4 : 42)
            GPTLiveVoiceOrb(level: max(audio.inputLevel, audio.outputLevel),
                            active: controller.microphone || speaking, preparing: preparing)
                .frame(width: hasReview || showTranscript ? 112 : 196, height: hasReview || showTranscript ? 112 : 196)
                .accessibilityHidden(true)
            VStack(spacing: 10) {
                Text(voiceTitle).font(.system(size: 24, weight: .medium, design: .rounded))
                    .accessibilityIdentifier("GPTLive voice state")
                Text(voiceHint).font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            if !controller.active && !preparing && failure == nil {
                Button(controller.voiceNeedsKey ? "Set up voice" : "Resume voice") { controller.beginVoice() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .accessibilityIdentifier("GPTLive connect")
            }
            Spacer(minLength: hasReview || showTranscript ? 0 : 32)
        }.frame(maxWidth: .infinity)
    }
    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(message, systemImage: "exclamationmark.circle")
                .font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("GPTLive error")
            HStack {
                Button("Voice settings") { controller.showSettings = true }
                Spacer()
                Button("Try again") {
                    if controller.connected { Task { await controller.setMicrophone(true) } }
                    else { controller.beginVoice() }
                }.disabled(preparing || session.state == .closing)
            }
        }.padding(16).background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
    }
    private var voiceControls: some View {
        HStack(spacing: 22) {
            roundButton(showText ? "Hide keyboard" : "Type a message", icon: "keyboard", selected: showText) {
                showText.toggle(); textFocused = showText
            }.accessibilityIdentifier("GPTLive keyboard")
            roundButton(controller.microphone ? "Mute microphone" : "Unmute microphone",
                        icon: controller.microphone ? "mic.fill" : "mic.slash.fill", selected: !controller.microphone, prominent: true) {
                Task { await controller.setMicrophone(!controller.microphone) }
            }.disabled(!controller.connected || controller.simulate || controller.microphoneStarting)
                .accessibilityIdentifier("GPTLive microphone")
            roundButton("End voice", icon: "xmark", prominent: true) { GPTLiveWindowController.close() }
                .disabled(controller.sending).accessibilityIdentifier("GPTLive end")
            roundButton(showTranscript ? "Hide transcript" : "Show transcript", icon: "captions.bubble", selected: showTranscript) {
                showTranscript.toggle()
            }.accessibilityIdentifier("GPTLive transcript toggle")
        }.frame(maxWidth: .infinity)
    }
    private func roundButton(_ title: String, icon: String, selected: Bool = false, prominent: Bool = false,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: prominent ? 21 : 18, weight: .medium))
                .frame(width: prominent ? 58 : 40, height: prominent ? 58 : 40)
                .background(selected ? Color.primary.opacity(0.12) : Color.primary.opacity(prominent ? 0.06 : 0), in: Circle())
                .contentShape(Circle())
        }.buttonStyle(.plain).help(title).accessibilityLabel(title)
    }
    private var textComposer: some View {
        HStack(alignment: .bottom, spacing: 12) {
            TextField("Message GPT-Live…", text: $controller.input, axis: .vertical)
                .lineLimit(1...4).textFieldStyle(.plain).focused($textFocused)
                .onSubmit { submitText() }.accessibilityIdentifier("GPTLive request")
            Button(action: submitText) { Image(systemName: "arrow.up.circle.fill").font(.system(size: 27)) }
                .buttonStyle(.plain).help("Send message").accessibilityLabel("Send message")
                .disabled(!controller.connected || session.backendBusy || controller.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || controller.input.count > 8000)
                .accessibilityIdentifier("GPTLive ask")
        }.padding(14).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Color.primary.opacity(0.08)))
    }
    private func submitText() {
        guard controller.connected, !session.backendBusy else { return }
        showTranscript = true
        Task { await controller.ask() }
    }
    private var transcript: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Transcript").font(.headline)
            if session.transcript.isEmpty && controller.fixtureTranscript.isEmpty {
                Text("Your conversation will appear here.").foregroundStyle(.secondary)
            }
            ForEach(session.transcript) { entry in
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.role == "user" ? "You" : entry.role == "assistant" ? "GPT-Live" : entry.role.capitalized)
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(entry.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
                    .background(Color.primary.opacity(entry.role == "user" ? 0.06 : 0.025), in: RoundedRectangle(cornerRadius: 16))
            }
            ForEach(Array(controller.fixtureTranscript.enumerated()), id: \.offset) { _, text in
                Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(14)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
            }
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("GPTLive transcript")
    }
    private var settings: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(controller.voiceNeedsKey ? "Set up voice" : "Voice settings").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { controller.showSettings = false }.keyboardShortcut(.cancelAction)
            }
            Form {
                Section("OpenAI API key") {
                    SecureField("API key", text: $controller.apiKey).textFieldStyle(.roundedBorder)
                        .disabled(controller.active).accessibilityIdentifier("GPTLive API key")
                    Toggle("Remember in Keychain", isOn: $controller.rememberKey).disabled(controller.active)
                    Text(controller.keyStatus.isEmpty ? "Your key connects directly to OpenAI from this Mac." : controller.keyStatus)
                        .font(.caption).foregroundStyle(.secondary)
                    if !controller.active {
                        HStack {
                            Button("Save key") { controller.saveKey() }.disabled(controller.apiKey.isEmpty)
                            Button("Forget key") { controller.forgetKey() }
                        }
                    }
                }
                Section("Audio") {
                    Toggle("Play voice replies", isOn: $controller.speaker)
                    Text("Uses your Mac’s current microphone and speakers. Use headphones with remote or virtual audio devices.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("App access") {
                    Text("Voice can find conversations, review replies, and prepare messages across msgblast. You approve messages before they’re sent.")
                        .font(.callout)
                    Text("OpenAI API usage is billed to your key. Attachment contents are not shared.")
                        .font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("Preview app state", isExpanded: $showContext) {
                        Button("Refresh") { contextPreview = controller.appStateJSON() }
                        Text(contextPreview).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                }
                if model.demo {
                    Section("Demo") {
                        Toggle("Simulate GPT-Live", isOn: $controller.simulate).disabled(controller.active)
                        Button("Create sample conversation") { Task { await controller.createSampleConversation() } }
                            .disabled(controller.active || model.busy).accessibilityIdentifier("GPTLive create sample")
                    }
                }
                Section("Session") {
                    LabeledContent("Models", value: "GPT-Live 1 · GPT-6 Luna")
                    Text(session.usageSummary).font(.caption).foregroundStyle(.secondary)
                    if controller.active {
                        Button("Disconnect to change setup") { Task { await controller.disconnect() } }
                            .disabled(session.state == .closing)
                    }
                }
            }.formStyle(.grouped)
            if !controller.active {
                Button("Start voice") { controller.beginVoice() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!controller.simulate && controller.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("GPTLive connect")
            }
        }.padding(24).frame(width: 470, height: 590)
    }
    private var draft: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Review message", systemImage: "square.and.pencil").font(.headline)
            Text("Conversation: " + controller.draftConversationTitle).font(.subheadline)
            Text("To: " + controller.draftRecipientName).font(.subheadline.bold())
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: Binding(get: { controller.pendingDraft?.text ?? "" }, set: { controller.editDraft($0) }))
                .font(.body).frame(minHeight: 100, maxHeight: 180).scrollContentBackground(.hidden)
                .padding(8).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .disabled(controller.sending).accessibilityIdentifier("GPTLive reviewed draft")
            VStack(alignment: .leading, spacing: 10) {
                Text("Nothing is sent until you click Send.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Discard") { controller.discardDraft() }.disabled(controller.sending)
                    Button(model.demo ? "Send (simulated)" : "Send message") {
                        Task { await controller.sendDraft() }
                    }.buttonStyle(.borderedProminent).disabled(!controller.canSendDraft)
                        .accessibilityIdentifier("GPTLive send draft")
                }
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
}

/// Drawn with native shapes; movement follows measured audio, and respects Reduce Motion.
private struct GPTLiveVoiceOrb: View {
    let level: Double
    let active: Bool
    let preparing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion || (!active && !preparing))) { timeline in
            let phase = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            let breath = active || preparing ? sin(phase * 1.6) * 0.025 : 0
            ZStack {
                Circle().fill(Color.cyan.opacity(0.08)).scaleEffect(1.12 + level * 0.12)
                Circle().fill(
                    RadialGradient(colors: [Color(red: 0.65, green: 0.93, blue: 1),
                                            Color(red: 0.15, green: 0.60, blue: 0.90),
                                            Color(red: 0.14, green: 0.30, blue: 0.66)],
                                   center: .init(x: 0.32 + breath, y: 0.25), startRadius: 0, endRadius: 190))
                    .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                    .shadow(color: .blue.opacity(active ? 0.18 : 0.08), radius: 20, y: 10)
                HStack(spacing: 7) {
                    ForEach(0..<5) { index in
                        Capsule().fill(.white.opacity(0.92))
                            .frame(width: 7, height: 10 + level * (18 + 32 * abs(sin(phase * 3 + Double(index) * 0.8))))
                    }
                }
            }.scaleEffect(1 + breath + level * 0.035)
                .saturation(active || preparing ? 1 : 0.5)
        }
    }
}
