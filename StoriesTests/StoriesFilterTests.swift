import WebKit
import XCTest
@testable import Stories

/// Real WebKit DOM tests, with local HTML fixtures. No Instagram account or network needed.
@MainActor
final class StoriesFilterTests: XCTestCase, WKScriptMessageHandler {
    private var view: WKWebView!
    private var ready: XCTestExpectation?
    private var states: [String] = []
    private let world = WKContentWorld.world(name: "StoriesFilterTests")

    private func fixture(_ html: String, url: String = "https://www.instagram.com/", viewerWaitMs: Int = 12000,
                         viewportHeight: Int? = nil) async throws {
        closeFixture()
        states = []
        ready = expectation(description: "Filter installed")
        let sourceURL = try XCTUnwrap(Bundle.main.url(forResource: "StoriesFilter", withExtension: "js"))
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let encodedURL = String(data: try JSONEncoder().encode(url), encoding: .utf8)!
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.limitsNavigationsToAppBoundDomains = true
        config.userContentController.add(self, contentWorld: world, name: "testState")
        config.userContentController.addUserScript(WKUserScript(source: source + """
        \nglobalThis.fixtureURL = \(encodedURL);
        globalThis.fixtureReports = [];
        if (\(viewportHeight != nil)) {
          globalThis.fixtureViewport = Object.assign(new EventTarget(), {height: \(viewportHeight ?? 700), offsetTop: 0});
          Object.defineProperty(window, 'visualViewport', {value: fixtureViewport});
        }
        globalThis.filter = StoriesFilter.install({document, window,
          viewerWaitMs: \(viewerWaitMs),
          currentURL: () => new URL(globalThis.fixtureURL),
          report: (state, locationID) => {
            globalThis.fixtureReports.push({state, locationID});
            window.webkit.messageHandlers.testState.postMessage(state);
          }
        });
        window.webkit.messageHandlers.testState.postMessage('ready');
        """, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world))
        view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 700), configuration: config)
        view.loadHTMLString("<!doctype html><html><head><meta name='viewport' content='width=device-width'></head><body>\(html)</body></html>", baseURL: nil)
        await fulfillment(of: [ready!], timeout: 15)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let value = message.body as? String else { return }
        if value == "ready" { ready?.fulfill(); ready = nil } else { states.append(value) }
    }

    private func evaluate(_ script: String) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            view.evaluateJavaScript(script, in: nil, in: world) { result in
                continuation.resume(with: result)
            }
        }
    }

    private func visible(_ id: String) async throws -> Bool {
        try await evaluate("""
        (() => {
          const el = document.getElementById('\(id)');
          return !!el && getComputedStyle(el).visibility === 'visible' && !!el.getClientRects().length;
        })()
        """) as? Bool == true
    }

    /// A nonempty bounding box alone does not prove visibility: overflow can clip it away.
    private func hittable(_ id: String) async throws -> Bool {
        try await evaluate("""
        (() => {
          const el = document.getElementById('\(id)');
          const rect = el.getBoundingClientRect();
          if (rect.width <= 0 || rect.height <= 0) return false;
          const hit = document.elementFromPoint(rect.x + rect.width / 2, rect.y + rect.height / 2);
          return !!hit && (el === hit || el.contains(hit));
        })()
        """) as? Bool == true
    }

    override func tearDown() {
        closeFixture()
        super.tearDown()
    }

    private func closeFixture() {
        view?.stopLoading()
        view?.configuration.userContentController.removeScriptMessageHandler(forName: "testState", contentWorld: world)
        view = nil
    }

    func testOnlyStoryTrayIsVisible() async throws {
        try await fixture("""
        <nav id='nav'><a href='/reels/'>Reels</a></nav>
        <main><div><a id='anna' href='/stories/anna/123/'>Anna</a><a id='sam' href='/stories/sam/'>Sam</a></div>
        <article id='post'>Suggested post <a id='embedded' href='/stories/ad/123/'>Advertisement</a></article></main>
        <aside id='suggestions'>Suggested accounts</aside>
        """)
        let anna = try await visible("anna"), sam = try await visible("sam")
        let post = try await visible("post"), nav = try await visible("nav")
        let embedded = try await visible("embedded"), suggestions = try await visible("suggestions")
        XCTAssertTrue(anna); XCTAssertTrue(sam)
        XCTAssertFalse(post); XCTAssertFalse(nav); XCTAssertFalse(embedded); XCTAssertFalse(suggestions)
        XCTAssertEqual(states.last, "home")
    }

    func testUnknownLayoutStaysHidden() async throws {
        try await fixture("<main id='unknown'>New feed layout</main>")
        let isVisible = try await visible("unknown")
        XCTAssertFalse(isVisible)
        XCTAssertEqual(states.last, "unavailable")
    }

    func testAbsoluteCarouselKeepsItsHeightAndCanBeTapped() async throws {
        try await fixture("""
        <main>
          <div id='viewport' style='height:110px; overflow:hidden; position:relative'>
            <ul style='height:104px; position:relative; margin:0; padding:0; list-style:none'>
              <li style='position:absolute; left:0; top:0; width:80px; height:100px'>
                <a id='story' href='/stories/anna/' style='display:block; width:80px; height:100px'>
                  <img width='64' height='64' alt='Anna'><span>Anna</span>
                </a>
              </li>
            </ul>
          </div>
          <article id='post'>Suggested post</article>
        </main>
        """)
        let height = try await evaluate("document.getElementById('viewport').getBoundingClientRect().height") as? Double
        let canTap = try await hittable("story")
        let postVisible = try await visible("post")
        XCTAssertEqual(height, 110)
        XCTAssertTrue(canTap, "The Story must be inside its visible, tappable carousel viewport.")
        XCTAssertFalse(postVisible)
        XCTAssertEqual(states.last, "home")
    }

    func testLiveCarouselStructureKeepsScrollContainerHittableAndPreservesItsOffset() async throws {
        // Structure measured on the failing iPhone: visible ring buttons inside a
        // wide flex track, inside an overflow:auto container hidden by our filter.
        let cards = (0..<9).map { index in
            """
            <div id='card\(index)' role='button' aria-label='Story' onclick="this.dataset.clicked='yes'"
                 style='display:flex; flex-direction:column; flex:0 0 102px; height:108px; touch-action:manipulation'>
              <img width='80' height='80' alt='Fixture'><span>Story</span>
            </div>
            """
        }.joined()
        try await fixture("""
        <main><div id='carousel' style='display:flex; overflow:auto; padding:8px 0'>
          <div id='track' style='display:flex; padding:0 9px'>\(cards)</div>
        </div><article id='feed'>Feed content</article></main>
        """)
        let scrollContainerVisible = try await visible("carousel")
        XCTAssertTrue(scrollContainerVisible, "Visible cards alone do not make a hidden WebKit scrolling box interactive.")
        let paddingHitsScroller = try await evaluate("""
        (() => { const el = document.getElementById('carousel'), r = el.getBoundingClientRect();
          return document.elementFromPoint(r.left + 2, r.top + 2) === el; })()
        """) as? Bool
        XCTAssertEqual(paddingHitsScroller, true)
        let offscreenCard = try await hittable("card8")
        XCTAssertFalse(offscreenCard)
        let moved = try await evaluate("""
        (() => { const el = document.getElementById('carousel');
          el.scrollLeft = el.scrollWidth; return el.scrollLeft; })()
        """) as! Double
        XCTAssertGreaterThan(moved, 0)
        _ = try await evaluate("filter.refresh(); filter.refresh();")
        let retainedOffset = try await evaluate("document.getElementById('carousel').scrollLeft") as! Double
        XCTAssertEqual(retainedOffset, moved, accuracy: 1)
        let lastCard = try await hittable("card8"), feed = try await visible("feed"), track = try await visible("track")
        XCTAssertTrue(lastCard); XCTAssertFalse(feed); XCTAssertFalse(track)
        let clicked = try await evaluate("document.getElementById('card8').click(); document.getElementById('card8').dataset.clicked") as? String
        XCTAssertEqual(clicked, "yes", "The original Story control retains its event handler.")
        let markersAfterOpening = try await evaluate("document.querySelectorAll('[data-stories-scroller]').length") as? Int
        XCTAssertEqual(markersAfterOpening, 0, "The carousel visibility exception applies only to the home tray.")
    }

    func testSharedScrollableFeedContainerIsNotRevealed() async throws {
        try await fixture("""
        <main><div id='shared' style='display:flex; overflow:auto; width:300px'>
          <a href='/stories/anna/' style='flex:0 0 100px'>Anna</a>
          <a href='/stories/sam/' style='flex:0 0 100px'>Sam</a>
          <article id='feed' style='flex:0 0 600px'>Suggested post</article>
        </div></main>
        """)
        let shared = try await visible("shared"), feed = try await visible("feed")
        XCTAssertFalse(shared); XCTAssertFalse(feed)
        let scrollers = try await evaluate("document.querySelectorAll('[data-stories-scroller]').length") as? Int
        XCTAssertEqual(scrollers, 0)
        XCTAssertEqual(states.last, "home")
    }

    func testStoryLinkOverlayPreservesSiblingAvatarAndName() async throws {
        try await fixture("""
        <main><ul><li style='position:relative; width:84px; height:100px; list-style:none'>
          <img id='avatar' width='64' height='64' alt='Anna'>
          <span id='name'>Anna</span>
          <a id='story' aria-label="Anna's story" href='/stories/anna/' style='position:absolute; inset:0'></a>
        </li></ul><article id='post'>Feed content</article></main>
        """)
        let avatar = try await visible("avatar"), name = try await visible("name")
        let canTap = try await hittable("story"), post = try await visible("post")
        XCTAssertTrue(avatar); XCTAssertTrue(name); XCTAssertTrue(canTap); XCTAssertFalse(post)
        XCTAssertEqual(states.last, "home")
    }

    func testInvisibleLinksDoNotReportAReadyHomeScreen() async throws {
        try await fixture("""
        <main><div style='display:none'><a href='/stories/anna/'>Anna</a></div>
        <a href='/stories/sam/' style='position:absolute; width:80px; height:90px'></a></main>
        """)
        XCTAssertEqual(states.last, "unavailable", "Hidden links and empty hit targets must not produce a blank success screen.")
    }

    func testMobileRingButtonsKeepArtworkLabelsAndOriginalActions() async throws {
        try await fixture("""
        <main><div role='menu' style='height:110px; overflow:hidden'>
          <div style='width:84px; height:104px'>
            <div id='story' role='button' tabindex='0' onclick="this.dataset.clicked='yes'" style='position:relative; width:72px; height:72px'>
              <canvas width='72' height='72' style='position:absolute; inset:0'></canvas>
              <img id='avatar' width='64' height='64' alt='Anna'>
            </div><span id='name'>Anna</span>
          </div>
        </div><article id='post'><div role='button'><canvas></canvas><img alt='Post author'></div>Feed</article></main>
        """)
        let avatar = try await visible("avatar"), name = try await visible("name")
        let canTap = try await hittable("story"), post = try await visible("post")
        let clicked = try await evaluate("document.getElementById('story').click(); document.getElementById('story').dataset.clicked") as? String
        XCTAssertTrue(avatar); XCTAssertTrue(name); XCTAssertTrue(canTap); XCTAssertFalse(post)
        XCTAssertEqual(clicked, "yes", "Filtering must keep the original Instagram controls and handlers.")
        XCTAssertEqual(states.last, "story-loading")
    }

    func testStoryLabelsDoNotRequireACanvasRing() async throws {
        try await fixture("""
        <main><button id='story' aria-label="Anna's story"><img width='64' height='64' alt='Anna'>Anna</button></main>
        """)
        let canTap = try await hittable("story")
        XCTAssertTrue(canTap)
        XCTAssertEqual(states.last, "home")
    }

    func testCardExpansionDoesNotRevealNeighbouringSuggestions() async throws {
        try await fixture("""
        <main><div><a id='story' href='/stories/anna/'>Anna</a>
          <button id='suggested'><img width='64' height='64' alt='Someone'>Follow</button>
        </div></main>
        """)
        let story = try await visible("story"), suggested = try await visible("suggested")
        XCTAssertTrue(story); XCTAssertFalse(suggested)
    }

    func testClippedArtworkDoesNotReportReady() async throws {
        try await fixture("""
        <main><div style='height:0; overflow:hidden'>
          <a href='/stories/anna/' style='display:block; height:100px'>Anna</a>
        </div></main>
        """)
        XCTAssertEqual(states.last, "unavailable")
    }

    func testReadinessRecoversAfterStylesheetChangesWithoutDOMMutation() async throws {
        try await fixture("""
        <style id='fixture-style'>#tray { opacity:0; }</style>
        <main id='tray'><a href='/stories/anna/'>Anna</a></main>
        """)
        XCTAssertEqual(states.last, "unavailable")
        _ = try await evaluate("document.getElementById('fixture-style').sheet.insertRule('#tray { opacity:1; }', 1)")
        for _ in 0..<20 {
            if states.last == "home" { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(states.last, "home", "CSS-only layout updates must not leave the app in a stale state.")
    }

    func testDynamicPostsStayHiddenAndStoriesBecomeVisible() async throws {
        try await fixture("<main id='main'><a href='/stories/anna/'>Anna</a></main>")
        _ = try await evaluate("document.getElementById('main').insertAdjacentHTML('beforeend', `<article id='latePost'>Feed</article><a id='lateStory' href='/stories/sam/'>Sam</a>`)")
        // A separate WebKit round trip runs after MutationObserver delivery.
        let postVisible = try await visible("latePost"), storyVisible = try await visible("lateStory")
        XCTAssertFalse(postVisible); XCTAssertTrue(storyVisible)
    }

    func testAuthenticationPageIsUntouchedAndOnlyStateIsReported() async throws {
        try await fixture("<form id='login'><input id='password' type='password' value='private-test-value'><button>Log in</button></form>",
                          url: "https://www.instagram.com/accounts/login/")
        let isVisible = try await visible("login")
        let password = try await evaluate("document.getElementById('password').value") as? String
        XCTAssertTrue(isVisible); XCTAssertEqual(password, "private-test-value")
        XCTAssertEqual(states, ["authentication"])
    }

    func testViewerAndSPARouteGuard() async throws {
        try await fixture("<nav id='nav'>Explore</nav><main id='viewer'><img width='300' height='500' alt='Story' src='data:image/svg+xml,%3Csvg xmlns=%22http://www.w3.org/2000/svg%22/%3E'><button id='next' aria-label='Next'>Next</button></main>",
                          url: "https://www.instagram.com/stories/anna/123/")
        let viewer = try await visible("viewer"), nav = try await visible("nav")
        XCTAssertTrue(viewer); XCTAssertFalse(nav)
        _ = try await evaluate("globalThis.fixtureURL = 'https://www.instagram.com/reels/'; filter.refresh();")
        let afterNavigation = try await visible("viewer")
        XCTAssertFalse(afterNavigation)
        XCTAssertEqual(states.last, "blocked")
    }

    func testGenericDivStoryViewerKeepsMediaAndControlsVisible() async throws {
        try await fixture("""
        <div id='viewer' style='position:fixed; inset:0; background:black'>
          <div><button id='close' aria-label='Schließen'>×</button></div>
          <div><img id='media' width='300' height='500' alt='Story'></div>
          <div><button id='previous'>‹</button><button id='next'>›</button></div>
        </div>
        """, url: "https://www.instagram.com/stories/anna/123/")
        let media = try await visible("media"), next = try await visible("next"), close = try await visible("close")
        XCTAssertTrue(media); XCTAssertTrue(next); XCTAssertTrue(close)
        XCTAssertEqual(states.last, "story")
    }

    func testStoryArticleInsideDialogIsNotTreatedAsFeed() async throws {
        try await fixture("""
        <div role='dialog' style='position:fixed; inset:0'>
          <article id='story'><img id='media' width='300' height='500' alt='Story'></article>
          <nav><button id='next'>Next story</button></nav>
        </div>
        """, url: "https://www.instagram.com/stories/anna/123/")
        let media = try await visible("media"), next = try await visible("next")
        XCTAssertTrue(media); XCTAssertTrue(next)
        XCTAssertEqual(states.last, "story")
    }

    func testViewerMountUsesLoadingStateInsteadOfEmptyTrayFallback() async throws {
        try await fixture("<div role='dialog'><img width='32' height='32' alt='Avatar'><div role='progressbar'>Loading story</div></div>",
                          url: "https://www.instagram.com/stories/anna/123/")
        XCTAssertEqual(states.last, "story-loading")
    }

    func testDedicatedViewerDoesNotRevealEnclosingApplicationShell() async throws {
        for modal in ["", "role='dialog'"] {
            try await fixture("""
            <div style='min-height:100vh'>
              <nav id='nav'><button>Explore</button></nav>
              <aside id='suggestions'>Suggested accounts</aside>
              <div \(modal) id='viewer' style='position:fixed; inset:0'>
                <img id='media' width='300' height='500' alt='Story'>
                <button id='close'>Close</button><button id='next'>Next</button>
              </div>
            </div>
            """, url: "https://www.instagram.com/stories/anna/123/")
            let media = try await visible("media"), next = try await visible("next")
            let nav = try await visible("nav"), suggestions = try await visible("suggestions")
            XCTAssertTrue(media); XCTAssertTrue(next)
            XCTAssertFalse(nav); XCTAssertFalse(suggestions)
            XCTAssertEqual(states.last, "story")
        }
    }

    func testTapOpensHomePortalThenNextAndCloseKeepWorking() async throws {
        try await fixture("""
        <main><a id='open' href='/stories/anna/123/'>Anna</a><article id='feed'>Suggested post</article></main>
        """)
        _ = try await evaluate("""
        document.getElementById('open').addEventListener('click', event => {
          event.preventDefault();
          document.body.insertAdjacentHTML('beforeend', `<div id='portal' style='position:fixed; inset:0; background:black'>
            <button id='close' onclick="document.getElementById('portal').remove()">Close</button>
            <div id='media-slot'><img id='media' width='300' height='500' alt='Story'></div>
            <button id='next'>Next</button></div>`);
        });
        document.getElementById('open').click();
        """)
        let media = try await visible("media"), feed = try await visible("feed")
        XCTAssertTrue(media); XCTAssertFalse(feed)
        XCTAssertTrue(states.contains("story-loading"))
        XCTAssertEqual(states.last, "story", "A Story portal can mount before Instagram updates the URL.")

        let canTapNext = try await hittable("next")
        XCTAssertTrue(canTapNext)
        _ = try await evaluate("""
        document.getElementById('next').addEventListener('click', () => {
          document.getElementById('media-slot').innerHTML = '<div role=progressbar>Loading next story</div>';
        });
        document.getElementById('next').click();
        """)
        _ = try await evaluate("true")
        XCTAssertEqual(states.last, "story-loading", "Replacing media inside an open viewer is not closing it.")
        _ = try await evaluate("document.getElementById('media-slot').innerHTML = '<video id=media width=300 height=500></video>'")
        let video = try await visible("media")
        XCTAssertTrue(video)
        XCTAssertEqual(states.last, "story")

        _ = try await evaluate("document.getElementById('close').click()")
        for _ in 0..<20 {
            if states.last == "home" { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let tray = try await visible("open"), feedAfterClose = try await visible("feed")
        XCTAssertTrue(tray); XCTAssertFalse(feedAfterClose)
        XCTAssertEqual(states.last, "home")
    }

    func testTapNavigatesThroughSkeletonIntoViewerAndBack() async throws {
        try await fixture("<main><a id='open' href='/stories/anna/123/'>Anna</a><article id='feed'>Feed</article></main>")
        _ = try await evaluate("""
        document.getElementById('open').addEventListener('click', event => {
          event.preventDefault();
          globalThis.fixtureURL = 'https://www.instagram.com/stories/anna/123/';
          document.body.insertAdjacentHTML('beforeend', '<div id=portal role=dialog style="position:fixed;inset:0"><div role=progressbar>Loading</div></div>');
        });
        document.getElementById('open').click();
        """)
        _ = try await evaluate("true")
        XCTAssertEqual(states.last, "story-loading")
        _ = try await evaluate("document.getElementById('portal').innerHTML = '<article><img id=media width=300 height=500 alt=Story></article><button id=next>Next</button>'")
        let media = try await visible("media"), next = try await visible("next"), feed = try await visible("feed")
        XCTAssertTrue(media); XCTAssertTrue(next); XCTAssertFalse(feed)
        XCTAssertEqual(states.last, "story")
        _ = try await evaluate("globalThis.fixtureURL = 'https://www.instagram.com/'; document.getElementById('portal').remove();")
        let tray = try await visible("open")
        XCTAssertTrue(tray)
        XCTAssertEqual(states.last, "home")
    }

    func testViewerTimeoutHasRecoveryAndCanAcceptLateMedia() async throws {
        try await fixture("<div id='viewer' role='dialog' style='position:fixed; inset:0'><div role='progressbar'>Loading</div></div>",
                          url: "https://www.instagram.com/stories/anna/123/", viewerWaitMs: 150)
        for _ in 0..<20 {
            if states.last == "story-unavailable" { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(states.contains("story-loading"))
        XCTAssertEqual(states.last, "story-unavailable")
        XCTAssertFalse(states.contains("unavailable"), "The viewer must not use the empty tray fallback.")
        _ = try await evaluate("document.getElementById('viewer').innerHTML = '<img id=media width=300 height=500 alt=Story>'")
        let media = try await visible("media")
        XCTAssertTrue(media)
        XCTAssertEqual(states.last, "story")
    }

    func testClosingViewerWithUnchangedStoryURLRequestsHomeOnce() async throws {
        try await fixture("""
        <article id='feed'>Suggested post</article>
        <div id='viewer' role='dialog' style='position:fixed; inset:0'>
          <img width='300' height='500' alt='Story'>
          <button id='close' onclick="document.getElementById('viewer').remove()">×</button>
        </div>
        """, url: "https://www.instagram.com/stories/anna/123/")
        XCTAssertEqual(states.last, "story")
        _ = try await evaluate("document.getElementById('close').click()")
        for _ in 0..<20 {
            if states.last == "story-ended" { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        _ = try await evaluate("filter.refresh(); filter.refresh();")
        XCTAssertEqual(states.last, "story-ended")
        XCTAssertEqual(states.filter { $0 == "story-ended" }.count, 1)
        XCTAssertFalse(states.contains("story-unavailable"))
        let feedVisible = try await visible("feed")
        XCTAssertFalse(feedVisible)
    }

    func testPlaybackEndingWithEmptyViewerShellReturnsHome() async throws {
        try await fixture("""
        <div id='viewer' role='dialog' style='position:fixed; inset:0'>
          <img id='media' width='300' height='500' alt='Story'>
        </div>
        """, url: "https://www.instagram.com/stories/anna/123/", viewerWaitMs: 300)
        XCTAssertEqual(states.last, "story")
        _ = try await evaluate("document.getElementById('media').remove()")
        for _ in 0..<20 {
            if states.last == "story-ended" { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(states.last, "story-ended")
        XCTAssertFalse(states.contains("story-unavailable"))
    }

    func testReturningHomeBeforeTrayRemountsDoesNotShowStoryError() async throws {
        try await fixture("""
        <article id='feed'>Feed</article>
        <div id='viewer' role='dialog' style='position:fixed; inset:0'><img width='300' height='500' alt='Story'></div>
        """, url: "https://www.instagram.com/stories/anna/123/")
        _ = try await evaluate("fixtureURL = 'https://www.instagram.com/'; document.getElementById('viewer').remove();")
        _ = try await evaluate("filter.refresh();")
        XCTAssertEqual(states.last, "story-ended", "Native code should load home when Instagram leaves no tray mounted.")
        XCTAssertFalse(states.contains("unavailable"))
        let feedVisible = try await visible("feed")
        XCTAssertFalse(feedVisible)
        _ = try await evaluate("document.body.insertAdjacentHTML('beforeend', '<a id=tray href=/stories/anna/>Anna</a>')")
        let trayVisible = try await visible("tray")
        XCTAssertTrue(trayVisible)
        XCTAssertEqual(states.last, "home")
    }

    func testViewerReplacementAndNewStoryLoadingAreNotTreatedAsExit() async throws {
        try await fixture("""
        <div id='viewer' role='dialog' style='position:fixed; inset:0'><img width='300' height='500' alt='Story'></div>
        """, url: "https://www.instagram.com/stories/anna/123/", viewerWaitMs: 1000)
        _ = try await evaluate("document.getElementById('viewer').remove(); filter.refresh();")
        XCTAssertEqual(states.last, "story-loading")
        _ = try await evaluate("document.body.insertAdjacentHTML('beforeend', '<div id=viewer role=dialog style=position:fixed;inset:0><video width=300 height=500></video></div>')")
        _ = try await evaluate("filter.refresh();")
        XCTAssertEqual(states.last, "story")
        XCTAssertFalse(states.contains("story-ended"))
        _ = try await evaluate("fixtureURL = 'https://www.instagram.com/stories/sam/456/'; document.getElementById('viewer').remove();")
        for _ in 0..<25 {
            if states.last == "story-unavailable" { break }
            try await Task.sleep(for: .milliseconds(100))
            // Unattached test web views can throttle their interval timer.
            _ = try await evaluate("filter.refresh();")
        }
        XCTAssertEqual(states.last, "story-unavailable", "A different Story that never opens retains its loading error.")
        XCTAssertFalse(states.contains("story-ended"))
    }

    func testUnrequestedHomeDialogIsNotRevealed() async throws {
        try await fixture("""
        <main><a href='/stories/anna/'>Anna</a></main>
        <div role='dialog' id='unrequested' style='position:fixed; inset:0'><img width='300' height='500' alt='Suggested post'></div>
        """)
        let dialog = try await visible("unrequested")
        XCTAssertFalse(dialog)
        XCTAssertEqual(states.last, "home")
    }

    func testPortraitFeedContentIsNotMistakenForAViewer() async throws {
        try await fixture("""
        <main><article><div id='feed'><img width='300' height='500' alt='Feed photo'><button>Like</button><button>Comment</button></div></article></main>
        """, url: "https://www.instagram.com/stories/anna/123/", viewerWaitMs: 0)
        let feed = try await visible("feed")
        XCTAssertFalse(feed)
        XCTAssertEqual(states.last, "story-unavailable")
    }

    func testReplyAndSendMoveAboveKeyboardAndRestoreAfterBlur() async throws {
        try await fixture("""
        <div role='dialog' style='position:fixed; inset:0; overflow:hidden'>
          <img width='300' height='500' alt='Story'>
          <form id='composer' style='position:absolute; bottom:0; left:0; right:0; height:60px; display:flex; transform:translateX(0px)'>
            <textarea id='reply' style='flex:1; min-width:0'>Draft reply</textarea>
            <button id='send' type='button' onclick="this.dataset.clicked='yes'">Send</button>
          </form>
        </div>
        """, url: "https://www.instagram.com/stories/anna/123/", viewportHeight: 400)
        let originalBottom = try await evaluate("document.getElementById('composer').getBoundingClientRect().bottom") as! Double
        XCTAssertGreaterThan(originalBottom, 400, "Fixture reproduces a reply below the keyboard boundary.")
        _ = try await evaluate("document.getElementById('reply').focus()")
        let bottom = try await evaluate("document.getElementById('composer').getBoundingClientRect().bottom") as! Double
        XCTAssertLessThanOrEqual(bottom, 388)
        let replyHittable = try await hittable("reply"), sendHittable = try await hittable("send")
        XCTAssertTrue(replyHittable); XCTAssertTrue(sendHittable)
        _ = try await evaluate("filter.refresh(); filter.refresh(); fixtureViewport.height=280; fixtureViewport.offsetTop=20; fixtureViewport.dispatchEvent(new Event('resize'))")
        let smallerBottom = try await evaluate("document.getElementById('composer').getBoundingClientRect().bottom") as! Double
        XCTAssertEqual(smallerBottom, 288, accuracy: 1, "Repeated layout passes must not accumulate translations.")
        _ = try await evaluate("fixtureViewport.offsetTop=40; fixtureViewport.dispatchEvent(new Event('scroll'))")
        let pannedBottom = try await evaluate("document.getElementById('composer').getBoundingClientRect().bottom") as! Double
        XCTAssertEqual(pannedBottom, 308, accuracy: 1)
        let draft = try await evaluate("document.getElementById('reply').value") as? String
        XCTAssertEqual(draft, "Draft reply")
        _ = try await evaluate("document.getElementById('send').click(); document.getElementById('reply').blur()")
        let restoredBottom = try await evaluate("document.getElementById('composer').getBoundingClientRect().bottom") as! Double
        let clicked = try await evaluate("document.getElementById('send').dataset.clicked") as? String
        let originalTransform = try await evaluate("document.getElementById('composer').style.transform") as? String
        XCTAssertEqual(restoredBottom, originalBottom, accuracy: 1)
        XCTAssertEqual(clicked, "yes"); XCTAssertEqual(originalTransform, "translateX(0px)")
        XCTAssertEqual(states.last, "story")
    }

    func testQuickReactionsDoNotObscureReplyOrSendAndReturnAfterBlur() async throws {
        try await fixture("""
        <div role='dialog' style='position:fixed; inset:0'>
          <img width='300' height='500' alt='Story'>
          <button id='close' style='position:absolute; top:0'>Close</button>
          <form id='composer' style='position:absolute; bottom:0; left:0; right:0; height:60px; display:flex'>
            <textarea id='reply' style='flex:1; min-width:0'>Draft</textarea>
            <button id='send' type='button' onclick="this.dataset.clicked='yes'">Send</button>
          </form>
          <div id='reactions' style='position:absolute; top:275px; left:0; right:0; z-index:10'>
            <h2 id='heading' style='height:45px; margin:0'>Quick Reactions</h2>
            <div style='display:flex; height:70px'>
              <button id='laugh' style='flex:1' onclick="this.dataset.sent='yes'">😂</button>
              <button style='flex:1'>😮</button><button style='flex:1'>😍</button><button style='flex:1'>😢</button>
            </div>
          </div>
        </div>
        """, url: "https://www.instagram.com/stories/anna/123/", viewportHeight: 400)
        let initiallyVisible = try await visible("reactions")
        XCTAssertTrue(initiallyVisible)
        _ = try await evaluate("document.getElementById('reply').focus()")
        let headingVisible = try await visible("heading"), reactionVisible = try await visible("laugh")
        let replyHittable = try await hittable("reply"), sendHittable = try await hittable("send")
        let closeVisible = try await visible("close")
        XCTAssertFalse(headingVisible); XCTAssertFalse(reactionVisible)
        XCTAssertTrue(replyHittable); XCTAssertTrue(sendHittable); XCTAssertTrue(closeVisible)
        let accidentallySent = try await evaluate("document.getElementById('laugh').dataset.sent || ''") as? String
        XCTAssertEqual(accidentallySent, "")
        _ = try await evaluate("document.getElementById('send').click(); document.getElementById('reply').blur()")
        let restoredHeading = try await visible("heading"), restoredReaction = try await hittable("laugh")
        let clicked = try await evaluate("document.getElementById('send').dataset.clicked") as? String
        XCTAssertTrue(restoredHeading); XCTAssertTrue(restoredReaction); XCTAssertEqual(clicked, "yes")
        XCTAssertEqual(states.last, "story")
    }

    func testLateLocalizedReactionGridWithEmojiImagesIsHiddenOnlyWhileEditing() async throws {
        try await fixture("""
        <div role='dialog' id='viewer' style='position:fixed; inset:0'>
          <img width='300' height='500' alt='Story'>
          <form style='position:absolute; bottom:0; height:60px'><textarea id='reply'></textarea><button>Send</button></form>
          <button id='like'><span><span>❤️</span></span></button>
        </div>
        """, url: "https://www.instagram.com/stories/anna/123/", viewportHeight: 400)
        _ = try await evaluate("""
        document.getElementById('reply').focus();
        document.getElementById('viewer').insertAdjacentHTML('beforeend', `<div id='reactions' style='position:absolute;top:250px'>
          <h2 id='heading'>Быстрые реакции</h2><div style='display:flex'>
          <div role='button'><img width='44' height='44' alt='😂'></div>
          <div role='button'><img width='44' height='44' alt='😮'></div>
          <div role='button'><img width='44' height='44' alt='😍'></div></div></div>`);
        """)
        let headingVisible = try await visible("heading"), likeVisible = try await visible("like")
        XCTAssertFalse(headingVisible); XCTAssertTrue(likeVisible, "A single nested emoji control is not a reaction grid.")
        _ = try await evaluate("fixtureViewport.height=280; fixtureViewport.dispatchEvent(new Event('resize')); filter.refresh()")
        let stillHidden = try await visible("reactions")
        XCTAssertFalse(stillHidden)
        _ = try await evaluate("filter.dispose()")
        let restored = try await visible("reactions")
        let remainingMarkers = try await evaluate("document.querySelectorAll('[data-stories-reactions-hidden]').length") as? Int
        XCTAssertTrue(restored); XCTAssertEqual(remainingMarkers, 0)
    }

    func testContentEditableReplyRestoresWhenKeyboardClosesAndOnDispose() async throws {
        try await fixture("""
        <div role='dialog' style='position:fixed; inset:0'>
          <img width='300' height='500' alt='Story'>
          <div id='composer' style='position:absolute; top:620px; height:48px; display:flex'>
            <div id='reply' role='textbox' contenteditable='true' style='width:240px'>Draft</div>
            <button id='send'>Send</button>
          </div>
        </div>
        """, url: "https://www.instagram.com/stories/anna/123/", viewportHeight: 360)
        _ = try await evaluate("document.getElementById('reply').focus()")
        let bottom = try await evaluate("document.getElementById('composer').getBoundingClientRect().bottom") as! Double
        XCTAssertEqual(bottom, 348, accuracy: 1)
        _ = try await evaluate("fixtureViewport.height=700; fixtureViewport.dispatchEvent(new Event('resize'))")
        let restored = try await evaluate("document.getElementById('composer').getBoundingClientRect().bottom") as! Double
        XCTAssertEqual(restored, 668, accuracy: 1)
        _ = try await evaluate("fixtureViewport.height=360; fixtureViewport.dispatchEvent(new Event('resize')); filter.dispose()")
        let disposed = try await evaluate("document.querySelector('[data-stories-reply]') === null") as? Bool
        XCTAssertEqual(disposed, true)
    }

    func testKeyboardHandlingDoesNotModifyAuthenticationForms() async throws {
        try await fixture("<form id='login' style='position:absolute; top:620px'><input id='username' type='text'></form>",
                          url: "https://www.instagram.com/accounts/login/", viewportHeight: 300)
        _ = try await evaluate("document.getElementById('username').focus(); fixtureViewport.dispatchEvent(new Event('resize'))")
        let untouched = try await evaluate("document.querySelector('[data-stories-reply]') === null && document.getElementById('login').style.top === '620px'") as? Bool
        XCTAssertEqual(untouched, true)
        XCTAssertEqual(states.last, "authentication")
    }

    func testInboxKeepsConversationRowsAndHidesUnrelatedNavigation() async throws {
        try await fixture("""
        <div id='app'>
          <nav id='global-nav'><a href='/reels/'>Reels</a><a href='/explore/'>Explore</a></nav>
          <aside id='suggestions'>Suggested accounts</aside>
          <main id='inbox' aria-label='Messages'>
            <header id='message-header'><h1>Messages</h1><a id='compose' href='/direct/new/'>New message</a></header>
            <div role='list'>
              <a id='anna-thread' href='/direct/t/123/'><img id='anna-avatar' width='40' height='40' alt='Anna'>
                <span id='anna-name'>Anna</span><span id='preview'>Thanks for the story reply!</span><span id='unread'>Unread</span>
              </a>
              <a id='sam-thread' href='/direct/t/456/'><span>Sam</span><span>See you tomorrow</span></a>
            </div>
          </main>
          <article id='feed'>Suggested post</article>
        </div>
        """, url: "https://www.instagram.com/direct/inbox/")
        let anna = try await hittable("anna-thread"), sam = try await visible("sam-thread")
        let avatar = try await visible("anna-avatar"), preview = try await visible("preview")
        let unread = try await visible("unread"), compose = try await hittable("compose")
        let header = try await visible("message-header"), nav = try await visible("global-nav")
        let feed = try await visible("feed"), suggestions = try await visible("suggestions")
        XCTAssertTrue(anna); XCTAssertTrue(sam); XCTAssertTrue(avatar); XCTAssertTrue(preview)
        XCTAssertTrue(unread); XCTAssertTrue(compose); XCTAssertTrue(header)
        XCTAssertFalse(nav); XCTAssertFalse(feed); XCTAssertFalse(suggestions)
        XCTAssertEqual(states.last, "inbox")
    }

    func testEmptyInboxIsReadyAndKeepsItsOriginalComposeAction() async throws {
        try await fixture("""
        <main id='inbox'>
          <header><h1>Messages</h1><a id='compose' href='/direct/new/'>New message</a></header>
          <div id='empty' role='status'><h2>Your messages</h2><p>Start a conversation with someone.</p></div>
        </main>
        <article id='feed'>Suggested post</article>
        """, url: "https://www.instagram.com/direct/inbox/")
        let empty = try await visible("empty"), canCompose = try await hittable("compose")
        XCTAssertTrue(empty); XCTAssertTrue(canCompose)
        XCTAssertEqual(states.last, "inbox", "An empty inbox is a usable messaging screen.")
        let preserved = try await evaluate("""
        document.getElementById('compose').addEventListener('click', event => {
          event.preventDefault(); event.currentTarget.dataset.opened = 'yes';
        });
        document.getElementById('compose').click();
        document.getElementById('compose').dataset.opened;
        """) as? String
        XCTAssertEqual(preserved, "yes", "The allowed new-message link must reach Instagram's original handler.")
    }

    func testLocalizedEmptyInboxWithIllustrationAndComposeButtonIsReady() async throws {
        try await fixture("""
        <main id='inbox'>
          <header><h1>Nachrichten</h1><button id='compose' onclick="this.dataset.opened='yes'">Neue Nachricht</button></header>
          <div id='empty'>
            <svg id='message-illustration' width='72' height='72' role='img' aria-label='Nachrichten'><circle cx='36' cy='36' r='30'></circle></svg>
            <h2>Deine Nachrichten</h2><p>Sende private Nachrichten an deine Freunde.</p>
          </div>
          <aside id='suggestions'><h2>Für dich</h2>Konten zum Folgen</aside>
        </main>
        <nav id='global-nav'><a href='/reels/'>Reels</a></nav>
        """, url: "https://www.instagram.com/direct/inbox/")
        let empty = try await visible("empty"), illustration = try await visible("message-illustration")
        let compose = try await hittable("compose"), suggestions = try await visible("suggestions")
        let nav = try await visible("global-nav")
        XCTAssertTrue(empty); XCTAssertTrue(illustration); XCTAssertTrue(compose)
        XCTAssertFalse(suggestions); XCTAssertFalse(nav)
        XCTAssertEqual(states.last, "inbox", "Localized empty inboxes need neither canonical anchors nor a status role.")
        let opened = try await evaluate("document.getElementById('compose').click(); document.getElementById('compose').dataset.opened") as? String
        XCTAssertEqual(opened, "yes")
    }

    func testInboxRouterButtonRowsStayVisibleWithoutCanonicalThreadLinks() async throws {
        for role in ["list", "grid", "none"] {
            try await fixture("""
            <main id='inbox'>
              <header><h1>Mensajes</h1><button id='compose' aria-label='Nuevo mensaje'><svg width='24' height='24' role='img' aria-label='Nuevo mensaje'><rect width='20' height='20'></rect></svg></button></header>
              <div id='threads' role='\(role)'>
                <div id='anna-thread' role='button' tabindex='0' onclick="this.dataset.opened='yes'" style='display:flex; align-items:center; min-height:60px'>
                  <img id='anna-avatar' width='40' height='40' alt='Anna'><div><span id='anna-name'>Anna</span><span id='anna-preview'>Gracias por tu respuesta</span></div>
                </div>
                <div id='sam-thread' role='button' tabindex='0' style='display:flex; align-items:center; min-height:60px'>
                  <img width='40' height='40' alt='Sam'><div><span>Sam</span><span>Hasta mañana</span></div>
                </div>
              </div>
              <aside id='suggestions'><h2>Personas sugeridas</h2>Más cuentas</aside>
              <nav id='global-nav'><a href='/explore/'>Explorar</a><a href='/reels/'>Reels</a></nav>
            </main>
            """, url: "https://www.instagram.com/direct/inbox/")
            let anna = try await hittable("anna-thread"), sam = try await hittable("sam-thread")
            let avatar = try await visible("anna-avatar"), name = try await visible("anna-name")
            let preview = try await visible("anna-preview"), suggestions = try await visible("suggestions")
            let nav = try await visible("global-nav")
            XCTAssertTrue(anna); XCTAssertTrue(sam); XCTAssertTrue(avatar); XCTAssertTrue(name); XCTAssertTrue(preview)
            XCTAssertFalse(suggestions); XCTAssertFalse(nav)
            XCTAssertEqual(states.last, "inbox", "Instagram router buttons inside a \(role) must work without href attributes.")
            let opened = try await evaluate("document.getElementById('anna-thread').click(); document.getElementById('anna-thread').dataset.opened") as? String
            XCTAssertEqual(opened, "yes")
        }
    }

    func testPlainDivInboxIsDiscoveredWithoutMainOrDirectLinks() async throws {
        try await fixture("""
        <nav id='global-nav'><a href='/'>Home</a><a href='/reels/'>Reels</a></nav>
        <div id='inbox'><h1>Mensajes</h1>
          <button><svg width='24' height='24'><rect width='20' height='20'></rect></svg></button>
          <div id='thread' role='button' onclick="this.dataset.opened='yes'" style='display:flex; height:72px'>
            <img width='48' height='48'><div><div>Anna</div><div>Gracias por tu respuesta</div></div>
          </div>
        </div>
        <article id='feed'>Suggested post</article>
        """, url: "https://www.instagram.com/direct/inbox/")
        let thread = try await hittable("thread"), nav = try await visible("global-nav")
        let feed = try await visible("feed")
        XCTAssertTrue(thread); XCTAssertFalse(nav); XCTAssertFalse(feed)
        XCTAssertEqual(states.last, "inbox")
        let opened = try await evaluate("document.getElementById('thread').click(); document.getElementById('thread').dataset.opened") as? String
        XCTAssertEqual(opened, "yes")
    }

    func testAvatarTilesAndPlaceholdersDoNotQualifyAsInboxRows() async throws {
        try await fixture("""
        <main><h1>Messages</h1><button><svg width='24' height='24'></svg></button>
          <div role='button' id='tile' style='width:80px; height:100px'><img width='48' height='48'><div>Anna</div><div>Note</div></div>
          <div role='button' id='placeholder' style='display:flex; height:72px'><img width='48' height='48'></div>
        </main>
        """, url: "https://www.instagram.com/direct/inbox/")
        let tile = try await visible("tile"), placeholder = try await visible("placeholder")
        XCTAssertFalse(tile); XCTAssertFalse(placeholder)
        XCTAssertEqual(states.last, "messages-loading")
    }

    func testConversationHistoryScrollAndOriginalSendHandlerRemainUsable() async throws {
        let olderMessages = (0..<12).map { "<p>Earlier message \($0)</p>" }.joined()
        try await fixture("""
        <nav id='global-nav'><a href='/explore/'>Explore</a></nav>
        <main id='conversation'>
          <header><a id='back' href='/direct/inbox/'>Messages</a><h1>Anna</h1></header>
          <div id='history' role='log' aria-label='Conversation' style='height:220px; overflow:auto'>
            <p id='incoming'>Thanks for replying to my story.</p><p id='outgoing'>That place looks lovely!</p>
            \(olderMessages)
          </div>
          <form id='composer' style='display:flex' onsubmit="event.preventDefault(); const field=document.getElementById('message'); const reply=document.createElement('p'); reply.id='sent-message'; reply.textContent=field.value; document.getElementById('history').append(reply); field.value=''; this.dataset.sent='yes'">
            <textarea id='message' aria-label='Message' style='flex:1'>Let's go this weekend.</textarea>
            <button id='send' type='submit'>Send</button>
          </form>
        </main>
        <article id='feed'>Feed content</article>
        """, url: "https://www.instagram.com/direct/t/123/")
        let incoming = try await visible("incoming"), outgoing = try await visible("outgoing")
        let message = try await hittable("message"), send = try await hittable("send")
        let nav = try await visible("global-nav"), feed = try await visible("feed")
        XCTAssertTrue(incoming); XCTAssertTrue(outgoing); XCTAssertTrue(message); XCTAssertTrue(send)
        XCTAssertFalse(nav); XCTAssertFalse(feed)
        XCTAssertEqual(states.last, "conversation")
        let offset = try await evaluate("document.getElementById('history').scrollTop=70; document.getElementById('history').scrollTop") as! Double
        XCTAssertGreaterThan(offset, 0)
        _ = try await evaluate("filter.refresh(); filter.refresh();")
        let retainedOffset = try await evaluate("document.getElementById('history').scrollTop") as! Double
        XCTAssertEqual(retainedOffset, offset, accuracy: 1, "Refreshing the filter must preserve conversation scrolling.")
        _ = try await evaluate("document.getElementById('send').click()")
        let sent = try await evaluate("document.getElementById('sent-message').textContent") as? String
        let draft = try await evaluate("document.getElementById('message').value") as? String
        let handlerRan = try await evaluate("document.getElementById('composer').dataset.sent") as? String
        let newMessageVisible = try await visible("sent-message")
        XCTAssertEqual(sent, "Let's go this weekend."); XCTAssertEqual(draft, "")
        XCTAssertEqual(handlerRan, "yes"); XCTAssertTrue(newMessageVisible)
        XCTAssertEqual(states.last, "conversation")
    }

    func testNewMessageKeepsRecipientSearchAndSelectionControls() async throws {
        try await fixture("""
        <nav id='global-nav'><a href='/reels/'>Reels</a></nav>
        <main id='compose'>
          <header><a href='/direct/inbox/'>Messages</a><h1>New message</h1><button id='chat'>Chat</button></header>
          <label for='recipient'>To:</label>
          <input id='recipient' type='search' aria-label='Search recipients' placeholder='Search' oninput="document.getElementById('anna-result').hidden=this.value !== 'anna'; this.dataset.searched='yes'">
          <div id='results' role='list'>
            <button id='anna-result' hidden onclick="this.dataset.selected='yes'"><img width='40' height='40' alt='Anna'><span>Anna</span></button>
          </div>
        </main>
        <article id='feed'>Suggested post</article>
        """, url: "https://www.instagram.com/direct/new/")
        let search = try await hittable("recipient"), chat = try await hittable("chat")
        let nav = try await visible("global-nav"), feed = try await visible("feed")
        XCTAssertTrue(search); XCTAssertTrue(chat); XCTAssertFalse(nav); XCTAssertFalse(feed)
        XCTAssertEqual(states.last, "message-compose")
        _ = try await evaluate("document.getElementById('recipient').value='anna'; document.getElementById('recipient').dispatchEvent(new Event('input', {bubbles:true}))")
        let result = try await hittable("anna-result")
        XCTAssertTrue(result)
        let selected = try await evaluate("document.getElementById('anna-result').click(); document.getElementById('anna-result').dataset.selected") as? String
        let searched = try await evaluate("document.getElementById('recipient').dataset.searched") as? String
        XCTAssertEqual(searched, "yes"); XCTAssertEqual(selected, "yes")
        XCTAssertEqual(states.last, "message-compose")
    }

    func testInboxComposePortalKeepsOriginalControlsWithoutChangingRoute() async throws {
        try await fixture("""
        <nav id='global-nav'><a href='/explore/'>Explore</a></nav>
        <main id='inbox'>
          <header><h1>Messages</h1><a href='/direct/new/'>New message</a></header>
          <a href='/direct/t/123/'>Anna</a>
          <button id='open-compose' type='button'>Start a conversation</button>
        </main>
        <article id='feed'>Suggested post</article>
        <div id='unrelated-dialog' role='dialog' style='position:fixed; inset:0'>
          <img width='300' height='500' alt='Suggested post'><button>Like</button>
        </div>
        """, url: "https://www.instagram.com/direct/inbox/")
        let unrelatedBefore = try await visible("unrelated-dialog")
        XCTAssertFalse(unrelatedBefore)
        _ = try await evaluate("""
        document.getElementById('open-compose').addEventListener('click', () => {
          document.body.insertAdjacentHTML('beforeend', `<div id='compose-dialog' role='dialog' aria-modal='true' style='position:fixed; inset:30px; z-index:10; background:white'>
            <h1>New message</h1><input id='portal-recipient' type='search' aria-label='Search recipients'>
            <button id='portal-chat' type='button' onclick="this.dataset.clicked='yes'">Chat</button>
            <button id='portal-cancel' type='button' onclick="document.getElementById('compose-dialog').remove()">Cancel</button>
          </div>`);
        });
        document.getElementById('open-compose').click();
        """)
        let recipient = try await hittable("portal-recipient"), chat = try await hittable("portal-chat")
        let cancel = try await hittable("portal-cancel"), nav = try await visible("global-nav")
        let feed = try await visible("feed"), unrelatedAfter = try await visible("unrelated-dialog")
        XCTAssertTrue(recipient); XCTAssertTrue(chat); XCTAssertTrue(cancel)
        XCTAssertFalse(nav); XCTAssertFalse(feed); XCTAssertFalse(unrelatedAfter)
        XCTAssertEqual(states.last, "inbox", "Instagram can compose in a portal while its URL remains the inbox.")
        let clicked = try await evaluate("document.getElementById('portal-chat').click(); document.getElementById('portal-chat').dataset.clicked") as? String
        XCTAssertEqual(clicked, "yes")
        _ = try await evaluate("document.getElementById('portal-cancel').click()")
        let inbox = try await hittable("open-compose")
        XCTAssertTrue(inbox); XCTAssertEqual(states.last, "inbox")
    }

    func testInboxConversationAndBackSPATransitionsKeepOriginalActions() async throws {
        try await fixture("""
        <nav id='global-nav'><a href='/reels/'>Reels</a></nav>
        <main id='messages'><header><h1>Messages</h1><a href='/direct/new/'>New message</a></header>
          <a id='thread' href='/direct/t/123/'>Anna — Thanks for the reply</a>
        </main>
        <article id='feed'>Suggested post</article>
        """, url: "https://www.instagram.com/direct/inbox/")
        _ = try await evaluate("""
        const inboxMarkup = document.getElementById('messages').innerHTML;
        document.getElementById('thread').addEventListener('click', event => {
          event.preventDefault(); fixtureURL='https://www.instagram.com/direct/t/123/';
          document.getElementById('messages').innerHTML = `<header><a id='back' href='/direct/inbox/'>Messages</a><h1>Anna</h1></header>
            <div role='log'><p id='incoming'>Thanks for the reply</p></div><form><textarea id='message'></textarea><button type='button'>Send</button></form>`;
          document.getElementById('back').addEventListener('click', backEvent => {
            backEvent.preventDefault(); fixtureURL='https://www.instagram.com/direct/inbox/';
            document.getElementById('messages').innerHTML=inboxMarkup;
          });
        });
        document.getElementById('thread').click();
        """)
        let history = try await visible("incoming"), composer = try await visible("message")
        let feed = try await visible("feed"), nav = try await visible("global-nav")
        XCTAssertTrue(history); XCTAssertTrue(composer); XCTAssertFalse(feed); XCTAssertFalse(nav)
        XCTAssertEqual(states.last, "conversation")
        _ = try await evaluate("document.getElementById('back').click()")
        let row = try await hittable("thread"), feedAfterBack = try await visible("feed")
        XCTAssertTrue(row); XCTAssertFalse(feedAfterBack)
        XCTAssertEqual(states.last, "inbox")
        XCTAssertFalse(states.contains("restricted-link"), "Inbox, thread and compose links are allowed within the messaging flow.")
    }

    func testMessagingLoadingTimeoutRecoversWhenConversationMountsLate() async throws {
        try await fixture("""
        <main id='messages'><div role='progressbar'>Loading messages</div></main>
        <article id='feed'>Suggested post</article>
        """, url: "https://www.instagram.com/direct/t/123/", viewerWaitMs: 150)
        for _ in 0..<20 {
            if states.last == "messages-unavailable" { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(states.contains("messages-loading"))
        XCTAssertEqual(states.last, "messages-unavailable")
        let feed = try await visible("feed")
        XCTAssertFalse(feed)
        _ = try await evaluate("""
        document.getElementById('messages').innerHTML = `<header><a href='/direct/inbox/'>Messages</a><h1>Anna</h1></header>
          <div role='log'><p id='late-message'>A message from Anna</p></div><form><textarea id='message'></textarea><button>Send</button></form>`;
        """)
        let lateMessage = try await visible("late-message"), composer = try await visible("message")
        XCTAssertTrue(lateMessage); XCTAssertTrue(composer)
        XCTAssertEqual(states.last, "conversation", "A later React mount must recover from the messaging error.")
        XCTAssertFalse(states.contains("unavailable"), "Messaging uses its own readiness and recovery states.")
    }

    func testInboxConversationOpensWithOffscreenHistoryLoader() async throws {
        try await fixture("""
        <nav id='global-nav'><a href='/reels/'>Reels</a></nav>
        <main id='messages'><h1>Messages</h1><a id='thread' href='/direct/t/123/'>Friend</a></main>
        <article id='feed'>Suggested post</article>
        """, url: "https://www.instagram.com/direct/inbox/", viewerWaitMs: 150)
        XCTAssertEqual(states.last, "inbox")
        _ = try await evaluate("""
        document.getElementById('thread').addEventListener('click', event => {
          event.preventDefault(); fixtureURL='https://www.instagram.com/direct/t/123/';
          document.getElementById('messages').innerHTML = `<header style='height:100px'>
              <a href='/direct/inbox/'>Messages</a><h1>Friend</h1><button>Details</button></header>
            <div id='history' style='height:220px; overflow:auto'>
              <div id='older-loader' role='progressbar' style='height:32px'>Loading older messages</div>
              <div style='height:5000px'></div><p id='incoming'>Latest message</p>
            </div>
            <div><div id='draft' role='textbox' contenteditable='true' style='min-height:24px'>Local draft</div>
              <button id='send' onclick="this.dataset.clicked='yes'">Send</button></div>`;
          const history = document.getElementById('history'); history.scrollTop=history.scrollHeight;
        });
        document.getElementById('thread').click();
        """)
        // Measured on the failing iPhone: a plain-div history retains an older-
        // messages progressbar thousands of pixels above its current scroll position.
        let loaderTop = try await evaluate("document.getElementById('older-loader').getBoundingClientRect().top") as! Double
        XCTAssertLessThan(loaderTop, -4000)
        let incoming = try await hittable("incoming"), draft = try await hittable("draft")
        let send = try await hittable("send"), feed = try await visible("feed"), nav = try await visible("global-nav")
        XCTAssertTrue(incoming); XCTAssertTrue(draft); XCTAssertTrue(send)
        XCTAssertFalse(feed); XCTAssertFalse(nav)
        XCTAssertEqual(states.last, "conversation")
        let originalOffset = try await evaluate("document.getElementById('history').scrollTop") as! Double
        _ = try await evaluate("filter.refresh(); filter.refresh(); document.getElementById('send').click();")
        let offset = try await evaluate("document.getElementById('history').scrollTop") as! Double
        let clicked = try await evaluate("document.getElementById('send').dataset.clicked") as? String
        let preservedDraft = try await evaluate("document.getElementById('draft').textContent") as? String
        XCTAssertEqual(offset, originalOffset); XCTAssertEqual(clicked, "yes"); XCTAssertEqual(preservedDraft, "Local draft")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(states.last, "conversation")
        XCTAssertFalse(states.contains("messages-unavailable"))
    }

    func testDeepPlainDivConversationKeepsDedicatedSurfaceAndOriginalActions() async throws {
        let editorWrappers = String(repeating: "<div>", count: 15)
        let editorClosures = String(repeating: "</div>", count: 15)
        for shell in ["div", "main"] {
            try await fixture("""
            <\(shell) id='app'>
              <div id='conversation' style='position:absolute; left:10px; top:10px; width:370px'>
                <div style='height:70px'><h1 style='margin:0'>Anna</h1><button id='details'>Details</button></div>
                <div id='history' style='height:320px; overflow-y:auto; overflow-x:hidden'>
                  <div style='height:5000px'></div>
                  <article id='shared-post' style='height:50px'>A post shared in this conversation</article>
                  <p id='incoming' style='height:30px; margin:0'>A message from Anna</p>
                </div>
                <div id='composer'>\(editorWrappers)
                  <div id='draft' contenteditable='true' style='min-height:32px'>An unsent draft</div>
                \(editorClosures)<button id='send' onclick="this.dataset.clicked='yes'">Send</button></div>
              </div>
              <div id='unrelated' style='position:absolute; left:10px; top:580px'>Unrelated application content</div>
              <nav id='global-nav' style='position:absolute; top:620px'><a href='/reels/'>Reels</a></nav>
            </\(shell)>
            """, url: "https://www.instagram.com/direct/t/123/")
            XCTAssertEqual(states.last, "conversation", "A deeply nested chat in a \(shell) shell needs no back link or history role.")
            _ = try await evaluate("document.getElementById('history').scrollTop=document.getElementById('history').scrollHeight; filter.refresh();")
            let root = try await evaluate("document.querySelector('[data-stories-messages]')?.id") as? String
            let incoming = try await hittable("incoming"), sharedPost = try await visible("shared-post")
            let draft = try await hittable("draft"), send = try await hittable("send")
            let unrelated = try await visible("unrelated"), nav = try await visible("global-nav")
            XCTAssertEqual(root, "conversation", "The enclosing \(shell) must not broaden the dedicated messaging surface.")
            XCTAssertTrue(incoming); XCTAssertTrue(sharedPost); XCTAssertTrue(draft); XCTAssertTrue(send)
            XCTAssertFalse(unrelated); XCTAssertFalse(nav)
            let originalOffset = try await evaluate("document.getElementById('history').scrollTop") as! Double
            _ = try await evaluate("filter.refresh(); filter.refresh(); document.getElementById('send').click();")
            let offset = try await evaluate("document.getElementById('history').scrollTop") as! Double
            let clicked = try await evaluate("document.getElementById('send').dataset.clicked") as? String
            let preservedDraft = try await evaluate("document.getElementById('draft').textContent") as? String
            XCTAssertEqual(offset, originalOffset); XCTAssertEqual(clicked, "yes"); XCTAssertEqual(preservedDraft, "An unsent draft")
        }
    }

    func testInferredHistoryRejectsSidebarHorizontalAndComposerScrollers() async throws {
        let cases: [(String, String)] = [
            ("sidebar", "<aside id='candidate-history' style='height:300px; overflow-y:auto'><div style='height:600px'>Inbox rows</div></aside><div id='draft' contenteditable='true' style='min-height:32px'>Draft</div>"),
            ("horizontal", "<div id='candidate-history' style='height:300px; overflow-x:auto; overflow-y:hidden'><div style='width:1200px'>Emoji choices</div></div><div id='draft' contenteditable='true' style='min-height:32px'>Draft</div>"),
            ("composer", "<div id='candidate-history' style='height:300px; overflow-y:auto'><div style='height:200px'>Composer controls</div><div id='draft' contenteditable='true' style='min-height:32px'>Draft</div></div>"),
            ("article sibling", "<div id='candidate-history' style='height:300px; overflow-y:auto'><p>Conversation history</p></div><article id='feed'>An unrelated post outside history</article><div id='draft' contenteditable='true' style='min-height:32px'>Draft</div>")
        ]
        for (name, markup) in cases {
            try await fixture("""
            <div style='position:absolute; left:10px; top:10px; width:370px'>
              <div style='height:70px'><h1 style='margin:0'>Anna</h1><button>Details</button></div>
              \(markup)
              <button id='send'>Send</button>
            </div>
            """, url: "https://www.instagram.com/direct/t/123/")
            let history = try await visible("candidate-history"), draft = try await visible("draft")
            XCTAssertFalse(history, name); XCTAssertFalse(draft, name)
            XCTAssertEqual(states.last, "messages-loading", "A \(name) must not qualify as a plain conversation history.")
            let markers = try await evaluate("document.querySelectorAll('[data-stories-messages]').length") as? Int
            XCTAssertEqual(markers, 0, name)
        }
    }

    func testInferredHistoryThreadReplacementIgnoresUnrelatedMutations() async throws {
        try await fixture("""
        <main>
          <div id='conversation' style='position:absolute; left:10px; top:10px; width:370px'>
            <div style='height:70px'><h1 id='participant' style='margin:0'>Anna</h1><button>Details</button></div>
            <div id='history' style='height:300px; overflow-y:auto; overflow-x:hidden'>
              <div><span id='message-text'>Anna's conversation</span></div>
            </div>
            <div id='composer'><div id='draft' contenteditable='true' style='min-height:32px'>An unsent draft</div><button>Send</button></div>
          </div>
          <div id='sidebar' style='position:absolute; top:510px; left:10px; width:370px; height:150px; overflow-y:auto'>
            <div style='height:500px'><span id='sidebar-text'>Another inbox conversation</span></div>
          </div>
        </main>
        """, url: "https://www.instagram.com/direct/t/123/")
        XCTAssertEqual(states.last, "conversation")
        _ = try await evaluate("fixtureURL='https://www.instagram.com/direct/t/456/'; filter.refresh();")
        let staleHistory = try await visible("message-text")
        XCTAssertFalse(staleHistory); XCTAssertEqual(states.last, "messages-loading")
        _ = try await evaluate("""
        document.getElementById('participant').firstChild.data='Sam';
        document.getElementById('draft').firstChild.data='A changed unsent draft';
        document.getElementById('draft').dispatchEvent(new Event('input', {bubbles:true}));
        document.getElementById('composer').append(document.createElement('button'));
        document.getElementById('history').className='updated-layout';
        document.getElementById('sidebar-text').firstChild.data='A new sidebar preview';
        filter.refresh();
        """)
        let stillStale = try await visible("message-text")
        XCTAssertFalse(stillStale, "Header, sidebar, draft, and layout changes must not release the old thread.")
        XCTAssertEqual(states.last, "messages-loading")
        let synchronousState = try await evaluate("""
        document.getElementById('message-text').firstChild.data='Sam conversation';
        filter.refresh();
        fixtureReports[fixtureReports.length-1].state;
        """) as? String
        let freshHistory = try await visible("message-text"), sidebar = try await visible("sidebar")
        let preservedDraft = try await evaluate("document.getElementById('draft').textContent") as? String
        XCTAssertEqual(synchronousState, "conversation", "Pending nested history mutations must be consumed before a synchronous refresh.")
        XCTAssertTrue(freshHistory); XCTAssertFalse(sidebar)
        XCTAssertEqual(states.last, "conversation"); XCTAssertEqual(preservedDraft, "A changed unsent draft")
    }

    func testInferredHistoryWaitsForVisibleLoaderAndIgnoresOffscreenOlderLoading() async throws {
        try await fixture("""
        <div style='position:absolute; left:10px; top:10px; width:370px'>
          <div style='height:70px'><h1 style='margin:0'>Anna</h1><button>Details</button></div>
          <div id='history' style='height:300px; overflow-y:auto; overflow-x:hidden'>
            <div id='loader' role='progressbar' style='height:32px'>Loading messages</div>
            <div style='height:5000px'></div><p id='incoming' style='height:30px; margin:0'>Latest message</p>
          </div>
          <div id='draft' contenteditable='true' style='min-height:32px'>An unsent draft</div><button>Send</button>
        </div>
        """, url: "https://www.instagram.com/direct/t/123/", viewerWaitMs: 150)
        XCTAssertEqual(states.last, "messages-loading", "Visible initial loading must block an inferred history.")
        _ = try await evaluate("document.getElementById('history').scrollTop=document.getElementById('history').scrollHeight; filter.refresh();")
        let loaderTop = try await evaluate("document.getElementById('loader').getBoundingClientRect().top") as! Double
        let incoming = try await hittable("incoming"), draft = try await hittable("draft")
        XCTAssertLessThan(loaderTop, -4000); XCTAssertTrue(incoming); XCTAssertTrue(draft)
        XCTAssertEqual(states.last, "conversation")
        _ = try await evaluate("""
        fixtureURL='https://www.instagram.com/direct/t/456/'; filter.refresh();
        document.getElementById('history').scrollTop=0;
        document.getElementById('incoming').firstChild.data='Replacement conversation'; filter.refresh();
        """)
        XCTAssertEqual(states.last, "messages-loading", "A visible loader must also block the freshly replaced thread.")
        _ = try await evaluate("document.getElementById('history').scrollTop=50; filter.refresh();")
        let clippedLoaderTop = try await evaluate("document.getElementById('loader').getBoundingClientRect().top") as! Double
        let clippedLoaderBottom = try await evaluate("document.getElementById('loader').getBoundingClientRect().bottom") as! Double
        let historyTop = try await evaluate("document.getElementById('history').getBoundingClientRect().top") as! Double
        XCTAssertGreaterThan(clippedLoaderTop, 0); XCTAssertLessThan(clippedLoaderBottom, historyTop)
        XCTAssertEqual(states.last, "conversation", "An older loader clipped by the history must not block replacement readiness.")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(states.last, "conversation"); XCTAssertFalse(states.contains("messages-unavailable"))
    }

    func testConversationReadinessIgnoresClippedAndHiddenLoadersButWaitsForVisibleLoading() async throws {
        try await fixture("""
        <main>
          <header style='height:100px'><a href='/direct/inbox/'>Messages</a><h1>Friend</h1></header>
          <div id='history' role='log' style='height:160px; overflow:auto'>
            <div id='loader' role='progressbar' style='height:32px'>Loading messages</div>
            <div style='height:180px'></div><p id='incoming'>Latest message</p>
          </div>
          <form><textarea id='draft'></textarea><button>Send</button></form>
        </main>
        """, url: "https://www.instagram.com/direct/t/123/")
        XCTAssertEqual(states.last, "messages-loading", "A visible initial loader must still block readiness.")
        let initiallyHidden = try await visible("draft")
        XCTAssertFalse(initiallyHidden)
        _ = try await evaluate("document.getElementById('history').scrollTop=50; filter.refresh();")
        let loaderTop = try await evaluate("document.getElementById('loader').getBoundingClientRect().top") as! Double
        XCTAssertGreaterThan(loaderTop, 0, "The loader is in the window bounds, but clipped above its scrolling container.")
        let draft = try await hittable("draft")
        XCTAssertTrue(draft); XCTAssertEqual(states.last, "conversation")
        _ = try await evaluate("""
        fixtureURL='https://www.instagram.com/direct/t/456/'; filter.refresh();
        document.getElementById('history').scrollTop=0;
        document.getElementById('incoming').textContent='Replacement conversation'; filter.refresh();
        """)
        XCTAssertEqual(states.last, "messages-loading", "Visible loading also blocks a freshly replaced thread.")
        _ = try await evaluate("document.getElementById('loader').style.display='none'; filter.refresh();")
        XCTAssertEqual(states.last, "conversation", "A hidden retained loader must not block the replacement thread.")
    }

    func testChangingThreadsHidesOldHistoryUntilInstagramReplacesIt() async throws {
        try await fixture("""
        <main id='conversation'>
          <header><a href='/direct/inbox/'>Messages</a><h1>Anna</h1></header>
          <div id='history' role='log'><p id='old-message'>Anna's private conversation</p></div>
          <form><textarea id='message'></textarea><button>Send</button></form>
        </main>
        """, url: "https://www.instagram.com/direct/t/123/")
        XCTAssertEqual(states.last, "conversation")
        _ = try await evaluate("fixtureURL='https://www.instagram.com/direct/t/456/'; filter.refresh();")
        let oldMessage = try await visible("old-message")
        XCTAssertFalse(oldMessage, "A newly selected thread must not temporarily display the previous participant's messages.")
        XCTAssertEqual(states.last, "messages-loading")
        _ = try await evaluate("document.getElementById('history').innerHTML='<p id=new-message>A message from Sam</p>'; document.querySelector('h1').textContent='Sam';")
        let newMessage = try await visible("new-message")
        XCTAssertTrue(newMessage)
        XCTAssertEqual(states.last, "conversation")
    }

    func testOpaqueLocationTokenRejectsQueuedStateImmediatelyAfterThreadNavigation() async throws {
        try await fixture("""
        <main>
          <header><a href='/direct/inbox/'>Messages</a><h1>Anna</h1></header>
          <div id='history' role='log'><p>A message from Anna</p></div>
          <form><textarea></textarea><button>Send</button></form>
        </main>
        """, url: "https://www.instagram.com/direct/t/123/")
        let firstValue = try await evaluate("fixtureReports[fixtureReports.length-1].locationID") as? String
        let first = try XCTUnwrap(firstValue)
        XCTAssertNotNil(UUID(uuidString: first), "The bridge sends an opaque nonce, without a participant or URL.")
        let firstIsCurrent = try await evaluate("filter.isCurrentLocation(fixtureReports[fixtureReports.length-1].locationID)") as? Bool
        XCTAssertEqual(firstIsCurrent, true)
        _ = try await evaluate("filter.refresh(true); filter.refresh(true)")
        let refreshed = try await evaluate("fixtureReports[fixtureReports.length-1].locationID") as? String
        XCTAssertEqual(refreshed, first, "Readiness refreshes for one location keep their nonce.")
        let immediatelyRejected = try await evaluate("""
        const previousLocationID=fixtureReports[fixtureReports.length-1].locationID;
        fixtureURL='https://www.instagram.com/direct/t/456/';
        !filter.isCurrentLocation(previousLocationID);
        """) as? Bool
        XCTAssertEqual(immediatelyRejected, true, "A queued report must be stale before any filter refresh runs.")
        _ = try await evaluate("filter.refresh(); document.getElementById('history').innerHTML='<p>A message from Sam</p>'; filter.refresh();")
        let secondValue = try await evaluate("fixtureReports[fixtureReports.length-1].locationID") as? String
        let second = try XCTUnwrap(secondValue)
        XCTAssertNotEqual(second, first); XCTAssertNotNil(UUID(uuidString: second))
        let secondIsCurrent = try await evaluate("filter.isCurrentLocation(fixtureReports[fixtureReports.length-1].locationID)") as? Bool
        XCTAssertEqual(secondIsCurrent, true)
        XCTAssertEqual(states.last, "conversation")
        let disposedRejected = try await evaluate("const finalLocationID=fixtureReports[fixtureReports.length-1].locationID; filter.dispose(); !filter.isCurrentLocation(finalLocationID)") as? Bool
        XCTAssertEqual(disposedRejected, true)
    }

    func testThreadReplacementRecognizesNestedHistoryChangesAndIgnoresDraftChanges() async throws {
        try await fixture("""
        <main id='conversation'>
          <header><a href='/direct/inbox/'>Messages</a><h1 id='participant'>Anna</h1></header>
          <div id='history' role='log'><div id='bubble'><span id='message-text'>Anna's conversation</span></div></div>
          <form><textarea id='draft' aria-label='Message'>An unsent draft</textarea><button>Send</button></form>
        </main>
        """, url: "https://www.instagram.com/direct/t/123/")
        _ = try await evaluate("fixtureURL='https://www.instagram.com/direct/t/456/'; filter.refresh();")
        let oldHistory = try await visible("message-text")
        XCTAssertFalse(oldHistory); XCTAssertEqual(states.last, "messages-loading")
        _ = try await evaluate("""
        document.getElementById('draft').firstChild.data='A changed unsent draft';
        document.getElementById('draft').value='A changed unsent draft';
        document.getElementById('draft').dispatchEvent(new Event('input', {bubbles:true}));
        document.getElementById('draft').setAttribute('aria-label', 'Message Sam');
        document.getElementById('history').className='updated-layout';
        """)
        let stillStale = try await visible("message-text")
        XCTAssertFalse(stillStale, "Draft and layout changes do not prove that the new thread's messages have arrived.")
        XCTAssertEqual(states.last, "messages-loading")
        _ = try await evaluate("""
        document.getElementById('message-text').firstChild.data='Sam conversation';
        document.getElementById('participant').firstChild.data='Sam';
        """)
        let freshHistory = try await visible("message-text")
        let preservedDraft = try await evaluate("document.getElementById('draft').value") as? String
        XCTAssertTrue(freshHistory, "React can update nested history text while retaining its wrapper and composer nodes.")
        XCTAssertEqual(states.last, "conversation")
        XCTAssertEqual(preservedDraft, "A changed unsent draft")
    }

    func testSynchronousRefreshConsumesPendingNestedHistoryMutation() async throws {
        try await fixture("""
        <main>
          <header><a href='/direct/inbox/'>Messages</a><h1>Anna</h1></header>
          <div role='log'><div><span id='message-text'>Anna's conversation</span></div></div>
          <form><textarea id='draft'>An unsent draft</textarea><button>Send</button></form>
        </main>
        """, url: "https://www.instagram.com/direct/t/123/")
        _ = try await evaluate("fixtureURL='https://www.instagram.com/direct/t/456/'; filter.refresh();")
        let staleHistory = try await visible("message-text")
        XCTAssertFalse(staleHistory); XCTAssertEqual(states.last, "messages-loading")
        let synchronousState = try await evaluate("""
        document.getElementById('message-text').firstChild.data='Sam conversation';
        filter.refresh();
        fixtureReports[fixtureReports.length-1].state;
        """) as? String
        XCTAssertEqual(synchronousState, "conversation", "Refreshing before MutationObserver delivery must consume pending history changes.")
        let freshHistory = try await visible("message-text")
        let draft = try await evaluate("document.getElementById('draft').value") as? String
        XCTAssertTrue(freshHistory); XCTAssertEqual(states.last, "conversation")
        XCTAssertEqual(draft, "An unsent draft")
    }

    func testConversationComposerMovesAboveKeyboardAndKeepsEmojiControl() async throws {
        try await fixture("""
        <main id='conversation' style='position:fixed; inset:0; overflow:hidden'>
          <header><a href='/direct/inbox/'>Messages</a><h1>Anna</h1></header>
          <div role='log'><p>A message from Anna</p></div>
          <form id='composer' style='position:absolute; bottom:0; left:0; right:0; height:60px; display:flex; transform:translateX(0px)'>
            <button id='emoji' type='button' onclick="this.dataset.opened='yes'">😊</button>
            <textarea id='message' aria-label='Message' style='flex:1; min-width:0'>Draft message</textarea>
            <button id='send' type='button' onclick="this.dataset.clicked='yes'">Send</button>
          </form>
        </main>
        """, url: "https://www.instagram.com/direct/t/123/", viewportHeight: 400)
        let originalBottom = try await evaluate("document.getElementById('composer').getBoundingClientRect().bottom") as! Double
        XCTAssertGreaterThan(originalBottom, 400)
        _ = try await evaluate("document.getElementById('message').focus()")
        let bottom = try await evaluate("document.getElementById('composer').getBoundingClientRect().bottom") as! Double
        let message = try await hittable("message"), send = try await hittable("send"), emoji = try await hittable("emoji")
        XCTAssertLessThanOrEqual(bottom, 388)
        XCTAssertTrue(message); XCTAssertTrue(send); XCTAssertTrue(emoji)
        _ = try await evaluate("filter.refresh(); fixtureViewport.height=280; fixtureViewport.offsetTop=20; fixtureViewport.dispatchEvent(new Event('resize'))")
        let resizedBottom = try await evaluate("document.getElementById('composer').getBoundingClientRect().bottom") as! Double
        XCTAssertEqual(resizedBottom, 288, accuracy: 1)
        _ = try await evaluate("document.getElementById('send').click(); document.getElementById('message').blur()")
        let restoredBottom = try await evaluate("document.getElementById('composer').getBoundingClientRect().bottom") as! Double
        let draft = try await evaluate("document.getElementById('message').value") as? String
        let clicked = try await evaluate("document.getElementById('send').dataset.clicked") as? String
        let transform = try await evaluate("document.getElementById('composer').style.transform") as? String
        XCTAssertEqual(restoredBottom, originalBottom, accuracy: 1)
        XCTAssertEqual(draft, "Draft message"); XCTAssertEqual(clicked, "yes")
        XCTAssertEqual(transform, "translateX(0px)"); XCTAssertEqual(states.last, "conversation")
    }

    func testMessagingCaptureGuardBlocksUnsupportedDirectRoutes() async throws {
        try await fixture("""
        <main><h1>Messages</h1><a href='/direct/new/'>New message</a><a href='/direct/t/123/'>Anna</a>
          <a id='requests' href='/direct/requests/'>Requests</a><a id='malformed' href='/direct/t/anna/'>Profile</a>
        </main>
        """, url: "https://www.instagram.com/direct/inbox/")
        for id in ["requests", "malformed"] {
            let allowed = try await evaluate("document.getElementById('\(id)').dispatchEvent(new MouseEvent('click', {bubbles:true, cancelable:true}))") as? Bool
            XCTAssertEqual(allowed, false)
        }
        XCTAssertEqual(states.last, "restricted-link")
        _ = try await evaluate("fixtureURL='https://www.instagram.com/direct/requests/'; filter.refresh();")
        let main = try await evaluate("getComputedStyle(document.querySelector('main')).visibility") as? String
        XCTAssertEqual(main, "hidden")
        XCTAssertEqual(states.last, "blocked")
    }

    func testNativeViewerStatesPreserveBackNavigationAndRequireIntentForHomeOverlay() {
        let suite = "StoriesViewerState-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = BrowserModel(preferences: preferences)
        model.setAccessAllowed(true)
        model.receiveFilterState("home", route: .home, isLoading: false)
        model.receiveFilterState("story", route: .home, isLoading: false)
        XCTAssertEqual(model.state, .home, "A generic home-page message cannot open an unrequested viewer.")
        model.receiveFilterState("story-loading", route: .blocked, isLoading: false)
        XCTAssertEqual(model.state, .home)
        model.receiveFilterState("story-loading", route: .home, isLoading: false)
        XCTAssertEqual(model.state, .openingStory)
        XCTAssertTrue(model.state.isStoryContext)
        model.receiveFilterState("story", route: .home, isLoading: false)
        XCTAssertEqual(model.state, .story)
        model.receiveFilterState("story-unavailable", route: .story, isLoading: false)
        XCTAssertEqual(model.state, .storyUnavailable)
        XCTAssertTrue(model.state.isStoryContext)
        model.receiveFilterState("home", route: .home, isLoading: false)
        XCTAssertEqual(model.state, .home)
        XCTAssertFalse(model.state.isStoryContext)
    }

    func testFeedOnAStoryRouteIsNeverRevealed() async throws {
        try await fixture("<main id='feed'><img alt='Profile'><article>A post</article></main>",
                          url: "https://www.instagram.com/stories/anna/", viewerWaitMs: 0)
        let isVisible = try await visible("feed")
        XCTAssertFalse(isVisible)
        XCTAssertEqual(states.last, "story-unavailable")
    }

    func testGenericImageContainerIsNotTreatedAsAViewer() async throws {
        try await fixture("<main id='suggestions'><img alt='Suggested account'>People to follow</main>",
                          url: "https://www.instagram.com/stories/anna/", viewerWaitMs: 0)
        let isVisible = try await visible("suggestions")
        XCTAssertFalse(isVisible)
        XCTAssertEqual(states.last, "story-unavailable")
    }

    func testSameKindOfSPARouteStillReportsReadiness() async throws {
        try await fixture("<main role='dialog'><img width='300' height='500' alt='Story'></main>",
                          url: "https://www.instagram.com/stories/anna/123/")
        _ = try await evaluate("globalThis.fixtureURL = 'https://www.instagram.com/stories/sam/456/'; filter.refresh();")
        XCTAssertEqual(states, ["story", "story"])
    }

    func testFilterRestoresItselfWhenStyleIsRemoved() async throws {
        try await fixture("<main><a id='story' href='/stories/anna/'>Anna</a><article id='post'>Feed</article></main>")
        _ = try await evaluate("document.getElementById('stories-filter-style').remove()")
        let postVisible = try await visible("post"), storyVisible = try await visible("story")
        XCTAssertFalse(postVisible); XCTAssertTrue(storyVisible)
    }

    func testCaptureGuardBlocksProfileLinks() async throws {
        try await fixture("<main><a id='profile' href='/anna/'>Anna’s profile</a></main>")
        let allowed = try await evaluate("document.getElementById('profile').dispatchEvent(new MouseEvent('click', {bubbles:true, cancelable:true}))") as? Bool
        XCTAssertEqual(allowed, false)
        XCTAssertEqual(states.last, "restricted-link")
    }

    func testGuardLeavesWrappedExternalLinksForNativeDecision() async throws {
        try await fixture("<a id='external' href='https://l.instagram.com/?u=https%3A%2F%2Fexample.com'>Story link</a>")
        let prevented = try await evaluate("""
        document.addEventListener('click', event => {
          globalThis.wasPrevented = event.defaultPrevented;
          event.preventDefault(); // Keep the fixture entirely offline.
        }, {once: true});
        document.getElementById('external').dispatchEvent(new MouseEvent('click', {bubbles:true, cancelable:true}));
        globalThis.wasPrevented;
        """) as? Bool
        XCTAssertEqual(prevented, false)
    }

    func testNativeAndJavaScriptPoliciesAgree() async throws {
        try await fixture("<main></main>")
        let urls = ["https://www.instagram.com/", "https://www.instagram.com/stories/anna/123/",
                    "https://www.instagram.com/accounts/login/", "https://www.instagram.com/challenge/test/",
                    "https://www.instagram.com/auth_platform?next=%2F", "https://instagram.com/auth_platform/",
                    "https://www.instagram.com/auth_platform/challenge/", "https://www.instagram.com/auth_platform-evil/",
                    "https://www.instagram.com/%61uth_platform/", "https://www.instagram.com/auth_platform%2Fchallenge/",
                    "https://www.instagram.com/direct/inbox/", "https://instagram.com/direct/inbox",
                    "https://www.instagram.com/direct/inbox/?folder=general", "https://www.instagram.com/direct/t/123/",
                    "https://www.instagram.com/direct/t/0", "https://www.instagram.com/direct/t/123?source=story",
                    "https://www.instagram.com/direct/new/", "https://instagram.com/direct/new",
                    "https://www.instagram.com/direct/", "https://www.instagram.com/direct/requests/",
                    "https://www.instagram.com/direct/inbox/extra/", "https://www.instagram.com/direct/new/extra/",
                    "https://www.instagram.com/direct/t/anna/", "https://www.instagram.com/direct/t/123/extra/",
                    "https://www.instagram.com/direct/t/123abc/", "https://www.instagram.com/direct/t/-1/",
                    "https://www.instagram.com/direct/t//", "https://www.instagram.com/Direct/inbox/",
                    "https://www.instagram.com/%64irect/inbox/", "https://www.instagram.com/direct%2Finbox/",
                    "https://www.instagram.com/direct/t/%31/", "https://evil.example/direct/inbox/",
                    "https://www.instagram.com:444/direct/inbox/", "http://www.instagram.com/direct/inbox/",
                    "https://www.instagram.com/reels/", "https://www.instagram.com/stories/highlights/123/",
                    "https://www.instagram.com/%73tories/anna/", "https://evil.example/",
                    "https://www.instagram.com/accounts/login-evil/", "http://www.instagram.com/"]
        for string in urls {
            let encoded = String(data: try JSONEncoder().encode(string), encoding: .utf8)!
            let jsRoute = try await evaluate("StoriesFilter.route(new URL(\(encoded)))") as? String
            XCTAssertEqual(jsRoute, NavigationPolicy.route(for: URL(string: string)!).rawValue, string)
        }
    }

    /// Optional public-login smoke check. It never enters credentials or signs in.
    func testLiveLoginAndLocalSignOut() async throws {
        guard ProcessInfo.processInfo.environment["STORIES_LIVE_SMOKE"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_STORIES_LIVE_SMOKE=1 to check the public Instagram login page.")
        }
        let suite = "StoriesLiveSmoke-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = BrowserModel(preferences: preferences)
        model.setAccessAllowed(true)
        model.signIn()
        var loginReady = false
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(300))
            if model.state == .authentication, let browser = model.webView {
                // Inspect structure only. Never read or supply credential values.
                loginReady = (try? await browser.evaluateJavaScript("!!document.querySelector('input[type=password]')")) as? Bool == true
                if loginReady { break }
            }
            if case .failure = model.state { break }
        }
        XCTAssertTrue(loginReady, "Instagram's public login form should be visible through the native filter.")
        XCTAssertEqual(model.webView?.url?.host, "www.instagram.com")
        let store = try XCTUnwrap(model.webView?.configuration.websiteDataStore)
        let probe = try XCTUnwrap(HTTPCookie(properties: [
            .domain: "www.instagram.com", .path: "/", .name: "stories_cleanup_probe", .value: "test-only"
        ]))
        await withCheckedContinuation { continuation in
            store.httpCookieStore.setCookie(probe) { continuation.resume() }
        }
        await model.signOut()
        let remainingCookies = await withCheckedContinuation { continuation in
            store.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
        let remainingRecords = await withCheckedContinuation { continuation in
            store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(remainingCookies.isEmpty, "Local sign-out must remove cookies.")
        XCTAssertTrue(remainingRecords.isEmpty, "Local sign-out must remove cached website data.")
        XCTAssertEqual(model.state, .welcome)
        XCTAssertNil(model.webView)
        XCTAssertNil(preferences.string(forKey: "websiteDataStoreID"))
        XCTAssertFalse(preferences.bool(forKey: "hasStarted"))
        preferences.removePersistentDomain(forName: suite)
    }
}
