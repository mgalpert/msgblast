import ApplicationServices
import Foundation
import os

/// Metadata Cua's action snapshots do not expose. One bounded reader serves
/// every profile; app parsers never walk live Accessibility elements themselves.
struct DesktopAccessibilityNode: Sendable {
    var role: String
    var subrole = ""
    var label = ""
    var value: String?
    var id = ""
    var domID = ""
    var classes: [String] = []
    var url: URL?
    var selected = false
    var enabled = true
    var focused = false
    var selectedText: String?
    var frame: DesktopAppSnapshot.Element.Frame?
    var identity: UInt?
    var editorText: String?
    var children: [Self] = []
    var descendants: [Self] {
        var result: [Self] = []
        func append(_ node: Self) {
            result.append(node)
            node.children.forEach(append)
        }
        append(self)
        return result
    }
}

enum DesktopAccessibilityError: LocalizedError {
    case incomplete, invalidElement
    var errorDescription: String? { "The app is still updating its controls. No input was sent." }
}

/// Which guard rejected the last accessibility read. "Still updating its controls" covers
/// several conditions; this names the one that fired. It never includes text from the app,
/// only counts, depths, roles and Accessibility error numbers. Read it with
/// `log stream --level info --predicate 'category == "desktop-accessibility"'`.
enum DesktopAccessibilityDiagnostics {
    private final class Box: @unchecked Sendable { let lock = NSLock(); var reason: String? }
    private static let box = Box()
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "msgblast", category: "desktop-accessibility")
    static var lastReason: String? { box.lock.withLock { box.reason } }
    static func clear() { box.lock.withLock { box.reason = nil } }
    static func record(_ app: DesktopAppProvider?, _ reason: String) {
        box.lock.withLock { box.reason = reason }
        logger.info("\(app?.name ?? "App", privacy: .public) accessibility read rejected: \(reason, privacy: .public)")
    }
    /// A driver tool exited with an error. The tool and status are public; the driver's own
    /// message may name windows or controls, so it stays private in the log.
    static func driverCallFailed(tool: String, status: Int32, stderr: String) {
        logger.info("App control tool \(tool, privacy: .public) exited with status \(status, privacy: .public): \(String(stderr.prefix(400)), privacy: .private)")
    }
    static func incomplete(_ app: DesktopAppProvider?, _ reason: String) -> DesktopAccessibilityError {
        record(app, reason)
        return .incomplete
    }
}

enum DesktopAccessibilityTree {
    struct Limits {
        var maximumNodes = 6_000
        var maximumDepth = 60
        var timeout: TimeInterval = 3
    }

    static func read<Handle>(_ root: Handle, app: DesktopAppProvider, limits: Limits = .init(),
                             now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                             focus: ((Handle) -> Bool?)? = nil,
                             attributes: (Handle) throws -> (DesktopAccessibilityNode, [Handle])) throws -> DesktopAccessibilityNode {
        DesktopAccessibilityDiagnostics.clear()
        let deadline = now() + limits.timeout
        var count = 0
        func checkDeadline() throws {
            guard now() < deadline else {
                throw DesktopAccessibilityDiagnostics.incomplete(app, "the read took longer than \(limits.timeout) s (\(count) nodes read)")
            }
        }
        func walk(_ handle: Handle, depth: Int, parentRole: String = "", insideWeb: Bool = false) throws -> DesktopAccessibilityNode {
            count += 1
            guard count <= limits.maximumNodes else {
                throw DesktopAccessibilityDiagnostics.incomplete(app, "the window has more than \(limits.maximumNodes) accessibility nodes")
            }
            guard depth <= limits.maximumDepth else {
                throw DesktopAccessibilityDiagnostics.incomplete(app, "the tree is deeper than \(limits.maximumDepth) levels, under \(parentRole)")
            }
            try checkDeadline()
            let captured: (DesktopAccessibilityNode, [Handle])
            do { captured = try attributes(handle) }
            catch DesktopAccessibilityError.invalidElement where app == .gemini && parentRole == "AXOutline" {
                try checkDeadline()
                return .init(role: "AXUnknown")
            } catch DesktopAccessibilityError.invalidElement {
                DesktopAccessibilityDiagnostics.record(app, "a node under \(parentRole) at depth \(depth) disappeared during the read")
                throw DesktopAccessibilityError.invalidElement
            } catch DesktopAccessibilityError.incomplete {
                let detail = DesktopAccessibilityDiagnostics.lastReason ?? "its attributes were unavailable"
                throw DesktopAccessibilityDiagnostics.incomplete(app, "a node under \(parentRole) at depth \(depth) could not be read: \(detail)")
            }
            try checkDeadline()
            var (node, children) = captured
            if let focus, DesktopAccessibility.isComposer(node, app: app) { node.focused = focus(handle) == true }
            if node.role.isEmpty, app == .gemini, parentRole == "AXOutline" { return .init(role: "AXUnknown") }
            guard !node.role.isEmpty else {
                throw DesktopAccessibilityDiagnostics.incomplete(app, "a node under \(parentRole) at depth \(depth) has no role")
            }
            // First-party ChatGPT can embed unrelated app surfaces. Those may
            // never supply the composer, controls or transcript of our chat.
            let nestedWeb = [.chatgpt, .dots].contains(app) && insideWeb && node.role == "AXWebArea"
            node.children = nestedWeb ? [] : try children.map { try walk($0, depth: depth + 1, parentRole: node.role, insideWeb: insideWeb || node.role == "AXWebArea") }
            try checkDeadline()
            return node
        }
        return try walk(root, depth: 0)
    }
}

