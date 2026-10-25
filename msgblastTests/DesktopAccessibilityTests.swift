import AppKit
import ApplicationServices
import WebKit
import XCTest
@testable import msgblastCore

final class DesktopAccessibilityTests: XCTestCase {
    private struct Source {
        var node: DesktopAccessibilityNode
        var children: [Int] = []
    }
    private func read(_ source: [Int: Source], app: DesktopAppProvider = .wabi, limits: DesktopAccessibilityTree.Limits = .init(), now: () -> TimeInterval = { 0 }) throws -> DesktopAccessibilityNode {
        try DesktopAccessibilityTree.read(0, app: app, limits: limits, now: now) { id in
            let value = source[id]!
            return (value.node, value.children)
        }
    }

    func testSharedSnapshotRetainsConversationMetadataAndExactDraft() throws {
        let url = URL(string: "wabi://app/threads/0123456789abcdef01234567")!
        let result = try read([
            0: Source(node: .init(role: "AXWindow"), children: [1]),
            1: Source(node: .init(role: "AXWebArea", url: url), children: [2]),
            2: Source(node: .init(role: "AXTextArea", label: "Message", value: "A\n\nB\n", id: "editor", classes: ["editor"], focused: true))
        ])
        XCTAssertEqual(result.children[0].url, url)
        let field = try XCTUnwrap(result.descendants.first { $0.id == "editor" })
        XCTAssertEqual(field.value, "A\n\nB\n")
        XCTAssertTrue(field.focused)
        XCTAssertEqual(field.classes, ["editor"])
    }

    func testEveryProfileRejectsPartialTreesInsteadOfReturningAUsableComposer() throws {
        let source = [0: Source(node: .init(role: "AXWindow"), children: [1, 2]),
                      1: Source(node: .init(role: "AXTextArea", label: "Message", value: "")),
                      2: Source(node: .init(role: "AXGroup"))]
        for app in [DesktopAppProvider.muse, .grokBot, .wabi, .gemini, .chatgpt, .dots, .claude] {
            XCTAssertThrowsError(try read(source, app: app, limits: .init(maximumNodes: 2)), "\(app)")
            XCTAssertThrowsError(try read(source, app: app, limits: .init(maximumDepth: 0)), "\(app)")
            var clock = 0.0
            XCTAssertThrowsError(try read(source, app: app, now: { clock += 4; return clock }), "\(app)")
        }
    }

    func testOnlyGeminiVirtualizedSidebarReferencesCanBeSkipped() throws {
        let source = [0: Source(node: .init(role: "AXWindow"), children: [1]),
                      1: Source(node: .init(role: "AXOutline"), children: [2]),
                      2: Source(node: .init(role: ""))]
        XCTAssertEqual(try read(source, app: .gemini).children[0].children[0].role, "AXUnknown")
        XCTAssertThrowsError(try read(source))
        var transcript = source
        transcript[1] = Source(node: .init(role: "AXGroup"), children: [2])
        XCTAssertThrowsError(try read(transcript, app: .gemini))
    }

    func testChatGPTAndDotsRejectStaleEditorFocusWhenAnotherControlOwnsInput() throws {
        for app in [DesktopAppProvider.chatgpt, .dots] {
            for label in ["Ask ChatGPT", "Message", "Work with ChatGPT"] {
                let source = [0: Source(node: .init(role: "AXWindow"), children: [1, 2]),
                              1: Source(node: .init(role: "AXTextArea", label: label, focused: true)),
                              2: Source(node: .init(role: "AXTextField", label: "Chat title", focused: true))]
                var checked: [Int] = []
                let tree = try DesktopAccessibilityTree.read(0, app: app, focus: { handle in
                    checked.append(handle)
                    return DesktopNativeFocus.observed(applicationMatches: false, applicationRole: "AXSearchField", elementFocused: true)
                }) { handle in
                    let value = source[handle]!
                    return (value.node, value.children)
                }
                XCTAssertEqual(checked, [1], "Only the actual chat editor needs native focus resolution")
                XCTAssertFalse(tree.children[0].focused, "A stale AXFocused flag must not authorize keyboard input: \(app), \(label)")
                XCTAssertTrue(tree.children[1].focused, "Other controls retain their own metadata")
            }
        }
    }

