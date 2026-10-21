import ApplicationServices
import Darwin
import Foundation

struct GrokBotNativeState: Codable, Sendable {
    let name: String
    let draft: String
}

enum GrokBotNativeReader {
    static func draftValue(_ value: String, emptyEditor: Bool) -> String {
        value == "\n" && emptyEditor ? "" : value
    }

    static func capture(_ target: DesktopAppConversation.Target) throws -> GrokBotNativeState {
        guard AXIsProcessTrusted() else {
            throw DesktopAppError.unavailable("Allow msgblast Accessibility access to connect your Grok Bot.")
        }
        func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
        }
        func string(_ element: AXUIElement, _ key: String) -> String { attribute(element, key) as? String ?? "" }
        guard let window = DesktopNativeWindowLookup.resolve(target) else { throw DesktopAppError.unavailable("Grok Bot's window could not be read safely. Dismiss dialogs and refresh the bots.") }
        var headings: [AXUIElement] = [], composers: [AXUIElement] = []
        var count = 0
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        func walk(_ element: AXUIElement, depth: Int) throws {
            count += 1
            guard count <= 6000, depth <= 60, ContinuousClock.now < deadline else {
                throw DesktopAppError.unavailable("Grok Bot's accessibility tree is incomplete.")
            }
            let role = string(element, "AXRole")
            guard role != "AXSheet", role != "AXDialog" else {
                throw DesktopAppError.unavailable("Dismiss Grok Bot's dialog before connecting.")
            }
            if role == "AXHeading", string(element, "AXDOMIdentifier") == "sand-conversation-heading" { headings.append(element) }
            if role == "AXTextArea", string(element, "AXDescription") == "Prompt" { composers.append(element) }
            for child in attribute(element, "AXChildren") as? [AXUIElement] ?? [] { try walk(child, depth: depth + 1) }
        }
        try walk(window, depth: 0)
        guard headings.count == 1, composers.count == 1,
              let value = attribute(composers[0], "AXValue") as? String else {
            throw DesktopAppError.unavailable("Grok Bot's selected bot or draft could not be verified.")
        }
        // The heading's AXValue is its level; its title/description names the bot.
        let title = string(headings[0], "AXTitle")
        let name = title.isEmpty ? string(headings[0], "AXDescription") : title
        guard !name.isEmpty else {
            throw DesktopAppError.unavailable("Grok Bot's conversation header is unavailable.")
        }
        let children = attribute(composers[0], "AXChildren") as? [AXUIElement] ?? []
        let emptyEditor = children.count == 1 && Set(attribute(children[0], "AXDOMClassList") as? [String] ?? []).isSuperset(of: ["is-empty", "is-editor-empty"])
            && (attribute(children[0], "AXChildren") as? [AXUIElement] ?? []).isEmpty
        return .init(name: name, draft: draftValue(value, emptyEditor: emptyEditor))
    }
}
