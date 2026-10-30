import AppKit
import SwiftUI
import msgblastCore

struct GPTLiveView: View {
    @ObservedObject var controller: GPTLiveController
    @ObservedObject private var session: GPTLiveSession
    @ObservedObject private var audio: GPTLiveAudio
    @ObservedObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showDebug = false
    @State private var showContext = false
    @State private var contextPreview = ""

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
        if controller.microphoneStarting { return controller.connected ? "Starting your microphone…" : "Allow microphone access" }
        if preparing { return "Connecting…" }
        if failure != nil { return audio.permissionDenied ? "Microphone access needed" : "Voice paused" }
        if controller.sending { return "Sending your message…" }
        if hasReview { return "Ready for your review" }
        if controller.simulate && controller.connected { return "Demo conversation" }
        if speaking { return "Speaking" }
        if session.backendBusy { return "Working on it…" }
        if controller.microphone { return "Listening" }
        if controller.connected { return "Microphone muted" }
        return "Ready when you are"
    }
    private var voiceHint: String {
        if controller.microphoneStarting { return "Approve the macOS prompt to start voice." }
        if preparing { return "Getting voice ready." }
        if hasReview { return "Check the message below before sending." }
        if controller.simulate { return "Sample replies and simulated sends. No microphone or API use." }
        if controller.microphone { return "Talk naturally. You can interrupt at any time." }
        if controller.connected { return "Turn on your mic to keep talking." }
        if controller.voiceNeedsKey { return "Add your OpenAI key in settings to get started." }
        return "Across msgblast"
    }
    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 20) {
                        voiceStage
                        if let failure { errorCard(failure) }
                        if let reviewed = controller.pendingDraft { draft(reviewed).id("review") }
                        if controller.pendingEndConversationID != nil { endConversationReview.id("end-review") }
                        if controller.showTranscript { transcript }
                        if !controller.status.isEmpty && !controller.status.hasPrefix("Connected") && !controller.status.hasPrefix("Demo session") && controller.status != "Session ended" {
                            Text(controller.status).font(.callout).foregroundStyle(.secondary)
                                .textSelection(.enabled).accessibilityIdentifier("GPTLive status")
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }.padding(.horizontal, 18).padding(.bottom, 16)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: controller.pendingDraft?.id) { _, id in
                    if id != nil { withAnimation(reduceMotion ? nil : .easeInOut) { proxy.scrollTo("review", anchor: .top) } }
                }
                .onChange(of: controller.pendingEndConversationID) { _, id in
                    if id != nil { proxy.scrollTo("end-review", anchor: .top) }
                }
                .onChange(of: session.transcript.last?.text) { if controller.showTranscript { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
            Divider()
            voiceControls.padding(.horizontal, 18).padding(.vertical, 18)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $controller.showSettings) { settings }
        .sheet(isPresented: $showDebug) { GPTLiveDebugView(activity: controller.activity) }
        .onChange(of: controller.selectedComparisonID) { controller.selectedRecipientID = "all" }
        .onChange(of: showContext) { _, expanded in if expanded { contextPreview = controller.appStateJSON() } }
        .onChange(of: controller.speaker) { if !controller.speaker { audio.stopPlayback() } }
    }
    private var header: some View {
        HStack {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 15, weight: .medium)).foregroundStyle(.white)
                .frame(width: 28, height: 28).background(.green.gradient, in: RoundedRectangle(cornerRadius: 7))
                .accessibilityHidden(true)
            Text("GPT-Live").font(.headline)
            Spacer()
            Menu {
                Button("Voice settings…", systemImage: "slider.horizontal.3") { controller.showSettings = true }
                Toggle("Show transcript", isOn: $controller.showTranscript)
                    .accessibilityIdentifier("GPTLive transcript toggle")
                Divider()
                Button("Activity…", systemImage: "list.bullet.rectangle") { showDebug = true }
                    .accessibilityIdentifier("GPTLive debug")
            } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Voice options").accessibilityLabel("Voice options").accessibilityIdentifier("GPTLive options")
        }.padding(.horizontal, 18).padding(.vertical, 14)
            .overlay(alignment: .bottom) { Divider() }
    }
    private var voiceStage: some View {
        VStack(spacing: 18) {
            GPTLiveVoiceMark(level: max(audio.inputLevel, audio.outputLevel),
                             active: controller.microphone || speaking, preparing: preparing,
                             compact: hasReview || controller.showTranscript)
                .accessibilityHidden(true)
            VStack(spacing: 7) {
                Text(voiceTitle).font(.system(size: 21, weight: .semibold))
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("GPTLive voice state")
                Text(voiceHint).font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            if !controller.active && !preparing && failure == nil {
                Button(controller.voiceNeedsKey ? "Set up voice" : "Resume voice") { controller.beginVoice() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .accessibilityIdentifier("GPTLive connect")
            }
        }.frame(maxWidth: .infinity).padding(.top, hasReview || controller.showTranscript ? 24 : 46)
            .padding(.bottom, 12)
    }
    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(message, systemImage: "exclamationmark.circle")
                .font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("GPTLive error")
            HStack {
                if audio.permissionDenied {
                    Button("Microphone settings") { model.setting("Privacy_Microphone") }
                } else {
                    Button("Voice settings") { controller.showSettings = true }
                }
                Spacer()
                Button("Try again") {
                    if controller.connected { Task { await controller.setMicrophone(true) } }
                    else { controller.beginVoice() }
                }.disabled(preparing || session.state == .closing)
            }
        }.padding(16).background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
    }
    private var voiceControls: some View {
        HStack(spacing: 36) {
            voiceButton(controller.microphone ? "Mute" : "Unmute",
                        help: controller.microphone ? "Mute microphone" : "Unmute microphone",
                        icon: controller.microphone ? "mic.fill" : "mic.slash.fill",
                        selected: controller.microphone) {
                controller.toggleMicrophone()
            }.disabled(!controller.canToggleMicrophone)
                .accessibilityIdentifier("GPTLive microphone")
            voiceButton("End", help: "End voice", icon: "xmark", endsVoice: true) { controller.dismiss() }
                .disabled(controller.sending).accessibilityIdentifier("GPTLive end")
        }.frame(maxWidth: .infinity)
    }
    private func voiceButton(_ title: String, help: String, icon: String, selected: Bool = false,
                             endsVoice: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 19, weight: .medium))
                    .foregroundStyle(endsVoice ? Color.white : selected ? Color.accentColor : Color.primary)
                    .frame(width: 48, height: 48)
                    .background(endsVoice ? Color.red : selected ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.06), in: Circle())
                Text(title).font(.caption).foregroundStyle(.secondary)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).help(help).accessibilityLabel(help)
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
    private func draft(_ reviewed: GPTLiveDraft) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Review message", systemImage: "square.and.pencil").font(.headline)
            Text("Conversation: " + controller.draftConversationTitle).font(.subheadline)
            Text("To: " + controller.draftRecipientName).font(.subheadline.bold())
                .fixedSize(horizontal: false, vertical: true)
            Text(reviewed.text)
                .font(.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier("GPTLive reviewed draft")
            Text("Ask me to change anything by voice.").font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                Text("Nothing is sent until you click Send.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Discard") { controller.discardDraft() }.disabled(controller.sending)
                    Button(model.demo ? "Send (simulated)" : "Send message") {
                        Task { await controller.sendDraft(reviewed) }
                    }.buttonStyle(.borderedProminent).disabled(!controller.canSendDraft)
                        .accessibilityIdentifier("GPTLive send draft")
                }
            }
        }.padding(14).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.06)))
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

