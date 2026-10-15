import SwiftUI
import WebKit

enum Palette {
    static let paper = Color(red: 0.965, green: 0.961, blue: 0.941)
    static let ink = Color(red: 0.16, green: 0.22, blue: 0.19)
    static let green = Color(red: 0.24, green: 0.37, blue: 0.28)
    static let muted = Color(red: 0.43, green: 0.47, blue: 0.43)
}

struct ContentView: View {
    @ObservedObject var browser: BrowserModel
    @ObservedObject var appLock: AppLock
    @State private var showSettings = false
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    private var canAccess: Bool {
        scenePhase == .active && browser.accessAllowed && !appLock.locked
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Palette.ink.opacity(0.09)).frame(height: 1)
            if browser.state == .loading || browser.state == .openingStory || browser.state == .openingMessages {
                ProgressView(value: browser.progress).tint(Palette.green)
                    .accessibilityLabel("Loading Instagram")
            }
            ZStack {
                Palette.paper
                if let webView = browser.webView {
                    InstagramWebView(webView: webView)
                        .id(browser.webViewIdentity)
                        .opacity(browser.state.showsWebContent ? 1 : 0)
                        .allowsHitTesting(browser.state.showsWebContent)
                        .accessibilityHidden(!browser.state.showsWebContent)
                }
                stateContent
            }
            if browser.state == .authentication {
                Label("Signing in at instagram.com", systemImage: "lock.fill")
                    .font(.caption).foregroundStyle(Palette.muted).padding(12)
            } else if browser.state == .home {
                Text("A little closer. A little less scrolling.")
                    .font(.caption).foregroundStyle(Palette.muted).padding(.top, 10).padding(.bottom, 4)
            }
            if showsSectionNavigation { sectionNavigation }
        }
        .background(Palette.paper)
        .foregroundStyle(Palette.ink)
        .tint(Palette.green)
        .disabled(!canAccess)
        .allowsHitTesting(canAccess)
        .accessibilityHidden(!canAccess)
        .sheet(isPresented: $showSettings) {
            SettingsView(browser: browser, appLock: appLock)
        }
        .alert("Your quiet space", isPresented: Binding(get: { canAccess && browser.notice != nil }, set: { if !$0 { dismissNotice() } })) {
            Button("OK", role: .cancel) { browser.notice = nil }
        } message: { Text(browser.notice ?? "") }
        .confirmationDialog("Open this link in your browser?", isPresented: Binding(
            get: { canAccess && browser.externalURL != nil }, set: { if !$0 { dismissExternalURL() } }
        ), titleVisibility: .visible) {
            if let url = browser.externalURL {
                Button("Open \(url.host ?? "link")") {
                    guard canAccess else { return }
                    openURL(url)
                    browser.externalURL = nil
                }
            }
            Button("Cancel", role: .cancel) { browser.externalURL = nil }
        } message: { Text("You’ll leave Stories. Your Instagram session stays in this app.") }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background || (phase != .active && !appLock.authenticating) {
                dismissPresentations()
            }
        }
        .onChange(of: appLock.locked) { _, locked in
            if locked { dismissPresentations() }
        }
        .onChange(of: browser.accessAllowed) { _, allowed in
            if !allowed {
                browser.notice = nil
                browser.externalURL = nil
                if !appLock.authenticating { showSettings = false }
            }
        }
    }

    private func dismissPresentations() {
        showSettings = false
        browser.notice = nil
        browser.externalURL = nil
    }

    // SwiftUI can reset presentation bindings while updating the view hierarchy.
    // Defer observable-model writes, and don't dismiss a newer pending prompt.
    private func dismissNotice() {
        guard let notice = browser.notice else { return }
        Task { @MainActor in
            guard browser.notice == notice else { return }
            browser.notice = nil
        }
    }

    private func dismissExternalURL() {
        guard let url = browser.externalURL else { return }
        Task { @MainActor in
            guard browser.externalURL == url else { return }
            browser.externalURL = nil
        }
    }

    private var header: some View {
        HStack {
            if browser.state.isStoryContext || browser.state.isMessagingContext && browser.state != .inbox {
                Button {
                    guard canAccess else { return }
                    if browser.state.isStoryContext { browser.showStories() }
                    else { browser.showMessages() }
                } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                    .accessibilityLabel(browser.state.isStoryContext ? "Back to stories" : "Back to messages")
                    .accessibilityIdentifier("backToSection")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(browser.section == .messages ? "messages" : "stories")
                    .font(.system(size: 29, weight: .medium, design: .serif))
                Text(browser.state == .authentication ? "YOUR INSTAGRAM, PRIVATELY"
                     : browser.state == .messageCompose ? "A NEW CONVERSATION"
                     : browser.section == .messages ? "KEEP IN TOUCH" : "JUST YOUR PEOPLE")
                    .font(.system(size: 9, weight: .semibold)).tracking(2)
                    .foregroundStyle(Palette.muted)
            }
            Spacer()
            if browser.state == .inbox {
                Button {
                    guard canAccess else { return }
                    browser.composeMessage()
                } label: {
                    Image(systemName: "square.and.pencil").frame(width: 44, height: 44)
                }
                .accessibilityLabel("New message")
                .accessibilityIdentifier("newMessage")
            }
            if browser.state != .welcome && browser.state != .signingOut {
                Button {
                    guard canAccess else { return }
                    browser.reload()
                } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 44, height: 44)
                }.accessibilityLabel("Refresh Instagram")
            }
            Button {
                guard canAccess else { return }
                showSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44)
            }.accessibilityLabel("Privacy and settings")
        }
        .padding(.horizontal, 20).padding(.vertical, 15)
    }

    private var showsSectionNavigation: Bool {
        browser.state != .welcome && browser.state != .authentication && browser.state != .signingOut
            && browser.browserKind != .authentication
    }

    private var sectionNavigation: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Palette.ink.opacity(0.09)).frame(height: 1)
            HStack(spacing: 12) {
                sectionButton(.stories, title: "Stories", symbol: "circle.dashed")
                sectionButton(.messages, title: "Messages", symbol: "bubble.left.and.bubble.right")
            }
            .padding(.horizontal, 20).padding(.vertical, 10)
        }
    }

    private func sectionButton(_ section: BrowserModel.Section, title: String, symbol: String) -> some View {
        let selected = browser.section == section
        return Button {
            guard canAccess else { return }
            browser.selectSection(section)
        } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 14, weight: selected ? .semibold : .medium))
                .frame(maxWidth: .infinity).frame(minHeight: 44)
                .foregroundStyle(selected ? Palette.green : Palette.muted)
                .background(selected ? Palette.green.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(section == .stories ? "storiesTab" : "messagesTab")
    }

    @ViewBuilder private var stateContent: some View {
        switch browser.state {
        case .welcome:
            WelcomeView(browser: browser, appLock: appLock)
        case .loading:
            StatusView(symbol: "circle.dotted", title: "A moment for your people.",
                       detail: "Opening Instagram with the distractions tucked away.") {
                ProgressView().tint(Palette.green)
            }
        case .openingStory:
            StatusView(symbol: "play.rectangle", title: "Opening story…",
                       detail: "Loading this moment from Instagram.") {
                ProgressView().tint(Palette.green)
                Button("Back to stories") { browser.showStories() }.font(.subheadline)
            }
        case .openingMessages:
            StatusView(symbol: "bubble.left.and.bubble.right", title: "Opening your messages…",
                       detail: "A little space for your conversations.") {
                ProgressView().tint(Palette.green)
            }
        case .messagesUnavailable:
            StatusView(symbol: "bubble.left", title: "Messages couldn’t open.",
                       detail: "Try refreshing, or return to your inbox.") {
                Button("Reload messages") { browser.reload() }.buttonStyle(PrimaryButtonStyle())
                Button("Back to inbox") { browser.showMessages() }.font(.subheadline)
                Button("Open Instagram sign-in") { browser.signIn() }.font(.subheadline)
            }
        case .storyUnavailable:
            StatusView(symbol: "play.slash", title: "This story couldn’t open.",
                       detail: "Try reloading it, or return to your Stories.") {
                Button("Reload") { browser.reload() }.buttonStyle(PrimaryButtonStyle())
                Button("Back to stories") { browser.showStories() }.font(.subheadline)
            }
        case .unavailable:
            StatusView(symbol: "leaf", title: "Stories aren’t visible yet.",
                       detail: "Instagram loaded, but we couldn’t display its Stories area. Refresh to try again; the rest of the page stays hidden.") {
                Button("Try stories again") { browser.showStories() }.buttonStyle(PrimaryButtonStyle())
                Button("Open Instagram sign-in") { browser.signIn() }.font(.subheadline)
            }
        case .failure(let message):
            StatusView(symbol: "wifi.exclamationmark", title: "Let’s try that again.", detail: message) {
                Button("Reload Instagram") { browser.reload() }.buttonStyle(PrimaryButtonStyle())
                Button("Open Instagram sign-in") { browser.signIn() }.font(.subheadline)
            }
        case .signingOut:
            StatusView(symbol: "lock", title: "Clearing this device.", detail: "Removing Instagram’s cookies and saved website data.") {
                ProgressView().tint(Palette.green)
            }
        default: EmptyView()
        }
    }
}

