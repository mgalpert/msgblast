import SwiftUI
import AppKit
import msgblastCore

/// Edits a local draft; the containing screen applies it when the user saves.
struct SharingPreferencesView: View {
    @Binding private var preferences: SharingPreferences
    private let showTitle: Bool
    @State private var usageExpanded = false
    @State private var healthExpanded = false
    @State private var showingSharingInformation = false
    private static let appIcon = Bundle.main.url(forResource: "SharingAppIcon", withExtension: "png", subdirectory: "Onboarding")
        .flatMap { NSImage(contentsOf: $0) }

    init(preferences: Binding<SharingPreferences>, showTitle: Bool = true) {
        _preferences = preferences
        self.showTitle = showTitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: showTitle ? 36 : 24) {
            if showTitle {
                VStack(spacing: 24) {
                    if let appIcon = Self.appIcon {
                        Image(nsImage: appIcon).resizable().interpolation(.high).antialiased(true)
                            .scaledToFit().frame(width: 80, height: 80)
                            .accessibilityHidden(true)
                    }
                    VStack(spacing: 16) {
                        Text("Help improve msgblast").font(.system(size: 30, weight: .bold))
                        Text("Choose what anonymous data you share to improve open source msgblast.")
                            .font(.body).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: showTitle ? 28 : 20) {
                sharingGroup(
                    symbol: "chart.bar.xaxis",
                    title: "Share usage statistics",
                    description: "Agents you use, and how often you use msgblast.",
                    reassurance: "We never send your conversations to our analytics.",
                    selected: $preferences.usage,
                    partiallySelected: usagePartial,
                    expanded: $usageExpanded
                ) {
                    choice("Agent usage", description: "Known agent types, counts, and setup progress, without personal names.", selected: $preferences.agentUsage)
                    choice("Message counts", description: "How many messages you send, without their contents.", selected: $preferences.messageCounts)
                    choice("Activity", description: "A random installation ID connects usage across days.", selected: $preferences.activity)
                }

                sharingGroup(
                    symbol: "heart.text.square",
                    title: "Share app health statistics",
                    description: "Errors and operation times that help us improve the app.",
                    selected: $preferences.health,
                    partiallySelected: healthPartial,
                    expanded: $healthExpanded
                ) {
                    choice("Reliability", description: "Failure categories, without error text or private details.", selected: $preferences.reliability)
                    choice("Performance", description: "Approximate operation times, without message contents.", selected: $preferences.performance)
                }

            }

            VStack(alignment: showTitle ? .center : .leading, spacing: 10) {
                HStack(spacing: 24) {
                    Button("How sharing works") { showingSharingInformation = true }
                        .buttonStyle(.plain).foregroundStyle(.blue)
                    Link("Privacy policy", destination: URL(string: "https://msgblast.app/privacy/")!)
                }
                .font(.callout)
            }
            .frame(maxWidth: .infinity, alignment: showTitle ? .center : .leading)
        }
        .tint(.blue)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $showingSharingInformation) { SharingInformationView() }
    }

    private var usagePartial: Bool {
        let values = [preferences.agentUsage, preferences.messageCounts, preferences.activity]
        return values.contains(true) && values.contains(false)
    }

    private var healthPartial: Bool {
        preferences.reliability != preferences.performance
    }

    private func sharingGroup<Content: View>(
        symbol: String,
        title: String,
        description: String,
        reassurance: String? = nil,
        selected: Binding<Bool>,
        partiallySelected: Bool,
        expanded: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Group {
            GridRow(alignment: .firstTextBaseline) {
                if showTitle { featureSymbol(symbol) }
                Toggle(title, isOn: selected)
                    .toggleStyle(.checkbox).labelsHidden()
                    .accessibilityLabel(title)
                    .accessibilityValue(partiallySelected ? "Some selected" : selected.wrappedValue ? "All selected" : "None selected")
                    .frame(width: 18, height: 18)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.headline).contentShape(Rectangle())
                        .onTapGesture { selected.wrappedValue.toggle() }
                        .accessibilityHidden(true)
                    Text(description).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    if let reassurance {
                        Text(reassurance).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if partiallySelected {
                        Text("Some selected").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    expanded.wrappedValue.toggle()
                } label: {
                    Image(systemName: expanded.wrappedValue ? "chevron.up" : "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel("\(expanded.wrappedValue ? "Collapse" : "Expand") \(title.lowercased())")
            }
            if expanded.wrappedValue {
                GridRow {
                    if showTitle { Color.clear.frame(width: 44, height: 0).gridCellUnsizedAxes(.vertical) }
                    Color.clear.frame(width: 18, height: 0).gridCellUnsizedAxes(.vertical)
                    VStack(alignment: .leading, spacing: 14, content: content)
                        .frame(maxWidth: .infinity, alignment: .leading).gridCellColumns(2)
                }
            }
        }
    }

    private func featureSymbol(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 30, weight: .regular))
            .foregroundStyle(.blue).frame(width: 44, height: 44)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
            .accessibilityHidden(true)
    }

    private func choice(_ title: String, description: String, selected: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(title, isOn: selected).toggleStyle(.checkbox)
            Text(description).font(.callout).foregroundStyle(.secondary)
                .lineLimit(1).padding(.leading, 20)
        }
    }

}

private struct SharingInformationView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("How sharing works").font(.title2.bold())
            VStack(alignment: .leading, spacing: 20) {
                explanation("Anonymous statistics you choose", "Known agent types and counts, onboarding steps, message counts, activity, errors, and approximate operation times. We never send messages, responses, contacts, custom agent names, or account details to analytics.")
                explanation("Activity across days", "When Activity is on, a random installation ID connects your selected statistics across days. It is not tied to your name or accounts. Turning Activity off removes this ID; turning it back on starts a new one.")
                explanation("Sent privately", "Statistics pass through Cloudflare to msgblast’s private PostHog project. We do not forward your IP address or create a personal profile. Screen recordings are never collected.")
                explanation("You stay in control", "Sharing starts after you save. Change your choices in Settings anytime. Turning a category off stops collection and clears unsent statistics. All app features work with sharing off.")
            }
            Divider()
            HStack {
                Link("View source code", destination: URL(string: "https://github.com/mgalpert/msgblast")!)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(32)
        .frame(width: 560)
        .onExitCommand { dismiss() }
    }

    private func explanation(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(text).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
