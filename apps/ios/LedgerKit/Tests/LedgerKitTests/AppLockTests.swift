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

    var prompts: [String] { lock.withLock { _prompts } }
    func answer(_ values: Bool...) { lock.withLock { _answers.append(contentsOf: values) } }

    func availableMethod() -> DeviceAuthMethod? { lock.withLock { _method } }
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
        await lock.phaseChanged(.inactive)
        #expect(lock.showsCover && !lock.showsUnlock)
        await lock.phaseChanged(.background)
        #expect(lock.showsCover && !lock.isLocked)   // off: covered, never locked
        await lock.phaseChanged(.active)
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
        #expect(AppLock(defaults: try defaults(), authenticator: StubAuthenticator(method: .touchID)).settingTitle
                == "Require Touch ID")
    }

    @Test("on: leaving locks, coming back asks once; a cancelled prompt leaves Unlock and never loops")
    func lockAndUnlock() async throws {
        let auth = StubAuthenticator(answers: [true])
        let lock = AppLock(defaults: try defaults(), authenticator: auth)
        await lock.setRequireAuth(true)

        await lock.phaseChanged(.inactive)
        #expect(!lock.isLocked)              // Control Center etc. only cover
        await lock.phaseChanged(.background)
        #expect(lock.isLocked && lock.showsCover)

        auth.answer(false)                   // the owner cancels the prompt
        await lock.phaseChanged(.active)
        #expect(lock.isLocked && lock.showsUnlock && auth.prompts.count == 2)
        // The prompt made the scene inactive and active again: no second automatic prompt.
        await lock.phaseChanged(.inactive)
        await lock.phaseChanged(.active)
        #expect(auth.prompts.count == 2 && lock.showsUnlock)

        auth.answer(true)                    // the Unlock button
        await lock.unlock()
        #expect(!lock.isLocked && !lock.showsCover)
    }

    @Test("a cold launch with it on starts locked and asks on the first activation")
    func coldLaunch() async throws {
        let store = try defaults()
        store.set(true, forKey: AppLock.requireKey)
        let auth = StubAuthenticator(answers: [true])
        let lock = AppLock(defaults: store, authenticator: auth)
        #expect(lock.isLocked && lock.showsCover)
        await lock.phaseChanged(.active)
        #expect(!lock.isLocked && auth.prompts == ["Unlock Bank Ledger"])
    }
}
