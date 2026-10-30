import SwiftUI
import msgblastMobileKit

struct RootView: View {
    @ObservedObject var app: MobileApp
    @Binding var incomingLink: String?
    /// The pairing sheet over an already paired Mac. Its own state, so consuming the link
    /// never closes it; only a successful pairing or Cancel does.
    @State private var showingRepair = false
    /// Where to open; production opens on the inbox.
    var launchScreen: LaunchScreen = .inbox
    @State private var path: [UUID] = []

    var body: some View {
        Group {
            if app.connection.pairedMac == nil {
                NavigationStack { PairingView(app: app, incomingLink: $incomingLink, startPasting: launchScreen == .pastePairingLink) }
            } else {
                NavigationStack(path: $path) { InboxView(app: app, launchScreen: launchScreen) }
            }
        }
        .sheet(isPresented: $showingRepair) {
            NavigationStack { PairingView(app: app, incomingLink: $incomingLink, close: { showingRepair = false }) }
                .interactiveDismissDisabled()  // Closes only on success or Cancel.
        }
        .onAppear {
            presentRepairIfNeeded()
            if case .conversation(let id) = launchScreen, path.isEmpty { path = [id] }
        }
        .onChange(of: incomingLink) { _, _ in presentRepairIfNeeded() }
    }
}

extension RootView {
    /// A link that arrives while a Mac is paired opens the pairing sheet. When no Mac is
    /// paired the root pairing screen reads it instead.
    fileprivate func presentRepairIfNeeded() {
        if incomingLink != nil && app.connection.pairedMac != nil { showingRepair = true }
    }
}

/// Where the app opens. Production always opens on the inbox (or pairing).
enum LaunchScreen: Equatable {
    case inbox, conversation(UUID), newConversation, settings, pastePairingLink
}

/// The connection status as the navigation subtitle, where Mail and Messages put theirs:
/// "Reconnecting…", "Mac Locked · 40s ago". Nothing when connected.
struct MacStatusSubtitle: ViewModifier {
    @ObservedObject var app: MobileApp
    @State private var now = Date()
    func body(content: Content) -> some View {
        let state = app.store.projection.macLocked && app.connection.state.canSend ? MacConnectionState.macLocked : app.connection.state
        let subtitle = state.navigationSubtitle(lastHeard: app.connection.lastHeard, reconnectingSince: app.connection.reconnectingSince, now: now)
        content
            .navigationSubtitle(subtitle ?? "")
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    now = Date()
                }
            }
    }
}

extension View {
    func macStatusSubtitle(_ app: MobileApp) -> some View { modifier(MacStatusSubtitle(app: app)) }
}

/// Decoded artwork and what was learned from its pixels, once per image.
final class AvatarArtwork {
    let image: UIImage
    /// An alpha channel with transparent corners: a mark or an app icon, drawn without a disc.
    let transparent: Bool
    /// Average luminance of the opaque pixels, for marks that would vanish on the background.
    let luminance: Double?
    init(_ image: UIImage) {
        self.image = image
        transparent = AvatarImages.cornersTransparent(image)
        luminance = transparent ? image.cgImage.flatMap { ArtworkTone.luminance(of: $0) } : nil
    }
}

/// Decoded artwork, by content reference, so rows do not decode the same bytes again.
@MainActor
enum AvatarImages {
    private static let cache = NSCache<NSString, AvatarArtwork>()

    nonisolated static func cornersTransparent(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage, ![.none, .noneSkipFirst, .noneSkipLast].contains(cg.alphaInfo) else { return false }
        let side = 8
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        let corners = [0, side - 1, side * (side - 1), side * side - 1]
        return corners.contains { pixels[$0 * 4 + 3] < 250 }
    }
    static func artwork(_ ref: String?, store: MobileStore) -> AvatarArtwork? {
        guard let ref, let data = store.avatar(ref) else { return nil }
        if let artwork = cache.object(forKey: ref as NSString) { return artwork }
        guard let image = UIImage(data: data) else { return nil }
        let artwork = AvatarArtwork(image)
        cache.setObject(artwork, forKey: ref as NSString)
        return artwork
    }
}

/// The app's mark for the pairing hero and Settings: `BrandMark`, a flat export of the
/// production icon. The layered app icon itself is never loaded as an image (UIKit
/// asserts on it). Falls back to a symbol when the asset is missing.
struct AppIconImage: View {
    var size: CGFloat = Space.hero
    static let image = UIImage(named: "BrandMark")
    var body: some View {
        if let image = Self.image {
            Image(uiImage: image)
                .resizable()
                .frame(width: size, height: size)
                // The icon's own squircle: 22 pt at 96 pt, scaled with the size (icon geometry, not spacing).
                .clipShape(RoundedRectangle(cornerRadius: size * 22 / 96, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: size / 16, y: size / 32)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "qrcode.viewfinder").font(.system(size: size * 0.66, weight: .light)).foregroundStyle(.tint)
        }
    }
}

/// A small ⓘ that shows the Mac's full reason in a popover, also on iPhone.
struct DetailButton: View {
    var title: String = "Details"
    var detail: String
    @State private var showing = false
    var body: some View {
        Button { showing = true } label: { Image(systemName: "info.circle") }
            .buttonStyle(.borderless)
            .accessibilityLabel(title)
            .popover(isPresented: $showing) { DetailPopover(text: detail) }
    }
}

struct DetailPopover: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: Space.popoverWidth, alignment: .leading)
            .padding(Space.screen)
            .presentationCompactAdaptation(.popover)
    }
}

/// Initials in a circle, tinted by product so forms of one product read as related.
/// The Mac's artwork for the agent when the phone has it cached, else initials.
struct AgentAvatar: View {
    var name: String
    var product: String
    var size: CGFloat = Space.avatarInline
    var artwork: AvatarArtwork? = nil
    @Environment(\.colorScheme) private var colorScheme

    /// The agent's name, product color and cached artwork from the projection.
    init(app: MobileApp, agentID: String, name: String, size: CGFloat = Space.avatarInline) {
        let agent = app.store.projection.agents[agentID]
        self.init(name: name, product: agent?.product.rawValue ?? agentID, size: size, artwork: AvatarImages.artwork(agent?.avatarRef, store: app.store))
    }
    init(name: String, product: String, size: CGFloat = Space.avatarInline, artwork: AvatarArtwork? = nil) {
        self.name = name; self.product = product; self.size = size; self.artwork = artwork
    }

    var body: some View {
        Group {
            if let artwork, artwork.transparent {
                // Transparent artwork (a mark, an app icon) is drawn as it is: no disc, no clip,
                // unless it would vanish here (a black mark in dark mode, a white one in light).
                Image(uiImage: artwork.image).resizable().scaledToFit()
                    .background {
                        if ArtworkTone.needsBacking(luminance: artwork.luminance, darkBackground: colorScheme == .dark) {
                            Circle().fill(Color(.secondarySystemFill))
                        }
                    }
            } else if let image = artwork?.image {
                Image(uiImage: image).resizable().scaledToFill().clipShape(Circle())
            } else {
                // No letter below 11 pt: small avatars are a plain color.
                Text(size * 0.45 >= 11 ? String(name.prefix(1)).uppercased() : "")
                    .font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(Self.color(product))
                    .clipShape(Circle())
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
    static func color(_ product: String) -> Color {
        let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .indigo, .brown, .cyan, .mint]
        // Stable across launches (String.hashValue is seeded per process).
        return palette[product.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % palette.count]
    }
}
