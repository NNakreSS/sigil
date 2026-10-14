// Renders Packaging/AppIcon.icns from the brand sigil. Run: swift scripts/make-icon.swift Packaging
import AppKit
import CryptoKit
import SwiftUI

// Same derivation as SigilCore.SigilGeometry.brand (seed "Sigil·195"); keep in sync.
func brandVertices() -> (points: [CGPoint], accent: Int) {
    let bytes = Array(SHA256.hash(data: Data("sigil/v1:Sigil·195".utf8)))
    let radii = (0..<7).map { 0.42 + Double(bytes[$0]) / 255 * 0.58 }
    let rotation = Double(UInt16(bytes[7]) << 8 | UInt16(bytes[8])) / 65536 * 360
    let accent = Int(bytes[9]) % 7
    let pts = radii.enumerated().map { i, r -> CGPoint in
        let a = Double(i) / 7 * 2 * .pi + rotation * .pi / 180 - .pi / 2
        return CGPoint(x: cos(a) * r, y: sin(a) * r)
    }
    return (pts, accent)
}

/// Wax-seal disc: a circle with a softly scalloped rim.
struct WaxSeal: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY), R = rect.width / 2
        let n = 720
        for i in 0...n {
            let a = Double(i) / Double(n) * 2 * .pi
            let r = R * (0.962 + 0.016 * sin(a * 13) + 0.014 * sin(a * 5 + 1.3) + 0.008 * sin(a * 29 + 0.4))
            let pt = CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        p.closeSubpath()
        return p
    }
}

struct Engraving: Shape {
    let pts: [CGPoint]
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY), R = rect.width / 2
        for (i, v) in pts.enumerated() {
            let pt = CGPoint(x: c.x + v.x * R, y: c.y + v.y * R)
            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        p.closeSubpath()
        return p
    }
}

struct IconArt: View {
    let ink = Color(red: 0x26 / 255, green: 0x21 / 255, blue: 0x5C / 255)
    let inkDeep = Color(red: 0x1A / 255, green: 0x16 / 255, blue: 0x42 / 255)
    let parchment = Color(red: 0xF7 / 255, green: 0xF4 / 255, blue: 0xEC / 255)
    let line = Color(red: 0xEE / 255, green: 0xED / 255, blue: 0xFE / 255)
    let soft = Color(red: 0xAF / 255, green: 0xA9 / 255, blue: 0xEC / 255)
    let verdigris = Color(red: 0x5D / 255, green: 0xCA / 255, blue: 0xA5 / 255)

    var body: some View {
        let (pts, accent) = brandVertices()
        ZStack {
            // macOS icon grid: 824pt artwork on a 1024pt canvas.
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(parchment)
                .overlay(RoundedRectangle(cornerRadius: 185, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.06), lineWidth: 3))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.25), radius: 22, y: 11)

            ZStack {
                WaxSeal().fill(inkDeep).offset(y: 10)            // seal thickness
                WaxSeal().fill(ink)
                Circle().stroke(line.opacity(0.20), lineWidth: 6).padding(58)
                Engraving(pts: pts)
                    .stroke(line, style: StrokeStyle(lineWidth: 24, lineCap: .round, lineJoin: .round))
                    .padding(118)
                ForEach(0..<7, id: \.self) { i in
                    let isAccent = i == accent
                    Circle()
                        .fill(isAccent ? verdigris : soft)
                        .frame(width: isAccent ? 70 : 40, height: isAccent ? 70 : 40)
                        .offset(x: pts[i].x * (620 / 2 - 118), y: pts[i].y * (620 / 2 - 118))
                }
            }
            .frame(width: 620, height: 620)
        }
        .frame(width: 1024, height: 1024)
    }
}

@MainActor
func png(size: Int) -> Data {
    let renderer = ImageRenderer(content: IconArt().scaleEffect(CGFloat(size) / 1024).frame(width: CGFloat(size), height: CGFloat(size)))
    renderer.scale = 1
    return NSBitmapImageRep(cgImage: renderer.cgImage!).representation(using: .png, properties: [:])!
}

@MainActor
func main() throws {
    let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Packaging")
    let iconset = root.appendingPathComponent("AppIcon.iconset")
    try? FileManager.default.removeItem(at: iconset)
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
        try png(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
        try png(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
    }
    try png(size: 1024).write(to: root.appendingPathComponent("AppIcon-1024.png"))
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    p.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("AppIcon.icns").path]
    try p.run()
    p.waitUntilExit()
    try FileManager.default.removeItem(at: iconset)
    print(p.terminationStatus == 0 ? "AppIcon.icns yazıldı" : "iconutil başarısız")
}

MainActor.assumeIsolated { try! main() }
