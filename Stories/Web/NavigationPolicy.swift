import Foundation

/// Controls document navigation and bridge origins. Instagram still loads its own resources.
enum NavigationPolicy {
    enum Route: String {
        case home, story, inbox, conversation, messageCompose, authentication, blocked
        var isMessaging: Bool { self == .inbox || self == .conversation || self == .messageCompose }
    }
    enum Decision: Equatable { case allow, external, block }

    static let homeURL = URL(string: "https://www.instagram.com/")!
    static let inboxURL = URL(string: "https://www.instagram.com/direct/inbox/")!
    static let composeURL = URL(string: "https://www.instagram.com/direct/new/")!
    static let loginURL = URL(string: "https://www.instagram.com/accounts/login/")!
    static let hosts: Set<String> = ["instagram.com", "www.instagram.com"]

    static func isInstagram(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && hosts.contains(url.host?.lowercased() ?? "")
            && (url.port == nil || url.port == 443)
            && url.user == nil && url.password == nil
    }

    static func route(for url: URL) -> Route {
        guard isInstagram(url), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              !parts.percentEncodedPath.contains("%"), !url.path.contains("\\") else { return .blocked }
        let path = parts.percentEncodedPath
        if path.isEmpty || path == "/" { return .home }
        if path == "/direct/inbox" || path == "/direct/inbox/" { return .inbox }
        if path == "/direct/new" || path == "/direct/new/" { return .messageCompose }
        if path.range(of: #"^/direct/t/[0-9]+/?$"#, options: .regularExpression) != nil { return .conversation }
        if path.range(of: #"^/stories/[A-Za-z0-9._]{1,30}(?:/[0-9]+)?/?$"#, options: .regularExpression) != nil {
            let username = path.split(separator: "/")[1].lowercased()
            return ["highlights", "archive", "create"].contains(username) ? .blocked : .story
        }
        let authenticationRoots = [
            "/accounts/login", "/accounts/password/reset", "/accounts/onetap",
            "/accounts/confirm_email", "/auth_platform", "/challenge", "/checkpoint", "/consent"
        ]
        if authenticationRoots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return .authentication
        }
        return .blocked
    }

    static func decide(_ url: URL, userInitiated: Bool) -> Decision {
        if isInstagram(url) { return route(for: url) == .blocked ? .block : .allow }
        // Never launch custom schemes, embedded credentials, downloads, or automatic redirects.
        return userInitiated && externalDestination(for: url) != nil ? .external : .block
    }

    static func allowsSubframe(_ url: URL, authentication: Bool, messaging: Bool = false, sourceIsInstagram: Bool = false) -> Bool {
        // Login and Direct bootstrap a session-sync iframe locally. These
        // documents inherit their creator's origin; they are not external providers.
        if (authentication || messaging) && sourceIsInstagram {
            if ["about:blank", "about:srcdoc"].contains(url.absoluteString) || isLoginSyncFrame(url) {
                return true
            }
        }
        // The approved exact login-sync frame also supports Direct initialization.
        // Other external documents and the Stories-only view stay blocked.
        return isInstagram(url)
    }

    private static func isLoginSyncFrame(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.host?.lowercased() == "www.facebook.com",
              url.port == nil || url.port == 443, url.user == nil, url.password == nil,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return ["/instagram/login_sync", "/instagram/login_sync/"].contains(parts.percentEncodedPath)
    }

    static func allowsResponse(url: URL?, isMainFrame: Bool, authentication: Bool, messaging: Bool = false,
                               canShowMIMEType: Bool, mimeType: String?,
                               contentDisposition: String? = nil) -> Bool {
        guard let url, canShowMIMEType, mimeType?.lowercased() == "text/html" else { return false }
        let disposition = contentDisposition?.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard disposition != "attachment" else { return false }
        if isMainFrame { return route(for: url) != .blocked }
        // The action already checked the initiating origin. Revalidate the exact
        // network destination here so the approved frame cannot redirect elsewhere.
        return isInstagram(url) || ((authentication || messaging) && isLoginSyncFrame(url))
    }

    static func allowsScriptMessageOrigin(isMainFrame: Bool, scheme: String, host: String, port: Int) -> Bool {
        isMainFrame && scheme.lowercased() == "https" && hosts.contains(host.lowercased())
            && (port == 0 || port == 443)
    }

    static func externalDestination(for url: URL) -> URL? {
        guard url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { return nil }
        // Instagram commonly wraps story links. Resolve wrapped URLs locally;
        // never load the redirector inside our authenticated web view.
        if url.host?.lowercased() == "l.instagram.com" {
            guard url.path.isEmpty || url.path == "/",
                  let values = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.filter({ $0.name == "u" }),
                  values.count == 1, let value = values.first?.value, let target = URL(string: value),
                  let host = target.host?.lowercased(), host != "instagram.com", !host.hasSuffix(".instagram.com") else { return nil }
            return externalDestination(for: target)
        }
        // Other Instagram subdomains aren't an escape hatch from the route restrictions.
        if let host = url.host?.lowercased(), host == "instagram.com" || host.hasSuffix(".instagram.com") {
            return nil
        }
        return url
    }
}
