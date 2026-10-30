import SwiftUI

/// Proposes at most `width` to its content and takes the content's own size, so a bubble
/// wraps at 78 percent of the screen yet hugs short text.
struct MaxWidth: Layout {
    var width: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(ProposedViewSize(width: min(proposal.width ?? width, width), height: proposal.height)) ?? .zero
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// Messages' bubble: an 18 pt continuous rounded rectangle; the last bubble of a run carries
/// the curved hook at its bottom outer corner (bottom right for yours, bottom left for
/// replies). The body and hook are one path, so the silhouette is continuous: the outer edge
/// runs straight down, curls out about 5 pt to a softly rounded tip on the baseline, and
/// sweeps back up and in to rejoin the bottom edge, with no straight sides or sharp vertex.
struct BubbleShape: Shape {
    var mine: Bool
    var tail: Bool
    func path(in rect: CGRect) -> Path {
        let r = min(Space.cornerBubble, rect.height / 2)
        guard tail else { return Path(roundedRect: rect, cornerRadius: r, style: .continuous) }
        // Drawn for an outgoing bubble, then mirrored for a reply. The hook scales with the
        // corner, so a one-line bubble keeps Messages' proportions.
        let k = r / Space.cornerBubble
        let x0 = rect.minX, y0 = rect.minY, x1 = rect.maxX, y1 = rect.maxY
        var p = Path()
        p.move(to: CGPoint(x: x0 + r, y: y0))
        p.addLine(to: CGPoint(x: x1 - r, y: y0))
        p.addArc(tangent1End: CGPoint(x: x1, y: y0), tangent2End: CGPoint(x: x1, y: y0 + r), radius: r)
        // The outer edge continues straight down, then curls out to the tip.
        p.addLine(to: CGPoint(x: x1, y: max(y0 + r, y1 - 14 * k)))
        p.addCurve(to: CGPoint(x: x1 + 5 * k, y: y1 - 0.3 * k),
                   control1: CGPoint(x: x1, y: y1 - 5 * k), control2: CGPoint(x: x1 + 1.8 * k, y: y1 - 1.2 * k))
        // A softly rounded tip on the baseline.
        p.addQuadCurve(to: CGPoint(x: x1 + 3.4 * k, y: y1 + 0.6 * k), control: CGPoint(x: x1 + 6.4 * k, y: y1 + 0.6 * k))
        // Back under the bubble and up into a shallow notch, then down into the bottom edge.
        p.addCurve(to: CGPoint(x: x1 - 6.5 * k, y: y1 - 3.4 * k),
                   control1: CGPoint(x: x1 + 0.4 * k, y: y1 + 0.6 * k), control2: CGPoint(x: x1 - 3 * k, y: y1 - 1.4 * k))
        p.addCurve(to: CGPoint(x: x1 - 17 * k, y: y1),
                   control1: CGPoint(x: x1 - 9.5 * k, y: y1 - 5 * k), control2: CGPoint(x: x1 - 13 * k, y: y1))
        p.addLine(to: CGPoint(x: x0 + r, y: y1))
        p.addArc(tangent1End: CGPoint(x: x0, y: y1), tangent2End: CGPoint(x: x0, y: y1 - r), radius: r)
        p.addLine(to: CGPoint(x: x0, y: y0 + r))
        p.addArc(tangent1End: CGPoint(x: x0, y: y0), tangent2End: CGPoint(x: x0 + r, y: y0), radius: r)
        p.closeSubpath()
        return mine ? p : p.applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: rect.minX + rect.maxX, ty: 0))
    }
}

/// One spacing system for every screen. Lists, margins and the pairing screen keep the
/// 4/8/16 pt grid; the thread, the compose bar and the inbox rows use Messages' own measured
/// metrics, which are tighter. Views use these names, never literal numbers.
enum Space {
    /// Horizontal screen margin; equals the list content inset.
    static let screen: CGFloat = 16
    /// Inside bubbles, notices and cards.
    static let inset: CGFloat = 12
    /// Between siblings.
    static let gap: CGFloat = 8
    /// Label to caption, badge to text.
    static let tight: CGFloat = 4
    /// Between stacked groups (pairing screen, time headers).
    static let section: CGFloat = 24
    /// Consecutive bubbles from one sender, as Messages groups them; also ring widths.
    static let hairline: CGFloat = 2

