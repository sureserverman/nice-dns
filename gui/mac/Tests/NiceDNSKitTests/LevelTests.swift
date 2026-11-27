import XCTest
@testable import NiceDNSKit

/// The status level (GUI spec section 3) and the check table. KitCheck runs
/// the same table of cases where XCTest is not installed.
final class LevelTests: XCTestCase {
    var ok = Status()
    var stale = Status()

    override func setUpWithError() throws {
        ok = try Status.parse(try fixture("status-installed.tsv"))
        stale = try Status.parse(try fixture("status-stale.tsv"))
    }

    func tweak(_ s: Status, _ f: (inout Status) -> Void) -> Status {
        var c = s
        f(&c)
        return c
    }

    func setVerdict(_ s: inout Status, _ name: String, _ verdict: String) {
        if let i = s.obs.firstIndex(where: { $0.name == name }) { s.obs[i].verdict = verdict }
    }

    func testBundledCheckTableEqualsTheSharedTable() throws {
        let shared = try String(contentsOf: shareURL("checks.tsv"), encoding: .utf8)
        XCTAssertEqual(try Checks.bundledText(), shared)
        XCTAssertEqual(try Checks.loadBundled(), try Checks.parse(shared))
        XCTAssertEqual(Checks.all.count, 18)
    }

    func testEveryFixtureObservationNameResolves() throws {
        for name in ["status-installed.tsv", "status-stale.tsv", "status-update-available.tsv"] {
            let s = try Status.parse(try fixture(name))
            for o in s.obs { XCTAssertNotNil(Checks.info(o.name), "\(name): \(o.name)") }
        }
    }

    func testAnUnknownNameGetsTheOtherRow() {
        let r = Checks.resolve("new-thing")
        XCTAssertEqual(r.group, "other")
        XCTAssertEqual(r.name, "new-thing")
        XCTAssertEqual(r.headline, "new-thing: check failed")
    }

    func testTheLevelTable() {
        XCTAssertEqual(Level.of(ok), .ok)
        XCTAssertEqual(Level.of(stale), .stale)
        XCTAssertEqual(Level.of(.error("x")), .error)
        XCTAssertEqual(Level.of(tweak(ok) { $0.controller.stale = Stale.never; setVerdict(&$0, "dns-owner", "unhealthy") }), .waiting)
        XCTAssertEqual(Level.of(tweak(ok) { $0.controller.stale = Stale.future }), .stale)
        XCTAssertEqual(Level.of(tweak(stale) { setVerdict(&$0, "dns-owner", "unhealthy") }), .stale)
        XCTAssertEqual(Level.of(tweak(ok) { $0.controller.stale = nil }), .ok)
    }

    func testOneFailedBackupRouteIsAttentionNotDown() {
        let s = tweak(ok) {
            setVerdict(&$0, "route:cloudflare-onion", "unhealthy")
            $0.controller.verdict = "FAIL [route:cloudflare-onion]"
            $0.route = Route(id: "cloudflare-exit", generation: "74")
        }
        XCTAssertEqual(Level.of(s), .attention)
        XCTAssertEqual(hero(s, now: 1794251840).title, "DNS works, on a backup route")
    }

    func testDownCases() {
        XCTAssertEqual(Level.of(tweak(ok) { setVerdict(&$0, "dns-owner", "unhealthy") }), .down)
        XCTAssertEqual(Level.of(tweak(ok) { setVerdict(&$0, "runtime", "unhealthy") }), .down)
        XCTAssertEqual(Level.of(tweak(ok) { $0.controller.verdict = "FAIL [chain-resolves]" }), .down)
        XCTAssertEqual(Level.of(tweak(ok) { $0.controller.verdict = "FAIL [x] indeterminate=(chain-resolves)" }), .attention)
        let allRoutes = tweak(ok) { s in for n in s.obs.map(\.name) where n.hasPrefix("route:") { setVerdict(&s, n, "unhealthy") } }
        XCTAssertEqual(Level.of(allRoutes), .down)
        XCTAssertEqual(hero(allRoutes, now: 1794251840).subtitle, "No route through Tor is answering.")
    }

    func testAttentionCases() {
        XCTAssertEqual(Level.of(tweak(ok) { setVerdict(&$0, "filtering", "unhealthy") }), .attention)
        XCTAssertEqual(Level.of(tweak(ok) { setVerdict(&$0, "filtering", "indeterminate") }), .attention)
        XCTAssertEqual(Level.of(tweak(ok) { $0.controller.verdict = "INDETERMINATE [filtering]" }), .attention)
        XCTAssertEqual(Level.of(tweak(ok) { $0.unreadable = [Unreadable(group: "bridges", reason: "x")] }), .attention)
        XCTAssertEqual(Level.of(tweak(ok) { $0.obs.append(Obs(name: "new-thing", verdict: "unhealthy", ms: nil, reason: "r")) }), .attention)
    }

    func testGlyphIsAViewOfTheLevel() {
        XCTAssertEqual(Level.ok.glyph, .green)
        XCTAssertEqual(Level.attention.glyph, .amber)
        XCTAssertEqual(Level.stale.glyph, .amber)
        XCTAssertEqual(Level.down.glyph, .red)
        XCTAssertEqual(Level.error.glyph, .red)
        XCTAssertEqual(Glyph.of(.notInstalled(hint: nil, unreadable: [])), .grey)
        XCTAssertEqual(Level.down.menuSymbol, "xmark.shield.fill")
    }

    func testAgoBuckets() {
        XCTAssertEqual(ago(995, now: 1000), "just now")
        XCTAssertEqual(ago(700, now: 1000), "5 min ago")
        XCTAssertEqual(ago(0, now: 7200), "2 h ago")
        XCTAssertEqual(ago(0, now: 3 * 86_400), "3 days ago")
        XCTAssertEqual(ago(1010, now: 1000), "in the future")
    }
}
