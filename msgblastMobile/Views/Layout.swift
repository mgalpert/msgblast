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

/// Messages' bubble: an 18 pt rounded rectangle, with a tail at the bottom outer corner on
/// the last bubble of a run (bottom right for yours, bottom left for replies).
struct BubbleShape: Shape {
    var mine: Bool
    var tail: Bool
    func path(in rect: CGRect) -> Path {
        let path = Path(roundedRect: rect, cornerRadius: min(Space.cornerBubble, rect.height / 2), style: .continuous)
        guard tail else { return path }
        // Drawn for an outgoing bubble, then mirrored for a reply.
        var wedge = Path()
        let x = rect.maxX, y = rect.maxY
        wedge.move(to: CGPoint(x: x - 18, y: y))
        wedge.addLine(to: CGPoint(x: x - 4, y: y))
        wedge.addQuadCurve(to: CGPoint(x: x + 5, y: y + 0.5), control: CGPoint(x: x + 1, y: y + 1))
        wedge.addQuadCurve(to: CGPoint(x: x, y: y - 12), control: CGPoint(x: x - 1, y: y - 3))
        wedge.addLine(to: CGPoint(x: x - 18, y: y - 12))
        wedge.closeSubpath()
        if !mine { wedge = wedge.applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: rect.minX + rect.maxX, ty: 0)) }
        // A union, not an added subpath: opposite windings would punch a hole at the corner.
        return path.union(wedge)
    }
}

/// One spacing system for every screen, on the 4/8 pt grid. Views use these names, never
/// literal numbers, so margins, gaps and corners stay consistent.
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

    /// Messages' bubble metrics: 18 pt corners, 14 × 10 padding, 2 pt within a run,
    /// 10 pt between runs, 16 pt around a time separator.
    static let cornerBubble: CGFloat = 18
    static let bubbleX: CGFloat = 14
    static let bubbleY: CGFloat = 10
    static let run: CGFloat = 2
    static let runGap: CGFloat = 10
    static let separator: CGFloat = 16
    /// Incoming bubbles take at most 72 percent of the width, outgoing 78.
    static let bubbleIncoming: CGFloat = 0.72

    /// Notices.
    static let corner: CGFloat = 16
    static let cornerCard: CGFloat = 12

    /// The compose field's minimum height, and the send and plus buttons inside or beside it;
    /// Send sits (fieldHeight - fieldButton) / 2 = 3 pt from the capsule's edge.
    static let fieldHeight: CGFloat = 36
    static let fieldButton: CGFloat = 30
    /// Minimum tap target.
    static let control: CGFloat = 44

    static let avatarRow: CGFloat = 40
    /// The avatar beside an incoming run.
    static let avatarThread: CGFloat = 30
    /// Header avatars: each in a group's cluster (overlapping by 8 pt), and a direct thread's one.
    static let avatarHeader: CGFloat = 36
    static let avatarHeaderDirect: CGFloat = 40
    /// The two circles of a group avatar inside `avatarRow` (the owner's Messages spec: 26 pt).
    static let avatarGroup: CGFloat = 26
    static let avatarInline: CGFloat = 22
    static let avatarChip: CGFloat = 16
    /// The status badge on a send-status glyph (owner's spec: 10 pt, scaled with the caption).
    static let statusBadge: CGFloat = 10
    /// The unread dot and the typing dots.
    static let dot: CGFloat = 8
    /// The inbox's unread column, present on every row so avatars align (owner's grid: 14 pt).
    static let unreadGutter: CGFloat = 14
    /// Inbox and New Conversation rows: the screen margin, 10 pt above and below (owner's grid).
    static let row = EdgeInsets(top: 10, leading: screen, bottom: 10, trailing: screen)

    /// A photo shown inline under a message.
    static let inlinePhoto: CGFloat = 240
    /// The app mark on the pairing screen.
    static let hero: CGFloat = 96
    /// Popover text width.
    static let popoverWidth: CGFloat = 296
    /// Outgoing bubbles take at most this share of the conversation's width.
    static let bubbleWidth: CGFloat = 0.78
}
