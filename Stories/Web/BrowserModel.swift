import SwiftUI
import WebKit
import OSLog

@MainActor
final class BrowserModel: NSObject, ObservableObject {
    enum State: Equatable {
        case welcome, loading, authentication, home, openingStory, story, storyUnavailable, unavailable, failure(String), signingOut
        case openingMessages, inbox, conversation, messageCompose, messagesUnavailable
        var showsWebContent: Bool {
            self == .authentication || self == .home || self == .story
                || self == .inbox || self == .conversation || self == .messageCompose
        }
        var isStoryContext: Bool { self == .openingStory || self == .story || self == .storyUnavailable }
        var isMessagingContext: Bool {
            self == .openingMessages || self == .inbox || self == .conversation
                || self == .messageCompose || self == .messagesUnavailable
        }
    }

    enum Section { case stories, messages }
    enum BrowserKind { case authentication, stories }
    @Published private(set) var section: Section = .stories
    @Published private(set) var accessAllowed = false
    @Published private(set) var rememberSession: Bool
    private(set) var browserKind: BrowserKind?
    private var dataStore: WKWebsiteDataStore?
    private var resumeURL: URL?
    private var requestedDestination: URL?
    private var expectedRoute: NavigationPolicy.Route?
    private var observedURL: URL?
    private var restorationAttempted = false
    private var recovering = false
    private var authenticationDocumentReady = false
    private var authenticationSubmissionPending = false
    private var parkedAuthenticationView: WKWebView?
    private var activeNavigation: WKNavigation?
    private var suspendedNavigation: WKNavigation?
    private var nativeSubmission: (request: URLRequest, generation: UUID)?
    private let removeStore: (WKWebsiteDataStore) async -> Bool
    private let loadRequest: @MainActor (WKWebView, URLRequest) -> Void

    @Published private(set) var state: State = .welcome
    @Published private(set) var webView: WKWebView?
    @Published private(set) var webViewIdentity = UUID()
    @Published var notice: String?
    @Published var externalURL: URL?
    @Published private(set) var progress: Double = 0

    private let world = WKContentWorld.world(name: "StoriesFilter")
    private var observations: [NSKeyValueObservation] = []
    private var timeout: Task<Void, Never>?
    private var generation = UUID()
    private var hasStoryIntent = false
    private var awaitingHomeCommit = false
    private let preferences: UserDefaults

    init(preferences: UserDefaults = .standard,
         removeStore: ((WKWebsiteDataStore) async -> Bool)? = nil,
         loadRequest: @escaping @MainActor (WKWebView, URLRequest) -> Void = { view, request in _ = view.load(request) }) {
        self.preferences = preferences
        self.loadRequest = loadRequest
        self.removeStore = removeStore ?? { store in await BrowserModel.removeWebsiteStore(store) }
        rememberSession = preferences.object(forKey: "rememberSession") as? Bool ?? true
        super.init()
        // Pending logout wins even if termination occurred between preference writes.
        if preferences.bool(forKey: "signOutPending") {
            if let identifier = preferences.string(forKey: "websiteDataStoreID") { queueCleanup(identifier) }
            forgetSavedSession()
        } else if let identifier = preferences.string(forKey: "websiteDataStoreID"), pendingStores.contains(identifier) {
            forgetSavedSession()
        }
        if !rememberSession { forgetSavedSession() }
        // Restore only after the foreground scene has passed its device lock.
    }

    func setAccessAllowed(_ allowed: Bool) {
        accessAllowed = allowed
        webView?.setAllMediaPlaybackSuspended(!allowed, completionHandler: nil)
        if !allowed { nativeSubmission = nil; notice = nil; externalURL = nil; return }
        restoreSessionIfNeeded()
        if browserKind == .authentication, authenticationDocumentReady,
           let view = webView, !view.isLoading, let url = view.url,
           NavigationPolicy.route(for: url) == .authentication, state == .loading {
            timeout?.cancel()
            expectedRoute = nil
            authenticationSubmissionPending = false
            requestedDestination = url
            state = .authentication
        }
    }

