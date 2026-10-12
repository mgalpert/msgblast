import AppKit
@preconcurrency import ApplicationServices
import msgblastCore

@MainActor
struct BusinessChoiceSender {
    func select(_ request: BusinessChoiceRequest, verify: @escaping @MainActor @Sendable () throws -> Void) async throws {
        guard AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) else {
            throw SendFailure.notSubmitted("Allow msgblast in System Settings → Privacy & Security → Accessibility to use Business choices, then click the choice again. Nothing was selected.")
        }
        let appURL = URL(fileURLWithPath: "/System/Applications/Messages.app")
        guard let bundleID = Bundle(url: appURL)?.bundleIdentifier, ["com.apple.MobileSMS", "com.apple.iChat"].contains(bundleID) else {
            throw SendFailure.notSubmitted("Apple Messages is unavailable. Nothing was selected.")
        }
        var components = URLComponents(); components.scheme = "imessage"; components.host = ""
        components.queryItems = [URLQueryItem(name: "chat", value: request.chatID)]
        guard let url = components.url else { throw SendFailure.notSubmitted("The Messages conversation address is invalid.") }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false; configuration.addsToRecentItems = false
        let app: NSRunningApplication = try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration) { app, error in
                if let app { continuation.resume(returning: app) }
                else { continuation.resume(throwing: SendFailure.notSubmitted(error?.localizedDescription ?? "Messages could not open this conversation.")) }
            }
        }
        guard app.bundleIdentifier == bundleID else { throw SendFailure.notSubmitted("The Messages application identity changed.") }
        try await BusinessChoiceAccessibility.select(pid: app.processIdentifier, request: request, verify: verify)
    }
}

@globalActor private actor BusinessChoiceAccessibilityActor {
    static let shared = BusinessChoiceAccessibilityActor()
}

@BusinessChoiceAccessibilityActor
private enum BusinessChoiceAccessibility {
    static func select(pid: pid_t, request: BusinessChoiceRequest, verify: @escaping @MainActor @Sendable () throws -> Void) async throws {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.5)
        var lastError: Error = SendFailure.notSubmitted("Messages has not loaded these choices. Nothing was selected.")
        // Only navigation/inspection can wait. Never repeat an AXPress after dispatch.
        for _ in 0..<8 {
            do {
                try Task.checkCancellation()
                try await verify()
                _ = try findButton(application, request: request)
                try await verify()
                let target = try findButton(application, request: request)
                try Task.checkCancellation()
                let code = AXUIElementPerformAction(target, kAXPressAction as CFString)
                guard code == .success else {
                    throw SendFailure.ambiguous("Messages did not confirm the choice action. Check the conversation before trying again; msgblast will not repeat it.")
                }
                return
            } catch let failure as SendFailure {
                if case .ambiguous = failure { throw failure }
                lastError = failure
            } catch { lastError = error }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw SendFailure.notSubmitted(lastError.localizedDescription)
    }

    private static func findButton(_ application: AXUIElement, request: BusinessChoiceRequest) throws -> AXUIElement {
        guard let windows = attribute(application, kAXWindowsAttribute) as? [AXUIElement] else {
            throw SendFailure.notSubmitted("Messages windows are unavailable. Nothing was selected.")
        }
        var targets: [AXUIElement] = []
        for window in windows where attribute(window, kAXTitleAttribute) as? String == request.conversationName {
            var nodes: [(AXUIElement, String)] = [(window, "window")], seen: [AXUIElement] = []
            var contexts: [BusinessChoiceSnapshot.Context] = [], buttons: [BusinessChoiceSnapshot.Button] = [], references: [Int: AXUIElement] = [:]
            let deadline = Date().addingTimeInterval(3)
            while let (node, group) = nodes.popLast() {
                guard seen.count < 2_000, Date() < deadline else { throw SendFailure.notSubmitted("Messages inspection did not finish. Nothing was selected.") }
                if seen.contains(where: { CFEqual($0, node) }) { continue }
                seen.append(node)
                let role = attribute(node, kAXRoleAttribute) as? String
                let title = attribute(node, kAXTitleAttribute) as? String
                let description = attribute(node, kAXDescriptionAttribute) as? String
                let value = attribute(node, kAXValueAttribute) as? String
                if let frame = frame(node) {
                    if let text = value ?? description ?? title, role == kAXTextAreaRole || role == kAXStaticTextRole {
                        contexts.append(.init(text: text, frame: frame))
                    }
                    if role == kAXButtonRole, let text = title ?? description,
                       request.payload.options.contains(where: { $0.title == text }), group != "window" {
                        let index = references.count
                        references[index] = node
                        buttons.append(.init(id: index, title: text, group: group, frame: frame, enabled: attribute(node, kAXEnabledAttribute) as? Bool == true))
                    }
                }
                if let children = attribute(node, kAXChildrenAttribute) as? [AXUIElement] {
                    let childGroup = role == kAXWindowRole ? "window" : String(CFHash(node))
                    nodes.append(contentsOf: children.map { ($0, childGroup) })
                }
            }
            let snapshot = BusinessChoiceSnapshot(conversationName: request.conversationName, contexts: contexts, buttons: buttons)
            if let index = try? request.matchingButton(in: snapshot), let target = references[index] { targets.append(target) }
        }
        guard targets.count == 1, let target = targets.first else {
            throw SendFailure.notSubmitted("Messages is not showing one matching conversation and choice card. Nothing was selected.")
        }
        return target
    }
    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    private static func frame(_ element: AXUIElement) -> BusinessChoiceSnapshot.Frame? {
        guard let position = attribute(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = attribute(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions), dimensions.width > 0, dimensions.height > 0 else { return nil }
        return .init(x: point.x, y: point.y, width: dimensions.width, height: dimensions.height)
    }
}
