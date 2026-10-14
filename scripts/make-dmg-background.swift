// Renders Packaging/dmg-background.tiff (1x + 2x). Run: swift scripts/make-dmg-background.swift Packaging
// Layout contract with scripts/dmg-settings.py: window 660×420, app icon centred at (180, 215), Applications at (480, 215).
import AppKit
import CryptoKit
import SwiftUI

let parchment = Color(red: 0xF7 / 255, green: 0xF4 / 255, blue: 0xEC / 255)
let ink = Color(red: 0x26 / 255, green: 0x21 / 255, blue: 0x5C / 255)
let accent = Color(red: 0x53 / 255, green: 0x4A / 255, blue: 0xB7 / 255)
let verdigris = Color(red: 0x0F / 255, green: 0x6E / 255, blue: 0x56 / 255)

func brandVertices() -> [CGPoint] {
    let bytes = Array(SHA256.hash(data: Data("sigil/v1:Sigil·195".utf8)))
    let radii = (0..<7).map { 0.42 + Double(bytes[$0]) / 255 * 0.58 }
    let rotation = Double(UInt16(bytes[7]) << 8 | UInt16(bytes[8])) / 65536 * 360
    return radii.enumerated().map { i, r in
        let a = Double(i) / 7 * 2 * .pi + rotation * .pi / 180 - .pi / 2
        return CGPoint(x: cos(a) * r, y: sin(a) * r)
    }
}

struct Sigil: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY), R = rect.width / 2
        for (i, v) in brandVertices().enumerated() {
            let pt = CGPoint(x: c.x + v.x * R, y: c.y + v.y * R)
            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        p.closeSubpath()
        return p
    }
}

/// Hand-drawn feeling arc from the app icon to Applications.
struct Arrow: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let start = CGPoint(x: 262, y: 200), end = CGPoint(x: 398, y: 200)
        p.move(to: start)
        p.addQuadCurve(to: end, control: CGPoint(x: 330, y: 150))
        // head
        p.move(to: CGPoint(x: end.x - 16, y: end.y - 14))
        p.addLine(to: end)
        p.addLine(to: CGPoint(x: end.x - 19, y: end.y + 5))
        return p
    }
}

struct Background: View {
    var body: some View {
        ZStack {
            parchment
            // Faint seal watermark behind everything.
            ZStack {
                Circle().fill(ink.opacity(0.035))
                Sigil().stroke(ink.opacity(0.07), style: StrokeStyle(lineWidth: 6, lineJoin: .round)).padding(60)
            }
            .frame(width: 360, height: 360)
            .offset(x: 230, y: -150)

            VStack(spacing: 4) {
                Text("Sigil").font(.system(size: 30, weight: .bold, design: .serif)).foregroundStyle(ink)
                Text("Her sunucuya kendi mührü").font(.system(size: 13, design: .serif)).italic().foregroundStyle(ink.opacity(0.6))
            }
            .position(x: 330, y: 62)

            Arrow()
                .stroke(accent, style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round, dash: [1, 9]))
            Arrow()
                .trim(from: 0.86, to: 1)
                .stroke(accent, style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))

            VStack(spacing: 6) {
                Text("Kurmak için Sigil’i Applications klasörüne sürükle")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(ink.opacity(0.8))
                HStack(spacing: 6) {
                    Circle().fill(verdigris).frame(width: 6, height: 6)
                    Text("Sonra Applications’tan aç; gerisini Sigil anlatır.")
                        .font(.system(size: 11)).foregroundStyle(ink.opacity(0.5))
                }
            }
            .position(x: 330, y: 345)
        }
        .frame(width: 660, height: 420)
    }
}

@MainActor
func render(scale: CGFloat) -> NSBitmapImageRep {
    let r = ImageRenderer(content: Background())
    r.scale = scale
    let rep = NSBitmapImageRep(cgImage: r.cgImage!)
    rep.size = NSSize(width: 660, height: 420)   // points, so Finder treats the 2x rep as Retina
    return rep
}

@MainActor
func main() throws {
    let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Packaging")
    let one = dir.appendingPathComponent("dmg-bg.png"), two = dir.appendingPathComponent("dmg-bg@2x.png")
    try render(scale: 1).representation(using: .png, properties: [:])!.write(to: one)
    try render(scale: 2).representation(using: .png, properties: [:])!.write(to: two)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
    p.arguments = ["-cathidpicheck", one.path, two.path, "-out", dir.appendingPathComponent("dmg-background.tiff").path]
    try p.run(); p.waitUntilExit()
    try FileManager.default.removeItem(at: one)
    try FileManager.default.removeItem(at: two)
    print(p.terminationStatus == 0 ? "dmg-background.tiff yazıldı" : "tiffutil başarısız")
}

MainActor.assumeIsolated { try! main() }