enum DesktopAccessibilityMetadata {
    static func check(_ status: AXError) throws {
        if status == .invalidUIElement { throw DesktopAccessibilityError.invalidElement }
        guard status == .success else { throw DesktopAccessibilityDiagnostics.incomplete(nil, "Accessibility error \(status.rawValue)") }
    }
    static func address(_ value: Any?) throws -> String? {
        guard let value else { return nil }
        if let url = value as? URL { return url.absoluteString }
        guard let string = value as? String, !string.isEmpty, URL(string: string) != nil else { throw DesktopAccessibilityDiagnostics.incomplete(nil, "a web area has no valid address") }
        return string
    }
    static func values(_ values: [String: Any]) throws -> [String: Any] {
        try values.reduce(into: [:]) { result, entry in
            let (key, value) = entry
            if CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError {
                var error = AXError.success
                guard AXValueGetValue(value as! AXValue, .axError, &error) else { throw DesktopAccessibilityDiagnostics.incomplete(nil, "an attribute error could not be decoded") }
                if error == .attributeUnsupported || error == .noValue { return }
                try check(error)
            } else { result[key] = value }
        }
    }
    static func frame(_ values: [String: Any]) -> DesktopAppSnapshot.Element.Frame? {
        guard let position = values["AXPosition"], let size = values["AXSize"],
              CFGetTypeID(position as CFTypeRef) == AXValueGetTypeID(), CFGetTypeID(size as CFTypeRef) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return .init(x: point.x, y: point.y, w: dimensions.width, h: dimensions.height)
    }

    static func node(_ attributes: [String: Any], identity: UInt? = nil) throws -> DesktopAccessibilityNode {
        let values = try values(attributes)
        let title = values["AXTitle"] as? String ?? ""
        let value = values["AXValue"]
        return DesktopAccessibilityNode(role: values["AXRole"] as? String ?? "", subrole: values["AXSubrole"] as? String ?? "",
            label: title.isEmpty ? values["AXDescription"] as? String ?? "" : title,
            value: value as? String ?? (value as? NSNumber)?.stringValue,
            id: values["AXIdentifier"] as? String ?? "", domID: values["AXDOMIdentifier"] as? String ?? "",
            classes: values["AXDOMClassList"] as? [String] ?? [], url: try address(values["AXURL"]).flatMap(URL.init(string:)),
            selected: values["AXSelected"] as? Bool == true, enabled: values["AXEnabled"] as? Bool != false,
            focused: values["AXFocused"] as? Bool == true, selectedText: values["AXSelectedText"] as? String,
            frame: frame(values), identity: identity)
    }
}

enum DesktopAccessibility {
    private static let keys = ["AXRole", "AXSubrole", "AXTitle", "AXDescription", "AXValue", "AXIdentifier", "AXDOMIdentifier", "AXDOMClassList", "AXURL", "AXSelected", "AXEnabled", "AXFocused", "AXSelectedText", "AXPosition", "AXSize", "AXChildren"]

