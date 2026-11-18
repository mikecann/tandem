import XCTest
@testable import TandemMedia

/// `CutListen.compare`: what's heard across a join against what the take
/// keeps there.
final class CutListenTests: XCTestCase {
    /// Words a quarter of a second apart, from `start`, ending on the join
    /// at 10 or starting there as their place in `text` says ("|").
    private func words(_ text: String, join: Double = 10, gap: Double = 0.25) -> [CutListen.Word] {
        let parts = text.split(separator: " ").map(String.init)
        let at = parts.firstIndex(of: "|") ?? parts.count
        var out: [CutListen.Word] = []
        for (index, part) in parts.enumerated() where part != "|" {
            let start = index < at ? join - Double(at - index) * gap : join + Double(index - at - 1) * gap + 0.02
            out.append(CutListen.Word(text: part, start: start, end: start + gap * 0.8))
        }
        return out
    }

    func testAJoinHeardAsTheTakeSaysItHasNoFindings() {
        let join = CutListen.compare(said: words("a little bit | that happened because"), heard: words("A little bit, | that happened, because"), at: 10)
        XCTAssertEqual(join.findings, [])
        XCTAssertFalse(join.clipped)
        XCTAssertEqual(join.said, "a little bit | that happened because")
        XCTAssertEqual(join.heard, "A little bit, | that happened, because")
    }

    func testWordsMatchLoosely() {
        // Numbers, spoken forms, letters spelled out, case and punctuation.
        let join = CutListen.compare(said: words("I want to see | 15 of TS."), heard: words("i wanna see | fifteen of t. s."), at: 10)
        XCTAssertEqual(join.findings, [], "\(join.findings)")
    }

    func testAWordWithANumberInItHeardAsWordsIsWhole() {
        // The Examples Page video (18 Nov 2026): the take's transcript wrote
        // "little3D", Bark heard "little three D", with the join's bar
        // between "three" and "D", and the check called it cut off.
        let join = CutListen.compare(said: words("build this whole little3D | world with robots"),
                                     heard: words("build this whole little three | D world with robots"), at: 10)
        XCTAssertEqual(join.findings, [], "\(join.findings)")
        XCTAssertEqual(CutListen.canonical("3D"), "threed")
        // With the D cut off it's still cut off, not near by an ending.
        let cut = CutListen.compare(said: words("build this whole little3D | world with robots"),
                                    heard: words("build this whole little three | world with robots"), at: 10)
        XCTAssertTrue(cut.clipped, "\(cut.findings)")
        let one = CutListen.compare(said: words("build this whole little3D | world with robots"),
                                    heard: words("build this whole little3 | world with robots"), at: 10)
        XCTAssertTrue(one.clipped, "\(one.findings)")
        XCTAssertEqual(CutListen.canonical("mp4"), "mpfour")
        XCTAssertEqual(CutListen.canonical("2026"), "twothousandtwentysix")
    }

    func testAKeptWordHeardCutShortIsClipped() throws {
        let join = CutListen.compare(said: words("we can extract | the data"), heard: words("we can extra | the data"), at: 10)
        let finding = try XCTUnwrap(join.findings.first)
        XCTAssertEqual(finding.kind, .heardAs)
        XCTAssertEqual(finding.said, "extract")
        XCTAssertEqual(finding.heard, "extra")
        XCTAssertFalse(finding.slip)
        XCTAssertTrue(join.clipped)
    }

    func testAKeptWordNotHeardIsClippedUnlessItsAShortWord() throws {
        let gone = CutListen.compare(said: words("we can extract | the data"), heard: words("we can | the data"), at: 10)
        XCTAssertEqual(gone.findings.map(\.kind), [.notHeard])
        XCTAssertTrue(gone.clipped)
        // "the" is as likely the engine's slip: a note.
        let the = CutListen.compare(said: words("we can extract | the data"), heard: words("we can extract | data"), at: 10)
        XCTAssertEqual(the.findings.map(\.kind), [.notHeard])
        XCTAssertTrue(try XCTUnwrap(the.findings.first).slip)
        XCTAssertFalse(the.clipped)
    }

    func testAFragmentOfACutWordIsClipped() throws {
        // "a little bit [okay] that": the cut starts inside "okay", and the
        // start of it is heard as "oh".
        let join = CutListen.compare(
            said: words("a little bit | that that happened"), heard: words("a little bit oh | that that happened"), at: 10,
            cutPast: ["okay", "that"], cutBefore: ["know."]
        )
        let finding = try XCTUnwrap(join.findings.first)
        XCTAssertEqual(finding.kind, .extra)
        XCTAssertEqual(finding.heard, "oh")
        XCTAssertFalse(finding.slip, "it sounds like the cut \"okay\"")
        XCTAssertTrue(finding.why.contains("okay"), finding.why)
        // An "oh" that sounds like nothing cut is the engine's: a note.
        let other = CutListen.compare(said: words("a little bit | that that happened"), heard: words("a little bit oh | that that happened"), at: 10)
        XCTAssertTrue(try XCTUnwrap(other.findings.first).slip)
    }

    func testAnInflectionIsASlip() throws {
        let join = CutListen.compare(said: words("that | happened because"), heard: words("that | happen because"), at: 10)
        let finding = try XCTUnwrap(join.findings.first)
        XCTAssertEqual(finding.kind, .heardAs)
        XCTAssertTrue(finding.slip)
    }

