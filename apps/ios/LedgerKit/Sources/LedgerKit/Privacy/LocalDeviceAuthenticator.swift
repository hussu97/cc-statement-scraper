import Foundation
#if canImport(LocalAuthentication)
import LocalAuthentication

/// `DeviceAuthenticating` on LocalAuthentication: biometrics with the device
/// passcode as the fallback (`.deviceOwnerAuthentication`), so a failed Face ID
/// never locks the owner out. Face ID needs `NSFaceIDUsageDescription` (project.yml).
public struct LocalDeviceAuthenticator: DeviceAuthenticating {
    public init() {}

    public func availableMethod() -> DeviceAuthMethod? {
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
