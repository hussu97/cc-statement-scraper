import Foundation
#if canImport(LocalAuthentication)
import LocalAuthentication

/// `DeviceAuthenticating` on LocalAuthentication: biometrics with the device
/// passcode as the fallback (`.deviceOwnerAuthentication`), so a failed Face ID
/// never locks the owner out. Face ID needs `NSFaceIDUsageDescription` (project.yml).
///
/// `@concurrent`: `canEvaluatePolicy` and `biometryType` are synchronous XPC calls
/// to the system's authentication service, so they run on the cooperative pool,
/// never on the main thread that awaits them (hang review, build 26).
public struct LocalDeviceAuthenticator: DeviceAuthenticating {
    public init() {}

    @concurrent
    public func availableMethod() async -> DeviceAuthMethod? {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return nil }
        switch context.biometryType {
        case .faceID: return .faceID
        case .touchID: return .touchID
        case .opticID: return .opticID
        default: return .passcode
        }
    }

    @concurrent
    public func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }
}
#endif
