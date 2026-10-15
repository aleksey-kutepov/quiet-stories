import SwiftUI

@main
struct StoriesApp: App {
    @StateObject private var browser = BrowserModel()
    @StateObject private var appLock = AppLock()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(browser: browser, appLock: appLock)
                .overlay {
                    if appLock.locked || scenePhase != .active {
                        LockScreen(appLock: appLock, interactive: scenePhase == .active)
                    }
                }
                .onAppear { applyScenePhase(scenePhase) }
                .onChange(of: scenePhase) { _, phase in applyScenePhase(phase) }
                .onChange(of: appLock.locked) { _, locked in
                    browser.setAccessAllowed(scenePhase == .active && !locked)
                }
                .preferredColorScheme(.light)
        }
    }

    private func applyScenePhase(_ phase: ScenePhase) {
        appLock.setForeground(phase == .active)
        if phase == .background {
            appLock.lock()
            browser.enterBackground()
        } else {
            browser.setAccessAllowed(phase == .active && !appLock.locked)
        }
    }
}
