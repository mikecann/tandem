import XCTest
@testable import TandemMedia

/// The clean plate on small made-up frames: a light grey wall, a dark
/// "person" square that moves about, and the matte RVM would give it.
final class CleanPlateTests: XCTestCase {
    let width = 64, height = 36

    func frame(wall: UInt8 = 200, person: CGRect?, personColour: UInt8 = 40, noise: (Int) -> Int = { _ in 0 }) -> [UInt8] {
        var out = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let inside = person?.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) ?? false
                let v = inside ? Int(personColour) : Int(wall) + noise(y * width + x)
                for c in 0..<3 { out[(y * width + x) * 4 + c] = UInt8(max(0, min(255, v))) }
            }
        }
        return out
    }

    func matte(_ person: CGRect, soft: CGRect? = nil, softValue: UInt8 = 200) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let p = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
                if person.contains(p) { out[y * width + x] = 255 } else if soft?.contains(p) ?? false { out[y * width + x] = softValue }
            }
        }
        return out
    }

    /// The person somewhere along the frame, a different place each sample.
    func person(_ index: Int) -> CGRect {
        CGRect(x: Double(index % 8) * 6, y: 8, width: 14, height: 28)
    }

    func testAStaticRoomGivesAPlateOfTheWall() throws {
        let samples = (0..<20).map { frame(person: person($0)) }
        let mattes = (0..<20).map { matte(person($0)) }
        let made = try CleanPlate.make(samples: samples, mattes: mattes, width: width, height: height).get()
        // Most of the frame was wall in three samples or more, and it's grey.
        XCTAssertGreaterThan(made.seen.filter { $0 == 255 }.count, width * height / 2)
        for i in 0..<(width * height) where made.seen[i] == 255 {
            XCTAssertEqual(made.plate[i * 4], 200, "plate pixel \(i)")
        }
    }

    func testABackgroundThatKeepsChangingGivesNone() throws {
        // A camera moving: the "wall" is different noise in every sample.
        let samples = (0..<20).map { s in frame(person: person(s), noise: { ($0 * 7919 + s * 104729) % 61 - 30 }) }
        let mattes = (0..<20).map { matte(person($0)) }
        guard case .failure(.notSteady) = try CleanPlate.make(samples: samples, mattes: mattes, width: width, height: height) else {
            return XCTFail("a changing background made a plate")
        }
    }

    func testLightDriftingOverTheTakeIsStillSteady() throws {
        // Daylight through a window: each sample a little lighter or darker.
        let samples = (0..<20).map { s in frame(wall: UInt8(185 + s), person: person(s)) }
        let mattes = (0..<20).map { matte(person($0)) }
        XCTAssertNoThrow(try CleanPlate.make(samples: samples, mattes: mattes, width: width, height: height).get())
    }

    /// A patch of the room that changes partway (a lamp switched on, a door
    /// opened) isn't trusted, though the rest of the plate is (review: its
    /// median matched neither look, and a prop could match it).
    func testAPatchThatChangesIsNotTrusted() throws {
        let patch = CGRect(x: 56, y: 0, width: 8, height: 36)
        let samples: [[UInt8]] = (0..<20).map { s in
            var f = frame(person: person(s))
            for y in 0..<height {
                for x in 56..<64 where patch.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) {
                    for c in 0..<3 { f[(y * width + x) * 4 + c] = s < 10 ? 80 : 240 }
                }
            }
            return f
        }
        let mattes = (0..<20).map { matte(person($0)) }
        let made = try CleanPlate.make(samples: samples, mattes: mattes, width: width, height: height).get()
        XCTAssertEqual(made.seen[18 * width + 60], 0, "the changing patch counts as seen")
        XCTAssertEqual(made.seen[18 * width + 50], 255, "the steady wall beside it should count")
    }

    /// Wall he only uncovers while the light is lower still counts: the
    /// medians are of exposure-matched sightings (review: against a median
    /// of the raw ones, its matched sightings looked unsteady).
    func testWallSeenOnlyInOneLightIsKept() throws {
        // Darker for the first half, lighter after; the patch at x 50...58
        // is behind him while it's lighter.
        let samples: [[UInt8]] = (0..<20).map { s in
            frame(wall: s < 10 ? 180 : 220, person: s < 10 ? CGRect(x: Double(s % 4) * 6, y: 8, width: 14, height: 28) : CGRect(x: 44, y: 0, width: 16, height: 36))
        }
        let mattes: [[UInt8]] = (0..<20).map { s in
            matte(s < 10 ? CGRect(x: Double(s % 4) * 6, y: 8, width: 14, height: 28) : CGRect(x: 44, y: 0, width: 16, height: 36))
        }
        let made = try CleanPlate.make(samples: samples, mattes: mattes, width: width, height: height).get()
        XCTAssertEqual(made.seen[18 * width + 53], 255, "wall seen only in the darker half was dropped")
    }

    /// He fills most of the frame and never moves: too little of the room
    /// is ever seen to be worth a plate.
    func testTooLittleOfTheRoomSeenGivesNone() throws {
        let still = CGRect(x: 0, y: 0, width: 50, height: 36)
        let samples = (0..<20).map { _ in frame(person: still) }
        let mattes = (0..<20).map { _ in matte(still) }
        guard case .failure(.tooLittleSeen) = try CleanPlate.make(samples: samples, mattes: mattes, width: width, height: height) else {
            return XCTFail("a room hardly ever seen made a plate")
        }
    }

    func testMakingThePlateStopsWhenAsked() {
        let samples = (0..<20).map { frame(person: person($0)) }
        let mattes = (0..<20).map { matte(person($0)) }
        XCTAssertThrowsError(try CleanPlate.make(samples: samples, mattes: mattes, width: width, height: height, shouldStop: { true })) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testTooFewSamplesGiveNone() throws {
        guard case .failure(.tooFewSamples) = try CleanPlate.make(samples: [frame(person: nil)], mattes: [matte(.zero)], width: width, height: height) else {
            return XCTFail("one frame made a plate")
        }
    }

    /// RVM's matte bulging out over the light wall (round the white logo on
    /// Mike's cap) loses that bulge; the person stays whole.
    func testTheMatteLosesWallItTookOverALightWall() {
        let plate = CleanPlate(plate: frame(person: nil), seen: [UInt8](repeating: 255, count: width * height), width: width, height: height)
        let body = CGRect(x: 0, y: 0, width: 30, height: 36)
        let picture = frame(person: body)
        // Soft matte over 30...40, which is wall.
        var alpha = matte(body, soft: CGRect(x: 30, y: 0, width: 10, height: 36))
        plate.refine(&alpha, frame: picture)
        XCTAssertLessThan(alpha[18 * width + 36], 20, "the bulge over the wall stayed")
        XCTAssertEqual(alpha[18 * width + 10], 255, "the person lost alpha")
    }

    /// Over a dark background the plate isn't trusted: the navy jacket
    /// matches the dark sofa as closely as the wall does.
    func testADarkBackgroundIsLeftAlone() {
        let plate = CleanPlate(plate: frame(wall: 45, person: nil), seen: [UInt8](repeating: 255, count: width * height), width: width, height: height)
        let body = CGRect(x: 0, y: 0, width: 30, height: 36)
        let picture = frame(wall: 45, person: body)
        var alpha = matte(body, soft: CGRect(x: 30, y: 0, width: 10, height: 36))
        let before = alpha
        plate.refine(&alpha, frame: picture)
        XCTAssertEqual(alpha, before)
    }

    /// Where the plate never saw the wall, nothing changes.
    func testWallThePlateNeverSawIsLeftAlone() {
        let plate = CleanPlate(plate: frame(person: nil), seen: [UInt8](repeating: 0, count: width * height), width: width, height: height)
        let body = CGRect(x: 0, y: 0, width: 30, height: 36)
        var alpha = matte(body, soft: CGRect(x: 30, y: 0, width: 10, height: 36))
        let before = alpha
        plate.refine(&alpha, frame: frame(person: body))
        XCTAssertEqual(alpha, before)
    }

    /// The frame's exposure differing from the plate's (the light changed
    /// since) doesn't stop it working.
    func testItAllowsForTheFramesExposure() {
        let plate = CleanPlate(plate: frame(wall: 180, person: nil), seen: [UInt8](repeating: 255, count: width * height), width: width, height: height)
        let body = CGRect(x: 0, y: 0, width: 30, height: 36)
        var alpha = matte(body, soft: CGRect(x: 30, y: 0, width: 10, height: 36))
        plate.refine(&alpha, frame: frame(wall: 215, person: body))
        XCTAssertLessThan(alpha[18 * width + 36], 20, "an exposure change kept the bulge")
    }
}
