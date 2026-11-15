import SwiftUI
import msgblastCore

struct SharingChoiceView: View {
    @ObservedObject var model: AppModel
    @State private var preferences = SharingPreferences()
    @State private var saving = false
    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                ScrollView {
                    SharingPreferencesView(preferences: $preferences)
                        .frame(maxWidth: 640)
                        .padding(.horizontal, 40).padding(.vertical, 36)
                        .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .center)
                }
            }
            if let error = model.error { Text(error).foregroundStyle(.orange).padding(.horizontal, 28) }
            Divider()
            HStack {
                Spacer()
                Button("Continue") {
                    saving = true
                    Task { _ = await model.saveSharingChoices(preferences); saving = false }
                }.buttonStyle(.borderedProminent).controlSize(.large)
                    .keyboardShortcut(.defaultAction).disabled(saving)
            }
            .padding(.trailing, 8)
            .frame(maxWidth: 640).padding(.horizontal, 40).padding(.vertical, 20)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: 840, maxHeight: .infinity)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 740, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { preferences = model.state.sharingConsent?.preferences ?? SharingPreferences() }
    }
}

struct SharingSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var preferences = SharingPreferences()
    @State private var saved = false
    @State private var saving = false
    @State private var saveError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if TelemetryCollector.endpoint(demo: model.demo) == nil {
                Text("Collection is disabled in this preview or source build.").font(.caption).foregroundStyle(.secondary)
            }
            SharingPreferencesView(preferences: $preferences, showTitle: false)
                .disabled(saving).allowsHitTesting(!saving)
            Button(saving ? "Saving…" : saved ? "Choices saved" : "Save choices") {
                let snapshot = preferences
                saving = true
                saveError = nil
                Task {
                    saved = await model.saveSharingChoices(snapshot)
                    if !saved { saveError = model.error ?? "Could not save your choices. Try again." }
                    saving = false
                }
            }.disabled(saved || saving)
            if let saveError { Text(saveError).font(.caption).foregroundStyle(.red) }
            Text("Changes take effect when you save your choices.").font(.caption).foregroundStyle(.secondary)
            Text("All features work with sharing turned off.").font(.caption).foregroundStyle(.secondary)
            if let id = model.state.sharingConsent?.installationID {
                LabeledContent("Installation ID") { Text(id.uuidString).textSelection(.enabled).font(.caption) }
                    .help("Include this ID in a private request to delete previously uploaded Activity data.")
            }
        }
        .onAppear { preferences = model.state.sharingConsent?.preferences ?? SharingPreferences() }
        .onChange(of: preferences) { _, _ in saved = false; saveError = nil }
    }
}
