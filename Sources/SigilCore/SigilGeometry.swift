import CryptoKit
import Foundation

/// The shape of a sigil: a seven-pointed seal whose vertex distances, rotation and accent vertex are derived
/// from a SHA-256 of its seed. Every server's sigil is seeded with its current public key, so the sigil is a
/// stable, recognisable picture of "the key this server trusts" and visibly changes when the key is rotated.
public struct SigilGeometry: Equatable, Hashable, Sendable {
    public static let vertexCount = 7

    /// Distance of each vertex from the centre, as a fraction of the radius (0.42 ... 1.0).
    public let radii: [Double]
    /// Rotation of the whole figure, in degrees (0 ..< 360).
    public let rotation: Double
    /// The vertex drawn in the accent colour.
    public let accentIndex: Int

    public init(radii: [Double], rotation: Double, accentIndex: Int) {
        precondition(radii.count == Self.vertexCount)
        self.radii = radii
        self.rotation = rotation
        self.accentIndex = accentIndex
    }

    public init(seed: String) {
        let bytes = Array(SHA256.hash(data: Data(("sigil/v1:" + seed).utf8)))
        radii = (0..<Self.vertexCount).map { 0.42 + Double(bytes[$0]) / 255 * 0.58 }
        rotation = Double(UInt16(bytes[7]) << 8 | UInt16(bytes[8])) / 65536 * 360
        accentIndex = Int(bytes[9]) % Self.vertexCount
    }

    /// The app's own mark.
    public static let brand = SigilGeometry(seed: "Sigil·195")

    /// Unit-circle vertex positions (centre 0,0; radius 1), y pointing down.
    public var vertices: [(x: Double, y: Double)] {
        // Spelled out step by step with explicit types: older Swift compilers time out type-checking the one-liner.
        let step: Double = 2 * Double.pi / Double(Self.vertexCount)
        let offset: Double = rotation * Double.pi / 180 - Double.pi / 2
        var out: [(x: Double, y: Double)] = []
        for (i, r) in radii.enumerated() {
            let angle: Double = Double(i) * step + offset
            out.append((x: cos(angle) * r, y: sin(angle) * r))
        }
        return out
    }
}

extension Server {
    /// Seeded with the server's current public key: changes exactly when the key is rotated.
    public var sigil: SigilGeometry { SigilGeometry(seed: publicKeyBlob) }
}