/// Native speech bubbles echo the app mark. The waveform follows measured audio.
private struct GPTLiveVoiceMark: View {
    let level: Double
    let active: Bool
    let preparing: Bool
    let compact: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(Color.green.opacity(0.035))
                Circle().strokeBorder(Color.green.opacity(active || preparing ? 0.65 : 0.22), lineWidth: 1.5)
                ZStack {
                    Image(systemName: "bubble.left.fill").offset(x: -14, y: -15).opacity(0.35)
                    Image(systemName: "bubble.right.fill").offset(x: 13, y: 0).opacity(0.60)
                    Image(systemName: "bubble.left.fill").offset(x: -1, y: 19)
                }.font(.system(size: compact ? 32 : 42)).foregroundStyle(.green.gradient)
            }.frame(width: compact ? 94 : 132, height: compact ? 94 : 132)
            TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion || !active)) { timeline in
                let phase = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                HStack(spacing: 5) {
                    ForEach(0..<7) { index in
                        Capsule().fill(Color.accentColor.opacity(active ? 1 : 0.35))
                            .frame(width: 4, height: 5 + min(1, max(0, level)) * (12 + 24 * abs(sin(phase * 3 + Double(index) * 0.8))))
                    }
                }.frame(height: 40)
            }
        }
    }
}
