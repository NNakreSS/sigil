import SigilCore
import SwiftUI

/// Interpolatable form of a sigil (7 radii + rotation) so SwiftUI can morph one key's seal into the next.
struct SigilVector: VectorArithmetic {
    var values: [Double]

    init(_ g: SigilGeometry) { values = g.radii + [g.rotation] }
    init(values: [Double]) { self.values = values }

    static var zero: SigilVector { SigilVector(values: Array(repeating: 0, count: SigilGeometry.vertexCount + 1)) }
    static func + (l: SigilVector, r: SigilVector) -> SigilVector { SigilVector(values: zip(l.padded, r.padded).map(+)) }
    static func - (l: SigilVector, r: SigilVector) -> SigilVector { SigilVector(values: zip(l.padded, r.padded).map(-)) }
    mutating func scale(by rhs: Double) { values = padded.map { $0 * rhs } }
    var magnitudeSquared: Double { padded.reduce(0) { $0 + $1 * $1 } }

    private var padded: [Double] {
        values.count == SigilGeometry.vertexCount + 1 ? values : Array(repeating: 0, count: SigilGeometry.vertexCount + 1)
    }

    /// Vertex positions in a rect, y down.
    func points(in rect: CGRect, inset: CGFloat) -> [CGPoint] {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let R = min(rect.width, rect.height) / 2 - inset
        let rot = padded[SigilGeometry.vertexCount]
        return (0..<SigilGeometry.vertexCount).map { i in
            let a = Double(i) / Double(SigilGeometry.vertexCount) * 2 * .pi + rot * .pi / 180 - .pi / 2
            let r = padded[i]
            return CGPoint(x: c.x + cos(a) * R * r, y: c.y + sin(a) * R * r)
        }
    }
}

/// The engraved outline. Animatable, and trimmable for the "inscribing" effect.
struct SigilOutline: Shape {
    var vector: SigilVector
    var inset: CGFloat

    var animatableData: SigilVector {
        get { vector }
        set { vector = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let pts = vector.points(in: rect, inset: inset)
        guard let first = pts.first else { return p }
        p.move(to: first)
        for pt in pts.dropFirst() { p.addLine(to: pt) }
        p.closeSubpath()
        return p
    }
}

/// Dots at the vertices (all but the accent one).
struct SigilDots: Shape {
    var vector: SigilVector
    var inset: CGFloat
    var radius: CGFloat
    var skip: Int?
    var only: Int?

    var animatableData: SigilVector {
        get { vector }
        set { vector = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        for (i, pt) in vector.points(in: rect, inset: inset).enumerated() {
            if let skip, i == skip { continue }
            if let only, i != only { continue }
            p.addEllipse(in: CGRect(x: pt.x - radius, y: pt.y - radius, width: radius * 2, height: radius * 2))
        }
        return p
    }
}

/// A server's seal: ink disc, engraved outline, vertex dots, one accent vertex.
///
/// - `geometry` change → the seal morphs (spring).
/// - `inscribe` < 1 → only part of the outline is drawn (adding a server draws it step by step).
/// - `busy` → slow turn, like a seal being pressed.
/// - `reachable == false` → the accent turns cinnabar.
struct SigilMark: View {
    var geometry: SigilGeometry
    var size: CGFloat
    var inscribe: Double = 1
    var busy = false
    var reachable: Bool? = true
    var showsDisc = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spin = 0.0

    var body: some View {
        let v = SigilVector(geometry)
        let inset = size * (showsDisc ? 0.16 : 0.08)
        let line = max(1.2, size / 30)
        let lineColor: Color = showsDisc ? .inkLine : .ink
        let accent: Color = reachable == false ? .cinnabar : .verdigris

        ZStack {
            if showsDisc {
                Circle().fill(Color.ink)
                Circle().strokeBorder(Color.inkLine.opacity(0.18), lineWidth: max(0.5, size / 90))
                    .padding(size * 0.05)
            }
            Group {
                SigilOutline(vector: v, inset: inset)
                    .trim(from: 0, to: inscribe)
                    .stroke(lineColor, style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round))
                SigilDots(vector: v, inset: inset, radius: max(1.2, size / 30), skip: geometry.accentIndex)
                    .fill(showsDisc ? Color.inkSoft : Color.ink.opacity(0.6))
                    .opacity(inscribe >= 1 ? 1 : 0)
                // The accent vertex carries the status colour, so it must stay readable even at sidebar sizes.
                SigilDots(vector: v, inset: inset, radius: max(2.6, size / 17), only: geometry.accentIndex)
                    .fill(accent)
                    .opacity(inscribe >= 1 ? 1 : 0)
            }
            .rotationEffect(.degrees(spin))
        }
        .frame(width: size, height: size)
        .animation(reduceMotion ? nil : Motion.morph, value: geometry)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: inscribe)
        .animation(Motion.gentle, value: reachable)
        .onChange(of: busy, initial: true) { _, isBusy in
            guard !reduceMotion else { return }
            if isBusy {
                withAnimation(.linear(duration: 6).repeatForever(autoreverses: false)) { spin = 360 }
            } else {
                withAnimation(Motion.stamp) { spin = 0 }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Seal "pressed" onto the page when it appears: drops in slightly large and tilted, settles with a spring.
struct StampIn: ViewModifier {
    @State private var landed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(landed || reduceMotion ? 1 : 1.28)
            .rotationEffect(.degrees(landed || reduceMotion ? 0 : -9))
            .opacity(landed || reduceMotion ? 1 : 0)
            .onAppear { withAnimation(Motion.stamp) { landed = true } }
    }
}

extension View {
    func stampIn() -> some View { modifier(StampIn()) }
}

/// Soft expanding ring, used while a connection check is running.
struct PulseRing: View {
    var color: Color
    @State private var expand = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .stroke(color.opacity(expand ? 0 : 0.5), lineWidth: 2)
            .scaleEffect(expand ? 1.35 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { expand = true }
            }
            .allowsHitTesting(false)
    }
}

/// The idle seal on empty screens: slowly re-forms through a few shapes, like breathing.
struct LivingSigil: View {
    var size: CGFloat
    @State private var seedIndex = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SigilMark(geometry: seedIndex == 0 ? .brand : SigilGeometry(seed: "breath-\(seedIndex)"), size: size)
            .task {
                guard !reduceMotion else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 3_200_000_000)
                    seedIndex = (seedIndex + 1) % 5
                }
            }
    }
}
