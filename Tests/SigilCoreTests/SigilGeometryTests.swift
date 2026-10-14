import XCTest
@testable import SigilCore

final class SigilGeometryTests: XCTestCase {
    func testDeterministic() {
        XCTAssertEqual(SigilGeometry(seed: "AAAAC3Nza-key-one"), SigilGeometry(seed: "AAAAC3Nza-key-one"))
    }

    func testDifferentKeysGiveDifferentSigils() {
        let a = SigilGeometry(seed: "key-a"), b = SigilGeometry(seed: "key-b")
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a.radii, b.radii)
    }

    func testValuesStayInRange() {
        for i in 0..<500 {
            let g = SigilGeometry(seed: "seed-\(i)")
            XCTAssertEqual(g.radii.count, 7)
            XCTAssertTrue(g.radii.allSatisfy { (0.42...1.0).contains($0) })
            XCTAssertTrue((0..<360).contains(g.rotation))
            XCTAssertTrue((0..<7).contains(g.accentIndex))
            XCTAssertTrue(g.vertices.allSatisfy { hypot($0.x, $0.y) <= 1.0001 })
        }
    }

    func testServerSigilFollowsItsKey() {
        var s = Server(alias: "a", host: "h", port: 22, user: "u", keyFileName: "k", publicKeyBlob: "OLDKEYBLOB", keyFingerprint: "F")
        let before = s.sigil
        s.publicKeyBlob = "NEWKEYBLOB"
        XCTAssertNotEqual(before, s.sigil, "rotating the key must change the sigil")
    }
}
