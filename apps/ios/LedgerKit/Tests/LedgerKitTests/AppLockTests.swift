import Foundation
import Testing
@testable import LedgerKit

/// A device owner check that answers from a script.
final class StubAuthenticator: DeviceAuthenticating, @unchecked Sendable {
    private let lock = NSLock()
    private var _method: DeviceAuthMethod?
    private var _answers: [Bool]
    private var _prompts: [String] = []

    init(method: DeviceAuthMethod? = .faceID, answers: [Bool] = []) {
        _method = method
        _answers = answers
    }

    private var _queries = 0

    var prompts: [String] { lock.withLock { _prompts } }
    /// How many times the device was asked which method it has (an XPC call on a phone).
    var queries: Int { lock.withLock { _queries } }
    /// The owner changes the device (removes the passcode, enrols Face ID).
    func setMethod(_ method: DeviceAuthMethod?) { lock.withLock { _method = method } }
    func answer(_ values: Bool...) { lock.withLock { _answers.append(contentsOf: values) } }

    func availableMethod() async -> DeviceAuthMethod? {
        lock.withLock {
            _queries += 1
            return _method
        }
    }
    func authenticate(reason: String) async -> Bool {
        lock.withLock {
            _prompts.append(reason)
            return _answers.isEmpty ? false : _answers.removeFirst()
        }
    }
}

@MainActor
@Suite("App lock: app-switcher cover and Require Face ID (IOS-22)")
struct AppLockTests {
    func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "ledger-lock-\(UUID().uuidString)"))
    }

    @Test("the screen is covered whenever the scene isn't active, lock or not")
    func coverWhenInactive() async throws {
        let lock = AppLock(defaults: try defaults(), authenticator: StubAuthenticator())
        #expect(!lock.showsCover && !lock.isLocked)
        await lock.phaseChanged(.inactive)?.value
        #expect(lock.showsCover && !lock.showsUnlock)
        await lock.phaseChanged(.background)?.value
        #expect(lock.showsCover && !lock.isLocked)   // off: covered, never locked
        await lock.phaseChanged(.active)?.value
        #expect(!lock.showsCover)
    }

    @Test("turning it on asks first; a device without Face ID or a passcode can't turn it on")
    func enabling() async throws {
        let store = try defaults()
        let auth = StubAuthenticator(answers: [false])
        let lock = AppLock(defaults: store, authenticator: auth)
        #expect(lock.settingTitle == "Require Face ID")
        await lock.setRequireAuth(true)
        #expect(!lock.requireAuth && lock.message == "Face ID didn't confirm it's you, so it stays off.")
        auth.answer(true)
        await lock.setRequireAuth(true)
        #expect(lock.requireAuth && lock.message == nil && store.bool(forKey: AppLock.requireKey))
        #expect(auth.prompts.count == 2)
        await lock.setRequireAuth(false)   // no prompt to turn it off
        #expect(!lock.requireAuth && auth.prompts.count == 2)

        let none = AppLock(defaults: try defaults(), authenticator: StubAuthenticator(method: nil))
        await none.setRequireAuth(true)
        #expect(!none.requireAuth && none.message == "Set up Face ID or a passcode in the Settings app first.")
        let touch = AppLock(defaults: try defaults(), authenticator: StubAuthenticator(method: .touchID))
        await touch.refreshMethod()
        #expect(touch.settingTitle == "Require Touch ID")
    }

    @Test("drawing the cover or Settings never asks the device: the method is read once per activation")
    func methodIsCached() async throws {
        let auth = StubAuthenticator(method: .faceID)
        let lock = AppLock(defaults: try defaults(), authenticator: auth)
        for _ in 0..<5 {
            _ = lock.settingTitle
            _ = lock.unlockTitle
            _ = lock.method
            _ = lock.showsUnlock
        }
        #expect(auth.queries == 0)   // init and every synchronous read: no LocalAuthentication call

        // Touch ID set up while the app was away: coming back reads it, once.
        auth.setMethod(.touchID)
        lock.phaseChanged(.background)
        await lock.phaseChanged(.active)?.value
        #expect(auth.queries == 1 && lock.unlockTitle == "Unlock with Touch ID")
    }

    @Test("on: leaving locks, coming back asks once; a cancelled prompt leaves Unlock and never loops")
    func lockAndUnlock() async throws {
        let auth = StubAuthenticator(answers: [true])
        let lock = AppLock(defaults: try defaults(), authenticator: auth)
        await lock.setRequireAuth(true)

        await lock.phaseChanged(.inactive)?.value
        #expect(!lock.isLocked)              // Control Center etc. only cover
        await lock.phaseChanged(.background)?.value
        #expect(lock.isLocked && lock.showsCover)

        auth.answer(false)                   // the owner cancels the prompt
        await lock.phaseChanged(.active)?.value
        #expect(lock.isLocked && lock.showsUnlock && auth.prompts.count == 2)
        // The prompt made the scene inactive and active again: no second automatic prompt.
        await lock.phaseChanged(.inactive)?.value
        await lock.phaseChanged(.active)?.value
        #expect(auth.prompts.count == 2 && lock.showsUnlock)

        auth.answer(true)                    // the Unlock button
        await lock.unlock()
        #expect(!lock.isLocked && !lock.showsCover)
    }

    @Test("passcode removed while locked: the lock turns itself off (persisted) instead of stranding the owner")
    func methodRemoved() async throws {
        let store = try defaults()
        let auth = StubAuthenticator(answers: [true])
        let lock = AppLock(defaults: store, authenticator: auth)
        await lock.setRequireAuth(true)
        lock.phaseChanged(.background)
        auth.setMethod(nil)                  // the owner removed the device passcode meanwhile
        await lock.phaseChanged(.active)?.value
        #expect(!lock.isLocked && !lock.showsCover)
        #expect(!lock.requireAuth && !store.bool(forKey: AppLock.requireKey))
        #expect(lock.message == AppLock.turnedOffMessage)
        #expect(auth.prompts.count == 1)     // only the one that turned it on
        // A cold launch with the setting still stored but no method also opens.
        let stale = try defaults()
        stale.set(true, forKey: AppLock.requireKey)
        let relaunch = AppLock(defaults: stale, authenticator: StubAuthenticator(method: nil))
        await relaunch.phaseChanged(.active)?.value
        #expect(!relaunch.isLocked && !stale.bool(forKey: AppLock.requireKey))
    }

    @Test("leaving covers at once, synchronously, before any await")
    func synchronousCover() throws {
        let lock = AppLock(defaults: try defaults(), authenticator: StubAuthenticator())
        #expect(lock.phaseChanged(.inactive) == nil)
        #expect(lock.showsCover)
        lock.phaseChanged(.background)
        #expect(lock.showsCover)
    }

    @Test("a cold launch with it on starts locked and asks on the first activation")
    func coldLaunch() async throws {
        let store = try defaults()
        store.set(true, forKey: AppLock.requireKey)
        let auth = StubAuthenticator(answers: [true])
        let lock = AppLock(defaults: store, authenticator: auth)
        #expect(lock.isLocked && lock.showsCover)
        await lock.phaseChanged(.active)?.value
        #expect(!lock.isLocked && auth.prompts == ["Unlock Bank Ledger"])
    }
}