    func testChatGPTNestedWebContentCannotSupplyConversationControls() throws {
        let source = [0: Source(node: .init(role: "AXWindow"), children: [1]),
                      1: Source(node: .init(role: "AXWebArea"), children: [2]),
                      2: Source(node: .init(role: "AXWebArea", url: URL(string: "https://foreign.invalid")), children: [3]),
                      3: Source(node: .init(role: "AXTextArea", label: "Ask ChatGPT", value: "Foreign draft"))]
        XCTAssertFalse(try read(source, app: .chatgpt).descendants.contains { $0.role == "AXTextArea" })
        XCTAssertTrue(try read(source, app: .wabi).descendants.contains { $0.role == "AXTextArea" })
    }
}

extension DesktopAccessibilityTests {
    func testProductionAttributeConversionRetainsStringURLAndNativeMetadata() throws {
        var point = CGPoint(x: 31, y: 36), size = CGSize(width: 1180, height: 900)
        let position = try XCTUnwrap(AXValueCreate(.cgPoint, &point))
        let dimensions = try XCTUnwrap(AXValueCreate(.cgSize, &size))
        let source: [Int: ([String: Any], [Int])] = [
            0: (["AXRole": "AXWindow", "AXPosition": position, "AXSize": dimensions], [1]),
            1: (["AXRole": "AXWebArea", "AXURL": "app://-/index.html"], [2]),
            2: (["AXRole": "AXTextArea", "AXDescription": "Ask ChatGPT", "AXValue": "A\n\n🧑🏽‍💻\n", "AXIdentifier": "editor", "AXDOMIdentifier": "prompt-textarea", "AXDOMClassList": ["editor"], "AXFocused": true, "AXSelected": true, "AXEnabled": false, "AXSelectedText": "🧑🏽‍💻"], [])
        ]
        let tree = try DesktopAccessibilityTree.read(0, app: .chatgpt) { handle in
            let (attributes, children) = source[handle]!
            return (try DesktopAccessibilityMetadata.node(attributes, identity: UInt(handle)), children)
        }
        XCTAssertEqual(tree.frame, .init(x: 31, y: 36, w: 1180, h: 900))
        XCTAssertEqual(tree.children[0].url?.absoluteString, "app://-/index.html")
        let field = try XCTUnwrap(tree.descendants.first { $0.domID == "prompt-textarea" })
        XCTAssertEqual(field.value, "A\n\n🧑🏽‍💻\n")
        XCTAssertEqual(field.selectedText, "🧑🏽‍💻")
        XCTAssertEqual(field.classes, ["editor"])
        XCTAssertEqual(field.identity, 2)
        XCTAssertTrue(field.focused)
        XCTAssertTrue(field.selected)
        XCTAssertFalse(field.enabled)
    }

    func testURLBridgeRejectsInvalidPresentValuesAndComparesBothSupportedRepresentations() throws {
        let text = "app://-/index.html"
        XCTAssertEqual(try DesktopAccessibilityMetadata.address(text), text)
        XCTAssertEqual(try DesktopAccessibilityMetadata.address(URL(string: text)!), text)
        XCTAssertNil(try DesktopAccessibilityMetadata.address(nil))
        XCTAssertThrowsError(try DesktopAccessibilityMetadata.address(42))
        XCTAssertThrowsError(try DesktopAccessibilityMetadata.address(""))
        XCTAssertNotEqual(try DesktopAccessibilityMetadata.address("https://muse.ai/thread/first"), try DesktopAccessibilityMetadata.address("https://muse.ai/thread/second"))
    }

    func testInvalidBatchedGeminiOutlineReferenceDoesNotHideOtherNativeReadFailures() throws {
        func capture(app: DesktopAppProvider, parent: String = "AXOutline", failure: AXError = .invalidUIElement) throws -> DesktopAccessibilityNode {
            try DesktopAccessibilityTree.read(0, app: app) { handle in
                switch handle {
                case 0: return (.init(role: "AXWindow"), [1])
                case 1: return (.init(role: parent), [2])
                default:
                    try DesktopAccessibilityMetadata.check(failure)
                    return (.init(role: ""), [])
                }
            }
        }
        XCTAssertEqual(try capture(app: .gemini).children[0].children[0].role, "AXUnknown")
        XCTAssertThrowsError(try capture(app: .wabi))
        XCTAssertThrowsError(try capture(app: .gemini, parent: "AXGroup"))
        XCTAssertThrowsError(try capture(app: .gemini, failure: .cannotComplete))
    }

