import XCTest
@testable import Stories

final class NavigationPolicyTests: XCTestCase {
    func testAllowedDestinations() {
        let cases: [(String, NavigationPolicy.Route)] = [
            ("https://www.instagram.com/", .home),
            ("https://instagram.com/?source=stories", .home),
            ("https://www.instagram.com/stories/anna/123456789/", .story),
            ("https://www.instagram.com/stories/a.b_c/", .story),
            ("https://www.instagram.com/direct/inbox", .inbox),
            ("https://instagram.com/direct/inbox/?source=stories", .inbox),
            ("https://www.instagram.com/direct/t/123456789/", .conversation),
            ("https://www.instagram.com/direct/t/0?source=inbox", .conversation),
            ("https://www.instagram.com/direct/new/", .messageCompose),
            ("https://www.instagram.com/direct/new", .messageCompose),
            ("https://www.instagram.com/accounts/login/?next=%2F", .authentication),
            ("https://www.instagram.com/accounts/login/two_factor/", .authentication),
            ("https://www.instagram.com/auth_platform?next=%2F", .authentication),
            ("https://instagram.com/auth_platform/", .authentication),
            ("https://www.instagram.com/auth_platform/challenge/", .authentication),
            ("https://www.instagram.com/challenge/abc/", .authentication),
            ("https://www.instagram.com/accounts/password/reset/", .authentication),
            ("https://www.instagram.com/accounts/onetap/", .authentication),
            ("https://www.instagram.com:443/", .home)
        ]
        for (string, route) in cases {
            let url = URL(string: string)!
            XCTAssertEqual(NavigationPolicy.route(for: url), route, string)
            XCTAssertEqual(NavigationPolicy.decide(url, userInitiated: false), .allow, string)
        }
    }

    func testDistractingAndAmbiguousRoutesAreBlocked() {
        let paths = ["/reels/", "/explore/", "/anna/", "/p/123/",
                     "/direct/", "/direct/requests/", "/direct/inbox/extra/", "/direct/new/extra/",
                     "/direct/t/", "/direct/t/not-an-id/", "/direct/t/-123/", "/direct/t/123/extra/",
                     "/direct/t/123/details/", "/direct/t/123/call/", "/direct/t/1.2/",
                     "/direct/%69nbox/", "/direct/t/%31/", "/direct/t/123%2F456/",
                     "/DIRECT/inbox/", "//direct/inbox/", "/direct//inbox/",
                     "/accounts/edit/", "/accounts/login-evil/", "/auth_platform-evil/",
                     "/%61uth_platform/", "/auth_platform%2Fchallenge/", "/stories/highlights/123/",
                     "/stories/create/", "/stories/", "/stories/anna/not-an-id/",
                     "/stories/anna/123/extra", "//stories/anna/", "/%73tories/anna/",
                     "/stories/anna%2Fexplore/", "/stories/../explore/"]
        for path in paths {
            let url = URL(string: "https://www.instagram.com" + path)!
            XCTAssertEqual(NavigationPolicy.decide(url, userInitiated: true), .block, path)
        }
    }

    func testFixedMessagingDestinationsAreAllowedAndClassified() {
        XCTAssertEqual(NavigationPolicy.route(for: NavigationPolicy.inboxURL), .inbox)
        XCTAssertEqual(NavigationPolicy.route(for: NavigationPolicy.composeURL), .messageCompose)
        for route in [NavigationPolicy.Route.inbox, .conversation, .messageCompose] {
            XCTAssertTrue(route.isMessaging)
        }
        for route in [NavigationPolicy.Route.home, .story, .authentication, .blocked] {
            XCTAssertFalse(route.isMessaging)
        }
    }

