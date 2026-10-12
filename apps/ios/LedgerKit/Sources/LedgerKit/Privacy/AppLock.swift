import Foundation
import Observation

/// How this device proves it is its owner.
public enum DeviceAuthMethod: String, Sendable, Equatable {
    case faceID, touchID, opticID, passcode

    /// `"Face ID"`, `"Touch ID"`, `"Optic ID"`, `"passcode"`.
    public var name: String {
        switch self {
        case .faceID: "Face ID"
        case .touchID: "Touch ID"
        case .opticID: "Optic ID"
        case .passcode: "passcode"
        }
    }
}

/// The device's owner check (LocalAuthentication in the app, a stub in tests).
public protocol DeviceAuthenticating: Sendable {
    /// What the device would ask for, or nil when it has no biometrics and no passcode.
    func availableMethod() -> DeviceAuthMethod?
    /// Shows the system prompt; true when the owner passed it.
    func authenticate(reason: String) async -> Bool
}

/// The privacy cover and the optional "Require Face ID" lock (BACKLOG IOS-22).
///
/// * Whenever the scene isn't active (app switcher, Control Center, a system
///   prompt) the screen is covered, so the multitasking snapshot never shows
///   balances or transactions.
/// * With "Require Face ID" on, going to the background locks the app; coming
///   back asks once, automatically. A cancelled or failed prompt leaves the
///   lock screen with an Unlock button; it never re-prompts in a loop (the
///   prompt itself makes the scene inactive and active again).
@MainActor
@Observable
public final class AppLock {
    /// The scene phase, without importing SwiftUI's `ScenePhase` into the decision.
    public enum Phase: Sendable { case active, inactive, background }

    static let requireKey = "ledger.requireDeviceAuth"

    /// The setting: ask for Face ID (or the passcode) when coming back.
    public private(set) var requireAuth: Bool
    /// The app is locked until the owner authenticates.
    public private(set) var isLocked: Bool
    /// The scene isn't active: the content is covered.
    public private(set) var isInactive = false
    public private(set) var isAuthenticating = false
    /// Why the setting couldn't be turned on.
    public private(set) var message: String?

    private let defaults: UserDefaults
    private let authenticator: any DeviceAuthenticating
    /// The automatic prompt has run since the app last came back from the background.
    private var prompted = false

    public init(defaults: UserDefaults, authenticator: any DeviceAuthenticating) {
        self.defaults = defaults
        self.authenticator = authenticator
        let required = defaults.bool(forKey: Self.requireKey)
        requireAuth = required
        isLocked = required   // a cold launch starts locked
    }

    /// Draw the cover over everything.
    public var showsCover: Bool { isInactive || isLocked }
    /// The cover shows the Unlock button (not just the blur).
    public var showsUnlock: Bool { isLocked && !isInactive && !isAuthenticating }

    public var method: DeviceAuthMethod { authenticator.availableMethod() ?? .faceID }

    /// `"Require Face ID"` (or Touch ID / passcode on such a device).
    public var settingTitle: String { "Require \(method.name)" }
    public var unlockTitle: String { "Unlock with \(method.name)" }
    public static let footer = "Bank Ledger always hides its screen in the app switcher. With this on, it also locks when you leave it and asks for Face ID (or your passcode) when you come back."

    public func phaseChanged(_ phase: Phase) async {
        switch phase {
        case .inactive:
            isInactive = true
        case .background:
            isInactive = true
            if requireAuth {
                isLocked = true
                prompted = false
            }
        case .active:
            isInactive = false
            if isLocked && !prompted {
                prompted = true
                await unlock()
            }
        }
    }

    /// The prompt (automatic on return, or the Unlock button).
    public func unlock() async {
        guard isLocked, !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }
        // Cancelling is not an error: the lock screen and its Unlock button stay.
        if await authenticator.authenticate(reason: "Unlock Bank Ledger") { isLocked = false }
    }

    /// Turning it on proves the owner can pass the check first, so nobody is
    /// locked out by a device without Face ID or a passcode. Turning it off
    /// needs no prompt: the app is already unlocked.
    public func setRequireAuth(_ on: Bool) async {
        message = nil
        guard on != requireAuth else { return }
        if on {
            guard let method = authenticator.availableMethod() else {
                message = "Set up Face ID or a passcode in the Settings app first."
                return
            }
            isAuthenticating = true
            let passed = await authenticator.authenticate(reason: "Turn on \(method.name) for Bank Ledger")
            isAuthenticating = false
            guard passed else {
                message = "\(method == .passcode ? "The passcode" : method.name) didn't confirm it's you, so it stays off."
                return
            }
        }
        requireAuth = on
        defaults.set(on, forKey: Self.requireKey)
    }
}