    func enterBackground() {
        setAccessAllowed(false)
        guard state != .signingOut else { return }
        if !rememberSession {
            let store = beginSignOut()
            Task { await finishSignOut(store) }
        } else if webView != nil {
            if browserKind == .authentication, authenticationDocumentReady,
               state == .authentication, let view = webView, let url = view.url,
               NavigationPolicy.route(for: url) == .authentication {
                // Keep a committed challenge in memory while the user gets an
                // authenticator code. No document navigation is allowed while parked.
                generation = UUID()
                timeout?.cancel()
                observations.removeAll()
                suspendedNavigation = activeNavigation
                nativeSubmission = nil
                view.stopLoading()
                view.removeFromSuperview()
                parkedAuthenticationView = view
                webView = nil
                browserKind = nil
                requestedDestination = nil
                expectedRoute = nil
                observedURL = nil
                state = .loading
                return
            }
            // A remembered session resumes its section, never a private thread or draft.
            resumeURL = browserKind == .authentication
                ? [requestedDestination, webView?.url].compactMap { $0 }
                    .first(where: { NavigationPolicy.route(for: $0) == .authentication }) ?? NavigationPolicy.loginURL
                : sectionURL
            requestedDestination = nil
            detachWebView()
            timeout?.cancel()
            state = section == .messages && resumeURL != NavigationPolicy.loginURL ? .openingMessages : .loading
        }
    }

    private func restoreSessionIfNeeded() {
        guard accessAllowed, webView == nil, !recovering, state != .signingOut else { return }
        if !pendingStores.isEmpty || preferences.bool(forKey: "signOutPending") {
            recovering = true
            state = .signingOut
            let currentGeneration = generation
            Task { [weak self] in
                guard let self else { return }
                await self.cleanupPendingStores()
                self.preferences.set(false, forKey: "signOutPending")
                self.recovering = false
                guard self.generation == currentGeneration else { return }
                self.state = .welcome
                self.restoreAfterRecovery()
            }
        } else { restoreAfterRecovery() }
    }

    private func restoreAfterRecovery() {
        guard accessAllowed, webView == nil, !recovering, state != .signingOut else { return }
        if let view = parkedAuthenticationView {
            parkedAuthenticationView = nil
            if let url = view.url, NavigationPolicy.route(for: url) == .authentication {
                attach(view, kind: .authentication)
                observedURL = url
                requestedDestination = url
                state = .authentication
                return
            }
            // A parked document can still change its location using history APIs.
            // Never reveal an unfiltered or unsupported document after unlocking.
            discard(view)
            authenticationDocumentReady = false
            if let url = view.url, NavigationPolicy.route(for: url) != .blocked {
                start(at: sectionURL)
            } else {
                state = .unavailable
                notice = "This destination is outside stories and messages. Open Instagram sign-in to continue."
            }
            return
        }
        if let url = resumeURL { resumeURL = nil; start(at: url) }
        else if !restorationAttempted {
            restorationAttempted = true
            if rememberSession && preferences.bool(forKey: "hasStarted") { start(at: NavigationPolicy.homeURL) }
        }
    }

    func setRememberSession(_ remember: Bool) async {
        guard accessAllowed, remember != rememberSession, state != .signingOut else { return }
        rememberSession = remember
        preferences.set(remember, forKey: "rememberSession")
        await signOut()
    }

    private func sessionStore() -> WKWebsiteDataStore {
        if let dataStore { return dataStore }
        let store: WKWebsiteDataStore
        if rememberSession {
            let identifier = preferences.string(forKey: "websiteDataStoreID").flatMap(UUID.init(uuidString:)) ?? UUID()
            preferences.set(identifier.uuidString, forKey: "websiteDataStoreID")
            store = WKWebsiteDataStore(forIdentifier: identifier)
        } else { store = .nonPersistent() }
        dataStore = store
        return store
    }

    func signIn() { start(at: NavigationPolicy.loginURL) }

    private func start(at url: URL) {
        start(URLRequest(url: url))
    }

    private func start(_ request: URLRequest) {
        guard accessAllowed, !recovering, state != .signingOut else { return }
        guard let url = request.url else { return }
        let route = NavigationPolicy.route(for: url)
        guard route != .blocked else { return }
        let kind: BrowserKind = route == .authentication ? .authentication : .stories
        if webView != nil, browserKind == kind { load(request); return }
        do {
            let configuration = try makeConfiguration(kind: kind, store: sessionStore())
            detachWebView()
            let view = WKWebView(frame: .zero, configuration: configuration)
            view.isOpaque = false
            view.backgroundColor = .clear
            view.scrollView.backgroundColor = .clear
            view.allowsBackForwardNavigationGestures = false
            view.isInspectable = false
            attach(view, kind: kind)
            if rememberSession { preferences.set(true, forKey: "hasStarted") }
            load(request)
        } catch {
            state = section == .messages ? .messagesUnavailable
                : .failure("The content filter could not be loaded. Reinstall the app to restore it.")
        }
    }