    func testNoAutomaticExternalNavigationOrCustomSchemes() {
        for string in ["https://example.com/", "https://instagram.com.evil.example/", "https://facebook.com/login/"] {
            XCTAssertEqual(NavigationPolicy.decide(URL(string: string)!, userInitiated: false), .block)
            XCTAssertEqual(NavigationPolicy.decide(URL(string: string)!, userInitiated: true), .external)
        }
        for string in ["http://instagram.com/", "instagram://stories", "javascript:alert(1)",
                       "file:///tmp/test", "data:text/html,hi", "https://user:pass@www.instagram.com/",
                       "https://www.instagram.com:444/", "https://help.instagram.com/",
                       "https://user:pass@example.com/", "https://www.instagram.com./"] {
            XCTAssertEqual(NavigationPolicy.decide(URL(string: string)!, userInitiated: false), .block, string)
        }
        XCTAssertEqual(NavigationPolicy.decide(URL(string: "https://help.instagram.com/")!, userInitiated: true), .block)
    }

    func testStoryLinkRedirectsAreUnwrappedWithoutFollowingThem() {
        let link = URL(string: "https://l.instagram.com/?u=https%3A%2F%2Fexample.com%2Fhello%3Fq%3D1&e=tracking")!
        XCTAssertEqual(NavigationPolicy.externalDestination(for: link)?.absoluteString, "https://example.com/hello?q=1")
        XCTAssertEqual(NavigationPolicy.decide(link, userInitiated: true), .external)
        XCTAssertEqual(NavigationPolicy.decide(link, userInitiated: false), .block)
        for string in ["https://l.instagram.com/?u=javascript%3Aalert(1)",
                       "https://l.instagram.com/?u=https%3A%2F%2Fwww.instagram.com%2Freels%2F",
                       "https://l.instagram.com/?u=https%3A%2F%2Fexample.com&u=https%3A%2F%2Fevil.example",
                       "https://l.instagram.com/?u=https%3A%2F%2Fl.instagram.com%2F"] {
            XCTAssertEqual(NavigationPolicy.decide(URL(string: string)!, userInitiated: true), .block, string)
        }
    }

    func testSubframesStayOnTrustedInstagramOrigins() {
        let allowed = ["https://www.instagram.com/challenge/frame/",
                       "https://instagram.com/embed/", "https://www.instagram.com:443/any/path/"]
        let blocked = ["http://www.instagram.com/challenge/", "https://instagram.com.evil.example/",
                       "https://www.instagram.com./", "https://help.instagram.com/",
                       "https://www.instagram.com:8443/challenge/", "https://user:pass@www.instagram.com/",
                       "https://user@www.instagram.com/", "file:///tmp/frame", "about:blank",
                       "data:text/html,challenge", "https://example.com/captcha/",
                       "https://www.google.com/recaptcha/api2/anchor", "https://hcaptcha.com/"]
        for authentication in [false, true] {
            for string in allowed {
                XCTAssertTrue(NavigationPolicy.allowsSubframe(URL(string: string)!, authentication: authentication), string)
            }
            for string in blocked {
                XCTAssertFalse(NavigationPolicy.allowsSubframe(URL(string: string)!, authentication: authentication), string)
            }
        }
    }

    func testLocalLoginSubframesRequireATrustedCreatorAndExactURL() {
        for destination in ["about:blank", "about:srcdoc"] {
            let url = URL(string: destination)!
            XCTAssertTrue(NavigationPolicy.allowsSubframe(url, authentication: true, sourceIsInstagram: true))
            XCTAssertFalse(NavigationPolicy.allowsSubframe(url, authentication: true))
            XCTAssertFalse(NavigationPolicy.allowsSubframe(url, authentication: false, sourceIsInstagram: true))
            XCTAssertTrue(NavigationPolicy.allowsSubframe(url, authentication: false, messaging: true, sourceIsInstagram: true))
            XCTAssertFalse(NavigationPolicy.allowsSubframe(url, authentication: false, messaging: true))
            XCTAssertEqual(NavigationPolicy.decide(url, userInitiated: false), .block)
        }
        for destination in ["about:blank?url=https://evil.example", "about:blank#login", "about:srcdoc?test",
                            "data:text/html,login", "javascript:void(0)", "https://example.com/challenge/"] {
            XCTAssertFalse(NavigationPolicy.allowsSubframe(URL(string: destination)!,
                authentication: true, sourceIsInstagram: true), destination)
        }
    }