    private static func attributes(_ element: AXUIElement) throws -> [String: Any] {
        var values: CFArray?
        try DesktopAccessibilityMetadata.check(AXUIElementCopyMultipleAttributeValues(element, keys as CFArray, [], &values))
        guard let values = values as? [Any], values.count == keys.count else { throw DesktopAccessibilityDiagnostics.incomplete(nil, "Accessibility returned \((values as? [Any])?.count ?? 0) of \(keys.count) attributes") }
        return try DesktopAccessibilityMetadata.values(Dictionary(uniqueKeysWithValues: zip(keys, values)))
    }

    private static func attribute(_ element: AXUIElement, _ key: String) throws -> CFTypeRef? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, key as CFString, &value)
        if status == .attributeUnsupported || status == .noValue { return nil }
        try DesktopAccessibilityMetadata.check(status)
        return value
    }


    static func isComposer(_ node: DesktopAccessibilityNode, app: DesktopAppProvider) -> Bool {
        switch app {
        case .muse:
            return (["AXTextArea", "AXTextField"].contains(node.role) && node.label == "Message") ||
                (node.role == "AXButton" && ["Message Attach file Dictate a message Send", "Message Attach file Dictate a message Stop"].contains(node.label))
        case .wabi: return ["AXTextArea", "AXTextField"].contains(node.role) && node.label == "Message"
        case .grokBot: return node.role == "AXTextArea" && node.label == "Prompt"
        case .chatgpt, .dots: return node.role == "AXTextArea" && ["Ask ChatGPT", "Message", "Work with ChatGPT"].contains(node.label)
        default: return false
        }
    }

    static func capture(_ target: DesktopAppConversation.Target, app: DesktopAppProvider) throws -> DesktopAccessibilityNode {
        guard AXIsProcessTrusted() else { throw DesktopAppError.unavailable("Allow msgblast Device Control and Data Access to connect your apps.") }
        guard let window = DesktopNativeWindowLookup.resolve(target) else {
            throw DesktopAccessibilityDiagnostics.incomplete(app, "window \(target.window) of process \(target.pid) was not found through Accessibility")
        }
        let initial = try attributes(window)
        var addresses: [(AXUIElement, String?)] = []
        let root = try DesktopAccessibilityTree.read(window, app: app, focus: { DesktopNativeFocus.capture(pid: target.pid, composer: $0) }) { element in
            let values = try attributes(element)
            var node = try DesktopAccessibilityMetadata.node(values, identity: CFHash(element))
            if node.role == "AXWebArea" { addresses.append((element, try DesktopAccessibilityMetadata.address(values["AXURL"]))) }
            if app == .muse, isComposer(node, app: app) { node.editorText = try museEditorText(element) }
            return (node, values["AXChildren"] as? [AXUIElement] ?? [])
        }
        let final = try attributes(window)
        guard root.role == "AXWindow" else { throw DesktopAccessibilityDiagnostics.incomplete(app, "the root element is \(root.role), not a window") }
        guard let initialFrame = DesktopAccessibilityMetadata.frame(initial), initialFrame == DesktopAccessibilityMetadata.frame(final) else {
            throw DesktopAccessibilityDiagnostics.incomplete(app, "the window frame changed or was unavailable during the read")
        }
        guard try addresses.allSatisfy({ try DesktopAccessibilityMetadata.address(attribute($0.0, "AXURL")) == $0.1 }) else {
            throw DesktopAccessibilityDiagnostics.incomplete(app, "a web area changed its address during the read")
        }
        return root
    }

    /// Muse's compound WebKit editor exposes exact text through parameterized
    /// ranges rather than AXValue. This is a profile hook, not another walker.
    private static func museEditorText(_ composer: AXUIElement) throws -> String {
        func parameter(_ key: String, _ argument: CFTypeRef) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyParameterizedAttributeValue(composer, key as CFString, argument, &value) == .success ? value : nil
        }
        return try MuseComposerText.read(markerText: {
            guard let range = parameter("AXTextMarkerRangeForUIElement", composer) else { return nil }
            return parameter("AXStringForTextMarkerRange", range) as? String
        }) { range in
            var native = CFRange(location: range.location, length: range.length)
            guard let rangeValue = AXValueCreate(.cfRange, &native) else { return nil }
            return parameter("AXStringForRange", rangeValue) as? String
        }
    }
}
