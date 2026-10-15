import SwiftUI

struct SettingsView: View {
    @ObservedObject var browser: BrowserModel
    @ObservedObject var appLock: AppLock
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmSignOut = false

    private var canAccess: Bool {
        scenePhase == .active && browser.accessAllowed && !appLock.locked
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("No app backend or analytics", systemImage: "checkmark.shield")
                    Label(browser.rememberSession ? "Login remembered on this device" : "Login kept only while the app is open", systemImage: "iphone")
                    Label("Login handled by Instagram", systemImage: "lock")
                } header: { Text("Private by design") }
                Section {
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
                    .disabled(appLock.authenticating || browser.state == .signingOut)
                    .accessibilityIdentifier("requireDeviceUnlock")
                    if browser.rememberSession && !appLock.enabled {
                        Text("Recommended for a remembered login: protect access with your device lock.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = appLock.error { Text(error).font(.caption).foregroundStyle(.secondary) }
                } footer: { Text("Use Face ID, Touch ID, or your device passcode when you return to the app.") }
                Section {
                    Toggle("Remember Instagram login", isOn: Binding(
                        get: { browser.rememberSession },
                        set: { value in
                            guard canAccess else { return }
                            Task {
                                guard browser.accessAllowed, !appLock.locked else { return }
                                await browser.setRememberSession(value)
                            }
                        }
                    ))
                    .disabled(appLock.authenticating || browser.state == .signingOut)
                    .accessibilityIdentifier("rememberInstagramLogin")
                } footer: {
                    Text("When off, this app clears your Instagram session when it moves to the background or closes. Changing this setting signs you out of this app and clears its current Instagram data.")
                }
                Section {
                    Text("In Instagram’s app or website, open Accounts Center → Password and security → Two-factor authentication. Choose your Instagram account and an authentication app, then save your recovery codes somewhere safe.")
                    Text("This is separate from Stories’ device lock and protects your Instagram account when signing in on a new device.")
                    Text("Some accounts now call Accounts Center “Meta Account.” Follow its password and security settings.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Text("Protect your Instagram account") }
                    .font(.subheadline)
                Section {
                    Text("To revoke a session at Instagram, open Accounts Center → Password and security → Where you’re logged in. Choose your Instagram account and log out the devices or sessions you want to remove.")
                    Text("If you see a login you don’t recognize, change your Instagram password and review two-factor authentication. Clearing Stories’ local data alone does not revoke a session at Instagram.")
                } header: { Text("Review Instagram sessions") }
                    .font(.subheadline)
                Section {
                    Text("Stories and Messages display Instagram’s website. Instagram handles your message history and delivery. Your login and normal website requests still go to Instagram.")
                    Text("Instagram’s own tracking and ads may still appear within stories. This app hides distracting surfaces; it does not control which stories Instagram serves.")
                    Text("Instagram can change its layout or restrict embedded browsers. Unrecognized content stays hidden. Facebook sign-in and destinations outside Instagram are not supported inside the app.")
                } header: { Text("What to know") }
                    .font(.subheadline).foregroundStyle(Palette.muted)
                if browser.state != .welcome {
                    Section {
                        Button("Sign out of this app", role: .destructive) {
                            guard canAccess else { return }
                            confirmSignOut = true
                        }
                        .disabled(appLock.authenticating || browser.state == .signingOut)
                        .accessibilityIdentifier("signOutOfStories")
                    } footer: { Text("Clears this app’s Instagram cookies, cache, and website storage. It does not sign you out on other devices or revoke sessions at Instagram.") }
                }
                Section {
                    Text("Made for a quieter connection.\nNot affiliated with Instagram or Meta.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden).background(Palette.paper)
            .navigationTitle("Your space").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        guard canAccess else { return }
                        dismiss()
                    }
                }
            }
            .confirmationDialog("Sign out and clear Instagram data?", isPresented: Binding(
                get: { canAccess && confirmSignOut },
                set: { confirmSignOut = $0 && canAccess }
            ), titleVisibility: .visible) {
                Button("Sign out", role: .destructive) {
                    guard canAccess else { return }
                    dismiss()
                    Task {
                        guard browser.accessAllowed, !appLock.locked else { return }
                        await browser.signOut()
                    }
                }
                Button("Cancel", role: .cancel) { confirmSignOut = false }
            }
        }
        .tint(Palette.green)
        .disabled(!canAccess)
        .opacity(canAccess ? 1 : 0)
        .allowsHitTesting(canAccess)
        .accessibilityHidden(!canAccess)
        .overlay {
            if !canAccess {
                LockScreen(appLock: appLock, interactive: scenePhase == .active)
            }
        }
        .onChange(of: canAccess) { _, allowed in
            if !allowed { confirmSignOut = false }
        }
    }
}