    func testLoginSyncFrameRequiresAuthenticationAndTrustedCreator() {
        for destination in ["https://www.facebook.com/instagram/login_sync/",
                            "https://www.facebook.com:443/instagram/login_sync?next=%2F"] {
            let url = URL(string: destination)!
            XCTAssertTrue(NavigationPolicy.allowsSubframe(url, authentication: true, sourceIsInstagram: true))
            XCTAssertFalse(NavigationPolicy.allowsSubframe(url, authentication: true))
            XCTAssertFalse(NavigationPolicy.allowsSubframe(url, authentication: false, sourceIsInstagram: true))
            XCTAssertTrue(NavigationPolicy.allowsSubframe(url, authentication: false, messaging: true, sourceIsInstagram: true))
            XCTAssertFalse(NavigationPolicy.allowsSubframe(url, authentication: false, messaging: true))
            XCTAssertEqual(NavigationPolicy.decide(url, userInitiated: false), .block)
            XCTAssertTrue(NavigationPolicy.allowsResponse(url: url, isMainFrame: false, authentication: false,
                messaging: true, canShowMIMEType: true, mimeType: "text/html"))
            XCTAssertFalse(NavigationPolicy.allowsResponse(url: url, isMainFrame: true, authentication: false,
                messaging: true, canShowMIMEType: true, mimeType: "text/html"))
            for isMainFrame in [false, true] {
                for authentication in [false, true] {
                    XCTAssertEqual(NavigationPolicy.allowsResponse(url: url,
                        isMainFrame: isMainFrame, authentication: authentication,
                        canShowMIMEType: true, mimeType: "text/html"), !isMainFrame && authentication)
                }
            }
        }
        for destination in ["https://www.facebook.com/login/", "https://facebook.com/instagram/login_sync/",
                            "https://www.facebook.com.evil.example/instagram/login_sync/",
                            "https://www.facebook.com:444/instagram/login_sync/",
                            "https://user:pass@www.facebook.com/instagram/login_sync/",
                            "http://www.facebook.com/instagram/login_sync/",
                            "https://www.facebook.com/instagram/login_sync/other/",
                            "https://www.facebook.com/instagram/login_sync-evil/",
                            "https://www.facebook.com/instagram/%6cogin_sync/",
                            "https://www.facebook.com/instagram/login_sync%2F"] {
            let url = URL(string: destination)!
            XCTAssertFalse(NavigationPolicy.allowsSubframe(url, authentication: true, sourceIsInstagram: true), destination)
            XCTAssertFalse(NavigationPolicy.allowsResponse(url: url, isMainFrame: false, authentication: true,
                canShowMIMEType: true, mimeType: "text/html"), destination)
        }
        let url = URL(string: "https://www.facebook.com/instagram/login_sync/")!
        XCTAssertFalse(NavigationPolicy.allowsResponse(url: url, isMainFrame: false, authentication: true,
            canShowMIMEType: true, mimeType: "application/octet-stream"))
        XCTAssertFalse(NavigationPolicy.allowsResponse(url: url, isMainFrame: false, authentication: true,
            canShowMIMEType: true, mimeType: "text/html", contentDisposition: "attachment"))
        XCTAssertFalse(NavigationPolicy.allowsScriptMessageOrigin(isMainFrame: true, scheme: "https",
            host: "www.facebook.com", port: 443))
    }

