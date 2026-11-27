import XCTest
@testable import NiceDNSKit

/// The Overview builders (GUI spec sections 3 to 7).
final class OverviewTests: XCTestCase {
    var ok = Status()
    var stale = Status()
    var update = Status()
    let now: UInt64 = 1794251840

    override func setUpWithError() throws {
        ok = try Status.parse(try fixture("status-installed.tsv"))
        stale = try Status.parse(try fixture("status-stale.tsv"))
        update = try Status.parse(try fixture("status-update-available.tsv"))
    }

    func tweak(_ s: Status, _ f: (inout Status) -> Void) -> Status {
        var c = s
        f(&c)
        return c
    }

    func setVerdict(_ s: inout Status, _ name: String, _ verdict: String) {
        if let i = s.obs.firstIndex(where: { $0.name == name }) { s.obs[i].verdict = verdict }
    }

    func testHeroCopy() {
        let h = hero(ok, now: now)
        XCTAssertEqual(h.title, "DNS is protected")
        XCTAssertEqual(h.subtitle, "Every lookup leaves through Tor. Checked just now.")
        let st = hero(stale, now: 1794251828 + 942)
        XCTAssertEqual(st.title, "Status is out of date")
        XCTAssertEqual(st.subtitle, "The last check ran 15 min ago. Checks are overdue.")
        XCTAssertFalse("\(st)".contains("stale 942"))
        let off = hero(tweak(stale) { $0.controller.schedule = "stopped" }, now: 1794251828 + 942)
        XCTAssertEqual(off.title, "Automatic checks are off")
        XCTAssertEqual(off.action, .turnOn)
        let owner = hero(tweak(ok) { setVerdict(&$0, "dns-owner", "unhealthy") }, now: now)
        XCTAssertEqual(owner.title, "This computer is not using nice-dns")
        XCTAssertEqual(hero(tweak(ok) { setVerdict(&$0, "filtering", "unhealthy") }, now: now).title, "DNS works, but ads are not blocked")
        let two = tweak(ok) { setVerdict(&$0, "filtering", "unhealthy"); setVerdict(&$0, "local-cache", "unhealthy") }
        XCTAssertEqual(hero(two, now: now).title, "DNS works, 2 checks need attention")
    }

    func testLookupPath() {
        let p = lookupPath(ok)
        XCTAssertEqual(p.nodes.map(\.label), ["This Mac", "Pi-hole", "Unbound", "Tor", "Cloudflare"])
        XCTAssertEqual(p.nodes.map(\.caption), ["Asks", "Blocks ads", "Resolves", "7 bridges", "Onion resolver"])
        XCTAssertEqual(p.nodes.map(\.tone), [.neutral, .ok, .ok, .ok, .ok])
        XCTAssertEqual(p.footer, "Answered in 1.9 s on the Cloudflare onion route. 3 backup routes are ready.")
        let backup = lookupPath(tweak(ok) {
            setVerdict(&$0, "route:cloudflare-onion", "unhealthy")
            $0.route = Route(id: "cloudflare-exit", generation: "74")
        })
        XCTAssertEqual(backup.nodes[4].caption, "Backup: Tor exit")
        XCTAssertTrue(backup.nodes[4].dashedIn)
        XCTAssertEqual(backup.nodes[4].tone, .attention)
        XCTAssertTrue(lookupPath(stale).nodes.allSatisfy { $0.tone == .neutral })
        XCTAssertEqual(pathLine(ok), "Pi-hole › Unbound › Tor › Cloudflare onion")
    }

    func testAttentionRowsAndGroups() {
        XCTAssertTrue(attentionRows(ok).isEmpty)
        let bad = tweak(ok) { setVerdict(&$0, "route:cloudflare-onion", "unhealthy") }
        let rows = attentionRows(bad)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].headline, "The Cloudflare onion route is not answering")
        XCTAssertEqual(rows[0].reason, "rcode NOERROR in 0 ms via tor-socat:18531 as tor.cloudflare-dns.com")
        let groups = checkGroups(ok)
        XCTAssertEqual(groups.map(\.id), ["this-computer", "services", "routes"])
        XCTAssertEqual(groups.map(\.passing), [5, 6, 4])
        XCTAssertTrue(checkGroups(bad)[2].startsExpanded)
        let other = checkGroups(tweak(ok) { $0.obs.append(Obs(name: "new-thing", verdict: "healthy", ms: nil, reason: "fine")) })
        XCTAssertEqual(other.last?.id, "other")
        XCTAssertEqual(other.last?.rows.first?.id, "new-thing")
    }

    func testRepairRowsCollapseTheJournal() {
        let rows = repairRows(ok, now: now)
        XCTAssertEqual(rows.map(\.text), ["Moved back to the Cloudflare onion route", "Moved to the Cloudflare Tor exit route"])
        XCTAssertEqual(rows.map(\.ago), ["1 h ago", "1 h ago"])
        let inProgress = repairRows(tweak(ok) { $0.recent.removeLast() }, now: now)
        XCTAssertEqual(inProgress.first?.text, "Moved back to the Cloudflare onion route (in progress)")
    }

    func testUpdateRowText() {
        XCTAssertEqual(updateRowText(ok, now: now).title, "Not checked yet")
        let a = updateRowText(update, now: 1794251900 + 21 * 60)
        XCTAssertEqual(a.title, "Update available")
        XCTAssertEqual(a.subtitle, "Branch main is now at 0f6a6e7c3d2b, found 21 min ago.")
        XCTAssertEqual(a.button, .install)
        let cur = tweak(ok) { $0.update.result = .current; $0.update.neverChecked = false; $0.update.checkedAt = 1000 }
        XCTAssertEqual(updateRowText(cur, now: 1600).subtitle, "Branch main, checked 10 min ago. nice-dns checks twice a day.")
        XCTAssertEqual(updateRowText(tweak(cur) { $0.update.auto = "stopped" }, now: 1600).subtitle, "Branch main, checked 10 min ago.")
    }

    func testSetupAndActionBarText() {
        XCTAssertEqual(versionRow(ok).title, "Installed 9 Nov 2026")
        XCTAssertEqual(versionRow(update).subtitle, "Branch main at 4b5432d1e0a9")
        XCTAssertEqual(adminSubtitle(ok), "Blocklists and query log at localhost:8880/admin")
        XCTAssertEqual(runningTitle("proxy-haproxy"), "Switching the Tor proxy to haproxy")
        XCTAssertEqual(resultTitle("proxy-socat", lines: []), "The Tor proxy is now socat")
        XCTAssertEqual(elapsedText(192), "3 min 12 s")
    }
}
