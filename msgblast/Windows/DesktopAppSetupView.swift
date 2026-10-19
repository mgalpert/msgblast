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
                Text("Open the intended conversation in \(app.name), then connect it. \(app == .wabi ? "Only the Wabi AI conversation is supported. " : "")Comparisons share that app conversation and its earlier context. Keep that conversation selected while a request is running.")
                    .font(.caption).foregroundStyle(.secondary)
                if let binding = session.state.desktopConversation {
                    Text("Conversation: \(binding.name)").font(.caption.weight(.semibold))
                }
                Toggle("Enable \(session.name)", isOn: Binding(get: { session.isEnabled }, set: { session.setEnabled($0) }))
                    .toggleStyle(.switch).disabled(busy || session.isSending)
                    .accessibilityIdentifier("Enable \(session.name)")
                HStack {
                    Button(session.state.desktopConversation == nil ? "Connect open conversation" : "Reconnect open conversation") {
                        Task { await session.connectDesktopConversation() }
                    }.disabled(busy || session.loading || session.isSending || !session.isEnabled)
                    if session.loading { ProgressView().controlSize(.small) }
                }
                Text(session.desktopStatus).font(.caption).foregroundStyle(.secondary)
                if !session.fixture {
                    Text("Requires cua-driver with Accessibility permission. Replies are observed text that stayed stable for three seconds; the app may continue working. Foreground input and automatic retries are disabled.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
