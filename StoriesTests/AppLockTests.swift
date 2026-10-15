import XCTest
@testable import Stories

@MainActor
final class AppLockTests: XCTestCase {
    func testLockIsOptionalAndRestoresSavedPreference() async {
        let optional = fixture(enabled: false)
        defer { optional.clear() }
        XCTAssertFalse(optional.model.enabled)
        XCTAssertFalse(optional.model.locked)

        let protected = fixture()
        defer { protected.clear() }
        XCTAssertTrue(protected.model.enabled)
        XCTAssertTrue(protected.model.locked)
    }

    func testUnlockRequiresForegroundAndSuccessfulAuthentication() async {
        let context = ControlledAuthenticationContext()
        let fixture = fixture(contexts: [context])
        defer { fixture.clear() }
        let model = fixture.model
        await model.unlock()
        XCTAssertFalse(context.started)
        XCTAssertTrue(model.locked)

        model.setForeground(true)
        let attempt = Task { await model.unlock() }
        await context.waitUntilStarted()
        XCTAssertTrue(model.locked)
        context.finish(.success(true))
        await attempt.value
        XCTAssertFalse(model.locked)
        XCTAssertFalse(model.authenticating)
        XCTAssertTrue(fixture.preferences.bool(forKey: "appLockEnabled"))
    }

    func testBackgroundInvalidatesUnlockAndRejectsLateSuccess() async {
        let context = ControlledAuthenticationContext()
        let fixture = fixture(contexts: [context])
        defer { fixture.clear() }
        let model = fixture.model
        model.setForeground(true)
        let attempt = Task { await model.unlock() }
        await context.waitUntilStarted()

        model.setForeground(false)
        model.lock()
        XCTAssertTrue(context.invalidated)
        XCTAssertFalse(model.authenticating)
        model.setForeground(true)
        context.finish(.success(true))
        await attempt.value
        XCTAssertTrue(model.locked)
    }

    func testTransientInactiveDefersSuccessUntilForeground() async {
        let context = ControlledAuthenticationContext()
        let fixture = fixture(contexts: [context])
        defer { fixture.clear() }
        let model = fixture.model
        model.setForeground(true)
        let attempt = Task { await model.unlock() }
        await context.waitUntilStarted()

        model.setForeground(false)
        XCTAssertFalse(context.invalidated, "The system authentication prompt can temporarily inactivate the scene.")
        context.finish(.success(true))
        await attempt.value
        XCTAssertTrue(model.locked)
        XCTAssertTrue(model.authenticating)
        model.setForeground(true)
        XCTAssertFalse(model.locked)
        XCTAssertFalse(model.authenticating)
    }

    func testBackgroundDiscardsSuccessDeferredWhileInactive() async {
        let context = ControlledAuthenticationContext()
        let fixture = fixture(contexts: [context])
        defer { fixture.clear() }
        let model = fixture.model
        model.setForeground(true)
        let attempt = Task { await model.unlock() }
        await context.waitUntilStarted()
        model.setForeground(false)
        context.finish(.success(true))
        await attempt.value

        model.lock()
        model.setForeground(true)
        XCTAssertTrue(model.locked)
        XCTAssertFalse(model.authenticating)
    }

    func testStaleFailureCannotClearNewAuthentication() async {
        let oldContext = ControlledAuthenticationContext()
        let newContext = ControlledAuthenticationContext()
        let fixture = fixture(contexts: [oldContext, newContext])
        defer { fixture.clear() }
        let model = fixture.model
        model.setForeground(true)
        let oldAttempt = Task { await model.unlock() }
        await oldContext.waitUntilStarted()
        model.lock()
        let newAttempt = Task { await model.unlock() }
        await newContext.waitUntilStarted()

        oldContext.finish(.failure(TestFailure.authentication))
        await oldAttempt.value
        XCTAssertTrue(model.locked)
        XCTAssertTrue(model.authenticating)
        XCTAssertNil(model.error)
        XCTAssertFalse(newContext.invalidated)
        newContext.finish(.success(true))
        await newAttempt.value
        XCTAssertFalse(model.locked)
    }

    func testCancellingUnlockInvalidatesContextAndRejectsLateSuccess() async {
        let context = ControlledAuthenticationContext()
        let fixture = fixture(contexts: [context])
        defer { fixture.clear() }
        let model = fixture.model
        model.setForeground(true)
        let attempt = Task { await model.unlock() }
        await context.waitUntilStarted()
        attempt.cancel()
        context.finish(.success(true))
        await attempt.value
        XCTAssertTrue(context.invalidated)
        XCTAssertTrue(model.locked)
        XCTAssertFalse(model.authenticating)
    }

