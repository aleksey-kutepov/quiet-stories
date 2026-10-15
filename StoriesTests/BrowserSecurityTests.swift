import WebKit
import SwiftUI
import Vision
import XCTest
@testable import Stories

/// Model requests are captured rather than loaded. WebKit probes use local HTML and synthetic cookies only.
@MainActor
final class BrowserSecurityTests: XCTestCase {
    private var suites: [String] = []
    private var requestedURLs: [URL] = []
    private var createdStores: [WKWebsiteDataStore] = []
    private var createdViews: [WeakTestWebView] = []

    private enum StoreIdentity: Hashable {
        case persistent(UUID)
        case ephemeral(ObjectIdentifier)
    }

    func testMessagesUseDesktopWebKitProfileAndOtherSectionsRestoreDefault() async throws {
        let browser = model(preferences(remember: false))
        browser.setAccessAllowed(true)
        browser.showStories()
        let view = try XCTUnwrap(browser.webView)
        XCTAssertTrue((view.customUserAgent ?? "").isEmpty)
        browser.showMessages()
        let messagingProfile = try XCTUnwrap(view.customUserAgent)
        XCTAssertTrue(messagingProfile.contains("Macintosh"))
        XCTAssertTrue(messagingProfile.contains("Safari/605.1.15"))
        XCTAssertFalse(view.configuration.userContentController.userScripts.isEmpty)
        XCTAssertTrue(view.configuration.limitsNavigationsToAppBoundDomains)
        browser.reload()
        XCTAssertEqual(view.customUserAgent, messagingProfile)
        browser.composeMessage()
        XCTAssertEqual(view.customUserAgent, messagingProfile)
        browser.showStories()
        XCTAssertTrue((view.customUserAgent ?? "").isEmpty)
        browser.signIn()
        XCTAssertTrue((browser.webView?.customUserAgent ?? "").isEmpty)
        await browser.signOut()
    }

