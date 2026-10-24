import Foundation

struct GrokBotNativeState: Codable, Equatable, Sendable {
    let name: String
    let draft: String
    var composerFocused: Bool? = nil
}

enum GrokBotAppProfile {
    static func draftValue(_ value: String, emptyEditor: Bool) -> String {
        if value == "\n", emptyEditor { return "" }
        // Grok's editor exposes one extra AX newline after a trailing hard
        // break. Remove that one padding character, preserving real blank lines.
        return value.hasSuffix("\n\n") ? String(value.dropLast()) : value
    }

    static func capture(_ target: DesktopAppConversation.Target) throws -> GrokBotNativeState {
        try parse(DesktopAccessibility.capture(target, app: .grokBot))
    }
    static func parse(_ root: DesktopAccessibilityNode) throws -> GrokBotNativeState {
        let nodes = root.descendants
        guard !nodes.contains(where: { ["AXSheet", "AXDialog"].contains($0.role) }) else { throw DesktopAppError.unavailable("Dismiss Grok Bot's dialog before connecting.") }
        let headings = nodes.filter { $0.role == "AXHeading" && $0.domID == "sand-conversation-heading" }
        let fields = nodes.filter { DesktopAccessibility.isComposer($0, app: .grokBot) }
        guard headings.count == 1, !headings[0].label.isEmpty, fields.count == 1, let field = fields.first, let value = field.value else {
            throw DesktopAppError.unavailable("Grok Bot's selected bot or draft could not be verified.")
        }
        let empty = field.children.count == 1 && Set(field.children[0].classes).isSuperset(of: ["is-empty", "is-editor-empty"]) && field.children[0].children.isEmpty
        return .init(name: headings[0].label, draft: draftValue(value, emptyEditor: empty), composerFocused: field.focused)
    }
}
