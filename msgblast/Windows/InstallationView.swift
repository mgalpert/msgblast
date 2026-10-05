import SwiftUI
import AppKit

struct InstallationView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable().frame(width: 64, height: 64)
            Text("Move msgblast to Applications")
                .font(.system(size: 24, weight: .semibold))
            Text("You’re opening the downloaded copy. Install msgblast before setting up Messages access.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            VStack(alignment: .leading, spacing: 12) {
                Text("1. Quit this copy of msgblast.")
                Text("2. Drag **msgblast.app** to **Applications**.")
                Text("3. Open **msgblast** from Applications.")
            }.padding(.vertical, 8)
            HStack(spacing: 12) {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                }
                Button("Quit msgblast") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 500, minHeight: 420)
    }
}
