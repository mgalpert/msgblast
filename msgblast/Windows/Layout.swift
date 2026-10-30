import SwiftUI

/// One spacing system for every Mac window. Lists, margins and sheets keep the 4/8/16 pt
/// grid; the thread and the compose bar use Messages on macOS' own metrics, which are
/// tighter. Views use these names, never literal numbers.
enum Space {
    static let screen: CGFloat = 16      // thread side margins
    static let inset: CGFloat = 12       // inside cards and notices
    static let gap: CGFloat = 8
    static let tight: CGFloat = 4
    static let section: CGFloat = 24
    static let hairline: CGFloat = 2
    // Messages' thread metrics
    static let cornerBubble: CGFloat = 18
    static let bubbleH: CGFloat = 12
    static let bubbleV: CGFloat = 7
    static let run: CGFloat = 2          // within a run
    static let runGap: CGFloat = 8       // between runs, and after a status row
    static let separator: CGFloat = 12   // above and below a time header
    static let bubbleMax: CGFloat = 0.75 // of the column width
    static let threadAvatarEdge: CGFloat = 8
    static let beside: CGFloat = 6       // avatar to bubble
    static let attached: CGFloat = 2     // sender name to bubble, bubble to status caption
    static let threadCaption: CGFloat = 11
    static let bodyText: CGFloat = 13    // NSFont.systemFontSize; Messages on macOS
    static let pinnedText: CGFloat = 13
    static let pinnedV: CGFloat = 8
    static let avatarThread: CGFloat = 28
    static let avatarHeader: CGFloat = 36
    static let avatarList: CGFloat = 24
    static let avatarChip: CGFloat = 16
    static let badge: CGFloat = 16       // check badge on a header avatar
    static let checkRing: CGFloat = 1.5  // the hollow check badge's stroke
    static let typingDot: CGFloat = 7
    static let typingHeight: CGFloat = 36
    static let reactionPill: CGFloat = 26
    // Compose bar (phase 2 uses these; define them now)
    static let fieldHeight: CGFloat = 30
    static let barEdge: CGFloat = 12
    static let barV: CGFloat = 8
    static let fieldTextInset: CGFloat = 12
    static let glyph: CGFloat = 16
    static let cornerCard: CGFloat = 10
    static let popoverWidth: CGFloat = 320
    static let columnMin: CGFloat = 320   // a conversation column's least width and height
    static let sheetWidth: CGFloat = 440  // the options sheet
}

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
