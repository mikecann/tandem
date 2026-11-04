import XCTest
@testable import TandemCore

/// `PrivateText`: the lines a privacy check flags, from what the Threadbear
/// launch video showed (the text here is made up in the same shapes), and
/// the lines of a coding video it must leave alone.
final class PrivateTextTests: XCTestCase {
    func categories(_ line: String) -> Set<PrivateText.Category> {
        Set(PrivateText.hits(in: line).map(\.category))
    }

    func assertFlags(_ line: String, _ category: PrivateText.Category, file: StaticString = #filePath, line number: UInt = #line) {
        XCTAssertTrue(categories(line).contains(category), "\"\(line)\" should be \(category): \(PrivateText.hits(in: line))", file: file, line: number)
    }

    func assertClean(_ line: String, file: StaticString = #filePath, line number: UInt = #line) {
        XCTAssertEqual(PrivateText.hits(in: line), [], "\"\(line)\" should be clean", file: file, line: number)
    }

    func testTheProjectsOverviewAnswer() {
        assertFlags("Crypto: the hardware wallet arrives Thursday, then sell the rest", .crypto)
        assertFlags("Passport: renewal forms in, photos booked", .identity)
        assertFlags("Travel: flights to Berlin on the 14th", .travel)
        assertFlags("QF 1 departs 4:05pm", .travel)
        assertFlags("Project X: the plan we agreed, company internal", .marked)
    }

    func testAnInterviewersQuotesWaitingForHisOK() {
        assertFlags("He must OK these four before they go public", .marked)
        assertFlags("Needs his approval before release", .marked)
    }

    func testContactDetails() {
        assertFlags("jane.doe@example.com", .email)
        assertFlags("Owner  m+test@convex.dev  Admin", .email)
        // The Convex dashboard's accounts table cuts them short.
        assertFlags("\"jane.doe@gmail.c...", .email)
        assertFlags("\"jane@example....", .email)
        assertFlags("+61 412 345 678", .phone)
        assertFlags("0412 345 678", .phone)
        assertFlags("(415) 555-0134", .phone)
        assertFlags("Call 07700 900123", .phone)
        assertFlags("Deliver to 12 Smith Street, Surry Hills NSW 2010", .address)
        assertFlags("Flat 3, 221B Baker St", .address)
        assertFlags("London SW1A 1AA", .address)
        assertFlags("Collect the keys at 12 Harbour Rise", .address)
    }

    func testReferencesKeysAndMoney() {
        assertFlags("Booking reference: X7KQ2P", .reference)
        assertFlags("Your order #4419023 has shipped", .reference)
        assertFlags("Confirmation code ABC123", .reference)
        assertFlags("CONVEX_DEPLOY_KEY=prod:happy-otter-123|eyJ2MiI6IjFhYjJjM2Q0ZTVmNiJ9", .secret)
        assertFlags("OPENAI_API_KEY=sk-proj-abcdefghijklmnop1234", .secret)
        assertFlags("password: hunter22", .secret)
        assertFlags("Balance $12,450.00", .money)
        assertFlags("Sold for A$479,000", .money)
        assertFlags("Budget $20k", .money)
        assertFlags("BSB 062-000 account 1234 5678", .money)
    }

    func testFamilyAndHealth() {
        assertFlags("on Dad's phone, but not in a store build yet", .personal)
        assertFlags("pick up my son from school", .personal)
        assertFlags("Dentist at 3", .personal)
    }

    func testACodingVideoIsLeftAlone() {
        for line in [
            "import Foundation", "func render(at time: Time) async throws -> CGImage", "Version 2.4.1 (build 1180)", "10:42 AM",
            "Swift Package Manager", "Open the terminal and run bun dev", "npx convex dev", "const order = await ctx.db.get(id)",
            "Recorded 2026-11-03 10:11:23", "Threadbear", "Projects", "4 threads need you", "Merged pull request #88",
            "src/components/Thread.tsx", "https://github.com/get-convex/convex-backend", "case .email: return \"an email\"",
            "Run 12 of 340 passed in 1.2 s",
            // What each thread cost, a path that looks like a token, a PR.
            "Opus 5.5 • $5.51", "$0.37 today", "/var/folders/rh/6mwtgc150llc9g21bybfslpm0000gn/T/coldopen-music",
            "Smaller cloud images (PR #60606) were merged", "Step 2 Open Tab View", "Section 3 Data Row", "bun add convex@latest", "@MainActor final class Viewer"
        ] {
            assertClean(line)
        }
    }
}
