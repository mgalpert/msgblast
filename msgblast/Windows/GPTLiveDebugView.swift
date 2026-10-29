import AppKit
import SwiftUI
import UniformTypeIdentifiers
import msgblastCore

struct GPTLiveDebugView: View {
    @ObservedObject var activity: GPTLiveActivityLog
    @Environment(\.dismiss) private var dismiss
    @State private var exportError: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("GPT-Live activity").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Toggle("Debug mode", isOn: $activity.enabled)
                .accessibilityIdentifier("GPTLive debug mode")
            Text(activity.enabled
                 ? "Tool arguments and results are captured from now on. Details and exports may contain conversation text. Credentials and audio are excluded."
                 : "Activity summaries are always available. Turn on Debug mode to inspect future tool arguments and results.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Kept in memory on this Mac. Nothing is saved or shared unless you copy or export it.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            if activity.entries.isEmpty {
                ContentUnavailableView("No activity yet", systemImage: "list.bullet.rectangle", description: Text("Connection events, tool calls, actions, results, errors, and usage appear here."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(activity.entries.reversed()) { entry in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(entry.timestamp, format: .dateTime.hour().minute().second().secondFraction(.fractional(3)))
                                        .monospacedDigit().foregroundStyle(.secondary)
                                    Text(entry.category.uppercased()).fontWeight(.semibold)
                                    Spacer()
                                }.font(.caption)
                                Text(entry.summary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                if let callID = entry.callID {
                                    Text("Call: " + callID).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                                if let detail = entry.detail {
                                    DisclosureGroup("Details") {
                                        Text(detail).font(.system(.caption, design: .monospaced))
                                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.top, 5)
                                    }.accessibilityIdentifier("GPTLive activity details")
                                }
                            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }.accessibilityIdentifier("GPTLive activity log")
            }
            if let exportError { Text(exportError).font(.caption).foregroundStyle(.orange) }
            Divider()
            HStack {
                Text("\(activity.entries.count) events" + (activity.droppedEntryCount > 0 ? " · \(activity.droppedEntryCount) older events removed" : ""))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { activity.clear(); copied = false; exportError = nil }.disabled(activity.entries.isEmpty)
                Button(copied ? "Copied" : "Copy JSON") { copy() }.disabled(activity.entries.isEmpty)
                Button("Export JSON…") { export() }.disabled(activity.entries.isEmpty)
                    .accessibilityIdentifier("GPTLive export activity")
            }
        }.padding(20).frame(minWidth: 600, idealWidth: 760, minHeight: 460, idealHeight: 620)
    }

    private func copy() {
        do {
            let data = try activity.jsonExportData()
            guard let text = String(data: data, encoding: .utf8) else { return }
            NSPasteboard.general.clearContents()
            copied = NSPasteboard.general.setString(text, forType: .string)
            exportError = copied ? nil : "Could not copy activity. Try Export JSON."
        } catch { exportError = "Could not prepare activity for copying." }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.title = "Export GPT-Live activity"
        panel.message = "This file may contain conversation text from debug details."
        panel.nameFieldStringValue = "gptlive-activity.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try activity.jsonExportData().write(to: url, options: .atomic)
                exportError = nil
            } catch { exportError = "Could not save activity to the selected location." }
        }
    }
}
