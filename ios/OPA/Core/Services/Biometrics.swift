import Foundation
import LocalAuthentication

enum Biometrics {
    /// Face ID / Touch ID with passcode fallback. Returns false on cancel or failure.
    static func authenticate(reason: String) async -> Bool {
        let ctx = LAContext()
        ctx.localizedCancelTitle = "取消"
        var error: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            #if targetEnvironment(simulator)
            return true   // Simulators without enrolled biometrics: allow so flows can be tested.
            #else
            return false
            #endif
        }
        return (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}
