import SwiftUI

// MARK: - Avatar

/// Orbit's round avatar: the `MascotDisc` color behind the dedicated `MascotAvatar` composition (eyes stay visible
/// down to 20 pt). `ring` adds a 1.5 pt Accent inner stroke; v2 headers do not use it (no ring around the avatar).
/// Decorative: hidden from VoiceOver.
struct OrbitAvatar: View {
    var size: CGFloat
    var ring: Bool = false

    var body: some View {
        Circle()
            .fill(Color.mascotDisc)
            .overlay {
                // The artwork has transparent corners: zoom 1.1x and re-center on the largest fully opaque
                // circle (radius 0.457, center 0.46 / 0.54 of the image) so the face fills the disc.
                Image(.mascotAvatar)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .scaleEffect(1.1)
                    .offset(x: size * 0.044, y: -size * 0.044)
            }
            .overlay {
                if ring { Circle().strokeBorder(Color.accentText, lineWidth: 1.5) }
            }
            .frame(width: size, height: size)
            .clipShape(.circle)
            .accessibilityHidden(true)
    }
}

// MARK: - Mascot

/// The full-body character at a given scale (welcome 178, chat empty state 140, task empty state 96).
/// `size` is the side of the square the artwork is fitted into, so swapping poses never shifts layout.
/// Soft contact shadow included. Motion is single-shot and off under Reduce Motion:
/// - `greet`: when it appears, a gentle sway (±6°, twice), then still.
/// - `.happy`: when it appears, one squash-and-bounce (0.6 s).
/// Decorative: hidden from VoiceOver (give the surrounding container the status text).
struct OrbitMascot: View {
    var pose: MascotPose
    var size: CGFloat
    var greet: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @State private var motionTick = 0

    var body: some View {
        ZStack {
            Image(pose.imageName)
                .resizable()
                .scaledToFit()
                .id(pose)
                .transition(.opacity)
        }
        .frame(width: size, height: size)
        .shadow(color: shadowColor, radius: size * 0.055, y: size * 0.08)
        .keyframeAnimator(initialValue: MascotMotion(), trigger: motionTick) { content, value in
            content
                .scaleEffect(x: value.scaleX, y: value.scaleY, anchor: .bottom)
                .rotationEffect(.degrees(value.angle), anchor: .bottom)
                .offset(y: value.lift)
        } keyframes: { _ in
            mascotKeyframes
        }
        .animation(reduceMotion ? Motion.fade : .easeOut(duration: 0.2), value: pose)
        .onAppear { if shouldAnimate(for: pose) { motionTick += 1 } }
        .onChange(of: pose) { _, new in if shouldAnimate(for: new) && new == .happy { motionTick += 1 } }
        .onChange(of: greet) { _, isGreeting in if isGreeting && shouldAnimate(for: pose) { motionTick += 1 } }
        .accessibilityHidden(true)
    }

    private var shadowColor: Color {
        scheme == .dark
            ? .black.opacity(0.5)
            : Color(red: 120.0 / 255, green: 72.0 / 255, blue: 30.0 / 255).opacity(0.16)
    }

    /// A motion plays on appearance for `.happy`, or for any pose when `greet` is set.
    private func shouldAnimate(for pose: MascotPose) -> Bool {
        !reduceMotion && (pose == .happy || greet)
    }

    /// One 0.6 s squash-and-bounce for `.happy`, otherwise the ±6° sway. Every property keeps a track in both
    /// cases (a single constant beat when unused) because keyframe tracks cannot be added conditionally.
    @KeyframesBuilder<MascotMotion>
    private var mascotKeyframes: some Keyframes<MascotMotion> {
        let bounce = pose == .happy
        let rest = [MascotBeat(0, 0.6)]
        KeyframeTrack(\.angle) {
            for beat in bounce ? rest : Self.swayAngles { CubicKeyframe(beat.value, duration: beat.duration) }
        }
        KeyframeTrack(\.scaleX) {
            for beat in bounce ? Self.squashX : Self.restOne { CubicKeyframe(beat.value, duration: beat.duration) }
        }
        KeyframeTrack(\.scaleY) {
            for beat in bounce ? Self.squashY : Self.restOne { CubicKeyframe(beat.value, duration: beat.duration) }
        }
        KeyframeTrack(\.lift) {
            for beat in bounce ? hopLift : rest { CubicKeyframe(beat.value, duration: beat.duration) }
        }
    }

    // Gentle wave: +6, -6, +6, -6, rest (1.1 s).
    private static let swayAngles = [MascotBeat(6, 0.14), MascotBeat(-6, 0.26), MascotBeat(6, 0.26), MascotBeat(-6, 0.26), MascotBeat(0, 0.18)]
    // Squash, rise while stretching, land with a small squash, settle (0.6 s).
    private static let squashY = [MascotBeat(0.93, 0.10), MascotBeat(1.06, 0.16), MascotBeat(0.97, 0.14), MascotBeat(1.0, 0.20)]
    private static let squashX = [MascotBeat(1.05, 0.10), MascotBeat(0.97, 0.16), MascotBeat(1.02, 0.14), MascotBeat(1.0, 0.20)]
    private static let restOne = [MascotBeat(1, 1.1)]
    private var hopLift: [MascotBeat] {
        [MascotBeat(0, 0.10), MascotBeat(-size * 0.06, 0.16), MascotBeat(0, 0.14), MascotBeat(0, 0.20)]
    }
}

/// One keyframe: target value and the time to reach it.
private struct MascotBeat: Sendable {
    var value: Double
    var duration: Double
    init(_ value: Double, _ duration: Double) { self.value = value; self.duration = duration }
}

/// Animated properties of the one-shot mascot motions.
struct MascotMotion: Sendable {
    var angle: Double = 0
    var scaleX: Double = 1
    var scaleY: Double = 1
    var lift: Double = 0
}
