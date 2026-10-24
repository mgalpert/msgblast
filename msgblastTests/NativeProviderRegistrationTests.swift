import XCTest
@testable import msgblastCore

final class NativeProviderRegistrationTests: XCTestCase {
    func testNativeProvidersKeepWebsiteAccountsAndConversationIdentitiesSeparate() throws {
        let pairs: [(WebProvider, WebProvider, DesktopAppProvider)] = [
            (.chatgptApp, .chatgpt, .chatgpt),
            (.dotsApp, .dots, .dots),
            (.claudeApp, .claude, .claude)
        ]
        let websiteStateNames = Set(WebProvider.webDefaults.map(\.storageFilename) + [WebProvider.dots.storageFilename])
        for (native, website, app) in pairs {
            XCTAssertEqual(native.desktopApp, app)
            XCTAssertTrue(native.usesNativeConversation)
            XCTAssertFalse(native.supportsCopies)
            XCTAssertEqual(native.sharesOneConversation, native == .dotsApp)
            XCTAssertTrue(WebProvider.desktopProviders.contains(native))
            XCTAssertFalse(websiteStateNames.contains(native.storageFilename))
            XCTAssertNotEqual(native.storageFilename, website.storageFilename)
            XCTAssertFalse(native.isChatURL(website.newChatURL))
            XCTAssertFalse(native.isSavedConversation(website.newChatURL))
            XCTAssertNil(native.canonicalConversationURL(website.newChatURL))
            XCTAssertFalse(native.acceptsReceipt(from: website.newChatURL, at: website.newChatURL))
            XCTAssertEqual(try JSONDecoder().decode(WebProvider.self, from: JSONEncoder().encode(website)), website)
        }
        XCTAssertEqual(Set(pairs.map { $0.0.storageFilename }).count, 3)
    }

    func testNativeOnlyOnboardingSkipsBrowserImportAndPreservesDistinctWebsiteChoices() throws {
        var state = OnboardingState()
        state.chooseConnector(.apps)
        state.selected = [.chatgptApp, .dotsApp, .claudeApp]
        state.begin()
        XCTAssertEqual(state.stage, .connecting)
        XCTAssertEqual(Set(state.pendingSteps), [.agent(.chatgptApp), .agent(.dotsApp), .agent(.claudeApp)])
        XCTAssertTrue(state.pendingWebProviders.isEmpty)
        XCTAssertTrue(state.selected.allSatisfy { OnboardingConnector.apps.includes($0) && !OnboardingConnector.clis.includes($0) })
        let saved = try JSONDecoder().decode(OnboardingState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(saved.selected, state.selected)
        state.chooseAgain()
        state.selected.insert(.chatgpt)
        state.selected.insert(.claude)
        state.selected.insert(.dots)
        state.begin()
        XCTAssertEqual(state.stage, .importing)
        XCTAssertEqual(state.pendingWebProviders, [.chatgpt, .claude, .dots])
    }
}