    func testResponsesRevalidateRedirectDestinationForEveryFrame() {
        for authentication in [false, true] {
            for isMainFrame in [false, true] {
                for destination in ["https://example.com/login/", "https://www.instagram.com.evil.example/",
                                    "https://www.instagram.com:444/", "https://user:pass@www.instagram.com/",
                                    "http://www.instagram.com/"] {
                    XCTAssertFalse(NavigationPolicy.allowsResponse(url: URL(string: destination)!,
                        isMainFrame: isMainFrame, authentication: authentication,
                        canShowMIMEType: true, mimeType: "text/html"), destination)
                }
                XCTAssertTrue(NavigationPolicy.allowsResponse(url: NavigationPolicy.loginURL,
                    isMainFrame: isMainFrame, authentication: authentication,
                    canShowMIMEType: true, mimeType: "text/html"))
                XCTAssertFalse(NavigationPolicy.allowsResponse(url: nil,
                    isMainFrame: isMainFrame, authentication: authentication,
                    canShowMIMEType: true, mimeType: "text/html"))
            }
        }
        let embed = URL(string: "https://www.instagram.com/embed/")!
        XCTAssertTrue(NavigationPolicy.allowsResponse(url: embed, isMainFrame: false, authentication: false,
                                                     canShowMIMEType: true, mimeType: "text/html"))
        XCTAssertFalse(NavigationPolicy.allowsResponse(url: embed, isMainFrame: true, authentication: false,
                                                      canShowMIMEType: true, mimeType: "text/html"))
    }

    func testDownloadAndNonHTMLResponsesAreRejectedInEveryFrame() {
        for isMainFrame in [false, true] {
            for mimeType in [nil, "application/octet-stream", "application/pdf", "image/svg+xml", "image/png"] {
                XCTAssertFalse(NavigationPolicy.allowsResponse(url: NavigationPolicy.loginURL,
                    isMainFrame: isMainFrame, authentication: true, canShowMIMEType: true, mimeType: mimeType))
            }
            XCTAssertFalse(NavigationPolicy.allowsResponse(url: NavigationPolicy.loginURL,
                isMainFrame: isMainFrame, authentication: true, canShowMIMEType: false, mimeType: "text/html"))
            for disposition in ["attachment", "attachment; filename=login.html", " Attachment ; filename=login.html"] {
                XCTAssertFalse(NavigationPolicy.allowsResponse(url: NavigationPolicy.loginURL,
                    isMainFrame: isMainFrame, authentication: true, canShowMIMEType: true,
                    mimeType: "text/html", contentDisposition: disposition), disposition)
            }
            XCTAssertTrue(NavigationPolicy.allowsResponse(url: NavigationPolicy.loginURL,
                isMainFrame: isMainFrame, authentication: true, canShowMIMEType: true,
                mimeType: "TEXT/HTML", contentDisposition: "inline; filename=login.html"))
        }
    }

    func testScriptBridgeRequiresMainFrameAndTrustedHTTPSOrigin() {
        XCTAssertTrue(NavigationPolicy.allowsScriptMessageOrigin(isMainFrame: true, scheme: "https",
                                                                 host: "www.instagram.com", port: 0))
        XCTAssertTrue(NavigationPolicy.allowsScriptMessageOrigin(isMainFrame: true, scheme: "HTTPS",
                                                                 host: "INSTAGRAM.COM", port: 443))
        XCTAssertFalse(NavigationPolicy.allowsScriptMessageOrigin(isMainFrame: false, scheme: "https",
                                                                  host: "www.instagram.com", port: 443))
        for scheme in ["http", "file", "data", ""] {
            XCTAssertFalse(NavigationPolicy.allowsScriptMessageOrigin(isMainFrame: true, scheme: scheme,
                                                                      host: "www.instagram.com", port: 443))
        }
        for host in ["instagram.com.evil.example", "help.instagram.com", "www.instagram.com.", ""] {
            XCTAssertFalse(NavigationPolicy.allowsScriptMessageOrigin(isMainFrame: true, scheme: "https",
                                                                      host: host, port: 443))
        }
        for port in [-1, 80, 444, 8443] {
            XCTAssertFalse(NavigationPolicy.allowsScriptMessageOrigin(isMainFrame: true, scheme: "https",
                                                                      host: "www.instagram.com", port: port))
        }
    }
}
