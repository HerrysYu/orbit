import SwiftUI

// MARK: - Color tokens
//
// Colors are asset-catalog color sets (Any + Dark, sRGB) reached through the generated symbols, for example
// `Color.canvas`, `.surface`, `.ink`. `Color.accentColor` is the `AccentColor` asset and has the same value as
// `accentText`. Spec: docs/design/v2-direction.md section 1.
//
//                    light     dark       use
//   canvas           #F7F6F4   #121110    page background
//   surface          #FFFFFF   #1C1B19    cards, grouped lists, composer, sheets, secondary button
//   ink              #1D1B19   #F2F0EC    titles, body text
//   inkSecondary     #5F5B55   #A8A49D    secondary text, section titles, line icons
//   inkTertiary      #736F69   #8C8882    placeholders, auxiliary info, chevrons (only on canvas / surface)
//   hairline         #E6E3DE   #2E2C29    0.5 pt strokes, separators, progress-line track
//   accentText       #A9521A   #F0A15E    text links, the 6 pt in-progress dot, the 2 pt progress line (= AccentColor)
//   primaryFill      #1D1B19   #F2F0EC    primary button fill
//   onPrimary        #FFFFFF   #121110    text / icons on primaryFill
//   userBubble       #ECEAE6   #2A2826    your message (only ink / inkSecondary on it)
//   success          #1F7A4A   #5FC48A    \
//   warning          #8A6100   #E8C14E     > text and 6 pt dots only, never a colored block
//   danger           #B3261E   #FF8A80    /
//
// Retired names, kept so code that still mentions them compiles. They carry no color any more:
//   brandApricot                          = accentText (in-progress marks)
//   brandSoft, successSoft, warningSoft, dangerSoft, surfaceInset
//                    #F5F3F0   #232220    one quiet neutral, a hair off the surface
//   orbitBubble      = surface            onUserBubble = ink
// New code should not use any of them: separate with a hairline instead of a tinted block.
//
// Character-only color (not a token): `mascotDisc` #FCE9D8 / #453022, the disc behind the avatar artwork.
// The stage glow (#FFF3E6 / #2A221C) and the flat OrbitMark palette live where they are drawn.
//
// Rules: no colored blocks and no shadows (depth = surface + hairline); Accent only for tappable text, the in-progress
// dot and the progress line; status colors are text or a 6 pt dot and always come with a word.

// MARK: - Spacing

/// 4-pt spacing scale (page margin 16-20, sections 24-32, inside components 12-16, related info 4-8).
enum Space {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24
    static let xxxl: CGFloat = 32
    /// Inner padding of a card (14); grouped-list rows use 12 x 14.
    static let card: CGFloat = 14
}

// MARK: - Corner radii

/// Corner radii; always used with `.continuous` corners. Sheets take the system radius.
/// v2: cards, buttons, the composer and every inner block share one radius (12); only the user's bubble is rounder.
enum Radius {
    /// Tiny tags and thumbnails (8).
    static let small: CGFloat = 8
    /// Buttons, thumbnails, small blocks (12).
    static let control: CGFloat = 12
    /// Inner blocks, notices, fields (12; was 16 before v2).
    static let note: CGFloat = 12
    /// Same as `note`; kept for existing call sites.
    static let inner: CGFloat = 12
    /// Cards and grouped lists (12).
    static let card: CGFloat = 12
    /// The user's message bubble (16).
    static let bubble: CGFloat = 16
    /// The corner a bubble used to flatten into a tail. v2 bubbles have no tail, so this equals `bubble`.
    static let tail: CGFloat = 16
    /// Composer / input area (12).
    static let input: CGFloat = 12
}

// MARK: - Motion

/// Springs. Critically damped by default (no overshoot); bounce only where a gesture carried momentum.
enum Motion {
    /// Layout / cards (0.38 s).
    static let standard = Animation.spring(duration: 0.38, bounce: 0)
    /// Small state changes: chips, toggles, icons (0.26 s).
    static let snappy = Animation.spring(duration: 0.26, bounce: 0)
    /// Press feedback; quick enough to feel attached to the finger (0.18 s).
    static let press = Animation.spring(duration: 0.18, bounce: 0)
    /// After a flick / drag release (the only place a bounce is allowed).
    static let momentum = Animation.spring(duration: 0.42, bounce: 0.18)
    /// The mascot flying into the avatar (matchedGeometryEffect, 0.4 s).
    static let fly = Animation.spring(duration: 0.4, bounce: 0)
    /// Reduce Motion replacement for every spring above.
    static let fade = Animation.easeOut(duration: 0.15)
}

/// Picks a spring or a 0.15 s cross-fade depending on Reduce Motion.
struct MotionAware {
    let reduce: Bool
    var spring: Animation { reduce ? Motion.fade : Motion.standard }
    var snappy: Animation { reduce ? Motion.fade : Motion.snappy }
    var press: Animation { reduce ? Motion.fade : Motion.press }
    var momentum: Animation { reduce ? Motion.fade : Motion.momentum }
    var fly: Animation { reduce ? Motion.fade : Motion.fly }
}

// MARK: - Elevation

extension View {
    /// Shadows are gone in v2: depth comes from the Surface color and the 0.5 pt Hairline, in light and dark alike.
    /// Kept as a no-op so older call sites compile; new code should not call it.
    func elevation(_ level: Int = 1) -> some View { self }
}

// MARK: - Helpers

extension Color {
    /// `#RRGGBB` (calendar colors, custom card tints). Not for design tokens: those are asset colors.
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
