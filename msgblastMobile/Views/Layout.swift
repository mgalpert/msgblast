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

    /// Bubbles and notices.
    static let corner: CGFloat = 16
    static let cornerCard: CGFloat = 12

    /// The compose field's minimum height, and the send and plus buttons inside or beside it;
    /// Send sits (fieldHeight - fieldButton) / 2 = 3 pt from the capsule's edge.
    static let fieldHeight: CGFloat = 36
    static let fieldButton: CGFloat = 30
    /// Minimum tap target.
    static let control: CGFloat = 44

    static let avatarRow: CGFloat = 40
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

    /// The app mark on the pairing screen.
    static let hero: CGFloat = 96
    /// Popover text width.
    static let popoverWidth: CGFloat = 296
    /// Bubbles take at most this share of the conversation's width.
    static let bubbleWidth: CGFloat = 0.78
}