    private func attach(_ view: WKWebView, kind: BrowserKind) {
        view.navigationDelegate = self
        view.uiDelegate = self
        browserKind = kind
        webViewIdentity = UUID()
        webView = view
        view.setAllMediaPlaybackSuspended(!accessAllowed, completionHandler: nil)
        observations = [
            view.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
                Task { @MainActor [weak self] in
                    guard view === self?.webView else { return }
                    self?.progress = view.estimatedProgress
                }
            },
            view.observe(\.url, options: [.new]) { [weak self] view, _ in
                Task { @MainActor [weak self] in self?.checkLocation(of: view) }
            }
        ]
    }

    private var sectionURL: URL { section == .messages ? NavigationPolicy.inboxURL : NavigationPolicy.homeURL }

    private func destinationAfterAuthentication(_ url: URL) -> URL {
        browserKind == .authentication && section == .messages && NavigationPolicy.route(for: url) != .authentication
            ? NavigationPolicy.inboxURL : url
    }

    // Authentication views deliberately have no user scripts or native bridge.
    func makeConfiguration(kind: BrowserKind, store: WKWebsiteDataStore) throws -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        configuration.limitsNavigationsToAppBoundDomains = true
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = .audio
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        if kind == .stories {
            guard let scriptURL = Bundle.main.url(forResource: "StoriesFilter", withExtension: "js") else {
                throw CocoaError(.fileNoSuchFile)
            }
            let source = try String(contentsOf: scriptURL, encoding: .utf8)
            configuration.userContentController.add(WeakScriptHandler(self), contentWorld: world, name: "storiesState")
            let bootstrap = source + """
            \nglobalThis.storiesFilterController = StoriesFilter.install({document, window,
                currentURL: () => new URL(window.location.href),
                report: (state, locationID) => window.webkit.messageHandlers.storiesState.postMessage({state, locationID})
            });
            """
            configuration.userContentController.addUserScript(WKUserScript(
                source: bootstrap, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world
            ))
        }
        return configuration
    }

    func selectSection(_ section: Section) {
        // Reselecting a tab returns from its viewer/composer to the section root.
        if self.section == section && ((section == .stories && state == .home)
            || (section == .messages && state == .inbox)) { return }
        if section == .stories { showStories() }
        else { showMessages() }
    }

    func showStories() {
        guard accessAllowed, !recovering, state != .signingOut else { return }
        section = .stories
        start(at: NavigationPolicy.homeURL)
    }

    func showMessages() {
        guard accessAllowed, !recovering, state != .signingOut else { return }
        section = .messages
        start(at: NavigationPolicy.inboxURL)
    }

    func composeMessage() {
        guard accessAllowed, !recovering, state != .signingOut else { return }
        section = .messages
        start(at: NavigationPolicy.composeURL)
    }

    func reload() {
        guard accessAllowed, state != .signingOut else { return }
        awaitingHomeCommit = false
        guard let view = webView else {
            if section == .messages { showMessages() } else { signIn() }
            return
        }
        let retryingDestination = expectedRoute != nil || state == .messagesUnavailable
        guard let url = retryingDestination ? requestedDestination ?? view.url : view.url ?? requestedDestination else {
            start(at: sectionURL)
            return
        }
        let route = NavigationPolicy.route(for: url)
        guard route != .blocked, route == .authentication || route.isMessaging == (section == .messages) else {
            let retry = requestedDestination.flatMap { destination -> URL? in
                let route = NavigationPolicy.route(for: destination)
                return route != .blocked && route.isMessaging == (section == .messages) ? destination : nil
            }
            start(at: retry ?? sectionURL)
            return
        }
        expectedRoute = route
        beginLoading(route: route)
        view.customUserAgent = userAgent(for: route)
        if view.url == url { view.reload() } else { load(url) }
    }

    private func userAgent(for route: NavigationPolicy.Route) -> String? {
        guard route.isMessaging else { return nil }
        // Instagram's mobile Direct document stalls on its loading skeleton in
        // WKWebView. The desktop Safari layout mounts at the same narrow viewport
        // and remains subject to the isolated filter and navigation policy.
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(version.majorVersion).\(version.minorVersion) Safari/605.1.15"
    }

    private func load(_ url: URL) {
        load(URLRequest(url: url))
    }

    private func load(_ request: URLRequest) {
        guard accessAllowed else { return }
        guard let url = request.url else { return }
        awaitingHomeCommit = false
        requestedDestination = url
        expectedRoute = NavigationPolicy.route(for: url)
        beginLoading(route: NavigationPolicy.route(for: url))
        if let webView {
            webView.endEditing(true)
            webView.customUserAgent = userAgent(for: NavigationPolicy.route(for: url))
            nativeSubmission = ["GET", "HEAD"].contains((request.httpMethod ?? "GET").uppercased())
                ? nil : (request, generation)
            loadRequest(webView, request)
        }
    }

    private func beginLoading(route: NavigationPolicy.Route = .home) {
        hasStoryIntent = route == .story
        if route.isMessaging { section = .messages }
        else if route == .home || route == .story { section = .stories }
        state = route.isMessaging ? .openingMessages : route == .story ? .openingStory : .loading
        progress = 0
        timeout?.cancel()
        let currentGeneration = generation
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(25))
            guard !Task.isCancelled, let self, self.generation == currentGeneration,
                  self.state == .loading || self.state == .openingStory || self.state == .openingMessages else { return }
            if self.state == .openingMessages { self.state = .messagesUnavailable }
            else {
                self.state = self.state == .openingStory ? .storyUnavailable
                    : .failure("Instagram took too long to respond. Check your connection and try again.")
            }
        }
    }

    func checkLocation(of view: WKWebView) {
        guard view === webView, let url = view.url else { return }
        let route = NavigationPolicy.route(for: url)
        if route == .blocked { state = section == .messages ? .messagesUnavailable : .unavailable; view.stopLoading() }
        else {
            let kind: BrowserKind = route == .authentication ? .authentication : .stories
            if browserKind != kind {
                state = .loading
                // Let an authentication form finish its original request before
                // handing the response to a newly filtered browser.
                if browserKind == .authentication && authenticationSubmissionPending && view.isLoading { return }
                // Reconcile both SPA transitions without ever revealing an unfiltered home page.
                if accessAllowed { start(at: destinationAfterAuthentication(url)) }
                else {
                    resumeURL = route == .authentication ? NavigationPolicy.loginURL : sectionURL
                    requestedDestination = nil
                    detachWebView()
                }
            } else if observedURL != url, expectedRoute == nil || expectedRoute == route {
                let authenticationHistoryChange = kind == .authentication && authenticationDocumentReady && expectedRoute == nil
                // SPA navigation must hide the previous conversation before its
                // replacement has been inspected and reported by the filter.
                observedURL = url
                requestedDestination = url
                expectedRoute = nil
                if authenticationHistoryChange {
                    // History API changes have no navigation completion callback
                    // and the unscripted login view has no readiness bridge.
                    timeout?.cancel()
                    state = .authentication
                } else { beginLoading(route: route) }
            }
        }
    }

    private var pendingStores: [String] { preferences.stringArray(forKey: "pendingSignOutStores") ?? [] }
    private func queueCleanup(_ identifier: String) {
        guard UUID(uuidString: identifier) != nil, !pendingStores.contains(identifier) else { return }
        preferences.set(pendingStores + [identifier], forKey: "pendingSignOutStores")
    }
    private func forgetSavedSession() {
        preferences.removeObject(forKey: "hasStarted")
        preferences.removeObject(forKey: "websiteDataStoreID")
    }
    private func detachWebView() {
        awaitingHomeCommit = false
        expectedRoute = nil
        observedURL = nil
        observations.removeAll()
        if let view = webView { discard(view) }
        if let view = parkedAuthenticationView { discard(view) }
        parkedAuthenticationView = nil
        authenticationDocumentReady = false
        authenticationSubmissionPending = false
        activeNavigation = nil
        suspendedNavigation = nil
        nativeSubmission = nil
        webView = nil
        browserKind = nil
    }
    private func discard(_ view: WKWebView) {
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
        view.configuration.userContentController.removeAllUserScripts()
        view.configuration.userContentController.removeScriptMessageHandler(forName: "storiesState", contentWorld: world)
        view.removeFromSuperview()
    }

    private func consumeNativeSubmission(_ request: URLRequest?, targetIsMainFrame: Bool?) -> Bool {
        guard targetIsMainFrame == true, let pending = nativeSubmission else { return false }
        nativeSubmission = nil
        guard pending.generation == generation, let request, request.url == pending.request.url,
              request.httpMethod == pending.request.httpMethod,
              request.httpBody == nil || request.httpBody == pending.request.httpBody else { return false }
        // WebKit can omit the prepared body in its delegate request. Authorization
        // is limited to this one native load; explicit headers must still agree.
        return (pending.request.allHTTPHeaderFields ?? [:]).allSatisfy {
            request.value(forHTTPHeaderField: $0.key) == $0.value
        }
    }

    private func acceptsNavigationCallback(_ navigation: WKNavigation?) -> Bool {
        guard let navigation else { return true }
        return navigation !== suspendedNavigation && (activeNavigation == nil || navigation === activeNavigation)
    }
    private func beginSignOut() -> WKWebsiteDataStore? {
        state = .signingOut
        generation = UUID()
        timeout?.cancel()
        // Commit logout intent before detaching or awaiting website-data deletion.
        preferences.set(true, forKey: "signOutPending")
        if let identifier = dataStore?.identifier?.uuidString ?? preferences.string(forKey: "websiteDataStoreID") { queueCleanup(identifier) }
        forgetSavedSession()
        let store = dataStore
        detachWebView()
        dataStore = nil
        resumeURL = nil
        requestedDestination = nil
        restorationAttempted = true
        externalURL = nil
        notice = nil
        hasStoryIntent = false
        section = .stories
        return store
    }
    func signOut() async {
        guard state != .signingOut else { return }
        let store = beginSignOut()
        await finishSignOut(store)
    }
    private func finishSignOut(_ store: WKWebsiteDataStore?) async {
        await Task.yield()
        if let store {
            let removed = await removeStore(store)
            if removed, let identifier = store.identifier { dequeueCleanup(identifier.uuidString) }
        }
        await cleanupPendingStores()
        preferences.set(false, forKey: "signOutPending")
        state = .welcome
    }
    private func dequeueCleanup(_ identifier: String) {
        preferences.set(pendingStores.filter { $0 != identifier }, forKey: "pendingSignOutStores")
    }
    private func cleanupPendingStores() async {
        for value in pendingStores {
            guard let identifier = UUID(uuidString: value) else { dequeueCleanup(value); continue }
            if await removeStore(WKWebsiteDataStore(forIdentifier: identifier)) { dequeueCleanup(value) }
        }
    }
    private static func removeWebsiteStore(_ store: WKWebsiteDataStore) async -> Bool {
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        guard let identifier = store.identifier else { return true }
        return await withCheckedContinuation { continuation in
            WKWebsiteDataStore.remove(forIdentifier: identifier) { error in continuation.resume(returning: error == nil) }
        }
    }
    func acceptsScriptMessage(isCurrentView: Bool, isMainFrame: Bool, scheme: String, host: String, port: Int) -> Bool {
        accessAllowed && isCurrentView && browserKind == .stories && NavigationPolicy.allowsScriptMessageOrigin(
            isMainFrame: isMainFrame, scheme: scheme, host: host, port: port)
    }

    struct FilterReport: Equatable {
        let state: String
        let locationID: String
    }

    static func filterReport(from body: Any) -> FilterReport? {
        guard let metadata = body as? [String: Any], Set(metadata.keys) == ["state", "locationID"],
              let state = metadata["state"] as? String, let locationID = metadata["locationID"] as? String,
              locationID.range(of: #"\A[A-Za-z0-9_-]{1,64}\z"#, options: .regularExpression) != nil else { return nil }
        let acceptedStates: Set<String> = [
            "authentication", "home", "story-loading", "story", "story-unavailable", "story-ended",
            "unavailable", "blocked", "restricted-link", "messages-loading", "inbox", "conversation",
            "message-compose", "messages-unavailable"
        ]
        guard acceptedStates.contains(state) else { return nil }
        return FilterReport(state: state, locationID: locationID)
    }

    /// Validate opaque location metadata inside the isolated filter world. A queued
    /// report from an earlier thread must not reveal it after a same-route SPA change.
    func receiveFilterReport(_ report: FilterReport, from view: WKWebView) async {
        guard Self.filterReport(from: ["state": report.state, "locationID": report.locationID]) != nil,
              view === webView, accessAllowed, browserKind == .stories, let url = view.url,
              !defersFilterReport(report, from: view) else { return }
        let currentGeneration = generation
        // filterReport(from:) restricts the token to characters safe in this literal.
        let script = "globalThis.storiesFilterController?.isCurrentLocation('\(report.locationID)') === true"
        let locationIsCurrent = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            view.evaluateJavaScript(script, in: nil, in: world) { result in
                if case .success(let valid) = result { continuation.resume(returning: valid as? Bool == true) }
                else { continuation.resume(returning: false) }
            }
        }
        guard locationIsCurrent, view === webView, view.url == url, accessAllowed,
              browserKind == .stories, generation == currentGeneration,
              !defersFilterReport(report, from: view) else { return }
        receiveFilterState(report.state, route: NavigationPolicy.route(for: url), isLoading: view.isLoading)
    }

    private func defersFilterReport(_ report: FilterReport, from view: WKWebView) -> Bool {
        guard report.state != "story-loading", report.state != "messages-loading", report.state != "restricted-link" else { return false }
        return view.isLoading || (expectedRoute != nil && requestedDestination != view.url)
    }

}

