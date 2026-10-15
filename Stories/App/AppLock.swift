import LocalAuthentication
import SwiftUI

@MainActor
protocol AppLockAuthenticationContext: AnyObject {
    func canAuthenticate() -> Bool
    func authenticate(reason: String) async throws -> Bool
    func invalidate()
}

@MainActor
final class DeviceOwnerAuthenticationContext: AppLockAuthenticationContext {
    private let context = LAContext()

    func canAuthenticate() -> Bool {
        context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    func authenticate(reason: String) async throws -> Bool {
        try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
    }

    func invalidate() { context.invalidate() }
}

@MainActor
final class AppLock: ObservableObject {
    @Published private(set) var enabled: Bool
    @Published private(set) var locked: Bool
    @Published private(set) var authenticating = false
    @Published var error: String?

    private enum Action {
        case unlock
        case setEnabled(Bool)
    }

    private let preferences: UserDefaults
    private let makeAuthenticationContext: @MainActor () -> any AppLockAuthenticationContext
    private var authenticationContext: (any AppLockAuthenticationContext)?
    private var authenticationGeneration = UUID()
    private var pendingAction: Action?
    private var foreground = false

    init(preferences: UserDefaults = .standard,
         makeAuthenticationContext: @escaping @MainActor () -> any AppLockAuthenticationContext = { DeviceOwnerAuthenticationContext() }) {
        self.preferences = preferences
        self.makeAuthenticationContext = makeAuthenticationContext
        let savedPreference = preferences.bool(forKey: "appLockEnabled")
        enabled = savedPreference
        locked = savedPreference
    }

    func setForeground(_ active: Bool) {
        foreground = active
        // The system authentication prompt can briefly make the scene inactive.
        // Preserve its result, but never uncover the app until the scene is active.
        if active, let action = pendingAction { complete(action) }
    }

    func lock() {
        invalidateAuthentication()
        if enabled { locked = true }
    }

    func unlock() async {
        guard locked else { return }
        await authenticate(.unlock, reason: "Unlock your Stories")
    }

    func setEnabled(_ value: Bool) async {
        guard value != enabled else { return }
        await authenticate(.setEnabled(value), reason: value
            ? "Protect Stories with your device lock" : "Turn off the Stories app lock")
    }

    private func authenticate(_ action: Action, reason: String) async {
        guard foreground, !authenticating, !Task.isCancelled else { return }
        authenticating = true
        error = nil
        authenticationGeneration = UUID()
        let generation = authenticationGeneration
        let context = makeAuthenticationContext()
        authenticationContext = context
        guard context.canAuthenticate() else {
            finishFailure(generation: generation, message: "Set a device passcode in Settings to use the app lock.")
            return
        }
        do {
            let success = try await withTaskCancellationHandler {
                try await context.authenticate(reason: reason)
            } onCancel: {
                Task { @MainActor [weak self] in self?.cancelAuthentication(generation: generation) }
            }
            guard generation == authenticationGeneration else { return }
            guard !Task.isCancelled else {
                cancelAuthentication(generation: generation)
                return
            }
            authenticationContext?.invalidate()
            authenticationContext = nil
            if success {
                if foreground { complete(action) }
                else { pendingAction = action }
            } else {
                finishFailure(generation: generation, message: "Authentication was not completed. Try again when you’re ready.")
            }
        } catch {
            guard generation == authenticationGeneration else { return }
            if Task.isCancelled || error is CancellationError {
                cancelAuthentication(generation: generation)
            } else {
                finishFailure(generation: generation, message: "Authentication was not completed. Try again when you’re ready.")
            }
        }
    }

    private func complete(_ action: Action) {
        pendingAction = nil
        authenticating = false
        error = nil
        switch action {
        case .unlock:
            locked = false
        case .setEnabled(let value):
            enabled = value
            locked = false
            preferences.set(value, forKey: "appLockEnabled")
        }
    }

    private func finishFailure(generation: UUID, message: String) {
        guard generation == authenticationGeneration else { return }
        invalidateAuthentication()
        error = message
    }

    private func cancelAuthentication(generation: UUID) {
        guard generation == authenticationGeneration else { return }
        invalidateAuthentication()
    }

    private func invalidateAuthentication() {
        authenticationGeneration = UUID()
        pendingAction = nil
        authenticationContext?.invalidate()
        authenticationContext = nil
        authenticating = false
        error = nil
    }
}
