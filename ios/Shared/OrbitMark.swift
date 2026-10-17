import SwiftUI

// Orbit mark: the character's silhouette with a tilted apricot ring and one satellite, drawn as vectors for
// 16-64 pt use (status lines, Live Activity, Dynamic Island, thinking indicator). Geometry follows
// `orbitMark()` in docs/design/mockups/src/icons.js on its 64 x 64 grid.
//
// This file is compiled into BOTH the app and the widget extension: it must not use asset-catalog colors or
// any app-only type. All colors are hard-coded.

// MARK: - Shape pieces

/// The drawable pieces of the mark, each a `Shape` fitted (square, centered) into the rect it is given.
/// Pieces are meant to be layered back to front: `ringBack`, a satellite behind the body, `body`, `ringFront`,
/// a satellite in front. `OrbitMark` does this for you.
struct OrbitMarkShape: Shape {
    enum Piece: Sendable {
        /// The drop-shaped body (fill / outline it).
        case body
        /// Upper half of the tilted ring: passes behind the body (stroke it).
        case ringBack
        /// Lower half of the tilted ring: passes in front of the body (stroke it).
        case ringFront
        /// The satellite disc at an angle on its orbit (radians, 0 = right end, increasing clockwise).
        case satellite(angle: Double)
    }

    var piece: Piece

    init(_ piece: Piece) {
        self.piece = piece
    }

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let scale = side / Geometry.grid
        var path: Path
        switch piece {
        case .body: path = Geometry.bodyPath()
        case .ringBack: path = Geometry.ringHalf(upper: true)
        case .ringFront: path = Geometry.ringHalf(upper: false)
        case .satellite(let angle):
            let c = Geometry.satelliteCenter(angle: angle)
            path = Path(ellipseIn: CGRect(x: c.x - Geometry.satelliteRadius, y: c.y - Geometry.satelliteRadius,
                                          width: Geometry.satelliteRadius * 2, height: Geometry.satelliteRadius * 2))
        }
        let transform = CGAffineTransform(translationX: rect.midX - side / 2, y: rect.midY - side / 2)
            .scaledBy(x: scale, y: scale)
        return path.applying(transform)
    }

    /// True when the satellite at `angle` is on the near (lower) half of the ring, in front of the body.
    static func isFront(angle: Double) -> Bool { sin(angle) >= 0 }

    /// Angle of the satellite when it is not orbiting (lower right, as in the reference artwork).
    static let restAngle = Geometry.restAngle

    /// Grid constants and paths, all in 64 x 64 design units.
    enum Geometry {
        static let grid: CGFloat = 64
        static let ringCenter = CGPoint(x: 32, y: 40)
        static let ringRadii = CGSize(width: 25, height: 8.2)
        static let ringTilt = Angle.degrees(-14)
        static let satelliteRadius: CGFloat = 4.6
        /// Satellite orbit: the ring ellipse grown just enough to pass through the reference position (50.2, 46.2).
        static let orbitRadii = CGSize(width: 26.2, height: 8.6)
        static let restAngle: Double = atan2(6.2 / 8.6, 18.2 / 26.2)

        private static var tilt: CGAffineTransform {
            CGAffineTransform(translationX: ringCenter.x, y: ringCenter.y)
                .rotated(by: CGFloat(ringTilt.radians))
                .translatedBy(x: -ringCenter.x, y: -ringCenter.y)
        }

        /// Center of the satellite on its orbit at `angle`, with the ring tilt applied.
        static func satelliteCenter(angle: Double) -> CGPoint {
            CGPoint(x: ringCenter.x + orbitRadii.width * CGFloat(cos(angle)),
                    y: ringCenter.y + orbitRadii.height * CGFloat(sin(angle)))
                .applying(tilt)
        }

        /// Half of the ring ellipse from its left end to its right end (round caps come from the stroke style).
        static func ringHalf(upper: Bool) -> Path {
            let cx = ringCenter.x, cy = ringCenter.y
            let rx = ringRadii.width, ry = ringRadii.height
            let k: CGFloat = 0.5522847498
            let dir: CGFloat = upper ? -1 : 1
            var p = Path()
            p.move(to: CGPoint(x: cx - rx, y: cy))
            p.addCurve(to: CGPoint(x: cx, y: cy + dir * ry),
                       control1: CGPoint(x: cx - rx, y: cy + dir * ry * k),
                       control2: CGPoint(x: cx - rx * k, y: cy + dir * ry))
            p.addCurve(to: CGPoint(x: cx + rx, y: cy),
                       control1: CGPoint(x: cx + rx * k, y: cy + dir * ry),
                       control2: CGPoint(x: cx + rx, y: cy + dir * ry * k))
            return p.applying(tilt)
        }

        /// The body silhouette.
        static func bodyPath() -> Path {
            var p = Path()
            p.move(to: CGPoint(x: 32, y: 56))
            p.addCurve(to: CGPoint(x: 15.4, y: 37.4), control1: CGPoint(x: 20.5, y: 56), control2: CGPoint(x: 14.5, y: 47.5))
            p.addCurve(to: CGPoint(x: 24.6, y: 16.6), control1: CGPoint(x: 16.2, y: 28.4), control2: CGPoint(x: 21, y: 21.6))
            p.addCurve(to: CGPoint(x: 27.8, y: 7.4), control1: CGPoint(x: 26.2, y: 14.3), control2: CGPoint(x: 26.8, y: 10.6))
            p.addCurve(to: CGPoint(x: 31.6, y: 7.1), control1: CGPoint(x: 28.5, y: 5.3), control2: CGPoint(x: 30.7, y: 5.2))
            p.addCurve(to: CGPoint(x: 39.6, y: 17.4), control1: CGPoint(x: 33.2, y: 10.6), control2: CGPoint(x: 35.6, y: 14.4))
            p.addCurve(to: CGPoint(x: 49.2, y: 37.4), control1: CGPoint(x: 45.6, y: 21.9), control2: CGPoint(x: 49.2, y: 28.6))
            p.addCurve(to: CGPoint(x: 32, y: 56), control1: CGPoint(x: 49.2, y: 48), control2: CGPoint(x: 43.4, y: 56))
            p.closeSubpath()
            return p
        }
    }
}

