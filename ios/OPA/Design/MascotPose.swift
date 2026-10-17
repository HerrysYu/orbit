import Foundation

/// Orbit mascot poses. Images live in Assets.xcassets/Mascot (temporary cut-outs from the concept sheet).
/// Shared by the design system (OrbitMascot) and the core model (Presence.mood).
enum MascotPose: String, CaseIterable, Sendable {
    case wave, attentive, thinking, focused, happy, side

    var imageName: String {
        switch self {
        case .wave: "MascotWave"
        case .attentive: "MascotAttentive"
        case .thinking: "MascotThinking"
        case .focused: "MascotFocused"
        case .happy: "MascotHappy"
        case .side: "MascotSide"
        }
    }
}
