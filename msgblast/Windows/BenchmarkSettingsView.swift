import SwiftUI

/// Cloud stream integration boundary: replace this content with the separately
/// consented account controller. Local tracking never activates cloud actions.
struct BenchmarkSettingsView: View {
    var body: some View {
        Form {
            Section("Benchmarks") {
                Text("Local only · account not connected").font(.headline)
                Text("Cloud accounts, private sync, publication, and contributions are not connected in this build.")
                Text("My Stats works on this Mac without an account. Enabling recording or marking a favorite does not upload anything.").foregroundStyle(.secondary)
            }
            Section("Separate choices") {
                Text("Private sync stores selected records for your account. Sharing publishes a reviewed redacted comparison through a direct link. Contribution adds eligible evidence to benchmark statistics.")
                Text("Each requires its own explicit choice. There are no public rankings or rewards in this build.").foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}