// MARK: - Mark

/// The Orbit mark at `size` x `size`.
/// - `outlined`: adds the #C9AE95 body outline (1.5 pt at 64 pt and up, scaled down to a 0.75 pt floor for small
///   sizes); use it on light backgrounds where the cream body would otherwise vanish (leave it off on dark / black
///   surfaces such as the Dynamic Island).
/// - `orbiting`: the satellite travels along the ring (about 4 s per turn, passing behind the body); static
///   under Reduce Motion. Use it as the "thinking" progress indicator.
struct OrbitMark: View {
    var size: CGFloat
    var outlined: Bool
    var orbiting: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(size: CGFloat, outlined: Bool = false, orbiting: Bool = false) {
        self.size = size
        self.outlined = outlined
        self.orbiting = orbiting
    }

    /// Seconds for one revolution of the satellite.
    private static let period: Double = 4

    private enum Palette {
        static let body = Color(orbitRGB: 0xF7ECDF)
        static let outline = Color(orbitRGB: 0xC9AE95)
        static let ring = Color(orbitRGB: 0xF2A15F)
        static let satellite = Color(orbitRGB: 0xEE8A3C)
    }

    var body: some View {
        let running = orbiting && !reduceMotion
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !running)) { context in
            mark(angle: running ? angle(at: context.date) : OrbitMarkShape.restAngle)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func angle(at date: Date) -> Double {
        let turns = date.timeIntervalSinceReferenceDate / Self.period
        return OrbitMarkShape.restAngle + (turns - turns.rounded(.down)) * 2 * .pi
    }

    private func mark(angle: Double) -> some View {
        let unit = size / OrbitMarkShape.Geometry.grid
        let front = OrbitMarkShape.isFront(angle: angle)
        let satellite = OrbitMarkShape(.satellite(angle: angle)).fill(Palette.satellite)
        return ZStack {
            OrbitMarkShape(.ringBack)
                .stroke(Palette.ring.opacity(0.85), style: StrokeStyle(lineWidth: 3.4 * unit, lineCap: .round))
            if !front { satellite }
            OrbitMarkShape(.body)
                .fill(Palette.body)
            if outlined {
                OrbitMarkShape(.body)
                    .stroke(Palette.outline, style: StrokeStyle(lineWidth: min(1.5, max(0.75, 1.6 * unit)), lineJoin: .round))
            }
            OrbitMarkShape(.ringFront)
                .stroke(Palette.ring, style: StrokeStyle(lineWidth: 3.6 * unit, lineCap: .round))
            if front { satellite }
        }
    }
}

private extension Color {
    /// 0xRRGGBB, sRGB.
    init(orbitRGB value: UInt32) {
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}