    override func tearDown() async throws {
        defer {
            for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
            createdStores.removeAll()
            createdViews.removeAll()
            suites.removeAll()
        }
        var seenStores = Set<StoreIdentity>()
        var stores: [WKWebsiteDataStore] = []
        for store in createdStores {
            let identity = store.identifier.map(StoreIdentity.persistent)
                ?? .ephemeral(ObjectIdentifier(store))
            if seenStores.insert(identity).inserted { stores.append(store) }
        }
        // SwiftUI/UIKit can release a dismantled hosting graph on a later run-loop turn.
        // WebKit requires every view using a persistent store to be released before deleting its identifier.
        for _ in 0..<100 {
            if !createdViews.contains(where: { $0.storeIdentifier != nil && $0.value != nil }) { break }
            try? await Task.sleep(for: .milliseconds(25))
        }
        let retainedIdentifiers = Set(createdViews.compactMap { $0.value == nil ? nil : $0.storeIdentifier })
        for store in stores {
            let cleared = await awaitStoreCleanup { completion in
                store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
                    completion(true)
                }
            }
            guard cleared else {
                XCTFail("WebKit did not finish clearing synthetic test data within 5 seconds.")
                continue
            }
            guard let identifier = store.identifier else { continue }
            if retainedIdentifiers.contains(identifier) {
                let diagnostic = XCTAttachment(string: "Skipped deletion of test store \(identifier): UIKit/SwiftUI still retained a WKWebView after the bounded release wait. Synthetic website data was cleared.")
                diagnostic.name = "Retained test WebKit view during cleanup"
                diagnostic.lifetime = .keepAlways
                add(diagnostic)
                continue
            }
            var deletionError: NSError?
            let removed = await awaitStoreCleanup { completion in
                WKWebsiteDataStore.remove(forIdentifier: identifier) { error in
                    if let error { deletionError = error as NSError }
                    completion(error == nil)
                }
            }
            if !removed {
                // Container deletion is best effort after synthetic website data is cleared.
                // Some simulator runtimes reject deletion even after tracked views are released.
                let reason = deletionError.map { "WebKit returned \($0.domain) code \($0.code)." }
                    ?? "WebKit did not call its deletion completion within 5 seconds."
                let diagnostic = XCTAttachment(string: "Test store \(identifier): \(reason) Synthetic website data was cleared before this best-effort deletion.")
                diagnostic.name = "Best-effort test WebKit store deletion"
                diagnostic.lifetime = .keepAlways
                add(diagnostic)
            }
        }
    }

    private func awaitStoreCleanup(_ operation: (@escaping (Bool) -> Void) -> Void) async -> Bool {
        await withCheckedContinuation { continuation in
            let completion = TestStoreCleanupCompletion(continuation: continuation)
            completion.startTimeout()
            operation { completion.finish(success: $0) }
        }
    }

    private func trackView(_ view: WKWebView) {
        createdStores.append(view.configuration.websiteDataStore)
        if !createdViews.contains(where: { $0.value === view }) {
            createdViews.append(WeakTestWebView(view))
        }
    }

    private func preferences(remember: Bool = true) -> UserDefaults {
        let suite = "StoriesBrowserSecurityTests.\(UUID().uuidString)"
        suites.append(suite)
        let preferences = UserDefaults(suiteName: suite)!
        preferences.set(remember, forKey: "rememberSession")
        return preferences
    }

    private func model(_ preferences: UserDefaults,
                       removeStore: ((WKWebsiteDataStore) async -> Bool)? = { _ in true }) -> BrowserModel {
        BrowserModel(preferences: preferences, removeStore: removeStore, loadRequest: { [weak self] view, request in
            if let url = request.url { self?.requestedURLs.append(url) }
            self?.trackView(view)
        })
    }

    private func waitUntil(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The expected asynchronous state did not arrive.", file: file, line: line)
        throw CocoaError(.coderInvalidValue)
    }

    func testRememberedSessionWaitsForForegroundAccessBeforeCreatingAWebView() async throws {
        let preferences = preferences()
        let identifier = UUID()
        preferences.set(true, forKey: "hasStarted")
        preferences.set(identifier.uuidString, forKey: "websiteDataStoreID")
        let browser = model(preferences)
        XCTAssertNil(browser.webView)
        XCTAssertEqual(browser.state, .welcome)
        XCTAssertTrue(requestedURLs.isEmpty)
        browser.setAccessAllowed(false)
        browser.signIn()
        browser.showStories()
        browser.showMessages()
        browser.composeMessage()
        XCTAssertNil(browser.webView)
        browser.setAccessAllowed(true)
        XCTAssertEqual(requestedURLs, [NavigationPolicy.homeURL])
        XCTAssertEqual(browser.browserKind, .stories)
        XCTAssertEqual(browser.webView?.configuration.websiteDataStore.identifier, identifier)
        await browser.signOut()
    }

    func testAccessRevocationPreventsSignInStoriesAndExternalPrompts() async {
        let browser = model(preferences(remember: false))
        browser.setAccessAllowed(true)
        browser.signIn()
        let original = browser.webView
        browser.externalURL = URL(string: "https://example.com/")
        browser.notice = "A prompt"
        browser.setAccessAllowed(false)
        browser.signIn()
        browser.showStories()
        browser.showMessages()
        browser.composeMessage()
        browser.selectSection(.stories)
        browser.selectSection(.messages)
        browser.reload()
        XCTAssertTrue(browser.webView === original)
        XCTAssertEqual(requestedURLs, [NavigationPolicy.loginURL])
        XCTAssertNil(browser.externalURL)
        XCTAssertNil(browser.notice)
        XCTAssertEqual(browser.section, .stories, "Locked actions cannot change the selected section.")
        await browser.signOut()
    }

    func testMessagingNavigationReusesFilteredSessionAndKeepsContentHiddenUntilReady() async throws {
        let browser = model(preferences(remember: false))
        browser.setAccessAllowed(true)
        browser.showStories()
        let storiesView = try XCTUnwrap(browser.webView)
        let store = storiesView.configuration.websiteDataStore
        browser.receiveFilterState("home", route: .home, isLoading: false)
        browser.showMessages()
        XCTAssertEqual(browser.section, .messages)
        XCTAssertEqual(browser.state, .openingMessages)
        XCTAssertTrue(browser.state.isMessagingContext)
        XCTAssertFalse(browser.state.showsWebContent)
        XCTAssertTrue(browser.webView === storiesView)
        XCTAssertTrue(browser.webView?.configuration.websiteDataStore === store)
        XCTAssertEqual(requestedURLs.last, NavigationPolicy.inboxURL)
        browser.receiveFilterState("home", route: .home, isLoading: false)
        XCTAssertEqual(browser.state, .openingMessages, "The previous document cannot reveal itself during inbox loading.")
        browser.receiveFilterState("inbox", route: .inbox, isLoading: false)
        XCTAssertEqual(browser.state, .inbox)
        XCTAssertTrue(browser.state.showsWebContent)

        browser.composeMessage()
        XCTAssertEqual(browser.state, .openingMessages)
        XCTAssertEqual(requestedURLs.last, NavigationPolicy.composeURL)
        browser.receiveFilterState("inbox", route: .inbox, isLoading: false)
        XCTAssertEqual(browser.state, .openingMessages)
        browser.receiveFilterState("message-compose", route: .messageCompose, isLoading: false)
        XCTAssertEqual(browser.state, .messageCompose)
        XCTAssertTrue(browser.state.showsWebContent)

        XCTAssertEqual(actionDecision(browser, view: storiesView,
            url: "https://www.instagram.com/direct/t/123/", mainFrame: true), .allow)
        XCTAssertEqual(browser.state, .openingMessages)
        browser.receiveFilterState("conversation", route: .conversation, isLoading: false)
        XCTAssertEqual(browser.state, .conversation)
        XCTAssertTrue(browser.state.showsWebContent)
        XCTAssertTrue(browser.webView === storiesView)
        browser.showStories()
        XCTAssertEqual(browser.section, .stories)
        XCTAssertEqual(browser.state, .loading)
        browser.receiveFilterState("conversation", route: .conversation, isLoading: false)
        XCTAssertEqual(browser.state, .loading, "A queued thread message cannot reopen the conversation after selecting Stories.")
        await browser.signOut()
    }

    func testRenderedSectionTabsRemainVisibleAfterAStoryReplyAndDuringStoryRecovery() async throws {
        let preferences = preferences(remember: false)
        let browser = model(preferences)
        browser.setAccessAllowed(true)
        browser.showStories()
        let view = try XCTUnwrap(browser.webView)
        let screen = try renderedScreen(browser: browser, preferences: preferences)
        defer { screen.close() }
        try await waitUntil { view.window === screen.window }
        try await assertRenderedSectionTabs(in: screen.window, named: "Stories loading")

        // This reply fixture has no account, cookies, external resources, or network request.
        view.configuration.userContentController.removeAllUserScripts()
        let loaded = expectation(description: "Local story reply fixture loaded")
        let delegate = LocalFixtureDelegate(loaded: loaded)
        view.navigationDelegate = delegate
        defer { view.stopLoading(); view.navigationDelegate = nil }
        view.loadHTMLString("""
        <html><head><meta name="viewport" content="width=device-width, initial-scale=1"></head>
        <body style="font: 18px -apple-system; padding: 24px; background: #eeeae0">
          <main><h2>A local story</h2><p>A moment from a synthetic contact.</p>
            <input id="reply" aria-label="Reply to story" placeholder="Reply to story">
            <button id="send" onclick="document.getElementById('sent').textContent = 'Reply sent'">Send</button>
            <p id="sent" aria-live="polite"></p>
          </main>
        </body></html>
        """, baseURL: NavigationPolicy.homeURL)
        await fulfillment(of: [loaded], timeout: 15)
        browser.receiveFilterState("home", route: .home, isLoading: false)
        try await assertRenderedSectionTabs(in: screen.window, named: "Stories home")
        browser.receiveFilterState("story-loading", route: .home, isLoading: false)
        XCTAssertEqual(browser.state, .openingStory)
        try await assertRenderedSectionTabs(in: screen.window, named: "Story opening")
        browser.receiveFilterState("story", route: .home, isLoading: false)
        XCTAssertEqual(browser.state, .story)
        _ = try await evaluate("""
        document.getElementById('reply').value = 'A synthetic reply';
        document.getElementById('send').click();
        document.getElementById('sent').textContent;
        """, in: view)
        let sentReply = try await evaluate("document.getElementById('sent').textContent", in: view) as? String
        XCTAssertEqual(sentReply, "Reply sent")
        try await assertRenderedSectionTabs(in: screen.window, named: "Story after reply")
        browser.receiveFilterState("story-unavailable", route: .home, isLoading: false)
        XCTAssertEqual(browser.state, .storyUnavailable)
        try await assertRenderedSectionTabs(in: screen.window, named: "Story unavailable")

        browser.selectSection(.messages)
        XCTAssertEqual(requestedURLs.last, NavigationPolicy.inboxURL)
        XCTAssertEqual(browser.state, .openingMessages)
        try await assertRenderedSectionTabs(in: screen.window, named: "Messages reached from story")
        browser.selectSection(.stories)
        browser.receiveFilterState("unavailable", route: .home, isLoading: false)
        XCTAssertEqual(browser.state, .unavailable)
        try await assertRenderedSectionTabs(in: screen.window, named: "Stories unavailable")
        browser.selectSection(.stories)
        browser.webView(view, didFailProvisionalNavigation: nil,
                        withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut))
        if case .failure = browser.state {} else { XCTFail("Expected a Stories navigation failure.") }
        try await assertRenderedSectionTabs(in: screen.window, named: "Stories navigation failure")
        await browser.signOut()
    }

    func testRenderedSectionTabsPersistInConversationComposerAndMessagingFailure() async throws {
        let preferences = preferences(remember: false)
        let browser = model(preferences)
        browser.setAccessAllowed(true)
        browser.showMessages()
        let view = try XCTUnwrap(browser.webView)
        let screen = try renderedScreen(browser: browser, preferences: preferences)
        defer { screen.close() }
        try await waitUntil { view.window === screen.window }
        try await assertRenderedSectionTabs(in: screen.window, named: "Messages opening")
        browser.receiveFilterState("inbox", route: .inbox, isLoading: false)
        try await assertRenderedSectionTabs(in: screen.window, named: "Messages inbox")

        XCTAssertEqual(actionDecision(browser, view: view,
            url: "https://www.instagram.com/direct/t/123/", mainFrame: true), .allow)
        browser.receiveFilterState("conversation", route: .conversation, isLoading: false)
        XCTAssertEqual(browser.state, .conversation)
        try await assertRenderedSectionTabs(in: screen.window, named: "Messages conversation")
        browser.selectSection(.messages)
        XCTAssertEqual(browser.state, .openingMessages, "Reselecting Messages must return a conversation to the inbox.")
        XCTAssertEqual(requestedURLs.last, NavigationPolicy.inboxURL)
        browser.receiveFilterState("inbox", route: .inbox, isLoading: false)
        browser.composeMessage()
        browser.receiveFilterState("message-compose", route: .messageCompose, isLoading: false)
        XCTAssertEqual(browser.state, .messageCompose)
        try await assertRenderedSectionTabs(in: screen.window, named: "Messages composer")
        browser.selectSection(.messages)
        XCTAssertEqual(browser.state, .openingMessages, "Reselecting Messages must leave the composer for the inbox.")
        XCTAssertEqual(requestedURLs.last, NavigationPolicy.inboxURL)
        browser.receiveFilterState("messages-unavailable", route: .inbox, isLoading: false)
        XCTAssertEqual(browser.state, .messagesUnavailable)
        try await assertRenderedSectionTabs(in: screen.window, named: "Messages unavailable")
        await browser.signOut()
    }

    func testRenderedSectionTabsAreAbsentDuringWelcomeAuthenticationAndSignOut() async throws {
        let preferences = preferences(remember: false)
        let gate = CleanupGate()
        let browser = model(preferences, removeStore: { await gate.remove($0) })
        browser.setAccessAllowed(true)
        let screen = try renderedScreen(browser: browser, preferences: preferences)
        defer { screen.close(); gate.finishPending(success: true) }
        try await assertRenderedSectionTabs(in: screen.window, named: "Welcome", visible: false)
        browser.signIn()
        let view = try XCTUnwrap(browser.webView)
        try await waitUntil { view.window === screen.window }
        let loaded = expectation(description: "Local authentication footer fixture loaded")
        let delegate = LocalFixtureDelegate(loaded: loaded)
        view.navigationDelegate = delegate
        defer { view.stopLoading(); view.navigationDelegate = nil }
        view.loadHTMLString("<html><body><form><input type='password' aria-label='Password'></form></body></html>",
                            baseURL: NavigationPolicy.loginURL)
        await fulfillment(of: [loaded], timeout: 15)
        browser.webView(view, didFinish: nil)
        XCTAssertEqual(browser.state, .authentication)
        try await assertRenderedSectionTabs(in: screen.window, named: "Instagram authentication", visible: false)
        let signOut = Task { await browser.signOut() }
        defer { signOut.cancel() }
        try await waitUntil { gate.pendingCount == 1 }
        XCTAssertEqual(browser.state, .signingOut)
        try await assertRenderedSectionTabs(in: screen.window, named: "Signing out", visible: false)
        gate.finishPending(success: true)
        await signOut.value
    }

    func testMessagingBridgeRequiresExactStateRouteAgreementAndRejectsPayloads() async throws {
        let browser = model(preferences(remember: false))
        browser.setAccessAllowed(true)
        browser.showMessages()
        let view = try XCTUnwrap(browser.webView)
        let cases: [(String, NavigationPolicy.Route, String, BrowserModel.State)] = [
            (NavigationPolicy.inboxURL.absoluteString, .inbox, "inbox", .inbox),
            ("https://www.instagram.com/direct/t/123/", .conversation, "conversation", .conversation),
            (NavigationPolicy.composeURL.absoluteString, .messageCompose, "message-compose", .messageCompose)
        ]
        for (url, route, message, ready) in cases {
            XCTAssertEqual(actionDecision(browser, view: view, url: url, mainFrame: true), .allow)
            for rejected in ["inbox", "conversation", "message-compose", "home", "story", "story-loading",
                             "unavailable", "blocked", "messages", "message-sent", "messages-unavailable ",
                             #"{"state":"conversation","body":"synthetic-private-message"}"#] where rejected != message {
                browser.receiveFilterState(rejected, route: route, isLoading: false)
                XCTAssertEqual(browser.state, .openingMessages, rejected)
            }
            for wrongRoute in [NavigationPolicy.Route.home, .story, .authentication, .blocked, .inbox, .conversation, .messageCompose]
                where wrongRoute != route {
                browser.receiveFilterState(message, route: wrongRoute, isLoading: false)
                browser.receiveFilterState("messages-loading", route: wrongRoute, isLoading: false)
                browser.receiveFilterState("messages-unavailable", route: wrongRoute, isLoading: false)
                XCTAssertEqual(browser.state, .openingMessages)
            }
            browser.receiveFilterState("messages-loading", route: route, isLoading: false)
            XCTAssertEqual(browser.state, .openingMessages)
            browser.receiveFilterState(message, route: route, isLoading: false)
            XCTAssertEqual(browser.state, ready)
            browser.receiveFilterState("messages-unavailable", route: route, isLoading: false)
            XCTAssertEqual(browser.state, .messagesUnavailable)
            XCTAssertFalse(browser.state.showsWebContent)
            XCTAssertTrue(browser.state.isMessagingContext)
        }
        await browser.signOut()
    }

    func testFilterBridgeAcceptsOnlyKnownStateAndOpaqueLocationMetadata() {
        let token = "ff527b29-b27a-4f9c-b5fe-f275f6e4b209"
        for state in ["authentication", "home", "story-loading", "story", "story-unavailable", "story-ended",
                      "unavailable", "blocked", "restricted-link", "messages-loading", "inbox", "conversation",
                      "message-compose", "messages-unavailable"] {
            XCTAssertEqual(BrowserModel.filterReport(from: ["state": state, "locationID": token]),
                           BrowserModel.FilterReport(state: state, locationID: token))
        }
        let invalid: [Any] = [
            "conversation", ["state": "conversation"], ["locationID": token],
            ["state": "message-sent", "locationID": token],
            ["state": "conversation", "locationID": token, "body": "synthetic-private-message"],
            ["state": "conversation", "locationID": token, "url": "/direct/t/123/"],
            ["state": 1, "locationID": token], ["state": "conversation", "locationID": 123],
            ["state": "conversation", "locationID": ""],
            ["state": "conversation", "locationID": token + "\n"],
            ["state": "conversation", "locationID": token + "\r"],
            ["state": "conversation", "locationID": String(repeating: "a", count: 65)],
            ["state": "conversation", "locationID": "/direct/t/123/"],
            ["state": "conversation", "locationID": "token'); true; ('"],
            ["state": "conversation", "locationID": [token]]
        ]
        for body in invalid { XCTAssertNil(BrowserModel.filterReport(from: body)) }
    }

    func testOpaqueLocationMetadataRejectsQueuedThreadReadinessAndFailureAfterSPAChange() async throws {
        let browser = model(preferences(remember: false))
        browser.setAccessAllowed(true)
        browser.showMessages()
        let view = try XCTUnwrap(browser.webView)
        // The fixture isolates native bridge timing from Instagram's page structure.
        view.configuration.userContentController.removeAllUserScripts()
        let loaded = expectation(description: "Local messaging location fixture loaded")
        let delegate = LocalFixtureDelegate(loaded: loaded)
        view.navigationDelegate = delegate
        defer { view.stopLoading(); view.navigationDelegate = nil }
        view.loadHTMLString("<html><body><main>Local messaging fixture</main></body></html>", baseURL: NavigationPolicy.inboxURL)
        await fulfillment(of: [loaded], timeout: 15)
        browser.checkLocation(of: view)
        _ = try await evaluate("""
        globalThis.fixtureLocationID = 'inbox-token';
        globalThis.fixtureLocationHref = location.href;
        globalThis.storiesFilterController = {
          isCurrentLocation: token => token === fixtureLocationID && fixtureLocationHref === location.href
        };
        true;
        """, in: view)
        await browser.receiveFilterReport(.init(state: "inbox", locationID: "inbox-token"), from: view)
        XCTAssertEqual(browser.state, .inbox)

        _ = try await evaluate("""
        history.replaceState({}, '', '/direct/t/123/');
        fixtureLocationID = 'thread-a-token'; fixtureLocationHref = location.href; true;
        """, in: view)
        browser.checkLocation(of: view)
        XCTAssertEqual(browser.state, .openingMessages)
        XCTAssertFalse(browser.state.showsWebContent)
        await browser.receiveFilterReport(.init(state: "conversation", locationID: "thread-a-token"), from: view)
        XCTAssertEqual(browser.state, .conversation)

        XCTAssertEqual(actionDecision(browser, view: view,
            url: "https://www.instagram.com/direct/t/456/", mainFrame: true), .allow)
        await browser.receiveFilterReport(.init(state: "conversation", locationID: "thread-a-token"), from: view)
        XCTAssertEqual(browser.state, .openingMessages, "Queued readiness cannot cancel loading while the old thread is still committed.")
        _ = try await evaluate("history.replaceState({}, '', '/direct/t/456/'); true;", in: view)
        browser.checkLocation(of: view)
        for state in ["conversation", "messages-unavailable"] {
            await browser.receiveFilterReport(.init(state: state, locationID: "thread-a-token"), from: view)
            XCTAssertEqual(browser.state, .openingMessages, "An earlier thread's report must not replace the loading state.")
        }
        _ = try await evaluate("fixtureLocationID = 'thread-b-token'; fixtureLocationHref = location.href; true;", in: view)
        await browser.receiveFilterReport(.init(state: "conversation", locationID: "thread-b-token"), from: view)
        XCTAssertEqual(browser.state, .conversation)
        browser.setAccessAllowed(false)
        await browser.receiveFilterReport(.init(state: "messages-unavailable", locationID: "thread-b-token"), from: view)
        XCTAssertEqual(browser.state, .conversation)
        await browser.signOut()
    }

    func testFailedProvisionalConversationReloadRetriesDestinationInsteadOfCommittedInbox() async throws {
        let browser = model(preferences(remember: false))
        browser.setAccessAllowed(true)
        browser.showMessages()
        let view = try XCTUnwrap(browser.webView)
        view.configuration.userContentController.removeAllUserScripts()
        let loaded = expectation(description: "Local committed inbox fixture loaded")
        let delegate = LocalFixtureDelegate(loaded: loaded)
        view.navigationDelegate = delegate
        defer { view.stopLoading(); view.navigationDelegate = nil }
        view.loadHTMLString("<html><body><main>Local inbox fixture</main></body></html>", baseURL: NavigationPolicy.inboxURL)
        await fulfillment(of: [loaded], timeout: 15)
        browser.checkLocation(of: view)
        browser.receiveFilterState("inbox", route: .inbox, isLoading: false)
        let destination = URL(string: "https://www.instagram.com/direct/t/123/")!
        XCTAssertEqual(actionDecision(browser, view: view, url: destination.absoluteString, mainFrame: true), .allow)
        browser.webView(view, didFailProvisionalNavigation: nil,
                        withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut))
        XCTAssertEqual(browser.state, .messagesUnavailable)
        XCTAssertEqual(view.url, NavigationPolicy.inboxURL)
        browser.reload()
        XCTAssertEqual(browser.state, .openingMessages)
        XCTAssertEqual(requestedURLs.last, destination)
        await browser.signOut()
    }

    func testMessagingErrorAndReloadKeepTheRequestedComposerAndSection() async throws {
        let browser = model(preferences(remember: false))
        browser.setAccessAllowed(true)
        browser.composeMessage()
        let view = try XCTUnwrap(browser.webView)
        browser.webView(view, didFailProvisionalNavigation: nil,
                        withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut))
        XCTAssertEqual(browser.state, .messagesUnavailable)
        XCTAssertEqual(browser.section, .messages)
        browser.reload()
        XCTAssertEqual(browser.state, .openingMessages)
        XCTAssertEqual(requestedURLs, [NavigationPolicy.composeURL, NavigationPolicy.composeURL])
        browser.receiveFilterState("message-compose", route: .messageCompose, isLoading: false)
        browser.webViewWebContentProcessDidTerminate(view)
        XCTAssertEqual(browser.state, .messagesUnavailable)
        XCTAssertEqual(browser.section, .messages)
        await browser.signOut()
    }

    func testMessagingLockRejectsMetadataNavigationAndPromptsUntilAccessReturns() async throws {
        let browser = model(preferences(remember: false))
        browser.setAccessAllowed(true)
        browser.showMessages()
        browser.receiveFilterState("inbox", route: .inbox, isLoading: false)
        let view = try XCTUnwrap(browser.webView)
        let requestCount = requestedURLs.count
        browser.setAccessAllowed(false)
        browser.showStories()
        browser.showMessages()
        browser.composeMessage()
        browser.reload()
        browser.receiveFilterState("conversation", route: .conversation, isLoading: false)
        browser.receiveFilterState("restricted-link", route: .inbox, isLoading: false)
        XCTAssertEqual(browser.state, .inbox)
        XCTAssertEqual(browser.section, .messages)
        XCTAssertEqual(requestedURLs.count, requestCount)
        XCTAssertNil(browser.notice)
        XCTAssertFalse(browser.acceptsScriptMessage(isCurrentView: true, isMainFrame: true,
            scheme: "https", host: "www.instagram.com", port: 443))
        XCTAssertEqual(actionDecision(browser, view: view,
            url: "https://www.instagram.com/direct/t/123/", mainFrame: true), .cancel)
        browser.setAccessAllowed(true)
        XCTAssertTrue(browser.webView === view)
        XCTAssertEqual(browser.state, .inbox)
        await browser.signOut()
    }

    func testRememberedMessagingBackgroundResumesInboxInsteadOfThreadOrComposer() async throws {
        for (destination, route, message) in [
            ("https://www.instagram.com/direct/t/123/", NavigationPolicy.Route.conversation, "conversation"),
            (NavigationPolicy.composeURL.absoluteString, NavigationPolicy.Route.messageCompose, "message-compose")
        ] {
            let browser = model(preferences())
            browser.setAccessAllowed(true)
            browser.showMessages()
            browser.receiveFilterState("inbox", route: .inbox, isLoading: false)
            let oldView = try XCTUnwrap(browser.webView)
            let store = oldView.configuration.websiteDataStore
            XCTAssertEqual(actionDecision(browser, view: oldView, url: destination, mainFrame: true), .allow)
            browser.receiveFilterState(message, route: route, isLoading: false)
            let requestCount = requestedURLs.count
            browser.enterBackground()
            XCTAssertNil(browser.webView)
            XCTAssertFalse(browser.accessAllowed)
            XCTAssertEqual(browser.section, .messages)
            XCTAssertEqual(browser.state, .openingMessages)
            browser.showMessages()
            XCTAssertEqual(requestedURLs.count, requestCount)
            browser.setAccessAllowed(true)
            XCTAssertFalse(browser.webView === oldView)
            XCTAssertTrue(browser.webView?.configuration.websiteDataStore === store)
            XCTAssertEqual(requestedURLs.count, requestCount + 1)
            XCTAssertEqual(requestedURLs.last, NavigationPolicy.inboxURL)
            browser.receiveFilterState(message, route: route, isLoading: false)
            XCTAssertEqual(browser.state, .openingMessages, "The discarded thread or draft cannot report readiness for the inbox.")
            browser.receiveFilterState("inbox", route: .inbox, isLoading: false)
            XCTAssertEqual(browser.state, .inbox)
            await browser.signOut()
            XCTAssertEqual(browser.section, .stories)
        }
    }

    func testMessagingAuthenticationReturnsToInboxUsingAnUnscriptedLoginView() async throws {
        let browser = model(preferences(remember: false))
        browser.setAccessAllowed(true)
        browser.showMessages()
        let messagesView = try XCTUnwrap(browser.webView)
        let store = messagesView.configuration.websiteDataStore
        XCTAssertEqual(actionDecision(browser, view: messagesView,
            url: NavigationPolicy.loginURL.absoluteString, mainFrame: true), .cancel)
        let authenticationView = try XCTUnwrap(browser.webView)
        XCTAssertEqual(browser.section, .messages)
        XCTAssertEqual(browser.browserKind, .authentication)
        XCTAssertTrue(authenticationView.configuration.websiteDataStore === store)
        XCTAssertTrue(authenticationView.configuration.userContentController.userScripts.isEmpty)
        XCTAssertFalse(browser.acceptsScriptMessage(isCurrentView: true, isMainFrame: true,
            scheme: "https", host: "www.instagram.com", port: 443))
        XCTAssertEqual(responseDecision(browser, view: authenticationView,
            url: NavigationPolicy.homeURL.absoluteString, mainFrame: true), .cancel)
        let restoredMessagesView = try XCTUnwrap(browser.webView)
        XCTAssertFalse(restoredMessagesView === authenticationView)
        XCTAssertEqual(browser.browserKind, .stories)
        XCTAssertEqual(browser.section, .messages)
        XCTAssertEqual(browser.state, .openingMessages)
        XCTAssertEqual(requestedURLs, [NavigationPolicy.inboxURL, NavigationPolicy.loginURL, NavigationPolicy.inboxURL])
        XCTAssertTrue(restoredMessagesView.configuration.websiteDataStore === store)
        browser.receiveFilterState("inbox", route: .inbox, isLoading: false)
        XCTAssertEqual(browser.state, .inbox)
        await browser.signOut()
    }

    func testStoryExitLoadsFixedHomeAndIgnoresOldMessagesUntilCommit() async throws {
        for route in [NavigationPolicy.Route.home, .story] {
            let browser = model(preferences(remember: false))
            browser.setAccessAllowed(true)
            browser.showStories()
            let view = try XCTUnwrap(browser.webView)
            browser.receiveFilterState("home", route: .home, isLoading: false)
            let requestCount = requestedURLs.count
            browser.receiveFilterState("story-ended", route: route, isLoading: false)
            XCTAssertEqual(browser.state, .home, "An exit requires an active Story session.")
            XCTAssertEqual(requestedURLs.count, requestCount)
            browser.receiveFilterState("story-loading", route: route, isLoading: false)
            browser.receiveFilterState("story", route: route, isLoading: false)
            browser.receiveFilterState("story-ended", route: .blocked, isLoading: false)
            XCTAssertEqual(browser.state, .story)
            browser.receiveFilterState("story-ended", route: route, isLoading: false)
            XCTAssertEqual(browser.state, .loading)
            XCTAssertFalse(browser.state.isStoryContext)
            XCTAssertEqual(requestedURLs.count, requestCount + 1)
            XCTAssertEqual(requestedURLs.last, NavigationPolicy.homeURL)
            for message in ["story-ended", "story-loading", "story", "story-unavailable", "unavailable"] {
                browser.receiveFilterState(message, route: route, isLoading: false)
                XCTAssertEqual(browser.state, .loading, "Ignore outgoing viewer messages: \(message)")
            }
            XCTAssertEqual(requestedURLs.count, requestCount + 1)
            browser.webView(view, didCommit: nil)
            browser.receiveFilterState("home", route: .home, isLoading: false)
            XCTAssertEqual(browser.state, .home, "The committed home document can report readiness.")
            await browser.signOut()
        }
    }

    func testStoryExitRespectsAccessAndRecoversAfterBackgrounding() async throws {
        let browser = model(preferences())
        browser.setAccessAllowed(true)
        browser.showStories()
        browser.receiveFilterState("story-loading", route: .home, isLoading: false)
        browser.receiveFilterState("story", route: .home, isLoading: false)
        browser.setAccessAllowed(false)
        browser.receiveFilterState("story-ended", route: .home, isLoading: false)
        XCTAssertEqual(requestedURLs, [NavigationPolicy.homeURL], "An exit cannot navigate while access is denied.")
        browser.setAccessAllowed(true)
        browser.receiveFilterState("story-ended", route: .home, isLoading: false)
        XCTAssertEqual(browser.state, .loading)
        XCTAssertEqual(requestedURLs.count, 2)
        let oldView = try XCTUnwrap(browser.webView)
        browser.enterBackground()
        browser.setAccessAllowed(true)
        XCTAssertFalse(browser.webView === oldView)
        browser.receiveFilterState("home", route: .home, isLoading: false)
        XCTAssertEqual(browser.state, .home, "A new foreground browser must not retain the dismissed viewer's message gate.")
        await browser.signOut()
    }

    func testAuthenticationAndStoriesUseTheSameSessionWithSeparateScriptConfigurations() async throws {
        let browser = model(preferences(remember: false))
        browser.setAccessAllowed(true)
        browser.signIn()
        let authenticationView = try XCTUnwrap(browser.webView)
        let store = authenticationView.configuration.websiteDataStore
        XCTAssertTrue(authenticationView.configuration.userContentController.userScripts.isEmpty)
        XCTAssertFalse(browser.acceptsScriptMessage(isCurrentView: true, isMainFrame: true,
                                                    scheme: "https", host: "www.instagram.com", port: 443))
        let cookie = try syntheticCookie()
        await setCookie(cookie, in: store)
        browser.showStories()
        let storiesView = try XCTUnwrap(browser.webView)
        XCTAssertFalse(storiesView === authenticationView)
        XCTAssertTrue(storiesView.configuration.websiteDataStore === store)
        XCTAssertEqual(storiesView.configuration.userContentController.userScripts.count, 1)
        XCTAssertTrue(storiesView.configuration.userContentController.userScripts[0].isForMainFrameOnly)
        let cookies = await cookies(in: storiesView.configuration.websiteDataStore)
        XCTAssertTrue(cookies.contains { $0.name == cookie.name && $0.value == cookie.value })
        browser.signIn()
        let nextAuthenticationView = try XCTUnwrap(browser.webView)
        XCTAssertFalse(nextAuthenticationView === storiesView)
        XCTAssertTrue(nextAuthenticationView.configuration.websiteDataStore === store)
        XCTAssertTrue(nextAuthenticationView.configuration.userContentController.userScripts.isEmpty)
        XCTAssertTrue(storiesView.configuration.userContentController.userScripts.isEmpty)
        XCTAssertEqual(requestedURLs, [NavigationPolicy.loginURL, NavigationPolicy.homeURL, NavigationPolicy.loginURL])
        await browser.signOut()
    }

    func testAuthenticationConfigurationHasNoFilterStyleOrBridgeInRealWebKit() async throws {
        let browser = model(preferences(remember: false))
        let store = WKWebsiteDataStore.nonPersistent()
        createdStores.append(store)
        let configuration = try browser.makeConfiguration(kind: .authentication, store: store)
        XCTAssertTrue(configuration.userContentController.userScripts.isEmpty)
        let view = WKWebView(frame: .zero, configuration: configuration)
        let loaded = expectation(description: "Local authentication fixture loaded")
        let delegate = LocalFixtureDelegate(loaded: loaded)
        view.navigationDelegate = delegate
        defer { view.stopLoading(); view.navigationDelegate = nil }
        view.loadHTMLString("<html><body><form><input id='password' type='password' value='synthetic-password'></form></body></html>", baseURL: nil)
        await fulfillment(of: [loaded], timeout: 15)
        let values = try await evaluate("""
        ({filter: typeof globalThis.StoriesFilter !== 'undefined',
          controller: typeof globalThis.storiesFilterController !== 'undefined',
          style: !!document.getElementById('stories-filter-style'),
          handler: !!globalThis.webkit?.messageHandlers?.storiesState,
          password: document.getElementById('password').value})
        """, in: view) as? [String: Any]
        let result = try XCTUnwrap(values)
        for key in ["filter", "controller", "style", "handler"] { XCTAssertEqual(result[key] as? Bool, false, key) }
        XCTAssertEqual(result["password"] as? String, "synthetic-password")
    }

    func testPendingLogoutSanitizesStartupAndRetriesCleanupWithoutRestoringOldSession() async throws {
        let preferences = preferences()
        let identifier = UUID()
        preferences.set(true, forKey: "hasStarted")
        preferences.set(identifier.uuidString, forKey: "websiteDataStoreID")
        preferences.set(true, forKey: "signOutPending")
        let gate = CleanupGate()
        let browser = model(preferences, removeStore: { await gate.remove($0) })
        defer { gate.finishPending(success: true) }
        XCTAssertNil(preferences.object(forKey: "hasStarted"))
        XCTAssertNil(preferences.string(forKey: "websiteDataStoreID"))
        XCTAssertEqual(preferences.stringArray(forKey: "pendingSignOutStores"), [identifier.uuidString])
        XCTAssertNil(browser.webView)
        XCTAssertTrue(gate.identifiers.isEmpty)
        browser.setAccessAllowed(true)
        try await waitUntil { gate.pendingCount == 1 }
        XCTAssertEqual(browser.state, .signingOut)
        browser.signIn()
        browser.showStories()
        XCTAssertNil(browser.webView)
        gate.finishPending(success: false)
        try await waitUntil { browser.state == .welcome }
        XCTAssertEqual(preferences.stringArray(forKey: "pendingSignOutStores"), [identifier.uuidString])
        XCTAssertTrue(requestedURLs.isEmpty)
        browser.setAccessAllowed(false)
        browser.setAccessAllowed(true)
        try await waitUntil { gate.pendingCount == 1 }
        gate.finishPending(success: true)
        try await waitUntil { browser.state == .welcome }
        XCTAssertEqual(gate.identifiers, [identifier, identifier])
        XCTAssertEqual(preferences.stringArray(forKey: "pendingSignOutStores"), [])
        XCTAssertFalse(preferences.bool(forKey: "signOutPending"))
        XCTAssertNil(browser.webView)
        XCTAssertTrue(requestedURLs.isEmpty)
    }

    func testQueuedCleanupWinsEvenWhenPendingFlagWasAlreadyCleared() async throws {
        let preferences = preferences()
        let identifier = UUID()
        preferences.set(true, forKey: "hasStarted")
        preferences.set(identifier.uuidString, forKey: "websiteDataStoreID")
        preferences.set([identifier.uuidString], forKey: "pendingSignOutStores")
        var removed: [UUID?] = []
        let browser = model(preferences, removeStore: { store in removed.append(store.identifier); return true })
        XCTAssertNil(preferences.object(forKey: "hasStarted"))
        XCTAssertNil(preferences.string(forKey: "websiteDataStoreID"))
        browser.setAccessAllowed(true)
        try await waitUntil { browser.state == .welcome && !removed.isEmpty }
        XCTAssertEqual(removed, [identifier])
        XCTAssertNil(browser.webView)
        XCTAssertTrue(requestedURLs.isEmpty)
    }

    func testSignOutCommitsLogoutIntentBeforeWaitingForDataDeletion() async throws {
        let preferences = preferences()
        let gate = CleanupGate()
        let browser = model(preferences, removeStore: { await gate.remove($0) })
        browser.setAccessAllowed(true)
        browser.signIn()
        let identifier = try XCTUnwrap(browser.webView?.configuration.websiteDataStore.identifier)
        let signOut = Task { await browser.signOut() }
        defer { signOut.cancel(); gate.finishPending(success: true) }
        try await waitUntil { gate.pendingCount == 1 }
        XCTAssertEqual(browser.state, .signingOut)
        XCTAssertNil(browser.webView)
        XCTAssertNil(preferences.object(forKey: "hasStarted"))
        XCTAssertNil(preferences.string(forKey: "websiteDataStoreID"))
        XCTAssertTrue(preferences.bool(forKey: "signOutPending"))
        XCTAssertEqual(preferences.stringArray(forKey: "pendingSignOutStores"), [identifier.uuidString])
        browser.setAccessAllowed(true)
        browser.signIn()
        XCTAssertNil(browser.webView)
        gate.finishPending(success: true)
        await signOut.value
        XCTAssertEqual(browser.state, .welcome)
        XCTAssertFalse(preferences.bool(forKey: "signOutPending"))
        XCTAssertEqual(preferences.stringArray(forKey: "pendingSignOutStores"), [])
    }

    func testPrivateSessionHasNoSavedIdentifierAndBackgroundDiscardsIt() async throws {
        let preferences = preferences(remember: false)
        let browser = model(preferences)
        browser.setAccessAllowed(true)
        browser.signIn()
        let firstStore = try XCTUnwrap(browser.webView?.configuration.websiteDataStore)
        XCTAssertFalse(firstStore.isPersistent)
        XCTAssertNil(firstStore.identifier)
        XCTAssertNil(preferences.string(forKey: "websiteDataStoreID"))
        XCTAssertFalse(preferences.bool(forKey: "hasStarted"))
        browser.enterBackground()
        XCTAssertFalse(browser.accessAllowed)
        XCTAssertNil(browser.webView)
        try await waitUntil { browser.state == .welcome }
        browser.setAccessAllowed(true)
        XCTAssertNil(browser.webView)
        browser.signIn()
        XCTAssertFalse(browser.webView?.configuration.websiteDataStore === firstStore)
        XCTAssertEqual(browser.webView?.configuration.websiteDataStore.isPersistent, false)
        await browser.signOut()
    }

    func testRememberSessionPolicyChangesSignOutInBothDirections() async throws {
        let preferences = preferences(remember: false)
        let browser = model(preferences)
        browser.setAccessAllowed(true)
        browser.signIn()
        await browser.setRememberSession(true)
        XCTAssertTrue(browser.rememberSession)
        XCTAssertTrue(preferences.bool(forKey: "rememberSession"))
        XCTAssertEqual(browser.state, .welcome)
        XCTAssertNil(browser.webView)
        browser.signIn()
        XCTAssertEqual(browser.webView?.configuration.websiteDataStore.isPersistent, true)
        XCTAssertNotNil(preferences.string(forKey: "websiteDataStoreID"))
        await browser.setRememberSession(false)
        XCTAssertFalse(browser.rememberSession)
        XCTAssertFalse(preferences.bool(forKey: "rememberSession"))
        XCTAssertEqual(browser.state, .welcome)
        XCTAssertNil(browser.webView)
        XCTAssertNil(preferences.string(forKey: "websiteDataStoreID"))
        browser.signIn()
        XCTAssertEqual(browser.webView?.configuration.websiteDataStore.isPersistent, false)
        await browser.signOut()
    }

    func testScriptBridgeRejectsAuthenticationStaleViewsFramesAndSpoofedOrigins() async {
        let browser = model(preferences(remember: false))
        browser.setAccessAllowed(true)
        browser.showStories()
        XCTAssertTrue(browser.acceptsScriptMessage(isCurrentView: true, isMainFrame: true, scheme: "https", host: "www.instagram.com", port: 443))
        for current in [false, true] {
            for mainFrame in [false, true] where !current || !mainFrame {
                XCTAssertFalse(browser.acceptsScriptMessage(isCurrentView: current, isMainFrame: mainFrame, scheme: "https", host: "www.instagram.com", port: 443))
            }
        }
        for (scheme, host, port) in [("http", "www.instagram.com", 443), ("https", "instagram.com.evil.example", 443),
                                    ("https", "help.instagram.com", 443), ("https", "www.instagram.com", 8443)] {
            XCTAssertFalse(browser.acceptsScriptMessage(isCurrentView: true, isMainFrame: true, scheme: scheme, host: host, port: port))
        }
        browser.signIn()
        XCTAssertFalse(browser.acceptsScriptMessage(isCurrentView: true, isMainFrame: true, scheme: "https", host: "www.instagram.com", port: 443))
        await browser.signOut()
    }

    func testNavigationDecisionsRejectUntrustedFramesAttachmentsAndAutomaticExternalNavigation() async throws {
        let browser = model(preferences(remember: false))
        browser.setAccessAllowed(true)
        browser.signIn()
        let view = try XCTUnwrap(browser.webView)
        XCTAssertEqual(actionDecision(browser, view: view, url: "https://example.com/challenge/", mainFrame: false), .cancel)
        XCTAssertNotNil(browser.notice)
        XCTAssertEqual(actionDecision(browser, view: view, url: "https://www.instagram.com/challenge/frame/", mainFrame: false), .allow)
        XCTAssertEqual(responseDecision(browser, view: view, url: "https://example.com/redirected/", mainFrame: false), .cancel)
        for mainFrame in [false, true] {
            XCTAssertEqual(responseDecision(browser, view: view, url: NavigationPolicy.loginURL.absoluteString,
                                             mainFrame: mainFrame, attachment: true), .cancel)
            XCTAssertEqual(actionDecision(browser, view: view, url: "https://example.com/", mainFrame: mainFrame), .cancel)
            XCTAssertNil(browser.externalURL)
        }
        XCTAssertEqual(actionDecision(browser, view: view, url: "https://example.com/", mainFrame: nil), .cancel)
        XCTAssertNil(browser.externalURL)
        XCTAssertEqual(actionDecision(browser, view: view, url: NavigationPolicy.loginURL.absoluteString,
                                       mainFrame: true, download: true), .cancel)
        await browser.signOut()
    }

    func testLocalFrameInitializationIsAllowedOnlyInsideCurrentAuthenticationView() async throws {
        let browser = model(preferences(remember: false))
        browser.setAccessAllowed(true)
        browser.signIn()
        for destination in ["about:blank", "about:srcdoc"] {
            browser.notice = nil
            let url = URL(string: destination)!
            XCTAssertEqual(browser.decideNavigationAction(url: url, targetIsMainFrame: false,
                userInitiated: false, shouldDownload: false, isCurrentView: true, sourceIsInstagram: true), .allow)
            XCTAssertNil(browser.notice)
            for target in [true, nil] as [Bool?] {
                XCTAssertEqual(browser.decideNavigationAction(url: url, targetIsMainFrame: target,
                    userInitiated: false, shouldDownload: false, isCurrentView: true, sourceIsInstagram: true), .cancel)
            }
            XCTAssertEqual(browser.decideNavigationAction(url: url, targetIsMainFrame: false,
                userInitiated: false, shouldDownload: false, isCurrentView: false, sourceIsInstagram: true), .cancel)
        }
        browser.showStories()
        XCTAssertEqual(browser.decideNavigationAction(url: URL(string: "about:blank"), targetIsMainFrame: false,
            userInitiated: false, shouldDownload: false, isCurrentView: true, sourceIsInstagram: true), .cancel)
        await browser.signOut()
    }

    func testAuthenticationReplacementAttachesTheCurrentWebViewToSwiftUI() async throws {
        let preferences = preferences(remember: false)
        let browser = model(preferences)
        browser.setAccessAllowed(true)
        browser.showStories()
        let initialView = try XCTUnwrap(browser.webView)
        let host = UIHostingController(rootView: ContentView(browser: browser, appLock: AppLock(preferences: preferences)))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previousKeyWindow?.makeKey() }
        host.view.layoutIfNeeded()
        try await waitUntil { initialView.window === window }

        browser.signIn()
        let authenticationView = try XCTUnwrap(browser.webView)
        XCTAssertFalse(authenticationView === initialView)
        try await waitUntil { authenticationView.window === window }
        XCTAssertNil(initialView.window)

        browser.showStories()
        let storiesView = try XCTUnwrap(browser.webView)
        try await waitUntil { storiesView.window === window }
        XCTAssertNil(authenticationView.window)
        await browser.signOut()
    }

    func testGenuineWebKitLoginCanInitializeAnInheritedBlankFrame() async throws {
        let browser = model(preferences(remember: false))
        browser.setAccessAllowed(true)
        browser.signIn()
        let view = try XCTUnwrap(browser.webView)
        let loaded = expectation(description: "Local login document loaded")
        let delegate = LocalFixtureDelegate(loaded: loaded)
        view.navigationDelegate = delegate
        view.loadHTMLString("<html><body><form><input type='password'></form></body></html>", baseURL: NavigationPolicy.loginURL)
        await fulfillment(of: [loaded], timeout: 15)
        view.navigationDelegate = browser
        browser.webView(view, didFinish: nil)
        _ = try await evaluate("""
        globalThis.loginFrameReady = false;
        const frame = document.createElement('iframe');
        frame.src = 'about:blank';
        frame.onload = () => { globalThis.loginFrameReady = true; };
        document.body.appendChild(frame);
        true;
        """, in: view)
        var frameReady = false
        for _ in 0..<100 {
            frameReady = try await evaluate("globalThis.loginFrameReady", in: view) as? Bool == true
            if frameReady || browser.notice != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(browser.notice, "A local login bootstrap frame is not an unsupported provider.")
        XCTAssertTrue(frameReady, "The frame's onload must fire so Instagram's login initialization can continue.")
        XCTAssertEqual(browser.state, .authentication)
        XCTAssertTrue(browser.webView === view)
        await browser.signOut()
    }

    func testLoginSyncFrameStaysInsideCurrentAuthenticationAndAccessChecks() async throws {
        let browser = model(preferences(remember: false))
        browser.setAccessAllowed(true)
        browser.signIn()
        let authenticationView = try XCTUnwrap(browser.webView)
        let url = URL(string: "https://www.facebook.com/instagram/login_sync/")!
        func action(mainFrame: Bool? = false, trustedSource: Bool = true, currentView: Bool = true) -> WKNavigationActionPolicy {
            browser.decideNavigationAction(url: url, targetIsMainFrame: mainFrame, userInitiated: false,
                shouldDownload: false, isCurrentView: currentView, sourceIsInstagram: trustedSource)
        }
        XCTAssertEqual(action(), .allow)
        XCTAssertEqual(responseDecision(browser, view: authenticationView, url: url.absoluteString, mainFrame: false), .allow)
        XCTAssertNil(browser.notice)
        XCTAssertTrue(browser.webView === authenticationView)
        XCTAssertTrue(authenticationView.configuration.userContentController.userScripts.isEmpty)
        XCTAssertEqual(action(trustedSource: false), .cancel)
        XCTAssertEqual(action(mainFrame: true), .cancel)
        XCTAssertEqual(action(mainFrame: nil), .cancel)
        XCTAssertEqual(action(currentView: false), .cancel)
        browser.setAccessAllowed(false)
        XCTAssertEqual(action(), .cancel)
        browser.setAccessAllowed(true)
        browser.showStories()
        XCTAssertEqual(action(), .cancel)
        XCTAssertEqual(responseDecision(browser, view: try XCTUnwrap(browser.webView), url: url.absoluteString, mainFrame: false), .cancel)
        browser.showMessages()
        XCTAssertEqual(action(), .allow)
        XCTAssertEqual(responseDecision(browser, view: try XCTUnwrap(browser.webView), url: url.absoluteString, mainFrame: false), .allow)
        XCTAssertEqual(action(trustedSource: false), .cancel)
        XCTAssertEqual(action(mainFrame: true), .cancel)
        XCTAssertEqual(browser.decideNavigationAction(url: URL(string: "about:blank"), targetIsMainFrame: false,
            userInitiated: false, shouldDownload: false, isCurrentView: true, sourceIsInstagram: true), .allow)
        browser.setAccessAllowed(false)
        XCTAssertEqual(action(), .cancel)
        await browser.signOut()
    }

    func testAuthPlatformRedirectKeepsTheUnscriptedAuthenticationView() async throws {
        let browser = model(preferences(remember: false))
        browser.setAccessAllowed(true)
        browser.signIn()
        let authenticationView = try XCTUnwrap(browser.webView)
        let destination = "https://www.instagram.com/auth_platform?next=%2F"
        XCTAssertEqual(actionDecision(browser, view: authenticationView, url: destination, mainFrame: true), .allow)
        XCTAssertEqual(responseDecision(browser, view: authenticationView, url: destination, mainFrame: true), .allow)
        XCTAssertTrue(browser.webView === authenticationView)
        XCTAssertEqual(browser.browserKind, .authentication)
        XCTAssertTrue(authenticationView.configuration.userContentController.userScripts.isEmpty)
        XCTAssertNil(browser.notice)
        XCTAssertEqual(requestedURLs, [NavigationPolicy.loginURL], "Allow Instagram's original request rather than replacing it with a GET.")
        await browser.signOut()
    }

    func testRedirectDecisionsReplaceViewsAtTheAuthenticationBoundary() async throws {
        let browser = model(preferences(remember: false))
        browser.setAccessAllowed(true)
        browser.signIn()
        let authenticationView = try XCTUnwrap(browser.webView)
        let store = authenticationView.configuration.websiteDataStore
        XCTAssertEqual(responseDecision(browser, view: authenticationView, url: NavigationPolicy.homeURL.absoluteString, mainFrame: true), .cancel)
        let storiesView = try XCTUnwrap(browser.webView)
        XCTAssertEqual(browser.browserKind, .stories)
        XCTAssertTrue(storiesView.configuration.websiteDataStore === store)
        XCTAssertEqual(actionDecision(browser, view: storiesView, url: NavigationPolicy.loginURL.absoluteString, mainFrame: true), .cancel)
        XCTAssertEqual(browser.browserKind, .authentication)
        XCTAssertTrue(browser.webView?.configuration.userContentController.userScripts.isEmpty == true)
        XCTAssertEqual(responseDecision(browser, view: storiesView, url: NavigationPolicy.homeURL.absoluteString, mainFrame: true), .cancel)
        XCTAssertEqual(browser.browserKind, .authentication, "A stale view must not reopen Stories.")
        await browser.signOut()
    }

    func testAuthenticationPOSTUsesOriginalViewUntilTheResponseThenOpensAFilteredGET() async throws {
        var requests: [URLRequest] = []
        let browser = BrowserModel(preferences: preferences(remember: false), removeStore: { _ in true },
            loadRequest: { [weak self] view, request in
                requests.append(request)
                self?.trackView(view)
            })
        browser.setAccessAllowed(true)
        browser.signIn()
        let authenticationView = try XCTUnwrap(browser.webView)
        let store = authenticationView.configuration.websiteDataStore
        defer { authenticationView.stopLoading(); authenticationView.navigationDelegate = nil }
        try await loadCommittedAuthenticationFixture(in: authenticationView, browser: browser)
        var request = URLRequest(url: NavigationPolicy.homeURL)
        request.httpMethod = "POST"
        request.httpBody = Data("verification=synthetic-code".utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let decision = browser.decideNavigationAction(url: request.url, targetIsMainFrame: true,
            userInitiated: false, shouldDownload: false, isCurrentView: true,
            sourceIsInstagram: true, request: request, sourceIsMainFrame: true)
        XCTAssertEqual(decision, .allow, "The original unscripted authentication view must submit the form once.")
        XCTAssertTrue(browser.webView === authenticationView)
        XCTAssertEqual(browser.browserKind, .authentication)
        XCTAssertEqual(browser.state, .loading, "Hide the authentication document while its POST response is pending.")
        XCTAssertEqual(requests.count, 1, "Do not replace the form submission with a native GET or replay its body.")

        XCTAssertEqual(responseDecision(browser, view: authenticationView,
            url: NavigationPolicy.homeURL.absoluteString, mainFrame: true), .cancel)
        let storiesView = try XCTUnwrap(browser.webView)
        XCTAssertFalse(storiesView === authenticationView)
        XCTAssertTrue(storiesView.configuration.websiteDataStore === store)
        XCTAssertEqual(browser.browserKind, .stories)
        XCTAssertEqual(browser.state, .loading)
        XCTAssertEqual(storiesView.configuration.userContentController.userScripts.count, 1)
        let handoff = try XCTUnwrap(requests.last)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(handoff.url, NavigationPolicy.homeURL)
        XCTAssertEqual(handoff.httpMethod, "GET")
        XCTAssertNil(handoff.httpBody, "The successful form's body must never be replayed into the filtered view.")
        XCTAssertNil(handoff.httpBodyStream)
        await browser.signOut()
    }

    func testGenuineWebKitFormPOSTIsAllowedInTheOriginalAuthenticationView() async throws {
        let browser = model(preferences(remember: false))
        browser.setAccessAllowed(true)
        browser.signIn()
        let authenticationView = try XCTUnwrap(browser.webView)
        defer { authenticationView.stopLoading(); authenticationView.navigationDelegate = nil }
        try await loadCommittedAuthenticationFixture(in: authenticationView, browser: browser)
        let submitted = expectation(description: "Local synthetic authentication form submitted")
        let delegate = AuthenticationFormDelegate(browser: browser, submitted: submitted)
        authenticationView.navigationDelegate = delegate
        _ = try await evaluate("document.getElementById('fixtureForm').requestSubmit(); true", in: authenticationView)
        await fulfillment(of: [submitted], timeout: 15)
        XCTAssertEqual(delegate.request?.httpMethod, "POST")
        XCTAssertEqual(delegate.request?.url, NavigationPolicy.homeURL)
        XCTAssertEqual(delegate.policy, .allow, "Real WebKit form requests must retain the authentication POST until its response.")
        XCTAssertTrue(browser.webView === authenticationView)
        XCTAssertEqual(browser.browserKind, .authentication)
        XCTAssertEqual(browser.state, .loading)
        XCTAssertEqual(requestedURLs, [NavigationPolicy.loginURL])
        await browser.signOut()
    }

    func testNonGETAuthenticationHandoffsPreserveTheOriginalRequest() async throws {
        for startsInStories in [true, false] {
            var requests: [URLRequest] = []
            let browser = BrowserModel(preferences: preferences(remember: false), removeStore: { _ in true },
                loadRequest: { [weak self] view, request in
                    requests.append(request)
                    self?.trackView(view)
                })
            browser.setAccessAllowed(true)
            if startsInStories { browser.showStories() }
            else { browser.signIn() }
            let originalView = try XCTUnwrap(browser.webView)
            let store = originalView.configuration.websiteDataStore
            var request = URLRequest(url: URL(string: "https://www.instagram.com/challenge/synthetic/")!)
            request.httpMethod = "POST"
            request.httpBody = Data("verification=synthetic-code".utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.setValue("synthetic-header", forHTTPHeaderField: "X-Synthetic-Fixture")
            let decision = browser.decideNavigationAction(url: request.url,
                targetIsMainFrame: startsInStories ? true : nil, userInitiated: false,
                shouldDownload: false, isCurrentView: true, sourceIsInstagram: true,
                request: request, sourceIsMainFrame: true)
            XCTAssertEqual(decision, .cancel, "Cancel the original navigation after handing its complete request to the authentication view.")
            let authenticationView = try XCTUnwrap(browser.webView)
            if startsInStories { XCTAssertFalse(authenticationView === originalView) }
            XCTAssertTrue(authenticationView.configuration.websiteDataStore === store)
            XCTAssertEqual(browser.browserKind, .authentication)
            XCTAssertTrue(authenticationView.configuration.userContentController.userScripts.isEmpty)
            XCTAssertEqual(requests.count, 2)
            let handoff = try XCTUnwrap(requests.last)
            XCTAssertEqual(handoff.url, request.url)
            XCTAssertEqual(handoff.httpMethod, "POST")
            XCTAssertEqual(handoff.httpBody, request.httpBody)
            XCTAssertEqual(handoff.value(forHTTPHeaderField: "Content-Type"), request.value(forHTTPHeaderField: "Content-Type"))
            XCTAssertEqual(handoff.value(forHTTPHeaderField: "X-Synthetic-Fixture"), "synthetic-header")
            await browser.signOut()
        }
    }

    func testNativePOSTHandoffAuthorizesTheFreshWebKitActionOnlyOnce() async throws {
        var requests: [URLRequest] = []
        var recordingDelegate: AuthenticationFormDelegate?
        weak var activeBrowser: BrowserModel?
        let submitted = expectation(description: "Native synthetic POST reached fresh WebKit policy")
        let browser = BrowserModel(preferences: preferences(remember: false), removeStore: { _ in true },
            loadRequest: { [weak self] view, request in
                requests.append(request)
                self?.trackView(view)
                guard request.httpMethod == "POST", let activeBrowser else { return }
                let delegate = AuthenticationFormDelegate(browser: activeBrowser, submitted: submitted)
                recordingDelegate = delegate
                view.navigationDelegate = delegate
                // The delegate inspects the genuine native-load action and cancels network access.
                _ = view.load(request)
            })
        activeBrowser = browser
        defer { recordingDelegate = nil }
        browser.setAccessAllowed(true)
        browser.showStories()
        let storiesView = try XCTUnwrap(browser.webView)
        var request = URLRequest(url: URL(string: "https://www.instagram.com/challenge/synthetic/")!)
        request.httpMethod = "POST"
        request.httpBody = Data("verification=synthetic-code".utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("synthetic-header", forHTTPHeaderField: "X-Synthetic-Fixture")
        XCTAssertEqual(browser.decideNavigationAction(url: request.url, targetIsMainFrame: true,
            userInitiated: false, shouldDownload: false, isCurrentView: true,
            sourceIsInstagram: true, request: request, sourceIsMainFrame: true), .cancel)
        let authenticationView = try XCTUnwrap(browser.webView)
        XCTAssertFalse(authenticationView === storiesView)
        await fulfillment(of: [submitted], timeout: 15)
        let delegate = try XCTUnwrap(recordingDelegate)
        XCTAssertEqual(delegate.policy, .allow, "Authorize the native POST on its fresh view even before an Instagram document supplies the source origin.")
        XCTAssertEqual(delegate.sourceIsInstagram, false)
        let actionRequest = try XCTUnwrap(delegate.request)
        XCTAssertEqual(actionRequest.httpMethod, "POST")
        XCTAssertEqual(actionRequest.url, request.url)
        XCTAssertEqual(actionRequest.value(forHTTPHeaderField: "X-Synthetic-Fixture"), "synthetic-header")
        XCTAssertEqual(requests.count, 2, "The handoff must submit once without recursively replacing its new view.")
        XCTAssertTrue(browser.webView === authenticationView)
        XCTAssertEqual(browser.browserKind, .authentication)
        XCTAssertEqual(browser.state, .loading)
        XCTAssertEqual(browser.decideNavigationAction(url: actionRequest.url, targetIsMainFrame: true,
            userInitiated: false, shouldDownload: false, isCurrentView: true,
            sourceIsInstagram: false, request: actionRequest, sourceIsMainFrame: true), .cancel,
            "A second equivalent untrusted action cannot reuse authorization for the native load.")
        XCTAssertEqual(requests.count, 2)
        await browser.signOut()
    }

    func testLosingAccessRevokesAnUnconsumedNativePOSTHandoff() async throws {
        let browser = model(preferences(remember: false))
        browser.setAccessAllowed(true)
        browser.showStories()
        var request = URLRequest(url: NavigationPolicy.loginURL)
        request.httpMethod = "POST"
        request.httpBody = Data("verification=synthetic-code".utf8)
        XCTAssertEqual(browser.decideNavigationAction(url: request.url, targetIsMainFrame: true,
            userInitiated: false, shouldDownload: false, isCurrentView: true,
            sourceIsInstagram: true, request: request), .cancel)
        XCTAssertEqual(browser.browserKind, .authentication)
        browser.setAccessAllowed(false)
        browser.setAccessAllowed(true)
        XCTAssertEqual(browser.decideNavigationAction(url: request.url, targetIsMainFrame: true,
            userInitiated: false, shouldDownload: false, isCurrentView: true,
            sourceIsInstagram: false, request: request), .cancel)
        await browser.signOut()
    }

    func testAuthenticationHandoffWithoutAccessiblePOSTBodyFailsWithoutReplacingTheView() async throws {
        for startsInStories in [true, false] {
            var requests: [URLRequest] = []
            let browser = BrowserModel(preferences: preferences(remember: false), removeStore: { _ in true },
                loadRequest: { [weak self] view, request in
                    requests.append(request)
                    self?.trackView(view)
                })
            browser.setAccessAllowed(true)
            if startsInStories { browser.showStories() }
            else { browser.signIn() }
            let originalView = try XCTUnwrap(browser.webView)
            var request = URLRequest(url: NavigationPolicy.loginURL)
            request.httpMethod = "POST"
            XCTAssertEqual(browser.decideNavigationAction(url: request.url,
                targetIsMainFrame: startsInStories ? true : nil, userInitiated: false,
                shouldDownload: false, isCurrentView: true, sourceIsInstagram: true,
                request: request, sourceIsMainFrame: true), .cancel)
            XCTAssertTrue(browser.webView === originalView)
            XCTAssertNotNil(browser.notice, "Explain that the original form must be retried instead of silently replacing a POST with GET.")
            XCTAssertEqual(requests.count, 1)
            await browser.signOut()
        }
    }

    func testUntrustedAndSubframeSourcesCannotPerformPOSTAuthenticationHandoffs() async throws {
        let browser = model(preferences(remember: false))
        browser.setAccessAllowed(true)
        browser.signIn()
        let authenticationView = try XCTUnwrap(browser.webView)
        var request = URLRequest(url: NavigationPolicy.homeURL)
        request.httpMethod = "POST"
        request.httpBody = Data("verification=synthetic-code".utf8)
        let invalidSources: [(Bool, Bool, Bool?)] = [(false, true, true), (true, false, true),
                                                    (false, true, nil), (true, false, nil)]
        for (trustedSource, mainSource, mainTarget) in invalidSources {
            XCTAssertEqual(browser.decideNavigationAction(url: request.url, targetIsMainFrame: mainTarget,
                userInitiated: false, shouldDownload: false, isCurrentView: true,
                sourceIsInstagram: trustedSource, request: request, sourceIsMainFrame: mainSource), .cancel)
            XCTAssertTrue(browser.webView === authenticationView)
            XCTAssertEqual(requestedURLs, [NavigationPolicy.loginURL])
        }
        await browser.signOut()
    }

    func testAuthenticationSPAHistoryChangesKeepTheCommittedFormVisibleWithoutReloading() async throws {
        for (method, path) in [("pushState", "/challenge/synthetic/"), ("replaceState", "/accounts/login/?step=verification")] {
            let browser = model(preferences(remember: false))
            browser.setAccessAllowed(true)
            browser.signIn()
            let authenticationView = try XCTUnwrap(browser.webView)
            let loaded = expectation(description: "Local authentication history fixture loaded: \(method)")
            let delegate = LocalFixtureDelegate(loaded: loaded)
            authenticationView.navigationDelegate = delegate
            defer { authenticationView.stopLoading(); authenticationView.navigationDelegate = nil }
            authenticationView.loadHTMLString("<html><body><form><input id='verification' value='synthetic-code'></form></body></html>",
                                              baseURL: NavigationPolicy.loginURL)
            await fulfillment(of: [loaded], timeout: 15)
            browser.webView(authenticationView, didFinish: nil)
            XCTAssertEqual(browser.state, .authentication)
            let requestCount = requestedURLs.count
            _ = try await evaluate("history.\(method)({}, '', '\(path)'); true", in: authenticationView)
            browser.checkLocation(of: authenticationView)
            await Task.yield()
            XCTAssertEqual(browser.state, .authentication, "A committed authentication SPA has no later didFinish callback to reveal its form.")
            XCTAssertTrue(browser.webView === authenticationView)
            XCTAssertEqual(browser.browserKind, .authentication)
            XCTAssertTrue(authenticationView.configuration.userContentController.userScripts.isEmpty)
            XCTAssertEqual(requestedURLs.last, NavigationPolicy.loginURL)
            XCTAssertEqual(requestedURLs.count, requestCount, "History changes must not issue a replacement load.")
            let value = try await evaluate("document.getElementById('verification').value", in: authenticationView) as? String
            XCTAssertEqual(value, "synthetic-code")
            await browser.signOut()
        }
    }

    func testRememberedAuthenticationBackgroundPreservesTheOffscreenChallengeUntilAccessReturns() async throws {
        let preferences = preferences()
        let browser = model(preferences)
        browser.setAccessAllowed(true)
        browser.signIn()
        let authenticationView = try XCTUnwrap(browser.webView)
        let screen = try renderedScreen(browser: browser, preferences: preferences)
        defer { screen.close(); authenticationView.stopLoading(); authenticationView.navigationDelegate = nil }
        try await waitUntil { authenticationView.window === screen.window }
        let loaded = expectation(description: "Local remembered challenge fixture loaded")
        let delegate = LocalFixtureDelegate(loaded: loaded)
        authenticationView.navigationDelegate = delegate
        authenticationView.loadHTMLString("<html><body><form><input id='verification'></form></body></html>",
                                          baseURL: NavigationPolicy.loginURL)
        await fulfillment(of: [loaded], timeout: 15)
        authenticationView.navigationDelegate = browser
        browser.webView(authenticationView, didFinish: nil)
        _ = try await evaluate("""
        document.getElementById('verification').value = 'synthetic-code';
        globalThis.syntheticChallengeToken = 'same-document';
        history.pushState({}, '', '/challenge/synthetic/?step=verification'); true;
        """, in: authenticationView)
        browser.checkLocation(of: authenticationView)
        let challengeURL = try XCTUnwrap(authenticationView.url)
        let requestCount = requestedURLs.count
        XCTAssertEqual(browser.state, .authentication)

        browser.enterBackground()
        XCTAssertFalse(browser.accessAllowed)
        XCTAssertNil(browser.webView)
        try await waitUntil { authenticationView.window == nil }
        browser.enterBackground()
        browser.setAccessAllowed(false)
        browser.signIn()
        browser.showStories()
        XCTAssertNil(browser.webView, "An authentication challenge cannot reattach before device access is granted.")
        XCTAssertEqual(requestedURLs.count, requestCount)
        XCTAssertEqual(authenticationView.url, challengeURL)

        browser.setAccessAllowed(true)
        XCTAssertTrue(browser.webView === authenticationView, "Backgrounding a remembered login must preserve the existing challenge document.")
        XCTAssertEqual(browser.state, .authentication)
        XCTAssertEqual(browser.browserKind, .authentication)
        XCTAssertEqual(requestedURLs.count, requestCount)
        XCTAssertEqual(authenticationView.url, challengeURL)
        XCTAssertTrue(authenticationView.configuration.userContentController.userScripts.isEmpty)
        try await waitUntil { authenticationView.window === screen.window }
        let value = try await evaluate("document.getElementById('verification').value", in: authenticationView) as? String
        let token = try await evaluate("globalThis.syntheticChallengeToken", in: authenticationView) as? String
        XCTAssertEqual(value, "synthetic-code")
        XCTAssertEqual(token, "same-document", "Restoring the same URL is insufficient if the challenge document was replaced.")
        await browser.signOut()
    }

    func testParkedAuthenticationHistoryChangesAreRevalidatedBeforeRestoring() async throws {
        for destination in ["/explore/", "/"] {
            let browser = model(preferences())
            browser.setAccessAllowed(true)
            browser.signIn()
            let authenticationView = try XCTUnwrap(browser.webView)
            let store = authenticationView.configuration.websiteDataStore
            defer { authenticationView.stopLoading(); authenticationView.navigationDelegate = nil }
            try await loadCommittedAuthenticationFixture(in: authenticationView, browser: browser)
            let requestCount = requestedURLs.count
            browser.enterBackground()
            XCTAssertNil(browser.webView)
            _ = try await evaluate("history.replaceState({}, '', '\(destination)'); true", in: authenticationView)
            browser.checkLocation(of: authenticationView)
            XCTAssertNil(browser.webView)
            XCTAssertEqual(requestedURLs.count, requestCount)
            browser.setAccessAllowed(true)
            XCTAssertFalse(browser.webView === authenticationView, "Never reveal a parked unscripted document after its route left authentication.")
            if destination == "/explore/" {
                XCTAssertNil(browser.webView)
                XCTAssertEqual(browser.state, .unavailable)
                XCTAssertEqual(requestedURLs.count, requestCount)
            } else {
                let storiesView = try XCTUnwrap(browser.webView)
                XCTAssertEqual(browser.browserKind, .stories)
                XCTAssertEqual(browser.state, .loading)
                XCTAssertTrue(storiesView.configuration.websiteDataStore === store)
                XCTAssertEqual(storiesView.configuration.userContentController.userScripts.count, 1)
                XCTAssertEqual(requestedURLs.count, requestCount + 1)
                XCTAssertEqual(requestedURLs.last, NavigationPolicy.homeURL)
            }
            await browser.signOut()
        }
    }

    func testParkedAuthenticationProcessTerminationRetriesOnlyAfterAccessReturns() async throws {
        let browser = model(preferences())
        browser.setAccessAllowed(true)
        browser.signIn()
        let authenticationView = try XCTUnwrap(browser.webView)
        let store = authenticationView.configuration.websiteDataStore
        defer { authenticationView.stopLoading(); authenticationView.navigationDelegate = nil }
        try await loadCommittedAuthenticationFixture(in: authenticationView, browser: browser)
        _ = try await evaluate("history.replaceState({}, '', '/challenge/synthetic/'); true", in: authenticationView)
        browser.checkLocation(of: authenticationView)
        let challengeURL = try XCTUnwrap(authenticationView.url)
        browser.enterBackground()
        browser.webViewWebContentProcessDidTerminate(authenticationView)
        XCTAssertNil(browser.webView)
        XCTAssertFalse(browser.accessAllowed)
        XCTAssertEqual(requestedURLs, [NavigationPolicy.loginURL])
        browser.setAccessAllowed(true)
        let replacement = try XCTUnwrap(browser.webView)
        XCTAssertFalse(replacement === authenticationView, "A terminated challenge process cannot restore its DOM.")
        XCTAssertTrue(replacement.configuration.websiteDataStore === store)
        XCTAssertEqual(browser.browserKind, .authentication)
        XCTAssertEqual(browser.state, .loading)
        XCTAssertTrue(replacement.configuration.userContentController.userScripts.isEmpty)
        XCTAssertEqual(requestedURLs, [NavigationPolicy.loginURL, challengeURL])
        await browser.signOut()
    }

    func testTerminatedActiveAuthenticationIsDiscardedInsteadOfParkedOnBackground() async throws {
        let browser = model(preferences())
        browser.setAccessAllowed(true)
        browser.signIn()
        let authenticationView = try XCTUnwrap(browser.webView)
        let store = authenticationView.configuration.websiteDataStore
        defer { authenticationView.stopLoading(); authenticationView.navigationDelegate = nil }
        try await loadCommittedAuthenticationFixture(in: authenticationView, browser: browser)
        _ = try await evaluate("history.replaceState({}, '', '/challenge/synthetic/'); true", in: authenticationView)
        browser.checkLocation(of: authenticationView)
        let challengeURL = try XCTUnwrap(authenticationView.url)
        browser.webViewWebContentProcessDidTerminate(authenticationView)
        if case .failure = browser.state {} else { XCTFail("A terminated active authentication process must show recovery.") }
        browser.enterBackground()
        XCTAssertNil(browser.webView)
        XCTAssertFalse(browser.accessAllowed)
        XCTAssertEqual(requestedURLs, [NavigationPolicy.loginURL])
        browser.setAccessAllowed(true)
        let replacement = try XCTUnwrap(browser.webView)
        XCTAssertFalse(replacement === authenticationView, "Clear authentication readiness when its process dies so backgrounding cannot park an unusable document.")
        XCTAssertTrue(replacement.configuration.websiteDataStore === store)
        XCTAssertEqual(browser.browserKind, .authentication)
        XCTAssertEqual(browser.state, .loading)
        XCTAssertTrue(replacement.configuration.userContentController.userScripts.isEmpty)
        XCTAssertEqual(requestedURLs, [NavigationPolicy.loginURL, challengeURL])
        await browser.signOut()
    }

    func testSignOutDiscardsParkedRememberedAuthenticationInsteadOfRestoringIt() async throws {
        let preferences = preferences()
        let browser = model(preferences)
        browser.setAccessAllowed(true)
        browser.signIn()
        let authenticationView = try XCTUnwrap(browser.webView)
        let oldStore = authenticationView.configuration.websiteDataStore
        let loaded = expectation(description: "Local parked sign-out fixture loaded")
        let delegate = LocalFixtureDelegate(loaded: loaded)
        authenticationView.navigationDelegate = delegate
        defer { authenticationView.stopLoading(); authenticationView.navigationDelegate = nil }
        authenticationView.loadHTMLString("<html><body><form><input value='synthetic-code'></form></body></html>",
                                          baseURL: NavigationPolicy.loginURL)
        await fulfillment(of: [loaded], timeout: 15)
        browser.webView(authenticationView, didFinish: nil)
        browser.enterBackground()
        XCTAssertNil(browser.webView)
        await browser.signOut()
        XCTAssertEqual(browser.state, .welcome)
        XCTAssertNil(preferences.string(forKey: "websiteDataStoreID"))
        XCTAssertFalse(preferences.bool(forKey: "hasStarted"))
        browser.setAccessAllowed(true)
        XCTAssertNil(browser.webView, "Access must not resurrect the signed-out challenge.")
        XCTAssertEqual(requestedURLs, [NavigationPolicy.loginURL])
        browser.signIn()
        let newView = try XCTUnwrap(browser.webView)
        XCTAssertFalse(newView === authenticationView)
        XCTAssertFalse(newView.configuration.websiteDataStore === oldStore)
        XCTAssertEqual(responseDecision(browser, view: authenticationView, url: NavigationPolicy.homeURL.absoluteString, mainFrame: true), .cancel)
        XCTAssertTrue(browser.webView === newView)
        await browser.signOut()
    }

    func testCommittedPrivateAuthenticationIsDiscardedOnBackground() async throws {
        let browser = model(preferences(remember: false))
        browser.setAccessAllowed(true)
        browser.signIn()
        let authenticationView = try XCTUnwrap(browser.webView)
        let oldStore = authenticationView.configuration.websiteDataStore
        let loaded = expectation(description: "Local private authentication fixture loaded")
        let delegate = LocalFixtureDelegate(loaded: loaded)
        authenticationView.navigationDelegate = delegate
        defer { authenticationView.stopLoading(); authenticationView.navigationDelegate = nil }
        authenticationView.loadHTMLString("<html><body><form><input value='synthetic-code'></form></body></html>",
                                          baseURL: NavigationPolicy.loginURL)
        await fulfillment(of: [loaded], timeout: 15)
        browser.webView(authenticationView, didFinish: nil)
        XCTAssertEqual(browser.state, .authentication)
        browser.enterBackground()
        XCTAssertNil(browser.webView)
        try await waitUntil { browser.state == .welcome }
        browser.setAccessAllowed(true)
        XCTAssertNil(browser.webView)
        browser.signIn()
        let newView = try XCTUnwrap(browser.webView)
        XCTAssertFalse(newView === authenticationView)
        XCTAssertFalse(newView.configuration.websiteDataStore === oldStore)
        XCTAssertFalse(newView.configuration.websiteDataStore.isPersistent)
        await browser.signOut()
    }

    func testAuthenticationSPASuccessReplacesUnscriptedViewBeforeShowingStories() async throws {
        let browser = model(preferences(remember: false))
        browser.setAccessAllowed(true)
        browser.signIn()
        let authenticationView = try XCTUnwrap(browser.webView)
        let store = authenticationView.configuration.websiteDataStore
        let loaded = expectation(description: "Local authentication SPA fixture loaded")
        let delegate = LocalFixtureDelegate(loaded: loaded)
        authenticationView.navigationDelegate = delegate
        defer { authenticationView.stopLoading(); authenticationView.navigationDelegate = nil }
        authenticationView.loadHTMLString("<html><body><form><input type='password'></form></body></html>", baseURL: NavigationPolicy.loginURL)
        await fulfillment(of: [loaded], timeout: 15)
        XCTAssertEqual(authenticationView.url, NavigationPolicy.loginURL)
        browser.webView(authenticationView, didFinish: nil)
        XCTAssertEqual(browser.state, .authentication)
        _ = try await evaluate("history.replaceState({}, '', '/'); true", in: authenticationView)
        browser.checkLocation(of: authenticationView)
        try await waitUntil { browser.browserKind == .stories }
        let storiesView = try XCTUnwrap(browser.webView)
        XCTAssertFalse(storiesView === authenticationView)
        XCTAssertTrue(storiesView.configuration.websiteDataStore === store)
        XCTAssertEqual(storiesView.configuration.userContentController.userScripts.count, 1)
        XCTAssertEqual(browser.state, .loading, "The unscripted home document must remain hidden.")
        XCTAssertEqual(requestedURLs.last, NavigationPolicy.homeURL)
        await browser.signOut()
    }

    func testGenuineWebKitNavigationActionSwitchesToFilteredStoriesAndCancelsOldViewNavigation() async throws {
        let browser = model(preferences(remember: false))
        browser.setAccessAllowed(true)
        browser.signIn()
        let authenticationView = try XCTUnwrap(browser.webView)
        let store = authenticationView.configuration.websiteDataStore
        let loaded = expectation(description: "Local login link fixture loaded")
        let delegate = LocalFixtureDelegate(loaded: loaded)
        authenticationView.navigationDelegate = delegate
        defer { authenticationView.stopLoading(); authenticationView.navigationDelegate = nil }
        authenticationView.loadHTMLString("<html><body><a id='stories' href='/'>Stories</a></body></html>",
                                          baseURL: NavigationPolicy.loginURL)
        await fulfillment(of: [loaded], timeout: 15)
        XCTAssertEqual(authenticationView.url, NavigationPolicy.loginURL)
        authenticationView.navigationDelegate = browser
        _ = try await evaluate("document.getElementById('stories').click(); true", in: authenticationView)
        try await waitUntil { browser.browserKind == .stories }
        let storiesView = try XCTUnwrap(browser.webView)
        XCTAssertFalse(storiesView === authenticationView)
        XCTAssertTrue(storiesView.configuration.websiteDataStore === store)
        XCTAssertEqual(storiesView.configuration.userContentController.userScripts.count, 1)
        XCTAssertEqual(requestedURLs, [NavigationPolicy.loginURL, NavigationPolicy.homeURL])
        XCTAssertEqual(authenticationView.url, NavigationPolicy.loginURL,
                       "WebKit must cancel the original view's navigation before any home document loads.")
        XCTAssertEqual(browser.state, .loading)
        await browser.signOut()
    }

    func testFailedOldCleanupCannotResetAnActiveNewSessionOnTemporaryInactivity() async throws {
        let preferences = preferences()
        let oldIdentifier = UUID()
        preferences.set(true, forKey: "hasStarted")
        preferences.set(oldIdentifier.uuidString, forKey: "websiteDataStoreID")
        preferences.set(true, forKey: "signOutPending")
        var removed: [UUID?] = []
        let browser = model(preferences, removeStore: { store in removed.append(store.identifier); return false })
        browser.setAccessAllowed(true)
        try await waitUntil { browser.state == .welcome && removed.count == 1 }
        browser.showStories()
        let activeView = try XCTUnwrap(browser.webView)
        XCTAssertNotEqual(activeView.configuration.websiteDataStore.identifier, oldIdentifier)
        browser.receiveFilterState("home", route: .home, isLoading: false)
        XCTAssertEqual(browser.state, .home)
        browser.setAccessAllowed(false)
        browser.setAccessAllowed(true)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(browser.webView === activeView)
        XCTAssertEqual(browser.state, .home)
        XCTAssertEqual(removed, [oldIdentifier])
        XCTAssertEqual(requestedURLs, [NavigationPolicy.homeURL])
        await browser.signOut()
    }

    func testRealLocalSignOutRemovesSyntheticCookies() async throws {
        let browser = model(preferences(remember: false), removeStore: nil)
        browser.setAccessAllowed(true)
        browser.signIn()
        let store = try XCTUnwrap(browser.webView?.configuration.websiteDataStore)
        let cookie = try syntheticCookie()
        await setCookie(cookie, in: store)
        let before = await cookies(in: store)
        XCTAssertTrue(before.contains { $0.name == cookie.name })
        await browser.signOut()
        let after = await cookies(in: store)
        XCTAssertTrue(after.isEmpty)
        XCTAssertNil(browser.webView)
        XCTAssertEqual(browser.state, .welcome)
    }

    private func loadCommittedAuthenticationFixture(in view: WKWebView, browser: BrowserModel) async throws {
        let loaded = expectation(description: "Local committed authentication fixture loaded")
        let delegate = LocalFixtureDelegate(loaded: loaded)
        view.navigationDelegate = delegate
        view.loadHTMLString("""
        <html><body><form id='fixtureForm' method='post' action='/'>
          <input id='verification' name='verification' value='synthetic-code'>
        </form></body></html>
        """, baseURL: NavigationPolicy.loginURL)
        await fulfillment(of: [loaded], timeout: 15)
        view.navigationDelegate = browser
        browser.webView(view, didFinish: nil)
        XCTAssertEqual(browser.state, .authentication)
    }

    private func actionDecision(_ browser: BrowserModel, view: WKWebView, url: String,
                                mainFrame: Bool?, download: Bool = false) -> WKNavigationActionPolicy? {
        browser.decideNavigationAction(url: URL(string: url), targetIsMainFrame: mainFrame,
            userInitiated: false, shouldDownload: download, isCurrentView: view === browser.webView)
    }

    private func renderedScreen(browser: BrowserModel, preferences: UserDefaults) throws -> RenderedBrowserScreen {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        return RenderedBrowserScreen(scene: scene, browser: browser, appLock: AppLock(preferences: preferences))
    }

    /// Read pixels in the footer, rather than finding the same words in the native header or page content.
    /// The retained full-screen image makes the rendered native navigation reviewable in the test result.
    private func assertRenderedSectionTabs(in window: UIWindow, named name: String, visible: Bool = true,
                                           file: StaticString = #filePath, line: UInt = #line) async throws {
        await Task.yield()
        window.rootViewController?.view.setNeedsLayout()
        window.rootViewController?.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(120))
        window.layoutIfNeeded()
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let screenshot = renderer.image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true), file: file, line: line)
        }
        let attachment = XCTAttachment(image: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        let pixels = try XCTUnwrap(screenshot.cgImage, file: file, line: line)
        let footerHeight = min(pixels.height, Int(100 * screenshot.scale))
        let footer = try XCTUnwrap(pixels.cropping(to: CGRect(x: 0, y: CGFloat(pixels.height - footerHeight),
            width: CGFloat(pixels.width), height: CGFloat(footerHeight))), file: file, line: line)
        let recognition = VNRecognizeTextRequest()
        recognition.recognitionLevel = .accurate
        recognition.recognitionLanguages = ["en-US"]
        recognition.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: footer).perform([recognition])
        let recognizedText = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string.lowercased() }
        let labels = Set(recognizedText.flatMap { $0.split(whereSeparator: { !$0.isLetter }).map(String.init) })
        for label in ["stories", "messages"] {
            XCTAssertEqual(labels.contains(label), visible,
                           "\(name): expected \(label) tab \(visible ? "visible" : "absent") in the rendered footer; found \(labels.sorted()).",
                           file: file, line: line)
        }
    }

    private func responseDecision(_ browser: BrowserModel, view: WKWebView, url: String,
                                  mainFrame: Bool, attachment: Bool = false) -> WKNavigationResponsePolicy? {
        browser.decideNavigationResponse(url: URL(string: url), isMainFrame: mainFrame,
            canShowMIMEType: true, mimeType: "text/html",
            contentDisposition: attachment ? "attachment; filename=login.html" : nil,
            isCurrentView: view === browser.webView)
    }

    private func syntheticCookie() throws -> HTTPCookie {
        try XCTUnwrap(HTTPCookie(properties: [.domain: "www.instagram.com", .path: "/", .name: "stories_synthetic_test",
                                             .value: "not-a-real-session", .secure: "TRUE"]))
    }
    private func setCookie(_ cookie: HTTPCookie, in store: WKWebsiteDataStore) async {
        await withCheckedContinuation { continuation in store.httpCookieStore.setCookie(cookie) { continuation.resume() } }
    }
    private func cookies(in store: WKWebsiteDataStore) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in store.httpCookieStore.getAllCookies { continuation.resume(returning: $0) } }
    }
    private func evaluate(_ script: String, in view: WKWebView) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            view.evaluateJavaScript(script, in: nil, in: WKContentWorld.world(name: "StoriesFilter")) { continuation.resume(with: $0) }
        }
    }
}

