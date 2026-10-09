import AppKit
import SwiftUI

@MainActor
final class BuildFeatureWindowController: NSObject, NSWindowDelegate {
    private static var current: BuildFeatureWindowController?
    private var hostedWindow: NSWindow?

    static func show() {
        if let window = current?.hostedWindow {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = BuildFeatureWindowController()
        current = controller
        controller.hostedWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    override init() {
        super.init()
        let host = NSHostingView(rootView: BuildFeatureView())
        host.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.contentView = host
        window.title = "Build a New Feature"
        window.minSize = NSSize(width: 500, height: 440)
        if let screen = NSScreen.main {
            window.setContentSize(NSSize(width: min(720, screen.visibleFrame.width),
                                         height: min(760, screen.visibleFrame.height - 40)))
        }
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        hostedWindow = window
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            self.hostedWindow?.delegate = nil
            self.hostedWindow = nil
            if Self.current === self { Self.current = nil }
        }
    }
}

struct BuildFeatureView: View {
    private enum CopyStatus { case idle, copied, failed }
    @State private var idea = ""
    @State private var copyStatus = CopyStatus.idle
    private let repository = URL(string: "https://github.com/mgalpert/msgblast")!
    private let fork = URL(string: "https://github.com/mgalpert/msgblast/fork")!
    private let download = URL(string: "https://github.com/mgalpert/msgblast/archive/refs/heads/main.zip")!
    private let guide = URL(string: "https://github.com/mgalpert/msgblast/blob/main/docs/build-from-source.md")!

    private var prompt: String {
        let feature = idea.trimmingCharacters(in: .whitespacesAndNewlines)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        return """
        I'm using msgblast and want to build a feature for myself, then share it with other users.
        Installed app: msgblast \(version) (build \(build)). Check the source revision separately.

        My feature idea: \(feature.isEmpty ? "[Describe the problem and the behavior you want.]" : feature)

        Use https://github.com/mgalpert/msgblast. Help me fork and clone it locally, or work in my existing clone. Downloading the source ZIP is also an option for personal use; use a Git clone of my fork to contribute.

        Read AGENTS.md, CONTRIBUTING.md, docs/build-from-source.md, docs/architecture.md, and docs/testing.md before making changes. Start from current upstream main for new work, preserve existing edits, and record the base SHA.

        Implement a focused change on a feature branch. Build separate Dev and Demo apps without replacing my installed app or changing its saved data. Use the blue Demo app with sample data for testing and screenshots/video. Dev uses live data. Run the relevant checks and explain their limits.

        Help me run my own build. Then prepare a PR against upstream main with a clear description of the problem and feature, validation, Base-SHA, Evidence-SHA, and Screenshots and Video sections showing this change with accessible images and a short playable video. Follow the repository's current evidence requirements. PR review and app release are separate from using my own build.
        """
    }

    var body: some View {
        let renderedPrompt = prompt
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .top, spacing: 16) {
                        Image(nsImage: NSApplication.shared.applicationIconImage)
                            .resizable().frame(width: 64, height: 64)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Excited to see what you build.")
                                .font(.system(size: 25, weight: .bold))
                            Text("Make msgblast work the way you want. Build it for yourself, then share it with everyone.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Public GitHub repository").font(.headline)
                        Link("github.com/mgalpert/msgblast ↗", destination: repository)
                        HStack(spacing: 16) {
                            Link("Fork on GitHub ↗", destination: fork)
                            Link("Download source ZIP", destination: download)
                        }
                        Text("Clone or download for personal use. Fork to contribute; GitHub sign-in is required.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("What would you like to build?").font(.headline)
                        TextField("e.g. Pin my favorite comparisons", text: $idea, axis: .vertical)
                            .lineLimit(2...4)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Feature idea, optional")
                        Text("Optional — you can add your idea in your coding agent.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 16) {
                            step(1, "Fork or download")
                            Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                            step(2, "Build for yourself")
                            Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                            step(3, "Share a pull request")
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            step(1, "Fork or download")
                            step(2, "Build for yourself")
                            step(3, "Share a pull request")
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Prompt for your coding agent").font(.headline)
                        ScrollView {
                            Text(renderedPrompt)
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .accessibilityIdentifier("Coding agent prompt")
                                .accessibilityLabel("Coding agent prompt")
                                .accessibilityValue(renderedPrompt)
                        }
                        .frame(height: 210)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
                    }
                    HStack(spacing: 12) {
                        Link("Build guide ↗", destination: guide)
                        Text("Mac + Xcode required to run the app.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pull requests are reviewed before they reach everyone.")
                        .font(.caption).foregroundStyle(.secondary)
                    if copyStatus == .copied {
                        Text("Prompt copied. Paste it into your coding agent to get started.")
                            .font(.caption)
                    } else if copyStatus == .failed {
                        Text("Couldn’t copy the prompt. Select the preview text and copy it.")
                            .font(.caption)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    NSPasteboard.general.clearContents()
                    copyStatus = NSPasteboard.general.setString(renderedPrompt, forType: .string) ? .copied : .failed
                } label: {
                    Label(copyStatus == .copied ? "Copied" : "Copy Prompt", systemImage: copyStatus == .copied ? "checkmark" : "doc.on.clipboard")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: idea) { copyStatus = .idle }
    }

    private func step(_ number: Int, _ title: String) -> some View {
        HStack(spacing: 8) {
            Text("\(number)").font(.caption.weight(.semibold))
                .frame(width: 24, height: 24)
                .overlay(Circle().stroke(Color(nsColor: .separatorColor)))
            Text(title).font(.callout).fixedSize()
        }
    }
}