extension BrowserModel: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let origin = message.frameInfo.securityOrigin
        guard acceptsScriptMessage(isCurrentView: message.webView === webView,
                isMainFrame: message.frameInfo.isMainFrame, scheme: origin.protocol, host: origin.host, port: origin.port),
              let report = Self.filterReport(from: message.body), let view = webView else { return }
        Task { [weak self, weak view] in
            guard let self, let view else { return }
            await self.receiveFilterReport(report, from: view)
        }
    }

    /// The bridge validates origin/frame above; keep transition handling independently testable.
    func receiveFilterState(_ value: String, route: NavigationPolicy.Route, isLoading: Bool) {
        // Ignore queued messages from the dismissed viewer until the home document
        // replaces it. In particular, a late failure must not restore the error screen.
        guard accessAllowed, !awaitingHomeCommit else { return }
        if let expectedRoute, route != expectedRoute, route != .authentication { return }
        switch value {
        case "authentication" where route == .authentication:
            hasStoryIntent = false
            state = .loading
            if let url = webView?.url, accessAllowed { start(at: url) }
        case "home" where route == .home:
            hasStoryIntent = false
            section = .stories
            state = .home
        case "story-loading" where route == .story || route == .home:
            hasStoryIntent = true
            if state != .openingStory { beginLoading(route: .story) }
        case "story" where route == .story || (route == .home && hasStoryIntent):
            hasStoryIntent = true
            state = .story
        case "story-unavailable" where route == .story || (route == .home && hasStoryIntent):
            hasStoryIntent = true
            state = .storyUnavailable
        case "story-ended" where accessAllowed && hasStoryIntent && (route == .story || route == .home):
            load(NavigationPolicy.homeURL)
            awaitingHomeCommit = true
        case "messages-loading" where route.isMessaging:
            hasStoryIntent = false
            if state != .openingMessages { beginLoading(route: route) }
        case "inbox" where route == .inbox:
            hasStoryIntent = false
            section = .messages
            state = .inbox
        case "conversation" where route == .conversation:
            hasStoryIntent = false
            section = .messages
            state = .conversation
        case "message-compose" where route == .messageCompose:
            hasStoryIntent = false
            section = .messages
            state = .messageCompose
        case "messages-unavailable" where route.isMessaging:
            hasStoryIntent = false
            section = .messages
            state = .messagesUnavailable
        case "unavailable" where route == .home || route == .story:
            if state == .loading && isLoading { return }
            state = route == .story || hasStoryIntent ? .storyUnavailable : .unavailable
        case "blocked" where route == .blocked:
            hasStoryIntent = false
            state = section == .messages ? .messagesUnavailable : .unavailable
        case "restricted-link": notice = "This app keeps you in stories and messages. Feeds, profiles, and Reels stay closed."
        default: return
        }
        if state != .loading && state != .openingStory && state != .openingMessages {
            expectedRoute = nil
            if let url = webView?.url, NavigationPolicy.route(for: url) == route { observedURL = url }
            timeout?.cancel()
        }
    }
}