    func testDisablingRequiresSuccessfulAuthentication() async {
        let failedContext = ControlledAuthenticationContext()
        let successfulContext = ControlledAuthenticationContext()
        let fixture = fixture(contexts: [failedContext, successfulContext])
        defer { fixture.clear() }
        let model = fixture.model
        model.setForeground(true)
        let failedAttempt = Task { await model.setEnabled(false) }
        await failedContext.waitUntilStarted()
        failedContext.finish(.success(false))
        await failedAttempt.value
        XCTAssertTrue(model.enabled)
        XCTAssertTrue(model.locked)
        XCTAssertTrue(fixture.preferences.bool(forKey: "appLockEnabled"))

        let successfulAttempt = Task { await model.setEnabled(false) }
        await successfulContext.waitUntilStarted()
        successfulContext.finish(.success(true))
        await successfulAttempt.value
        XCTAssertFalse(model.enabled)
        XCTAssertFalse(model.locked)
        XCTAssertFalse(fixture.preferences.bool(forKey: "appLockEnabled"))
    }

    func testBackgroundRejectsLateDisableSuccess() async {
        let context = ControlledAuthenticationContext()
        let fixture = fixture(contexts: [context])
        defer { fixture.clear() }
        let model = fixture.model
        model.setForeground(true)
        let attempt = Task { await model.setEnabled(false) }
        await context.waitUntilStarted()
        model.setForeground(false)
        model.lock()
        context.finish(.success(true))
        await attempt.value
        model.setForeground(true)
        XCTAssertTrue(model.enabled)
        XCTAssertTrue(model.locked)
        XCTAssertTrue(fixture.preferences.bool(forKey: "appLockEnabled"))
    }

    func testEnablingWaitsForForegroundBeforeChangingPreference() async {
        let context = ControlledAuthenticationContext()
        let fixture = fixture(enabled: false, contexts: [context])
        defer { fixture.clear() }
        let model = fixture.model
        model.setForeground(true)
        let attempt = Task { await model.setEnabled(true) }
        await context.waitUntilStarted()
        model.setForeground(false)
        context.finish(.success(true))
        await attempt.value
        XCTAssertFalse(model.enabled)
        XCTAssertFalse(fixture.preferences.bool(forKey: "appLockEnabled"))
        model.setForeground(true)
        XCTAssertTrue(model.enabled)
        XCTAssertTrue(fixture.preferences.bool(forKey: "appLockEnabled"))
    }

    func testBackgroundRejectsEnablingResultEvenWhenLockWasDisabled() async {
        let context = ControlledAuthenticationContext()
        let fixture = fixture(enabled: false, contexts: [context])
        defer { fixture.clear() }
        let model = fixture.model
        model.setForeground(true)
        let attempt = Task { await model.setEnabled(true) }
        await context.waitUntilStarted()
        model.setForeground(false)
        model.lock()
        context.finish(.success(true))
        await attempt.value
        model.setForeground(true)
        XCTAssertTrue(context.invalidated)
        XCTAssertFalse(model.enabled)
        XCTAssertFalse(fixture.preferences.bool(forKey: "appLockEnabled"))
    }

    func testUnavailableOrCancelledAuthenticationCannotDisableLock() async {
        let unavailable = ControlledAuthenticationContext(available: false)
        let cancelled = ControlledAuthenticationContext()
        let fixture = fixture(contexts: [unavailable, cancelled])
        defer { fixture.clear() }
        let model = fixture.model
        model.setForeground(true)
        await model.setEnabled(false)
        XCTAssertTrue(model.enabled)
        XCTAssertTrue(model.locked)
        XCTAssertFalse(model.authenticating)
        XCTAssertNotNil(model.error)

        let attempt = Task { await model.setEnabled(false) }
        await cancelled.waitUntilStarted()
        cancelled.finish(.failure(CancellationError()))
        await attempt.value
        XCTAssertTrue(model.enabled)
        XCTAssertTrue(model.locked)
        XCTAssertFalse(model.authenticating)
        XCTAssertTrue(fixture.preferences.bool(forKey: "appLockEnabled"))
    }

    private func fixture(enabled: Bool = true, contexts: [ControlledAuthenticationContext] = []) -> Fixture {
        let suite = "StoriesAppLockTests-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        preferences.set(enabled, forKey: "appLockEnabled")
        var remainingContexts = contexts
        let model = AppLock(preferences: preferences, makeAuthenticationContext: { remainingContexts.removeFirst() })
        return Fixture(model: model, preferences: preferences, suite: suite)
    }

    private struct Fixture {
        let model: AppLock
        let preferences: UserDefaults
        let suite: String
        func clear() { preferences.removePersistentDomain(forName: suite) }
    }

    private enum TestFailure: Error { case authentication }
}

@MainActor
private final class ControlledAuthenticationContext: AppLockAuthenticationContext {
    private let available: Bool
    private var continuation: CheckedContinuation<Bool, Error>?
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private(set) var started = false
    private(set) var invalidated = false

    init(available: Bool = true) { self.available = available }

    func canAuthenticate() -> Bool { available }

    func authenticate(reason: String) async throws -> Bool {
        started = true
        startedContinuation?.resume()
        startedContinuation = nil
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func invalidate() {
        // Deliberately allow a later callback to exercise generation validation.
        invalidated = true
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }

    func finish(_ result: Result<Bool, Error>) {
        guard let pending = continuation else {
            XCTFail("Authentication must start before completing it.")
            return
        }
        continuation = nil
        pending.resume(with: result)
    }
}
