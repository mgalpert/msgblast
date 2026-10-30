import SwiftUI
import AppKit
@preconcurrency import LinkPresentation
import msgblastCore

enum MessageAppearance {
    static let outgoingBubbleColor = Color(nsColor: .systemBlue)
    static let incomingBubbleColor = Color(nsColor: NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(srgbRed: 59 / 255, green: 59 / 255, blue: 61 / 255, alpha: 1)
        }
        return NSColor(srgbRed: 233 / 255, green: 233 / 255, blue: 235 / 255, alpha: 1)
    })
}

@MainActor
final class LinkPreviewStore: ObservableObject {
    @Published private(set) var metadata: [URL: LPLinkMetadata] = [:]
    private var requested: Set<URL> = []

    func load(_ url: URL) async {
        guard requested.insert(url).inserted else { return }
        let provider = LPMetadataProvider()
        provider.timeout = 15
        do { metadata[url] = try await provider.startFetchingMetadata(for: url) }
        catch {
            // A link remains usable when the website cannot provide a preview.
            let fallback = LPLinkMetadata()
            fallback.originalURL = url; fallback.url = url; fallback.title = url.host
            metadata[url] = fallback
        }
    }
}

struct NativeLinkPreview: NSViewRepresentable {
    let url: URL
    let metadata: LPLinkMetadata?
    func makeNSView(context: Context) -> LPLinkView { LPLinkView(url: url) }
    func updateNSView(_ view: LPLinkView, context: Context) {
        if let metadata, view.metadata != metadata { view.metadata = metadata }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: LPLinkView, context: Context) -> CGSize? {
        let width = min(proposal.width ?? 320, 320)
        let size = view.intrinsicContentSize
        let height = size.width > 0 && size.height > 0 ? size.height * min(1, width / size.width) : 80
        return CGSize(width: width, height: max(60, height))
    }
}

struct RichLinkView: View {
    @ObservedObject var store: LinkPreviewStore
    let url: URL
    var body: some View {
        NativeLinkPreview(url: url, metadata: store.metadata[url])
            .fixedSize(horizontal: false, vertical: true)
            .task(id: url) { await store.load(url) }
    }
}

struct ReactionBadge: View {
    let reactions: [MessageReaction]
    var body: some View {
        HStack(spacing: -4) {
            ForEach(reactions) { reaction in
                Text(reaction.emoji).font(.system(size: 18))
                    .frame(width: 32, height: 32)
                    .background(MessageAppearance.incomingBubbleColor, in: Circle())
                    .overlay(Circle().stroke(Color(nsColor: .textBackgroundColor), lineWidth: 2))
                    .accessibilityLabel("\(reaction.outgoing ? "You" : "Recipient") reacted \(reaction.emoji)")
            }
        }
        .background(alignment: .bottomLeading) {
            Circle().fill(MessageAppearance.incomingBubbleColor).frame(width: 8, height: 8).offset(x: 0, y: 5)
            Circle().fill(MessageAppearance.incomingBubbleColor).frame(width: 4, height: 4).offset(x: -4, y: 11)
        }
    }
}

struct BusinessChoicesView: View {
    @ObservedObject var model: AppModel
    let message: Message
    let member: Member
    let payload: BusinessMessagePayload
    var body: some View {
        let available = model.canChooseBusinessOption(message, member: member, optionID: payload.options.first?.id ?? -1)
        VStack(alignment: .leading, spacing: 8) {
            Text(payload.title).font(.body.weight(.medium)).textSelection(.enabled)
            ForEach(payload.options) { option in
                if payload.kind == .quickReply && !message.outgoing {
                    let selected = model.businessChoiceAttempt(message).map { $0.status == .submitted && $0.optionID == option.id } ?? false
                    Button {
                        Task { await model.chooseBusinessOption(message, member: member, optionID: option.id) }
                    } label: {
                        HStack {
                            Text(option.title)
                            if selected { Image(systemName: "checkmark").accessibilityHidden(true) }
                        }
                    }
                    .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                    .padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Choose \(option.title)")
                    .accessibilityValue(selected ? "Selected" : "Not selected")
                    .disabled(!available)
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        if let section = option.section { Text(section).font(.caption).foregroundStyle(.secondary) }
                        HStack { Text(option.title); if option.selected { Image(systemName: "checkmark").accessibilityLabel("Selected") } }
                        if let subtitle = option.subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                if option.id != payload.options.last?.id { Divider() }
            }
            if let attempt = model.businessChoiceAttempt(message) {
                Text(attempt.detail ?? "Selecting…").font(.caption).foregroundStyle(.secondary)
                if attempt.status == .uncertain {
                    Button("Check in Messages") { model.openMessages(member) }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
                }
            }
            if payload.kind != .quickReply {
                Button("Open in Messages") { model.openMessages(member) }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
            }
        }
        .padding(12).frame(minWidth: 180, maxWidth: 360, alignment: .leading)
        .background(message.outgoing ? Color.blue.opacity(0.15) : MessageAppearance.incomingBubbleColor, in: RoundedRectangle(cornerRadius: 15))
    }
}