@MainActor
private final class WeakTestWebView {
    weak var value: WKWebView?
    let storeIdentifier: UUID?

    init(_ view: WKWebView) {
        value = view
        storeIdentifier = view.configuration.websiteDataStore.identifier
    }
}

@MainActor
private final class TestStoreCleanupCompletion {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var timeout: Task<Void, Never>?

    init(continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }

    func startTimeout() {
        timeout = Task { [self] in
            do { try await Task.sleep(for: .seconds(5)) }
            catch { return }
            finish(success: false)
        }
    }

    func finish(success: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        timeout = nil
        continuation.resume(returning: success)
    }
}

@MainActor
private final class RenderedBrowserScreen {
    let window: UIWindow
    private let previousKeyWindow: UIWindow?

    init(scene: UIWindowScene, browser: BrowserModel, appLock: AppLock) {
        previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let host = UIHostingController(rootView: ContentView(browser: browser, appLock: appLock)
            .environment(\.dynamicTypeSize, .large)
            .environment(\.scenePhase, .active))
        // Fix the test's appearance and text size so the crop always covers the footer labels.
        host.overrideUserInterfaceStyle = .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
    }

    func close() {
        window.isHidden = true
        window.rootViewController = nil
        previousKeyWindow?.makeKey()
        window.windowScene = nil
    }
}