    func testSlowFinalAttributeReadCannotReturnAPartialSnapshotAfterDeadline() {
        var clock = 0.0
        XCTAssertThrowsError(try DesktopAccessibilityTree.read(0, app: .wabi, limits: .init(timeout: 3), now: { clock }) { _ in
            clock = 4
            return (.init(role: "AXWindow"), [Int]())
        })
    }
}

extension DesktopAccessibilityTests {
    func testUnsupportedBatchedAttributesAreAbsentButInvalidSlotsStopSnapshot() throws {
        func errorValue(_ error: AXError) -> AXValue {
            var error = error
            return AXValueCreate(.axError, &error)!
        }
        let field = try DesktopAccessibilityMetadata.node([
            "AXRole": "AXTextArea", "AXValue": "Exact\n\ndraft", "AXDescription": "Message",
            "AXURL": errorValue(.attributeUnsupported), "AXSelectedText": errorValue(.noValue)
        ])
        XCTAssertNil(field.url)
        XCTAssertNil(field.selectedText)
        XCTAssertEqual(field.value, "Exact\n\ndraft")
        XCTAssertThrowsError(try DesktopAccessibilityMetadata.node(["AXRole": "AXWebArea", "AXURL": errorValue(.cannotComplete)]))
        XCTAssertThrowsError(try DesktopAccessibilityMetadata.node(["AXRole": errorValue(.invalidUIElement)])) { error in
            guard case DesktopAccessibilityError.invalidElement = error else { return XCTFail("Expected native invalid-element identity") }
        }
    }
}

@MainActor
private final class AccessibilitySmokeNavigation: NSObject, WKNavigationDelegate {
    let loaded: XCTestExpectation
    init(_ loaded: XCTestExpectation) { self.loaded = loaded }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded.fulfill() }
}

extension DesktopAccessibilityTests {
    @MainActor
    func testNativeCaptureReadsTestOwnedWebKitEditorWhenAccessIsGranted() async throws {
        try XCTSkipUnless(AXIsProcessTrusted(), "Native AX smoke requires an already authorized test host; this test never requests access.")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("msgblast-native-ax-smoke-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("editor.html")
        try """
        <!doctype html><html><body><textarea id="composer" aria-label="Message" class="native-smoke">A

        B</textarea><script>document.getElementById('composer').focus()</script></body></html>
        """.write(to: file, atomically: true, encoding: .utf8)
        let editor = WKWebView(frame: .init(x: 0, y: 0, width: 600, height: 400))
        let window = NSWindow(contentRect: editor.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "msgblast test-owned Accessibility surface"
        window.contentView = editor
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.orderBack(nil)
        let loaded = expectation(description: "Local test editor loaded")
        let navigation = AccessibilitySmokeNavigation(loaded)
        editor.navigationDelegate = navigation
        editor.loadFileURL(file, allowingReadAccessTo: directory)
        await fulfillment(of: [loaded], timeout: 5)
        window.makeFirstResponder(editor)
        let target = DesktopAppConversation.Target(pid: Int(ProcessInfo.processInfo.processIdentifier), window: window.windowNumber)
        let tree = try await Task.detached { try DesktopAccessibility.capture(target, app: .wabi) }.value
        XCTAssertEqual(tree.role, "AXWindow")
        XCTAssertNotNil(tree.frame)
        XCTAssertTrue(tree.descendants.contains { $0.role == "AXWebArea" && $0.url == file })
        let field = try XCTUnwrap(tree.descendants.first { DesktopAccessibility.isComposer($0, app: .wabi) })
        XCTAssertEqual(field.value, "A\n\nB")
        XCTAssertEqual(field.domID, "composer")
        XCTAssertTrue(field.classes.contains("native-smoke"))
        XCTAssertTrue(field.focused)
    }
}