extension BrowserModel: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let origin = navigationAction.sourceFrame.securityOrigin
        let sourceIsInstagram = NavigationPolicy.allowsScriptMessageOrigin(
            isMainFrame: true, scheme: origin.protocol, host: origin.host, port: origin.port)
        let policy = decideNavigationAction(url: navigationAction.request.url,
            targetIsMainFrame: navigationAction.targetFrame?.isMainFrame,
            userInitiated: navigationAction.navigationType == .linkActivated,
            shouldDownload: navigationAction.shouldPerformDownload, isCurrentView: webView === self.webView,
            sourceIsInstagram: sourceIsInstagram, request: navigationAction.request,
            sourceIsMainFrame: navigationAction.sourceFrame.isMainFrame)
        #if DEBUG
        // Log only classification and origin metadata, never URL paths/queries,
        // form bodies, page content, passwords, or cookies.
        let url = navigationAction.request.url
        let frame = navigationAction.targetFrame.map { $0.isMainFrame ? "main" : "subframe" } ?? "new-window"
        let route = url.map { NavigationPolicy.route(for: $0).rawValue } ?? "missing-url"
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "Stories", category: "Navigation").debug(
            "action policy=\(policy.rawValue) frame=\(frame, privacy: .public) scheme=\(url?.scheme ?? "", privacy: .public) host=\(url?.host ?? "", privacy: .public) route=\(route, privacy: .public) trustedSource=\(sourceIsInstagram)")
        #endif
        decisionHandler(policy)
    }

    func decideNavigationAction(url: URL?, targetIsMainFrame: Bool?, userInitiated: Bool,
                                shouldDownload: Bool, isCurrentView: Bool,
                                sourceIsInstagram: Bool = false, request: URLRequest? = nil,
                                sourceIsMainFrame: Bool = true) -> WKNavigationActionPolicy {
        guard isCurrentView, accessAllowed, !shouldDownload, let url else {
            return .cancel
        }
        let authorizedNativeSubmission = consumeNativeSubmission(request, targetIsMainFrame: targetIsMainFrame)
        if targetIsMainFrame == false {
            let allowed = NavigationPolicy.allowsSubframe(url, authentication: browserKind == .authentication,
                                                         messaging: section == .messages, sourceIsInstagram: sourceIsInstagram)
            if !allowed, browserKind == .authentication {
                notice = "Instagram requested an unsupported verification provider. This frame was blocked. Try another verification method on Instagram’s login page."
            }
            return allowed ? .allow : .cancel
        }
        let decision = NavigationPolicy.decide(url, userInitiated: userInitiated)
        switch decision {
        case .allow:
            let originalRequest = request ?? URLRequest(url: url)
            guard originalRequest.url == url else { return .cancel }
            let isSubmission = !["GET", "HEAD"].contains((originalRequest.httpMethod ?? "GET").uppercased())
            if isSubmission && !authorizedNativeSubmission && (!sourceIsInstagram || !sourceIsMainFrame) { return .cancel }
            let destination = destinationAfterAuthentication(url)
            let route = NavigationPolicy.route(for: destination)
            let kind: BrowserKind = route == .authentication ? .authentication : .stories
            if isSubmission, browserKind == .authentication, kind == .stories, targetIsMainFrame == true {
                // The server must process the form before response policy swaps
                // the hidden authentication document for a filtered GET view.
                requestedDestination = url
                expectedRoute = NavigationPolicy.route(for: url)
                authenticationSubmissionPending = true
                beginLoading(route: .authentication)
                return .allow
            }
            if browserKind != kind || targetIsMainFrame == nil || destination != url {
                if isSubmission {
                    // WebKit may omit a prepared form body. Never silently turn
                    // that submission into GET or submit an incomplete request.
                    guard destination == url,
                          originalRequest.httpBody != nil || originalRequest.httpBodyStream != nil else {
                        notice = "Instagram couldn’t transfer this sign-in step. Open Instagram sign-in and try again."
                        return .cancel
                    }
                }
                start(destination == url ? originalRequest : URLRequest(url: destination))
                return .cancel
            } else {
                requestedDestination = destination
                expectedRoute = route
                beginLoading(route: route)
                return .allow
            }
        case .external:
            externalURL = NavigationPolicy.externalDestination(for: url)
            return .cancel
        case .block:
            notice = "This destination is outside stories and messages. Return to either section or finish signing in on Instagram."
            return .cancel
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let attachment = (navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")
        decisionHandler(decideNavigationResponse(url: navigationResponse.response.url,
            isMainFrame: navigationResponse.isForMainFrame, canShowMIMEType: navigationResponse.canShowMIMEType,
            mimeType: navigationResponse.response.mimeType, contentDisposition: attachment,
            isCurrentView: webView === self.webView))
    }

    func decideNavigationResponse(url: URL?, isMainFrame: Bool, canShowMIMEType: Bool,
                                  mimeType: String?, contentDisposition: String?,
                                  isCurrentView: Bool) -> WKNavigationResponsePolicy {
        guard isCurrentView, accessAllowed,
              NavigationPolicy.allowsResponse(url: url,
                isMainFrame: isMainFrame, authentication: browserKind == .authentication,
                messaging: section == .messages, canShowMIMEType: canShowMIMEType, mimeType: mimeType,
                contentDisposition: contentDisposition) else {
            if isCurrentView, accessAllowed {
                if isMainFrame { state = section == .messages ? .messagesUnavailable : .unavailable }
                else if browserKind == .authentication { notice = "Instagram’s verification frame was blocked because its destination or content is unsupported." }
            }
            return .cancel
        }
        if isMainFrame, let url {
            let destination = destinationAfterAuthentication(url)
            let kind: BrowserKind = NavigationPolicy.route(for: destination) == .authentication ? .authentication : .stories
            if browserKind != kind || destination != url { start(at: destination); return .cancel }
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard webView === self.webView, accessAllowed,
              acceptsNavigationCallback(navigation) else { return }
        awaitingHomeCommit = false
        checkLocation(of: webView)
        guard webView === self.webView, browserKind == .authentication,
              let url = webView.url, NavigationPolicy.route(for: url) == .authentication else { return }
        timeout?.cancel()
        authenticationDocumentReady = true
        authenticationSubmissionPending = false
        observedURL = url
        expectedRoute = nil
        requestedDestination = url
        state = .authentication
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard accessAllowed, acceptsNavigationCallback(navigation) else { return }
        checkLocation(of: webView)
        guard webView === self.webView else { return }
        if browserKind == .authentication {
            guard let url = webView.url, NavigationPolicy.route(for: url) == .authentication else { return }
            timeout?.cancel()
            authenticationDocumentReady = true
            authenticationSubmissionPending = false
            observedURL = url
            expectedRoute = nil
            requestedDestination = url
            state = .authentication
            return
        }
        // A missing or broken filter must never reveal the Stories page.
        webView.evaluateJavaScript("storiesFilterController.refresh(true); true", in: nil, in: world) { [weak self] result in
            guard let self, webView === self.webView else { return }
            if case .success(let installed) = result, installed as? Bool == true { return }
            self.state = self.section == .messages ? .messagesUnavailable
                : .failure("The content filter did not start. The page has been kept hidden.")
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard webView === self.webView, accessAllowed else { return }
        activeNavigation = navigation
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard acceptsNavigationCallback(navigation) else { return }
        failed(error, from: webView)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard acceptsNavigationCallback(navigation) else { return }
        failed(error, from: webView)
    }

    private func failed(_ error: Error, from view: WKWebView) {
        guard view === webView, accessAllowed else { return }
        if (error as NSError).domain == NSURLErrorDomain && (error as NSError).code == NSURLErrorCancelled {
            if browserKind == .authentication, authenticationDocumentReady, !view.isLoading,
               let url = view.url, NavigationPolicy.route(for: url) == .authentication {
                timeout?.cancel()
                expectedRoute = nil
                authenticationSubmissionPending = false
                requestedDestination = url
                state = .authentication
            }
            return
        }
        #if DEBUG
        let failure = error as NSError
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "Stories", category: "Navigation").error(
            "load failed domain=\(failure.domain, privacy: .public) code=\(failure.code)")
        #endif
        timeout?.cancel()
        state = section == .messages && browserKind != .authentication ? .messagesUnavailable
            : hasStoryIntent ? .storyUnavailable : .failure("Instagram couldn’t load. Check your connection, then try again.")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if webView === parkedAuthenticationView {
            resumeURL = webView.url.flatMap { NavigationPolicy.route(for: $0) == .authentication ? $0 : nil }
                ?? NavigationPolicy.loginURL
            discard(webView)
            parkedAuthenticationView = nil
            authenticationDocumentReady = false
            return
        }
        guard webView === self.webView else { return }
        authenticationDocumentReady = false
        authenticationSubmissionPending = false
        nativeSubmission = nil
        activeNavigation = nil
        suspendedNavigation = nil
        timeout?.cancel()
        state = section == .messages && browserKind != .authentication ? .messagesUnavailable
            : hasStoryIntent ? .storyUnavailable : .failure("Instagram’s browser stopped. Reload to continue.")
    }
}

extension BrowserModel: WKUIDelegate {
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }

    func webView(_ webView: WKWebView, contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
                 completionHandler: @escaping (UIContextMenuConfiguration?) -> Void) {
        completionHandler(nil)
    }
}

/// WKUserContentController retains handlers; this proxy prevents a browser/model cycle.
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