@MainActor
private final class CleanupGate {
    private var pending: [CheckedContinuation<Bool, Never>] = []
    private(set) var identifiers: [UUID?] = []
    var pendingCount: Int { pending.count }
    func remove(_ store: WKWebsiteDataStore) async -> Bool {
        identifiers.append(store.identifier)
        if Task.isCancelled { return true }
        return await withCheckedContinuation { pending.append($0) }
    }
    func finishPending(success: Bool) {
        let continuations = pending
        pending.removeAll()
        continuations.forEach { $0.resume(returning: success) }
    }
}

@MainActor
private final class AuthenticationFormDelegate: NSObject, WKNavigationDelegate {
    let browser: BrowserModel
    let submitted: XCTestExpectation
    private(set) var request: URLRequest?
    private(set) var policy: WKNavigationActionPolicy?
    private(set) var sourceIsInstagram: Bool?

    init(browser: BrowserModel, submitted: XCTestExpectation) {
        self.browser = browser
        self.submitted = submitted
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        request = navigationAction.request
        let origin = navigationAction.sourceFrame.securityOrigin
        sourceIsInstagram = NavigationPolicy.allowsScriptMessageOrigin(
            isMainFrame: true, scheme: origin.protocol, host: origin.host, port: origin.port)
        browser.webView(webView, decidePolicyFor: navigationAction) { [weak self] policy in
            self?.policy = policy
            self?.submitted.fulfill()
            // Inspect the real WebKit action without sending synthetic data to Instagram.
            decisionHandler(.cancel)
        }
    }
}

@MainActor
private final class LocalFixtureDelegate: NSObject, WKNavigationDelegate {
    let loaded: XCTestExpectation
    init(loaded: XCTestExpectation) { self.loaded = loaded }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded.fulfill() }
}
