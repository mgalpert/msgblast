import ApplicationServices
import Darwin
import Foundation

enum DesktopNativeWindowLookup {
    static func find<Element>(pid: Int, windowID: UInt32, listed: [Element],
                              ownerPID: () -> Int?, number: (Element) -> UInt32?,
                              isWindow: (Element) -> Bool, remote: ((Data) -> Element?)?,
                              now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) -> Element? {
        guard let process = Int32(exactly: pid), process > 0, windowID > 0, ownerPID() == pid else { return nil }
        let matches = listed.filter { isWindow($0) && number($0) == windowID }
        if !matches.isEmpty { return matches.count == 1 ? matches.first : nil }
        guard let remote else { return nil }
        let deadline = now() + 0.3
        // macOS omits other Spaces from AXWindows. Resolve only this process's
        // exact AXWindow, using the bounded remote-token lookup also used by
        // CuaDriver (MIT; see ThirdPartyNotices.txt).
        for elementID in UInt64(0)..<2_000 {
            guard now() < deadline else { return nil }
            var process = process, zero: UInt32 = 0, magic: UInt32 = 0x636f636f, identifier = elementID
            var token = Data()
            withUnsafeBytes(of: &process) { token.append(contentsOf: $0) }
            withUnsafeBytes(of: &zero) { token.append(contentsOf: $0) }
            withUnsafeBytes(of: &magic) { token.append(contentsOf: $0) }
            withUnsafeBytes(of: &identifier) { token.append(contentsOf: $0) }
            if let candidate = remote(token), isWindow(candidate), number(candidate) == windowID { return candidate }
        }
        return nil
    }

    // WindowServer includes other Spaces even when the app's AXWindows is empty.
    // This only reads the exact process/window; it never activates or moves it.
    static func resolve(_ target: DesktopAppConversation.Target) -> AXUIElement? {
        guard let pid = pid_t(exactly: target.pid), pid > 0,
              let requestedWindow = UInt32(exactly: target.window), requestedWindow > 0 else { return nil }
        typealias WindowNumber = @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> Int32
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
        let windowNumber = unsafeBitCast(symbol, to: WindowNumber.self)
        func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        typealias RemoteWindow = @convention(c) (CFData) -> Unmanaged<AXUIElement>?
        let remoteSymbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementCreateWithRemoteToken")
        let remoteWindow = remoteSymbol.map { unsafeBitCast($0, to: RemoteWindow.self) }
        let window = find(pid: target.pid, windowID: requestedWindow,
            listed: attribute(app, "AXWindows") as? [AXUIElement] ?? [], ownerPID: {
                let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, requestedWindow) as? [[String: Any]] ?? []
                return rows.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == requestedWindow })?[kCGWindowOwnerPID as String] as? Int
            }, number: { candidate in
                var number: UInt32 = 0
                return windowNumber(candidate, &number) == AXError.success.rawValue ? number : nil
            }, isWindow: { attribute($0, "AXRole") as? String == "AXWindow" }, remote: remoteWindow.map { create in
                { token in
                    guard let candidate = create(token as CFData)?.takeRetainedValue() else { return nil }
                    AXUIElementSetMessagingTimeout(candidate, 0.05)
                    return candidate
                }
            })
        if let window { AXUIElementSetMessagingTimeout(window, 0.2) }
        return window
    }
}

// A background web editor may report its web area as the app's focused
// element while the editor's own AXFocused attribute is true.
enum DesktopNativeFocus {
    static func observed(applicationMatches: Bool?, applicationRole: String?, elementFocused: Bool?) -> Bool? {
        if applicationMatches == true { return true }
        // A different concrete control is conflicting focus, even if an old
        // editor flag has not cleared. Only toolkit wrapper roots may defer.
        let wrappers = ["AXWebArea", "AXGroup", "AXWindow", "AXApplication"]
        if applicationMatches == false, !wrappers.contains(applicationRole ?? "") { return false }
        return elementFocused ?? applicationMatches
    }
    static func capture(pid: Int, composer: AXUIElement) -> Bool? {
        func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
        }
        let app = AXUIElementCreateApplication(pid_t(pid))
        AXUIElementSetMessagingTimeout(app, 0.2)
        let focus = attribute(app, "AXFocusedUIElement").flatMap { value -> AXUIElement? in
            CFGetTypeID(value) == AXUIElementGetTypeID() ? value as! AXUIElement : nil
        }
        return observed(applicationMatches: focus.map { CFEqual($0, composer) },
                        applicationRole: focus.flatMap { attribute($0, "AXRole") as? String },
                        elementFocused: attribute(composer, "AXFocused") as? Bool)
    }
}