private struct WelcomeView: View {
    @ObservedObject var browser: BrowserModel
    @ObservedObject var appLock: AppLock
    @Environment(\.scenePhase) private var scenePhase

    private var canAccess: Bool {
        scenePhase == .active && browser.accessAllowed && !appLock.locked
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: -8) {
                    StoryCircle(symbol: "sun.max", color: Color(red: 0.81, green: 0.62, blue: 0.43), rotation: -12)
                    StoryCircle(symbol: "leaf", color: Color(red: 0.51, green: 0.64, blue: 0.50), rotation: 8)
                    StoryCircle(symbol: "moon.stars", color: Color(red: 0.62, green: 0.63, blue: 0.76), rotation: -8)
                }
                .accessibilityHidden(true).padding(.top, 44).padding(.bottom, 42)
                Text("Stay close.\nSkip the scroll.")
                    .font(.system(size: 45, weight: .regular, design: .serif))
                    .tracking(-1.6).fixedSize(horizontal: false, vertical: true)
                Text("The little moments from your people.\nA quieter way to open Instagram.")
                    .font(.system(size: 17)).foregroundStyle(Palette.muted)
                    .lineSpacing(5).padding(.top, 19)
                VStack(alignment: .leading, spacing: 18) {
                    benefit("bubble.left.and.bubble.right", "Stories and messages, without the feed")
                    benefit("lock", "Sign in directly with Instagram")
                    benefit("iphone", browser.rememberSession ? "Your login, remembered on this device" : "Your login, only while the app is open")
                }.padding(.vertical, 36)
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Require device unlock", isOn: Binding(
                        get: { appLock.enabled },
                        set: { value in
                            guard canAccess else { return }
                            Task {
                                guard browser.accessAllowed, !appLock.locked else { return }
                                await appLock.setEnabled(value)
                            }
                        }
                    ))
                    .disabled(!canAccess || appLock.authenticating)
                    .accessibilityIdentifier("onboardingRequireDeviceUnlock")
                    Text(browser.rememberSession && !appLock.enabled
                         ? "Recommended: protect your remembered Instagram login with Face ID, Touch ID, or your device passcode."
                         : "Protect access to Stories when you return to the app.")
                        .font(.caption).foregroundStyle(Palette.muted)
                    if let error = appLock.error {
                        Text(error).font(.caption).foregroundStyle(Palette.muted)
                    }
                    Text("You can choose whether to remember your login in Privacy and settings. For extra Instagram protection, enable an authentication app under Accounts Center → Password and security → Two-factor authentication.")
                        .font(.caption).foregroundStyle(Palette.muted)
                }
                .padding(18)
                .background(Palette.green.opacity(0.06), in: RoundedRectangle(cornerRadius: 17))
                .padding(.bottom, 24)
                Button {
                    guard canAccess else { return }
                    browser.signIn()
                } label: {
                    HStack { Text("Continue with Instagram"); Spacer(); Image(systemName: "arrow.right") }
                }.buttonStyle(PrimaryButtonStyle())
                .disabled(!canAccess || appLock.authenticating)
                .accessibilityIdentifier("continueWithInstagram")
                Text("An independent, personal-use browser.\nNo account with us. No app analytics.")
                    .font(.caption).foregroundStyle(Palette.muted).lineSpacing(4)
                    .frame(maxWidth: .infinity).multilineTextAlignment(.center).padding(.top, 18)
            }
            .frame(maxWidth: 420, alignment: .leading)
            .padding(.horizontal, 28).padding(.bottom, 30)
            .frame(maxWidth: .infinity)
        }
    }

    private func benefit(_ symbol: String, _ title: String) -> some View {
        Label { Text(title).font(.subheadline) } icon: {
            Image(systemName: symbol).font(.system(size: 18)).frame(width: 25).foregroundStyle(Palette.green)
        }
    }
}

