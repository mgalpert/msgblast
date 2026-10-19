import SwiftUI
import msgblastCore

struct DesktopAppSetupView: View {
    @ObservedObject var session: WebAgentSession
    var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let app = session.provider.desktopApp {
                Text(session.fixture ? "Simulated desktop conversation · no app contacted" : "Chat here while cua-driver operates \(app.name) in the background.")
                    .font(.caption).foregroundStyle(.secondary)
                Text(app == .muse ? "Open Muse and connect it here. Each comparison creates its own side chat. Saved side-chat IDs let you return to the same conversation after its title changes or msgblast restarts. The first message includes a request reference to verify the new chat. Keep Muse on the current desktop while a request runs." : "Open the intended conversation in \(app.name), then connect it. \(app == .wabi ? "Only the Wabi AI conversation is supported. " : "")Comparisons share that app conversation and its earlier context. Keep that conversation selected while a request is running.")
                    .font(.caption).foregroundStyle(.secondary)
                if let binding = session.state.desktopConversation {
                    let sideChat = session.state.comparisonID.flatMap { session.state.museAppConversations[$0.uuidString] }
                    Text("Conversation: \(app == .muse ? sideChat?.title ?? "New side chat per comparison" : binding.name)").font(.caption.weight(.semibold))
                }
                Toggle("Enable \(session.name)", isOn: Binding(get: { session.isEnabled }, set: { session.setEnabled($0) }))
                    .toggleStyle(.switch).disabled(busy || session.isSending)
                    .accessibilityIdentifier("Enable \(session.name)")
                HStack {
                    Button(app == .muse ? "Connect Muse" : session.state.desktopConversation == nil ? "Connect open conversation" : "Reconnect open conversation") {
                        Task { await session.connectDesktopConversation() }
                    }.disabled(busy || session.loading || session.isSending || !session.isEnabled)
                    if session.loading { ProgressView().controlSize(.small) }
                }
                Text(session.desktopStatus).font(.caption).foregroundStyle(.secondary)
                if !session.fixture {
                    Text("Requires cua-driver with Accessibility permission. \(app == .muse ? "Window-capture access is also needed for resuming chats. Grant msgblast Accessibility permission to verify Muse's side-chat address and exact draft. " : "")Replies are observed text that stayed stable for three seconds; the app may continue working. Foreground input and automatic retries are disabled.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