    /// Messages' thread metrics: 18 pt corners, 12 × 7 text inset, 2 pt within a run, 8 pt
    /// between runs and after a status row, 12 pt above and below a time header.
    static let cornerBubble: CGFloat = 18
    static let bubbleH: CGFloat = 12
    static let bubbleV: CGFloat = 7
    static let run: CGFloat = 2
    static let runGap: CGFloat = 8
    static let separator: CGFloat = 12
    /// Bubbles take at most 75 percent of the thread's width, incoming and outgoing alike.
    static let bubbleMax: CGFloat = 0.75
    /// In groups the incoming avatar sits 8 pt from the screen edge with 6 pt to its bubble
    /// (so the bubble starts at 42 pt); the red Not sent mark is 6 pt from its bubble.
    static let threadAvatarEdge: CGFloat = 8
    static let beside: CGFloat = 6
    /// Sender name above its bubble, status row below it, quote block above it.
    static let attached: CGFloat = 2
    static let quoteGap: CGFloat = 4
    /// Thread type: sender names and time headers 11 pt, quotes 10 pt, the pinned prompt 15 pt.
    static let threadCaption: CGFloat = 11
    static let quoteText: CGFloat = 10
    static let pinnedText: CGFloat = 15
    static let pinnedV: CGFloat = 10
    /// A tapback pill's height at the default size; all but the bubble's top inset rises above it.
    static let reactionPill: CGFloat = 26
    /// The red Not sent mark beside a bubble.
    static let notSentMark: CGFloat = 20
    /// Typing bubble: 7 pt dots 4 pt apart, 36 pt tall.
    static let typingDot: CGFloat = 7
    static let typingHeight: CGFloat = 36

    /// Notices.
    static let corner: CGFloat = 16
    static let cornerCard: CGFloat = 12

    /// The compose field's minimum height; the plus and Send circles beside it match it.
    static let fieldHeight: CGFloat = 36
    /// Compose bar: 8 pt from the screen edges and between its three elements, 6 pt above and
    /// below; inside the field the badge starts 10 pt in and text without one 12 pt in.
    static let barEdge: CGFloat = 8
    static let barV: CGFloat = 6
    static let fieldBadgeInset: CGFloat = 10
    static let fieldTextInset: CGFloat = 12
    /// Glyphs in and beside the compose field, and the agent badge inside it.
    static let glyph: CGFloat = 20
    static let badge: CGFloat = 18
    /// Minimum tap target.
    static let control: CGFloat = 44

    static let avatarRow: CGFloat = 40
    /// The avatar beside an incoming run in a group.
    static let avatarThread: CGFloat = 28
    /// Rows in the Details sheet's shared content lists.
    static let avatarList: CGFloat = 30
    /// Header avatars: each in a group's cluster (overlapping by 8 pt), and a direct thread's one.
    static let avatarHeader: CGFloat = 36
    static let avatarHeaderDirect: CGFloat = 40
    /// Inbox rows, measured from Messages on iOS 26: a 50 pt avatar 20 pt from the edge, the
    /// unread dot (10 pt) 6 pt from the edge, text 14 pt after the avatar, 12 pt above and
    /// below; a group's two circles are 28 pt inside the 50 pt frame.
    static let avatarInbox: CGFloat = 50
    static let avatarGroup: CGFloat = 28
    static let inboxAvatarEdge: CGFloat = 20
    static let unreadDot: CGFloat = 10
    static let unreadEdge: CGFloat = 6
    static let inboxTextGap: CGFloat = 14
    static let inboxRowV: CGFloat = 12
    static let avatarInline: CGFloat = 22
    static let avatarChip: CGFloat = 16
    /// The status badge on a send-status glyph (Messages: 9 pt, scaled with the caption).
    static let statusBadge: CGFloat = 9
    /// New Conversation and Details rows: the screen margin, 10 pt above and below (owner's grid).
    static let row = EdgeInsets(top: 10, leading: screen, bottom: 10, trailing: screen)

    /// A photo shown inline under a message.
    static let inlinePhoto: CGFloat = 240
    /// The app mark on the pairing screen.
    static let hero: CGFloat = 96
    /// Popover text width.
    static let popoverWidth: CGFloat = 296
}

extension Font {
    /// A fixed Messages size that still follows Dynamic Type, scaled like `style`.
    static func scaled(_ size: CGFloat, weight: UIFont.Weight = .regular, relativeTo style: UIFont.TextStyle) -> Font {
        Font(UIFontMetrics(forTextStyle: style).scaledFont(for: .systemFont(ofSize: size, weight: weight)) as CTFont)
    }
}