private struct StoryCircle: View {
    let symbol: String
    let color: Color
    let rotation: Double
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 31, weight: .light)).foregroundStyle(Palette.ink.opacity(0.8))
            .frame(width: 78, height: 78).background(color.opacity(0.45), in: Circle())
            .padding(5).overlay(Circle().stroke(color, lineWidth: 1.4))
            .background(Palette.paper, in: Circle()).rotationEffect(.degrees(rotation))
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white).padding(.horizontal, 21).padding(.vertical, 18)
            .frame(maxWidth: .infinity)
            .background(Palette.green.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 17))
    }
}

private struct StatusView<Actions: View>: View {
    let symbol: String
    let title: String
    let detail: String
    @ViewBuilder let actions: () -> Actions
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: symbol).font(.system(size: 39, weight: .light)).foregroundStyle(Palette.green)
            Text(title).font(.system(size: 30, weight: .regular, design: .serif)).multilineTextAlignment(.center)
            Text(detail).font(.subheadline).foregroundStyle(Palette.muted).multilineTextAlignment(.center).lineSpacing(4)
            actions().padding(.top, 8)
        }.padding(32).frame(maxWidth: 420)
    }
}

private struct InstagramWebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct LockScreen: View {
    @ObservedObject var appLock: AppLock
    let interactive: Bool
    var body: some View {
        ZStack {
            Palette.paper.ignoresSafeArea()
            VStack(spacing: 24) {
                Image(systemName: "lock").font(.system(size: 36, weight: .light))
                Text("stories").font(.system(size: 44, weight: .regular, design: .serif))
                if interactive && appLock.locked {
                    Text("A little space, just for you.").foregroundStyle(Palette.muted)
                    Button("Unlock Stories") { Task { await appLock.unlock() } }
                        .buttonStyle(PrimaryButtonStyle()).disabled(appLock.authenticating)
                    if let error = appLock.error { Text(error).font(.caption).multilineTextAlignment(.center) }
                }
            }.padding(36).frame(maxWidth: 400).foregroundStyle(Palette.ink)
        }
        .accessibilityAddTraits(.isModal)
    }
}
