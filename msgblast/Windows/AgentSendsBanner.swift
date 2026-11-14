import SwiftUI
import msgblastCore

/// Above the agents workspace while an outside agent's send runs, with Stop, and while sends are stopped.
struct AgentSendsBanner: View {
    @ObservedObject var activity: AgentControlActivity

    var body: some View {
        if let running = activity.log.running {
            HStack {
                ProgressView().controlSize(.small)
                Text("Sending for an outside agent: \(running.summary)")
                Spacer()
                Button(activity.stopped ? "Stopping after this send" : "Stop Agent Sends") { activity.stopped = true }
                    .disabled(activity.stopped)
                    .help("The send already under way finishes. Nothing new is sent until you allow agent sends again.")
            }.padding(18).background(.bar)
        } else if activity.stopped {
            HStack {
                Text("Agent sends are stopped. Outside agents can still read.").foregroundStyle(.secondary)
                Spacer()
                Button("Allow Agent Sends") { activity.stopped = false }
            }.padding(18).background(.bar)
        }
    }
}

/// Settings → Outside agents: the same Stop switch and what agents sent since msgblast opened.
struct AgentSendsSettings: View {
    @ObservedObject var activity: AgentControlActivity

    var body: some View {
        Toggle("Stop agent sends", isOn: $activity.stopped)
            .help("While on, agents with Full access can still read, but nothing they ask to send goes out.")
        if !activity.log.entries.isEmpty {
            DisclosureGroup("Recent sends") {
                ForEach(activity.log.entries.prefix(10)) { entry in
                    LabeledContent(entry.summary) {
                        Text("\(entry.result ?? "Sending…") · \(entry.started.formatted(date: .omitted, time: .shortened))")
                            .lineLimit(1).truncationMode(.tail)
                    }
                }
            }
        }
    }
}