    func testAJoinOnlyCutsTheEndOfTheWordBeforeIt() throws {
        // The Tandem video at 02:59.213: Bark heard "Filmora" as "for mora".
        // A cut at the join can take the end of "Filmora", never its start.
        let split = CutListen.compare(said: words("project called Automate Filmora | that was attempt"), heard: words("project called automate for mora | that was attempt"), at: 10)
        XCTAssertFalse(split.clipped, "\(split.findings)")
        // Its start not heard: the engine's.
        let start = CutListen.compare(said: words("called Automate Filmora | that was"), heard: words("called Automate mora | that was"), at: 10)
        XCTAssertFalse(start.clipped, "\(start.findings)")
        XCTAssertEqual(start.findings.map(\.kind), [.heardAs])
        // Its end not heard: cut short.
        let end = CutListen.compare(said: words("called Automate Filmora | that was"), heard: words("called Automate Film | that was"), at: 10)
        XCTAssertTrue(end.clipped, "\(end.findings)")
        XCTAssertEqual(try XCTUnwrap(end.findings.first).said, "Filmora")
    }

    func testAJoinOnlyCutsTheStartOfTheWordAfterIt() throws {
        let start = CutListen.compare(said: words("we can | extract the data"), heard: words("we can | tract the data"), at: 10)
        XCTAssertTrue(start.clipped, "\(start.findings)")
        let end = CutListen.compare(said: words("we can | extract the data"), heard: words("we can | extra the data"), at: 10)
        XCTAssertFalse(end.clipped, "its end isn't at the join: \(end.findings)")
    }

    func testAWordPastTheOneAfterTheJoinIsANote() {
        // The Tandem video at 03:30.113: "filmore" is the second word after
        // the join, which the cut can't reach.
        let join = CutListen.compare(said: words("hacky way | any filmore update would"), heard: words("hacky way. | Any filmwater update would"), at: 10)
        XCTAssertEqual(join.findings.map(\.kind), [.heardAs])
        XCTAssertFalse(join.clipped, "\(join.findings)")
    }

    func testAWordHeardAsSomethingElseAtTheJoinIsANote() {
        // A name heard as another word, nothing short: the engine's.
        let join = CutListen.compare(said: words("a project called | Filmora that"), heard: words("a project called | Fulmar that"), at: 10)
        XCTAssertFalse(join.clipped, "\(join.findings)")
        // A plain word heard as another is: "new" heard as "nude." on the
        // Ian video was a cut-off an agent fixed.
        let plain = CutListen.compare(said: words("throw that into like new | um it's not"), heard: words("throw that into like nude. | um it's not"), at: 10)
        XCTAssertTrue(plain.clipped, "\(plain.findings)")
    }

    func testAWordHeardBetweenTheJoinsWordsThatTheTakeDoesntKeepIsClipped() throws {
        // Something heard right at the join that no kept word accounts for
        // is what's left of a cut one; the same word further off is a note.
        let at = CutListen.compare(said: words("lies about | it's actually true"), heard: words("lies about | cause it's actually true"), at: 10)
        XCTAssertTrue(at.clipped, "\(at.findings)")
        let off = CutListen.compare(said: words("lies about | it's actually true"), heard: words("lies about | it's cause actually true"), at: 10)
        XCTAssertFalse(off.clipped, "\(off.findings)")
    }

    func testAWordBetweenTwoCloseJoinsIsBlamedOnOne() {
        // Joins at 10 and 10.4 with "data" (10.05 to 10.35) between them:
        // not heard, it's a finding at the nearer join, not both.
        let said = [CutListen.Word(text: "the", start: 9.6, end: 9.95), CutListen.Word(text: "data", start: 10.05, end: 10.3),
                    CutListen.Word(text: "store", start: 10.45, end: 10.8)]
        let heard = [CutListen.Word(text: "the", start: 9.6, end: 9.95), CutListen.Word(text: "store", start: 10.45, end: 10.8)]
        let first = CutListen.compare(said: said, heard: heard, at: 10, otherJoins: [10.4])
        let second = CutListen.compare(said: said, heard: heard, at: 10.4, otherJoins: [10])
        XCTAssertEqual(first.findings.map(\.said), ["data"])
        XCTAssertTrue(first.clipped)
        XCTAssertEqual(second.findings, [], "\(second.findings)")
    }

    func testTheCacheKeyChangesWithTheModel() {
        let samples = [Float](repeating: 0.1, count: 100)
        let key = CutListenCache.key(samples, engine: "Bark", model: "a")
        XCTAssertEqual(key, CutListenCache.key(samples, engine: "Bark", model: "a"))
        XCTAssertNotEqual(key, CutListenCache.key(samples, engine: "Bark", model: "b"))
        // Bark's names its pinned revision and its files' checksums.
        XCTAssertTrue(BarkListener.model.contains(BarkModelStore.revision), BarkListener.model)
        XCTAssertTrue(BarkListener.model.contains("v\(CutListen.version)"), BarkListener.model)
    }

    func testMismatchesAwayFromTheJoinArentFindings() {
        // The render's own edges cut words off: only what's near the join counts.
        let join = CutListen.compare(said: words("something in the recent | past and then on"), heard: words("thing in the recent | past and then"), at: 10)
        XCTAssertEqual(join.findings, [])
    }
}
